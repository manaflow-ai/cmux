//! A peer is a remote acpmux daemon. This daemon is an ACP client of it:
//! it watches the peer's sessions, forwards requests for them, and relays
//! the peer's notifications to local clients. Reconnects with backoff and
//! jitter, forever; a slow peer is `degraded`, a lost one `reconnecting`
//! (`peer_link.rs`).

use crate::no_panic::LockExt;
use crate::peer_link::{
    Backoff, Heard, Link, LinkTimings, PeerState, SilenceBudget, SleepWatch, WAKE_PROBE,
    write_deadline,
};
use crate::rpc::{Message, RpcError, method};
use cmux_json::JsonSet as _;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::{Mutex, Notify, mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

#[path = "peer_carried.rs"]
mod carried;
#[path = "peer_carriers.rs"]
mod carriers;
#[path = "peer_dual.rs"]
mod dual;
#[cfg(test)]
#[path = "peer_dual_tests.rs"]
mod dual_tests;
pub(crate) use carriers::paired_install;
#[path = "peer_carrier.rs"]
mod carrier;
pub use dual::DualStats;
#[path = "peer_features.rs"]
mod features;
#[path = "peer_health.rs"]
mod health;
#[path = "peer_overlay.rs"]
pub(crate) mod overlay;

#[cfg(feature = "hub-carrier")]
#[path = "peer_hub.rs"]
mod hub_path;
#[path = "peer_ssh.rs"]
mod ssh_errors;
#[path = "peer_tokens.rs"]
mod tokens;
#[path = "peer_wanted.rs"]
mod wanted;
use wanted::BackoffWait;
#[path = "peer_runtime.rs"]
mod runtime;
#[path = "peer_runtime_io.rs"]
mod runtime_io;

#[cfg(test)]
#[path = "peer_features_tests.rs"]
mod features_tests;
#[cfg(test)]
#[path = "peer_state_tests.rs"]
mod state_tests;

#[cfg(test)]
#[path = "peer_prompt_tests.rs"]
mod prompt_tests;

#[cfg(test)]
#[path = "peer_restart_tests.rs"]
mod restart_tests;

#[cfg(test)]
#[path = "peer_handshake_tests.rs"]
mod handshake_tests;
#[cfg(test)]
#[path = "peer_liveness_tests.rs"]
mod liveness_tests;
#[cfg(test)]
#[path = "peer_pipeline_tests.rs"]
mod pipeline_tests;

/// Source of `Peer::generation`.
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

/// Instances created before this point cannot repopulate a signed-out account's snapshots.
pub(crate) fn generation_boundary() -> u64 {
    NEXT_GENERATION.load(Ordering::SeqCst)
}

/// A peer watch includes the hub's remote sessions as well as its local ones.
/// A bidirectional pair must not import those already-mirrored rows, or each
/// reconnect/update would prefix the name with another peer hop.
fn is_mirrored_session(summary: &Value) -> bool {
    summary.get("peer").and_then(Value::as_str).is_some()
}

/// The `clientInfo.name` a peer link gives in `initialize`: the daemon it connects to keeps no
/// presence for it, whatever it serves the link as (`server/view.rs`).
pub const CLIENT_NAME: &str = "acpmux-peer";

/// The link's own notice (never a peer's) that a chat it streams was attached again without
/// history after a reconnect: what the peer sent between the links never came, and the hub tells
/// that chat's local clients they lagged (`hub/peers.rs`), so each reads on from its own last
/// record (`_acpmux/lagged {sessionIds}`).
pub const REATTACHED_NOTICE: &str = "_acpmux/peer_reattached";

/// The link's own `_acpmux/attach` of a peer's session `id`: it subscribes and reads no history,
/// and names its byte limit all the same, as `bound_page` does for a client's attach. A peer on an
/// older build reads `limit: 0` as no limit and has none of its own, so it answers with the whole
/// log in one frame, and one of 32.8 MB reset the link with its 29 chats (2026-10-21).
pub fn hidden_attach(id: &str) -> Value {
    json!({"sessionId": id, "limit": 0, "visible": false, "maxBytes": crate::hub::page_bytes(&json!({}))})
}

/// A reconnect attach resumes the mirror after its last delivered event. Keep
/// the same byte bound as normal pages; the peer's `hasMore` response remains
/// authoritative and a later reconnect will request the remainder.
pub fn hidden_attach_after(id: &str, after: u64) -> Value {
    json!({
        "sessionId": id,
        "afterSeq": after,
        "limit": 2000,
        "visible": false,
        "eventStream": true,
        "maxBytes": crate::hub::page_bytes(&json!({})),
    })
}

/// What the hub receives from a peer, tagged with the peer's name and
/// generation so notices from a replaced or removed peer can be dropped.
#[derive(Debug)]
pub enum PeerNotice {
    Connected,
    Disconnected(String),
    /// The remote daemon sent WebSocket Close 1012; its rows stay usable while it restarts.
    Restarting,
    /// Full session list from `_acpmux/watch` or a single `session_changed`: each row's compact
    /// JSON, which the hub parses one row at a time.
    Sessions(Vec<Arc<str>>),
    /// What changed in the peer's list since the link's cursor (`hub/row_log.rs`): the rows
    /// changed, each as its text, and the peer's own ids of the rows that went. The rest stand as
    /// the peer last listed them.
    SessionsPatch {
        rows: Vec<Arc<str>>,
        gone: Vec<String>,
    },
    SessionChanged {
        session: Value,
        kind: String,
        seq: u64,
    },
    Notification {
        method: String,
        params: Value,
        /// The link it came on (`Peer::link_epoch` when it was read).
        link: u64,
    },
}

#[cfg(test)]
impl PeerNotice {
    /// A list of `rows`, each sent as its text, as a link sends it.
    pub(crate) fn sessions_from_values(rows: Vec<Value>) -> Self {
        Self::Sessions(rows.iter().map(row_text).collect())
    }
}

/// The rows of a list as a test reads them.
#[cfg(test)]
pub(crate) fn parse_rows(rows: &[Arc<str>]) -> Vec<Value> {
    rows.iter().map(|row| serde_json::from_str(row).unwrap_or(Value::Null)).collect()
}

/// A row as a list carries it: its compact JSON.
fn row_text(row: &Value) -> Arc<str> {
    Arc::from(serde_json::to_string(row).unwrap_or_default())
}

/// Which list a request's reply is, for the reader (`Peer::watch_key`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ListKey {
    /// No list: the caller takes the reply.
    None,
    /// The handshake's watch list, or a page of it.
    Watch,
    /// The handshake's watch, sent with `initialize` before its reply (`pipelined_key`).
    Pipelined,
}

/// What a daemon lists in `initialize` when the connection state its `initialize` sets (the
/// client's name, whether it lends GitHub) is set before the next request on that connection
/// runs: a peer link may then send `_acpmux/watch` with `initialize`, without waiting for its
/// reply (one round trip less on every reconnect).
pub const HANDSHAKE_PIPELINE_FEATURE: &str = "handshakePipeline";

/// A deliberate restart is not a transport failure and does not advance retry backoff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LinkEnd {
    Stopped,
    Restarting,
    /// The link ended to move to another path of this peer (`peer_carriers.rs`): no outage,
    /// the next connect runs at once and its chats resume from their cursors.
    Switching,
}

pub struct Peer {
    /// The owner of this peer's own tasks (its lent GitHub actions, its attach retries):
    /// `stop` cancels them, and the hub's shutdown joins them (`Peer::close_tasks`).
    scope: cmux_scope::Scope,
    pub name: String,
    /// Unique per `Peer` instance; a replacement under the same name gets a
    /// new one.
    pub generation: u64,
    pub url: String,
    token: Option<String>,
    /// The peer's peer token (`server/peer_auth.rs`), sent with `token`.
    peer_token: Option<String>,
    /// The `ssh -W` process carrying an `ssh://` peer's current connection.
    tunnel: Mutex<Option<tokio::process::Child>>,
    wireguard: std::sync::OnceLock<(Arc<crate::wireguard::Transport>, std::net::SocketAddr)>,
    /// The daemon's hub carrier and the hub `daemonId` this peer's config names (its WireGuard
    /// key), if any (`peer_hub.rs`).
    #[cfg(feature = "hub-carrier")]
    hub_carrier: std::sync::OnceLock<(crate::hub_carrier::HubCarrierSlot, Option<String>)>,
    /// The paired install the cmux link dials for this peer (`peer_carriers.rs`).
    link_host: std::sync::OnceLock<String>,
    /// The peer's config names its own route (`wireguard` or `linkHost`): no overlay path is
    /// found or recalled for it (`peer_overlay.rs`).
    explicit_route: AtomicBool,
    /// The cmux link's socket when known ahead of its registration (tests); else read per dial.
    link_socket: std::sync::OnceLock<std::path::PathBuf>,
    /// The peer's paths and which one carries the link (`peer_paths.rs`), made on first use.
    paths: StdMutex<Option<crate::peer_paths::Paths>>,
    /// The path the live link runs on, while it is open.
    serving: StdMutex<Option<crate::peer_paths::Via>>,
    /// The selector moved the session to another path: the link moves at its next quiet moment.
    switch_wanted: AtomicBool,
    /// The probes of this peer's other paths run (`Peer::start_probes`).
    probing: AtomicBool,
    /// Requests the peer sent this daemon that are still being answered (`Answering`).
    answering: carriers::Answering,
    /// The hub's last-known-good book (`peer_last_good.rs`).
    last_good: std::sync::OnceLock<Arc<crate::peer_last_good::LastGood>>,
    /// While the link's path is in doubt, the probe of another path that gets a copy of each
    /// frame (`peer_dual.rs`).
    shadow: StdMutex<Option<dual::Shadow>>,
    /// The chats whose events either path may deliver, each once by its seq
    /// (`Peer::merge_event`).
    dual_sessions: StdMutex<HashSet<String>>,
    /// The one merger both paths' chat events go through (`peer_dual.rs`).
    dual_merge: Mutex<dual::Merger>,
    /// Whether each path presented the peer token when it last opened: only such paths are the
    /// peer's one principal there, and only they carry dual send (`Peer::dual_wanted`).
    token_paths: StdMutex<HashMap<crate::peer_paths::Via, bool>>,
    /// Chats a load, resume or attach is replaying now, with how many are in flight
    /// (`Peer::replay_start`): read and set under `dual_merge`.
    replaying: StdMutex<HashMap<String, u32>>,
    /// Every link that carries each request still owed an answer, and the epoch it was sent
    /// at (`peer_carried.rs`): what a cancel goes to, what a path switch sends again (a request
    /// bound to its link's connection: a `session/load`, an attach), and which requests the
    /// shadow carries a copy of.
    carried: Arc<StdMutex<carried::Carriers>>,
    /// The link ended to switch paths; its bound requests go again on the next link.
    switched: AtomicBool,
    /// This peer's own part of each dual id, and the frames copied so far.
    dual_nonce: String,
    dual_frames: AtomicU64,
    dual_stats: dual::DualStats,
    /// Outbound frames, each tagged with the link epoch it was admitted on:
    /// `serve` drops one whose link is gone, so it never goes out on the next,
    /// and `fail_link_requests` fails the request it carries as not sent.
    out: mpsc::Sender<Outbound>,
    out_rx: Mutex<Option<mpsc::Receiver<Outbound>>>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    /// The pending keys whose frame `serve` wrote to the live link: when the link drops, only
    /// these may have run on the peer; every other request waiting fails as not sent.
    on_wire: OnWire,
    /// Requests whose client cancelled them after they went to the peer (`request_cancel.rs`):
    /// their late answers are dropped on purpose and logged.
    cancelled: Arc<StdMutex<crate::request_cancel::Cancelled>>,
    /// Accepted prompt identities survive transport loss; reconnect only reads their outcome.
    prompts: Arc<StdMutex<HashMap<String, PendingPrompt>>>,
    /// The handshake finished on the live link (`initialize` and `_acpmux/watch` answered, the
    /// sessions listed): what `connected` reports. False from the moment the link drops.
    pub connected: AtomicBool,
    /// The hub applied this link's session list (its `Connected` notice, which follows the
    /// list): until then a name missing from the rows may only not be listed yet, so a
    /// no-session answer for it is not final (`Hub::no_session_is_final`). False from the
    /// hub's `Disconnected`.
    pub rows_ready: AtomicBool,
    /// One more than the link epoch whose session list the hub applied last (its `Connected`
    /// notice), 0 before any: the rows are that link's ([`Self::rows_current`]).
    rows_link: AtomicU64,
    /// The links whose `Connected` notice is on its way to the hub, oldest first: the hub takes
    /// one with each `Connected` it applies, so it knows which link's list that one follows.
    listed_links: StdMutex<std::collections::VecDeque<u64>>,
    /// The WebSocket is open, handshake or not: only the handshake's own requests go out
    /// while it is open and not `connected`.
    open: AtomicBool,
    pub last_error: StdMutex<Option<String>>,
    /// The carrier, a token refusal and when the state began (`peer_carrier.rs`).
    facts: StdMutex<carrier::LinkFacts>,
    /// Version and build the peer reported at handshake.
    pub remote_version: StdMutex<Option<(String, String)>>,
    /// The build of this peer whose watch list the last handshake read in pages of rows
    /// (`Peer::watch_row_pages`): the next handshake to that build reads it so at once, without
    /// the two whole lists it would refuse (each a full build, 10-15 s on a busy peer).
    row_pages_for: StdMutex<Option<String>>,
    /// The origin the peer serves this daemon as (its initialize reply):
    /// `peer` when it accepted the peer token, `remote` (Web) otherwise.
    served_as: StdMutex<Option<String>>,
    /// The daemon run the peer named in its initialize reply
    /// (`personInstance`): the only run its pending prompts may carry
    /// (`hub/person.rs` (c)). A claim, not a proof.
    person_instance: StdMutex<Option<String>>,
    /// Whether the peer advertised the folder-trust gate in initialize.
    trust_gate: AtomicBool,
    /// This caller's own opt-out for its remote chains there (`PeerConfig`
    /// `vmBoundary`, `hub/vm_boundary.rs`): each `session/new` it forwards
    /// says `vmBoundary: true`.
    vm_boundary: AtomicBool,
    /// This Mac lends the peer its GitHub login (`PeerConfig` `githubBroker`,
    /// `github_broker.rs`), and how many of its actions may run at once: the slots of its name
    /// (`owner_slots`), which a reconnect's new peer shares with the old one.
    github_broker: AtomicBool,
    github_slots: Arc<tokio::sync::Semaphore>,
    /// The link (`link_epoch` + 1; 0 for none) whose handshake's watch was answered by the peer
    /// serving this daemon as a peer: the only link a GitHub action is taken on.
    github_link: AtomicU64,
    /// Wakes this peer's running GitHub actions when lending ends (`githubBroker` off, the link
    /// ended, the peer stopped), so they stop then rather than run on.
    github_revoked: tokio::sync::Notify,
    /// The cmux sign-in the app lent this daemon, for an App token when `gh` has no keyring
    /// login (`github_app_token.rs`); set once by the hub.
    github_app: std::sync::OnceLock<Arc<crate::github_app_token::AppLease>>,
    /// Whether the peer takes `_acpmux/file_put` (`hub/file_uploads.rs`).
    file_put: AtomicBool,
    /// It lists `filePutChunks` (`hub/file_uploads.rs`).
    file_put_chunks: AtomicBool,
    /// Whether the peer serves `_acpmux/media_open` and `_acpmux/media_range` (`hub/media_read.rs`).
    media_read: AtomicBool,
    /// Bumped each time a connection to the peer ends (and at `stop`): what the peer kept for
    /// the connection, like its media handles, went with it (`server/media_forward.rs`).
    link_epoch: Arc<AtomicU64>,
    /// Whether the peer serves `_acpmux/subagent_transcript` (`hub/subagent_transcript.rs`).
    subagent_transcript: AtomicBool,
    /// Whether the peer serves `_acpmux/native_history` (`hub/native_history.rs`).
    native_history: AtomicBool,
    /// The peer lists `sessionAuth` (`hub/session_auth.rs`).
    session_auth: AtomicBool,
    /// The features the peer listed at its last handshake (`lists`).
    features: StdMutex<Vec<String>>,
    /// One more than the link epoch whose handshake listed `sessionResume`
    /// (`server/requests/session_open.rs`); 0 when the last handshake did not.
    session_resume_link: AtomicU64,
    /// The peer lists `session-messages-v1`: its prompt acceptances name the message they kept.
    session_messages: AtomicBool,
    /// The peer lists `personStop` (`server/requests/person_stop.rs`).
    pub(crate) person_stop: AtomicBool,
    /// The peer token was held back: the transport is plain `ws://` to a
    /// host that is not loopback (`carries_peer_token`). Logged once.
    withheld: AtomicBool,
    /// The peer token this connection presented (`stale_token`).
    presented: StdMutex<Option<String>>,
    /// The remote's tokens from the last ssh read, for the next connect (`peer_tokens.rs`).
    read_tokens: tokens::TokenCache,
    /// A link of this peer was connected once: a later read runs before its tunnel opens.
    linked_once: AtomicBool,
    /// An ssh attempt timed out in the banner exchange since the link was last ready: the host
    /// is slow, and its attempts get the long connect deadline (`ssh_connect_secs`).
    slow_banner: AtomicBool,
    /// From the WebSocket opening until `stale_token` cleared it: callers'
    /// requests and notifications are refused, so none goes out on a link
    /// that is dropped to reconnect as a peer, or waits to go out on the next.
    admitting: AtomicBool,
    /// The chats local clients want streamed, each with the ticket of its latest mark: a client
    /// that relies on a mark already there renews it, so an attach refused meanwhile does not
    /// take it away (`attach_hidden`).
    attached: StdMutex<HashMap<String, u64>>,
    marks: AtomicU64,
    /// Per attached chat, the greatest event sequence local clients have already received: a
    /// reconnect asks the peer for records after it instead of attaching with `limit: 0` (which
    /// silently loses the gap between links). A chat marked in `attached` with no cursor has no
    /// baseline yet, and the next link attaches it without history as before.
    cursors: StdMutex<HashMap<String, u64>>,
    /// The marked chats whose cursor a page settled ([`Self::note_baseline`]): for these a
    /// cursor of 0 is a baseline too (the peer's chat held nothing yet, as a new Cloud chat
    /// does), so a reconnect replays them from it instead of attaching them without history.
    baselined: StdMutex<HashSet<String>>,
    /// The chats whose attach failed on a live link and is being tried again on that link
    /// ([`Self::retry_attach`]): one retry loop per chat.
    attach_retries: StdMutex<HashSet<String>>,
    /// Highest live sequence observed while a session is being replayed. The
    /// payload is intentionally not retained: the next bounded page fetches it
    /// from the peer journal, so memory cannot grow with a long turn.
    replay_highwater: StdMutex<HashMap<String, u64>>,
    /// Per chat replayed on this link, the last sequence its replay delivered. A live frame the
    /// peer queued before the final page can still be read after it: one at or below this is a
    /// repeat and dropped. It lasts only until the chat's first newer live frame, or the next
    /// request about the chat (a `session/load` sends its history again, which is no repeat).
    replay_tail: StdMutex<HashMap<String, u64>>,
    notices: mpsc::Sender<(String, u64, PeerNotice)>,
    stop: AtomicBool,
    /// A replacement requested now attempts immediately, even if its cache is parked.
    retry_immediately: AtomicBool,
    /// Wakes `serve` so `stop` closes the live connection.
    stop_signal: Notify,
    /// Broadcasts explicit stop/replacement to callers waiting for a reconnect.
    stop_changed: tokio::sync::watch::Sender<bool>,
    /// A client waits on the peer: reconnects come within seconds (`peer_wanted.rs`).
    wanted: wanted::Wanted,
    /// Counts connect attempts that settled (ready or failed), bumped by the
    /// hub once it applied the outcome, so a caller can await the next one.
    settled: tokio::sync::watch::Sender<u64>,
    /// Connected, degraded or reconnecting, and since when (`peer_link.rs`).
    link: StdMutex<Link>,
    /// Where each change of `state()` goes once the hub runs the peer (`report_states`).
    states: StdMutex<Option<Arc<crate::peer_states::PeerStates>>>,
    timings: LinkTimings,
    /// How long this peer's links may stay silent: longer for one that answers late. Made from
    /// `timings` at the first link, so a test can set them first.
    silence: StdMutex<Option<SilenceBudget>>,
    /// When the hub last saved this peer's sessions (`hub/peer_cache.rs`).
    pub(crate) cache_saved_at: AtomicU64,
    /// The last successful cache write still records an outage that Connected must clear.
    pub(crate) cache_saved_outage: AtomicBool,
    /// At most one non-final cache writer may be queued for this peer.
    pub(crate) cache_write_pending: AtomicBool,
    /// Monotonic notice sequence; a cache is dirty until this reaches the flushed sequence.
    pub(crate) cache_dirty_seq: AtomicU64,
    /// The notice sequence included in the most recent successful cache write.
    pub(crate) cache_flushed_seq: AtomicU64,
    /// Version of this peer's remote rows, bumped by every row mutation or purge.
    pub(crate) remote_rows_epoch: AtomicU64,
    /// Local purges that are fenced against an in-flight full-list projection. Cleared when the
    /// next list wins its swap; a later list may then reflect a peer-side recreation.
    pub(crate) remote_purge_fences: StdMutex<HashSet<String>>,
    /// This instance's outage outlived its grace and its rows went unreachable
    /// (`hub/peer_grace.rs`). Kept here, not in the notice loop, so it goes with the instance.
    pub(crate) outage_ended: AtomicBool,
    /// The sessions this instance's link purged before its list (`hub/purge_tombstones.rs`).
    pub(crate) purge_tombstones: crate::hub::purge_tombstones::PurgeTombstones,
    /// The peer's last `_acpmux/host_health` and when it came (`peer_health.rs`).
    health: StdMutex<Option<(u64, Value)>>,
    /// An ask for it is out.
    health_asking: AtomicBool,
    /// The pending key of the handshake's `_acpmux/watch`, or of a page of its list
    /// (`watch_request_on`). The reader publishes that reply's list itself, before it reads the
    /// next frame, so a `session_changed` the peer sent after the reply reaches the hub after
    /// the list, never before it. A list in pages is published once, whole, after its last.
    watch_key: StdMutex<Option<String>>,
    /// The pending key of a watch sent with `initialize`, before its reply
    /// (`Peer::pipelined_watch`), until the handshake read that reply: the reader holds the
    /// watch's reply, and the changes after it, until then, and drops them when the
    /// initialize reply says the watch was not the one to ask.
    pipelined_key: StdMutex<Option<String>>,
    /// Whether the last handshake's peer listed [`HANDSHAKE_PIPELINE_FEATURE`]; kept past the
    /// link's end, unlike `features`, for the next link's handshake.
    pipelines: AtomicBool,
    /// Whether the peer follows its list from a cursor (`hub/row_log.rs` `CAPABILITY`), and the
    /// position of its list the hub holds (`listEpoch`, `listSeq`): set once a whole list or a
    /// follow is read, moved on by each `session_changed`. The next link asks for what changed
    /// after it, not the list.
    list_follow: AtomicBool,
    list_cursor: StdMutex<Option<(String, u64)>>,
    /// Whether the list the cursor is in was read with tools: a follow is asked for the same way.
    cursor_tools: AtomicBool,
    /// This link's messages from the peer so far: the bytes of their frames, and of their JSON
    /// text (more when the peer compresses them, `frame_compress.rs`).
    received: ReceivedBytes,
}

/// What a link received: frame bytes and JSON text bytes, from its open.
#[derive(Debug, Default)]
pub struct ReceivedBytes {
    frames: AtomicU64,
    text: AtomicU64,
}

impl ReceivedBytes {
    fn reset(&self) {
        self.frames.store(0, Ordering::SeqCst);
        self.text.store(0, Ordering::SeqCst);
    }

    fn add(&self, frame: usize, text: usize) {
        let n = |b: usize| u64::try_from(b).unwrap_or(u64::MAX);
        self.frames.fetch_add(n(frame), Ordering::SeqCst);
        self.text.fetch_add(n(text), Ordering::SeqCst);
    }

    /// (frame bytes, text bytes) since the link opened.
    pub fn read(&self) -> (u64, u64) {
        (self.frames.load(Ordering::SeqCst), self.text.load(Ordering::SeqCst))
    }
}

impl Peer {
    /// Reads every page after the watch reply `first` with `_acpmux/sessions {cursor}` on link
    /// `link`; the reader gathers their rows (`watch_key`). A cursor given twice, or one that is
    /// not a string, is an error that ends the handshake, never a loop or a short list.
    async fn watch_pages(&self, first: Value, tools: bool, link: u64) -> Result<(), RpcError> {
        let (mut seen, mut next) = (HashSet::new(), page_cursor(&first)?);
        while let Some(cursor) = next {
            if !seen.insert(cursor.clone()) {
                let why = format!("the peer gave the watch page cursor {cursor:?} twice");
                return Err(RpcError::internal(why));
            }
            let params = json!({"withTools": tools, "cursor": cursor});
            let page = self.watch_request_on(method::MUX_SESSIONS, params, link).await?;
            next = page_cursor(&page)?;
        }
        Ok(())
    }
}

impl Peer {
    /// Reads the watch list on link `link` in pages of a count of rows, without tools:
    /// `_acpmux/watch {limit}`, then `_acpmux/sessions {limit, cursor}` (the keyset pages every
    /// peer serves, those from before #28182 too). The reader gathers their rows (`watch_key`).
    /// Each page after the first is sized from the one before to about [`WATCH_PAGE_BYTES`], so
    /// a list over the limit takes a few pages: such a peer builds its list again for most
    /// pages while its sessions change, four back to back and then one per pace window (up to
    /// 15 s), and many small pages would outlast the handshake. A page refused as too large is
    /// asked for again with half the rows. A cursor given twice, or one that is not a string,
    /// ends the handshake.
    async fn watch_row_pages(&self, link: u64) -> Result<(), RpcError> {
        let (mut rows, mut cursor, mut seen) = (WATCH_FIRST_ROWS, None::<String>, HashSet::new());
        loop {
            let (m, params) = match &cursor {
                None => {
                    (method::MUX_WATCH, json!({"enabled": true, "withTools": false, "limit": rows}))
                }
                Some(after) => (
                    method::MUX_SESSIONS,
                    json!({"withTools": false, "limit": rows, "cursor": after}),
                ),
            };
            let page = match self.watch_paced(m, params, link).await {
                Err(e) if too_large(&e) && rows > 1 => {
                    rows /= 2;
                    continue;
                }
                page => page?,
            };
            let Some(next) = page_cursor(&page)? else { return Ok(()) };
            if !seen.insert(next.clone()) {
                let why = format!("the peer gave the watch page cursor {next:?} twice");
                return Err(RpcError::internal(why));
            }
            cursor = Some(next);
            rows = next_page_rows(&page).unwrap_or(rows);
        }
    }

    /// The first `_acpmux/watch` a handshake asks for, and whether with tools, as the link knows
    /// the peer now: what changed after the cursor of the list the hub holds when the peer
    /// serves this daemon as a peer and follows its list (`hub/row_log.rs`), else the whole list
    /// without tools; None when the list is read in pages of rows (`build` needed them last
    /// time).
    fn first_watch(&self, build: Option<&String>) -> Option<(Value, bool)> {
        let watch = |tools: bool| json!({"enabled": true, "withTools": tools});
        let follows =
            self.list_follow.load(Ordering::SeqCst) && self.served_as().as_deref() == Some("peer");
        let cursor = follows.then(|| self.list_cursor.lock_or_recover().clone()).flatten();
        if let Some((epoch, after)) = cursor {
            let tools = self.cursor_tools.load(Ordering::SeqCst);
            let mut asked = watch(tools);
            asked.set("afterSeq", json!(after));
            asked.set("listEpoch", Value::String(epoch));
            return Some((asked, tools));
        }
        let row_pages = build.is_some() && self.row_pages_for.lock_or_recover().as_ref() == build;
        (!row_pages).then(|| (watch(false), false))
    }

    /// The watch a handshake sends with `initialize`, before its reply: the one it would ask for
    /// after it, as the last link's `initialize` said (it served this daemon as a peer, from a
    /// daemon that lists [`HANDSHAKE_PIPELINE_FEATURE`]). None on a first link, or when the last
    /// one said otherwise.
    fn pipelined_watch(&self) -> Option<Value> {
        if !self.pipelines.load(Ordering::SeqCst) || self.served_as().as_deref() != Some("peer") {
            return None;
        }
        let build = self.remote_build().filter(|b| b != "unknown");
        self.first_watch(build.as_ref()).map(|(params, _)| params)
    }

    /// Whether the watch sent with `initialize` (`sent`) is the one to ask for now that its reply
    /// was read; settles it for the reader either way. One that is not is never published: its
    /// key is no longer the list's.
    fn keep_pipelined(&self, sent: Option<&Value>, build: Option<&String>) -> bool {
        let kept = sent.is_some_and(|sent| {
            self.pipelined_watch().is_some()
                && self.first_watch(build).is_some_and(|(asked, _)| asked == *sent)
        });
        let key = self.pipelined_key.lock_or_recover().take();
        if !kept && let Some(key) = key {
            self.watch_key.lock_or_recover().take_if(|k| *k == key);
        }
        kept
    }

    /// The first watch's answer: the pipelined one's when it was kept (`sent`), asked for
    /// again after the pause a pacing peer asks for; else asked for now.
    async fn watch_first(
        &self,
        params: Value,
        link: u64,
        sent: Option<Result<Value, RpcError>>,
    ) -> Result<Value, RpcError> {
        match sent {
            Some(Err(e)) if paced(&e).is_some() => {
                tokio::time::sleep(paced(&e).unwrap_or_default()).await;
                self.watch_paced(method::MUX_WATCH, params, link).await
            }
            Some(answer) => answer,
            None => self.watch_paced(method::MUX_WATCH, params, link).await,
        }
    }

    /// [`Self::watch_request_on`], asked again after the wait a peer's `list.paced` refusal
    /// names: a daemon from before its pacer was deleted (W4, 2026-11-12) refuses a list it would
    /// make wait more than 30 s. This one never refuses. The handshake's deadline bounds the
    /// retries.
    async fn watch_paced(&self, m: &str, params: Value, link: u64) -> Result<Value, RpcError> {
        loop {
            match self.watch_request_on(m, params.clone(), link).await {
                Err(e) if paced(&e).is_some() => {
                    tokio::time::sleep(paced(&e).unwrap_or_default()).await;
                }
                answer => return answer,
            }
        }
    }
}

/// The longest a handshake reading its watch list in pages may take in all: each page moves its
/// deadline on by the handshake's own (`LinkTimings::handshake`), never past this.
const HANDSHAKE_MOST: Duration = Duration::from_secs(300);

/// The rows of the first watch page read by count (`Peer::watch_row_pages`): about 5 MB
/// without tools at the incident's row sizes (2.3 KB).
const WATCH_FIRST_ROWS: u64 = 2048;

/// The bytes a later watch page read by count is sized to: about half the message limit, so a
/// page whose rows grow meanwhile still fits.
const WATCH_PAGE_BYTES: u64 = 8 << 20;

/// The most rows a watch page read by count asks for.
const WATCH_MAX_ROWS: u64 = 1 << 16;

/// Why a handshake that ran out of time failed.
fn timed_out(started: tokio::time::Instant) -> String {
    format!("handshake timed out after {}s", started.elapsed().as_secs())
}

/// The rows of the next page, from `page`'s: as many as fit in [`WATCH_PAGE_BYTES`] at its
/// mean row size. None for a page with no rows.
fn next_page_rows(page: &Value) -> Option<u64> {
    let rows = u64::try_from(page.get("sessions")?.as_array()?.len()).ok().filter(|n| *n > 0)?;
    let bytes = u64::try_from(serde_json::to_vec(page).ok()?.len()).ok()?;
    let fit = rows.saturating_mul(WATCH_PAGE_BYTES).checked_div(bytes)?;
    Some(fit.clamp(1, WATCH_MAX_ROWS))
}

/// The longest wait a peer's `list.paced` reply may ask of a watch request before it is asked again.
const WATCH_PACED_MAX: Duration = Duration::from_secs(30);

/// How long to wait before asking again, when `e` is a peer's `list.paced` refusal.
fn paced(e: &RpcError) -> Option<Duration> {
    let data = e.data.as_ref()?;
    (data.get("reason").and_then(Value::as_str) == Some("list.paced")).then(|| {
        let ms = data.get("retryAfterMs").and_then(Value::as_u64).unwrap_or(1_000);
        Duration::from_millis(ms).min(WATCH_PACED_MAX)
    })
}

/// A watch or page reply's `nextCursor`: none when absent or null, an error when not a string.
fn page_cursor(reply: &Value) -> Result<Option<String>, RpcError> {
    match reply.get("nextCursor") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(cursor)) => Ok(Some(cursor.clone())),
        Some(other) => Err(RpcError::internal(format!("the peer gave the page cursor {other}"))),
    }
}

/// Whether `e` is a reply too large to send (`RpcError::too_large`).
fn too_large(e: &RpcError) -> bool {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
        == Some("message.too_large")
}

/// ssh's ConnectTimeout (`Peer::ssh_connect_secs`).
const SSH_CONNECT_SECS: u64 = 3;
const SSH_CONNECT_SLOW_SECS: u64 = 20;

/// An attempt still connecting this long after it began is begun again when a client asks for
/// the peer (`Peer::connect_once`): one sent into a network that was down waits out TCP's
/// retransmit backoff, while a new one connects at once.
const RESTART_AFTER: Duration = Duration::from_secs(1);

/// How long a tunnel opened beside the token read may wait for it (`Peer::connect_once`).
const EARLY_TUNNEL_FOR: Duration = Duration::from_secs(3);

/// The waits before each reread of a remote that has no peer token yet
/// (`Peer::remote_tokens_settled`, `Peer::stale_token`).
const TOKEN_REREADS: [Duration; 3] =
    [Duration::from_secs(1), Duration::from_secs(2), Duration::from_secs(4)];

/// One frame queued for the link: the link epoch it was admitted on, and the pending key of
/// the request it carries (None for a notification).
struct Outbound {
    epoch: u64,
    key: Option<String>,
    line: String,
}

/// A request or notification that found no room in the queue before its deadline: the link
/// is stalled. It was not sent, so retrying it never runs it twice.
fn queue_timed_out(name: &str, waited: Duration) -> RpcError {
    RpcError::internal(format!(
        "peer_unreachable: the link to {name} took no new request for {}s; the request was not sent; run `acpmux machine ls` and retry",
        waited.as_secs()
    ))
    .with_data(json!({
        "reason": "peer_unreachable",
        "retryable": true,
        "try": "acpmux machine ls",
        "detail": "the request was not sent",
        "peer": name,
        "queuedMs": u64::try_from(waited.as_millis()).unwrap_or(u64::MAX),
    }))
}

/// The requests whose answer waits on the agent's turn, never on the link alone.
pub(crate) fn waits_on_turn(m: &str) -> bool {
    matches!(m, method::SESSION_PROMPT | method::MUX_WAIT)
}

fn connect_timed_out(after: Duration) -> String {
    format!("connect timed out after {}s", after.as_secs())
}

fn stopped_reading(budget: Duration) -> String {
    format!("peer stopped reading (a send waited {}s)", budget.as_secs())
}

/// Why a write that timed out (`write_deadline`) dropped the link: a wake probe whose deadline
/// passed, else the send budget.
fn write_late(budget: Duration, wake_probe: Option<tokio::time::Instant>) -> String {
    match wake_probe {
        Some(probe) if probe <= tokio::time::Instant::now() => {
            format!("no answer {}s after this computer woke", WAKE_PROBE.as_secs())
        }
        _ => stopped_reading(budget),
    }
}

/// The default WebSocket port of an `ssh://` peer.
pub const SSH_PEER_PORT: u16 = 47811;

/// An `ssh://` peer's ssh destination (`[user@]host`) and remote port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshTarget {
    pub destination: String,
    pub port: u16,
}

/// Parse and check `ssh://[user@]host[:port]`. Every part reaches an ssh or
/// scp argv, and a peer URL can come from any WebSocket token holder
/// (`_acpmux/peer_add`), so a part that ssh could read as an option or that
/// carries anything but a name is refused: an empty user or host, one that
/// starts with `-` (`-oProxyCommand=...`, `-F...`), whitespace or a control
/// character, an `@` in the host, and a port that is not a plain number in
/// 1..=65535. The reason never quotes the value (it may hold a secret).
pub fn ssh_target(url: &str) -> Result<SshTarget, &'static str> {
    let rest = url.strip_prefix("ssh://").ok_or("not an ssh:// url")?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let (user, hostport) = match rest.split_once('@') {
        Some((user, hostport)) => (Some(user), hostport),
        None => (None, rest),
    };
    let bracketed = hostport.starts_with('[') && hostport.ends_with(']');
    let (host, port) = match hostport.rsplit_once(':') {
        Some((host, port)) if !bracketed => {
            let plain = !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit());
            let port = port.parse::<u16>().ok().filter(|p| plain && *p > 0);
            (host, port.ok_or("the port is not a plain number")?)
        }
        _ => (hostport, SSH_PEER_PORT),
    };
    check_ssh_part(host, "host")?;
    if host.contains('@') {
        return Err("the host has an @");
    }
    let destination = match user {
        Some(user) => {
            check_ssh_part(user, "user")?;
            format!("{user}@{host}")
        }
        None => host.to_owned(),
    };
    Ok(SshTarget { destination, port })
}

/// A peer's canonical endpoint (hq plans/cmux-next/acpmux-one-daemon.md):
/// `ssh://HOST`, the ssh config's user and the machine's one daemon on
/// [`SSH_PEER_PORT`]. Some(it) when `url` is an `ssh://` URL that names a user
/// or another port, so a listing can say where it should point; None when it
/// already is canonical or is not an `ssh://` peer. It never re-points one.
pub fn canonical_endpoint(url: &str) -> Option<String> {
    let t = ssh_target(url).ok()?;
    let host = t.destination.rsplit_once('@').map_or(t.destination.as_str(), |(_, h)| h);
    (t.destination != host || t.port != SSH_PEER_PORT).then(|| format!("ssh://{host}"))
}

fn check_ssh_part(part: &str, what: &'static str) -> Result<(), &'static str> {
    let host = what == "host";
    if part.is_empty() {
        return Err(if host { "the host is empty" } else { "the user is empty" });
    }
    if part.starts_with('-') {
        return Err(if host {
            "the host starts with - (an ssh option)"
        } else {
            "the user starts with - (an ssh option)"
        });
    }
    // Names only: a user's ssh_config may put %h or %r into a shell command
    // (ProxyCommand, Match exec), and scp reads `/` and `:` itself.
    let name = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-');
    let plain = if let Some(inner) = part.strip_prefix('[').and_then(|p| p.strip_suffix(']')) {
        // A bracketed IPv6 address (scp strips the brackets).
        host && !inner.is_empty()
            && inner.bytes().all(|b| b.is_ascii_hexdigit() || matches!(b, b':' | b'.' | b'%'))
    } else {
        part.bytes().all(name)
    };
    if !plain {
        return Err(if host {
            "the host is not a plain name or [IPv6] address"
        } else {
            "the user is not a plain name"
        });
    }
    Ok(())
}

/// `ssh ... -W 127.0.0.1:PORT -- DESTINATION`: the `--` ends ssh's options,
/// so the destination is never read as one.
/// `connect_secs` is ssh's ConnectTimeout (`Peer::ssh_connect_secs`).
pub fn tunnel_argv(destination: &str, port: u16, connect_secs: u64) -> Vec<String> {
    let mut argv: Vec<String> = [
        "-o",
        "BatchMode=yes",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    argv.push(format!("ConnectTimeout={connect_secs}"));
    argv.push("-W".into());
    argv.push(format!("127.0.0.1:{port}"));
    argv.push("--".into());
    argv.push(destination.to_owned());
    argv
}

/// `ssh ... -- DESTINATION '<fixed command>'`: the remote config, a NUL,
/// then the remote daemon's peer token of this launch, if it has one.
pub fn read_config_argv(destination: &str, connect_secs: u64) -> Vec<String> {
    let connect = format!("ConnectTimeout={connect_secs}");
    [
        "-o",
        "BatchMode=yes",
        "-o",
        connect.as_str(),
        "--",
        destination,
        "cat ~/.acpmux/config.json; printf '\\0'; cat ~/.acpmux/run/peer.token 2>/dev/null",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// Whether a direct (not ssh) peer URL may carry the peer token: `wss://`,
/// or `ws://` to a loopback host. Over plain `ws://` to any other host the
/// token would cross a network in clear, and the peer serves it as Web
/// anyway (`server/peer_auth.rs`). An `ssh://` peer connects through a
/// tunnel to the remote's loopback, so it always may.
pub fn carries_peer_token(url: &str) -> bool {
    let Ok(uri) = url.parse::<tokio_tungstenite::tungstenite::http::Uri>() else { return false };
    let host = uri.host().unwrap_or_default().trim_start_matches('[').trim_end_matches(']');
    match uri.scheme_str() {
        Some("wss") => true,
        Some("ws") => {
            host.eq_ignore_ascii_case("localhost")
                || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.to_canonical().is_loopback())
        }
        _ => false,
    }
}

/// The output of `read_config_argv`: the config bytes and the peer token
/// (None when absent or not a 64-digit hex token).
pub fn split_remote_read(out: &[u8]) -> (&[u8], Option<String>) {
    let Some(at) = out.iter().position(|b| *b == 0) else { return (out, None) };
    let (config, rest) = out.split_at_checked(at).unwrap_or((out, &[]));
    (config, peer_token_text(rest.get(1..).unwrap_or_default()))
}

/// A daemon's `run/peer.token` file: the token, trimmed, when it is 64 hex
/// digits; None for anything else.
pub fn peer_token_text(bytes: &[u8]) -> Option<String> {
    let token = std::str::from_utf8(bytes).ok().map(str::trim);
    token.filter(|t| t.len() == 64 && t.bytes().all(|b| b.is_ascii_hexdigit())).map(str::to_owned)
}

/// What a peer reads from another daemon's `~/.acpmux/config.json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDaemonConfig {
    /// The dashboard token (`websocket.token`).
    pub token: String,
    /// The WebSocket listen address (`websocket.listen`), when set.
    pub listen: Option<String>,
}

/// Why [`remote_daemon_config`] found no token. The reason never quotes
/// the file (it holds a secret).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteConfigError {
    /// Not JSON.
    Unreadable,
    /// JSON without a `websocket.token` string.
    NoToken,
}

/// Parse another daemon's `config.json` bytes, as an `ssh://` peer reads
/// them at each connect and the Cloud link's peer bridge reads them over
/// the remote tunnel.
pub fn remote_daemon_config(config: &[u8]) -> Result<RemoteDaemonConfig, RemoteConfigError> {
    let cfg: Value = serde_json::from_slice(config).map_err(|_| RemoteConfigError::Unreadable)?;
    let token = cfg
        .pointer("/websocket/token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .ok_or(RemoteConfigError::NoToken)?
        .to_owned();
    let listen = cfg.pointer("/websocket/listen").and_then(Value::as_str).map(str::to_owned);
    Ok(RemoteDaemonConfig { token, listen })
}

type PendingReplies = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>;

/// `Peer::on_wire`.
type OnWire = Arc<StdMutex<HashSet<String>>>;

#[derive(Clone)]
struct PendingPrompt {
    session: String,
    prompt: String,
    accepted: bool,
}

/// Removes a request's pending entry when `Peer::request` returns or is
/// dropped; the reader has already removed it when the reply came.
struct ForgetPending {
    pending: PendingReplies,
    on_wire: OnWire,
    prompts: Arc<StdMutex<HashMap<String, PendingPrompt>>>,
    key: Option<String>,
    /// Set once its frame is queued to the peer: what a cancel of it needs.
    cancel: Option<carried::PeerCancel>,
    /// Its carriers (`peer_carried.rs`): its entry goes with it.
    carried: Arc<StdMutex<carried::Carriers>>,
}

impl Drop for ForgetPending {
    fn drop(&mut self) {
        let Some(key) = self.key.take() else { return };
        self.on_wire.lock_or_recover().remove(&key);
        self.prompts.lock_or_recover().remove(&key);
        // Its client cancelled it: its entry goes first, and the peer hears the cancel on every
        // link that still carries it, only if it still owed the answer (review F1 of #41285).
        // An answer that took the entry first went to a waiter that is gone, and is dropped as
        // late. The cancel takes its carriers itself (`PeerCancel::cancel`).
        let cancel = self.cancel.take().filter(|_| crate::request_cancel::requested());
        let carried = self.carried.clone();
        let forget = move |map: &mut HashMap<String, _>| {
            let owed = map.remove(&key).is_some();
            match cancel {
                Some(cancel) => cancel.cancel(&key, owed),
                None => carried.lock_or_recover().forget(&key),
            }
        };
        if let Ok(mut map) = self.pending.try_lock() {
            forget(&mut map);
        } else if let Ok(rt) = tokio::runtime::Handle::try_current() {
            let pending = self.pending.clone();
            rt.spawn(async move {
                forget(&mut *pending.lock().await);
            });
        }
    }
}

/// `url` without its `token=` query items, and the first one's value.
pub fn lift_query_token(url: &str) -> (String, Option<String>) {
    let (rest, fragment) = url.split_once('#').map_or((url, None), |(r, f)| (r, Some(f)));
    let Some((base, query)) = rest.split_once('?') else { return (url.to_owned(), None) };
    let mut token = None;
    let kept: Vec<&str> = query
        .split('&')
        .filter(|item| match item.strip_prefix("token=") {
            Some(t) => {
                if token.is_none() && !t.is_empty() {
                    token = Some(t.to_owned());
                }
                false
            }
            None => true,
        })
        .collect();
    let mut out = base.to_owned();
    if !kept.is_empty() {
        out.push('?');
        out.push_str(&kept.join("&"));
    }
    if let Some(f) = fragment {
        out.push('#');
        out.push_str(f);
    }
    (out, token)
}

#[cfg(test)]
#[path = "peer_attach_tests.rs"]
mod attach_tests;

#[cfg(test)]
mod remote_config_tests {
    use super::*;

    #[test]
    fn a_query_token_moves_out_of_a_peer_url() {
        assert_eq!(
            lift_query_token("ws://h:1/?token=abc"),
            ("ws://h:1/".to_owned(), Some("abc".to_owned()))
        );
        assert_eq!(
            lift_query_token("ws://h:1/acp?x=1&token=abc&y=2"),
            ("ws://h:1/acp?x=1&y=2".to_owned(), Some("abc".to_owned()))
        );
        assert_eq!(lift_query_token("ws://h:1/"), ("ws://h:1/".to_owned(), None));
        assert_eq!(
            lift_query_token("ws://h:1/?mytoken=a"),
            ("ws://h:1/?mytoken=a".to_owned(), None)
        );
    }

    #[test]
    fn the_links_own_attach_names_its_byte_limit() {
        let attach = hidden_attach("s");
        assert_eq!(attach["sessionId"], "s");
        assert_eq!(attach["limit"], 0);
        assert_eq!(attach["visible"], false);
        assert_eq!(attach["maxBytes"], crate::hub::page_bytes(&json!({})));
    }

    #[test]
    fn a_remote_config_gives_its_token_and_listen_address() {
        let cfg = br#"{"websocket": {"listen": "127.0.0.1:47811", "token": "abc"}}"#;
        let parsed = remote_daemon_config(cfg).unwrap();
        assert_eq!(parsed.token, "abc");
        assert_eq!(parsed.listen.as_deref(), Some("127.0.0.1:47811"));
        let no_listen = remote_daemon_config(br#"{"websocket": {"token": "abc"}}"#).unwrap();
        assert_eq!(no_listen.listen, None);
    }

    #[test]
    fn a_remote_config_without_a_token_is_refused_without_quoting_it() {
        assert_eq!(remote_daemon_config(b"not json"), Err(RemoteConfigError::Unreadable));
        for cfg in [
            &br#"{}"#[..],
            br#"{"websocket": {"listen": "x"}}"#,
            br#"{"websocket": {"token": ""}}"#,
        ] {
            assert_eq!(remote_daemon_config(cfg), Err(RemoteConfigError::NoToken));
        }
    }

    #[test]
    fn a_peer_token_is_64_hex_digits() {
        let good = "a".repeat(64);
        assert_eq!(peer_token_text(format!("{good}\n").as_bytes()), Some(good.clone()));
        assert_eq!(peer_token_text(b""), None);
        assert_eq!(peer_token_text("g".repeat(64).as_bytes()), None);
        assert_eq!(peer_token_text("a".repeat(63).as_bytes()), None);
        let read = [br#"{"websocket":{"token":"t"}}"#.as_slice(), b"\0", good.as_bytes()].concat();
        assert_eq!(split_remote_read(&read).1, Some(good));
    }
}

#[cfg(test)]
#[path = "peer_briefs_tests.rs"]
mod briefs_tests;

#[cfg(test)]
mod link_epoch_tests {
    use super::*;

    /// A prompt admitted on a link that went down before it was registered fails at once: the
    /// next link drops its frame, and a prompt has no deadline, so it would wait for good.
    #[tokio::test]
    async fn a_prompt_admitted_on_a_link_that_went_down_fails_instead_of_waiting() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        peer.connected.store(true, Ordering::SeqCst);
        let admitted_on = peer.link_epoch();
        // The link drops and the next one is up again before the request registers.
        peer.link_ended();
        let answer = tokio::time::timeout(
            Duration::from_secs(5),
            peer.link_request_on(method::SESSION_PROMPT, json!({}), Some(admitted_on)),
        )
        .await
        .expect("a prompt on a dead link must not wait");
        assert!(answer.is_err());
        assert_eq!(peer.pending_requests().await, 0, "no entry left behind");
    }

    /// A forwarded request its client cancels (`request_cancel.rs`): the peer hears
    /// `$/cancel_request` for its id on the link it went out on, nothing waits on it any more,
    /// and its id is kept so the late answer is dropped on purpose.
    #[tokio::test]
    async fn a_cancelled_request_tells_the_peer_and_waits_for_nothing() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        peer.connected.store(true, Ordering::SeqCst);
        peer.open.store(true, Ordering::SeqCst);
        peer.features.lock_or_recover().push(crate::request_cancel::FEATURE.to_owned());
        let mut out = peer.out_rx.lock().await.take().unwrap();
        let (cancel, cancelled) = oneshot::channel();
        let asking = peer.clone();
        let task = tokio::spawn(async move {
            crate::request_cancel::until_cancelled(
                cancelled,
                asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
            )
            .await
        });
        let sent = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
        let request: Value = serde_json::from_str(&sent.line).unwrap();
        assert_eq!(peer.pending_requests().await, 1);
        cancel.send(()).unwrap();
        assert!(task.await.unwrap().is_none(), "the request gave up");
        let note = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
        let note: Value = serde_json::from_str(&note.line).unwrap();
        assert_eq!(note["method"], method::CANCEL_REQUEST);
        assert_eq!(note["params"]["requestId"], request["id"]);
        assert_eq!(peer.pending_requests().await, 0, "no entry left behind");
        let key = request["id"].to_string();
        assert!(peer.cancelled.lock_or_recover().take_late(&key, "peer"), "its answer is dropped");
    }

    /// Review F1 of #41285: the peer's answer comes between the cancel and the cleanup of its
    /// entry (the pending map was busy as the request was dropped). It reaches a waiter that is
    /// gone, so it is dropped and logged as late, never lost unlogged, and a peer that already
    /// answered hears no cancel.
    #[tokio::test]
    async fn an_answer_between_the_cancel_and_the_cleanup_is_dropped_as_late() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        peer.connected.store(true, Ordering::SeqCst);
        peer.open.store(true, Ordering::SeqCst);
        peer.features.lock_or_recover().push(crate::request_cancel::FEATURE.to_owned());
        let mut out = peer.out_rx.lock().await.take().unwrap();
        let (cancel, cancelled) = oneshot::channel();
        let asking = peer.clone();
        let task = tokio::spawn(async move {
            crate::request_cancel::until_cancelled(
                cancelled,
                asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
            )
            .await
        });
        let sent = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
        let request: Value = serde_json::from_str(&sent.line).unwrap();
        let key = request["id"].to_string();
        let mut busy = peer.pending.lock().await;
        cancel.send(()).unwrap();
        assert!(task.await.unwrap().is_none(), "the request gave up");
        // The link's reader takes the answer's entry while the cleanup waits for the map.
        let waiter = busy.remove(&key).expect("the entry is still there");
        assert!(waiter.send(Ok(json!({}))).is_err(), "its waiter is gone");
        drop(busy);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while peer.cancelled.lock_or_recover().dropped == 0
            && tokio::time::Instant::now() < deadline
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(peer.cancelled.lock_or_recover().dropped, 1, "dropped as late, and logged");
        assert!(peer.cancelled.lock_or_recover().is_empty(), "no id kept for an answer that came");
        assert_eq!(peer.pending_requests().await, 0);
        assert!(out.try_recv().is_err(), "a peer that answered hears no cancel");
    }

    /// Review F2 of #41285: a cancel to a peer whose outbound queue is full is never dropped:
    /// it goes out once there is room (an awaited send).
    #[tokio::test]
    async fn a_cancel_to_a_peer_with_a_full_queue_still_goes_out() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        peer.connected.store(true, Ordering::SeqCst);
        peer.open.store(true, Ordering::SeqCst);
        peer.features.lock_or_recover().push(crate::request_cancel::FEATURE.to_owned());
        let mut out = peer.out_rx.lock().await.take().unwrap();
        let (cancel, cancelled) = oneshot::channel();
        let asking = peer.clone();
        let task = tokio::spawn(async move {
            crate::request_cancel::until_cancelled(
                cancelled,
                asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
            )
            .await
        });
        let sent = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
        let request: Value = serde_json::from_str(&sent.line).unwrap();
        let mut filler = 0;
        while peer
            .out
            .try_send(Outbound { epoch: sent.epoch, key: None, line: "{}".into() })
            .is_ok()
        {
            filler += 1;
        }
        assert!(filler > 0, "the queue was filled");
        cancel.send(()).unwrap();
        assert!(task.await.unwrap().is_none(), "the request gave up");
        for _ in 0..filler {
            let frame = out.recv().await.unwrap();
            assert_eq!(frame.line, "{}");
        }
        let note = tokio::time::timeout(Duration::from_secs(5), out.recv())
            .await
            .expect("the cancel went out once there was room")
            .unwrap();
        let note: Value = serde_json::from_str(&note.line).unwrap();
        assert_eq!(note["method"], method::CANCEL_REQUEST);
        assert_eq!(note["params"]["requestId"], request["id"]);
        assert_eq!(peer.pending_requests().await, 0);
    }

    /// A peer that does not list the feature hears nothing more: an older daemon.
    #[tokio::test]
    async fn an_older_peer_gets_no_cancel_frame() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        peer.connected.store(true, Ordering::SeqCst);
        peer.open.store(true, Ordering::SeqCst);
        let mut out = peer.out_rx.lock().await.take().unwrap();
        let (cancel, cancelled) = oneshot::channel();
        let asking = peer.clone();
        let task = tokio::spawn(async move {
            crate::request_cancel::until_cancelled(
                cancelled,
                asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
            )
            .await
        });
        tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
        cancel.send(()).unwrap();
        assert!(task.await.unwrap().is_none());
        assert!(tokio::time::timeout(Duration::from_millis(200), out.recv()).await.is_err());
        assert_eq!(peer.pending_requests().await, 0);
    }

    /// Review of #24797 at 45ab6b1: lending was on for a plain `ws://` peer on another host, so
    /// anything on the path could answer the handshake as that peer and ask as it.
    #[test]
    fn github_is_lent_only_over_ssh_tls_or_loopback() {
        let (tx, _rx) = mpsc::channel(8);
        for (url, lends) in [
            ("ws://10.0.0.5:7777", false),
            ("ws://box.example:7777", false),
            ("ws://127.0.0.1:7777", true),
            ("ws://localhost:7777", true),
            ("ws://[::1]:7777", true),
            ("ws://127.0.0.2:7777", true),
            ("ws://[::2]:7777", false),
            ("wss://box.example", true),
            ("ssh://leo@box.example", true),
        ] {
            let peer = Peer::new("p", url, None, None, tx.clone());
            peer.set_github_broker(true);
            assert_eq!(peer.github_broker(), lends, "{url}");
        }
    }

    /// Review of #24797 at ee07ea5: an action admitted just before the peer stopped took the
    /// epoch after the stop as its own, so it still ran.
    #[tokio::test]
    async fn an_action_admitted_before_a_stop_never_runs() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("stopped-mid-admit", "ws://127.0.0.1:9", None, None, tx);
        peer.set_github_broker(true);
        let link = peer.link_epoch();
        peer.github_link.store(link + 1, Ordering::SeqCst);
        let slot = crate::github_broker::admit_owner(
            &peer.name,
            peer.github_ready(link),
            &peer.github_slots,
        )
        .unwrap();
        peer.stop();
        let mut out = peer.out_rx.lock().await.take().unwrap();
        peer.serve_github_action(json!(1), json!({"action": "read", "repo": "o/r"}), slot, link);
        let sent = tokio::time::timeout(Duration::from_secs(1), out.recv()).await;
        assert!(
            sent.is_err(),
            "nothing ran or answered: {:?}",
            sent.ok().flatten().map(|f| f.line)
        );
        assert_eq!(peer.github_slots.available_permits(), crate::github_broker::OWNER_SLOTS);
    }

    /// Review of #24797 at 30e24d1: each reconnect's new peer had slots of its own while the
    /// old one's GitHub actions still ran, so reconnects started more than `OWNER_SLOTS` `gh`s.
    #[tokio::test]
    async fn a_reconnect_shares_its_github_slots_with_the_actions_still_running() {
        let (tx, _rx) = mpsc::channel(8);
        let old = Peer::new("slots-across-reconnects", "ws://127.0.0.1:9", None, None, tx.clone());
        let running: Vec<_> = (0..crate::github_broker::OWNER_SLOTS)
            .map(|_| crate::github_broker::admit_owner(&old.name, true, &old.github_slots).unwrap())
            .collect();
        old.stop();
        let new = Peer::new("slots-across-reconnects", "ws://127.0.0.1:9", None, None, tx);
        let e = crate::github_broker::admit_owner(&new.name, true, &new.github_slots).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.busy");
        drop(running);
        assert!(crate::github_broker::admit_owner(&new.name, true, &new.github_slots).is_ok());
    }
}

#[cfg(test)]
mod frame_epoch_tests {
    use super::*;
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

    /// A frame admitted on a link that went down is dropped when `serve` dequeues it, even
    /// when its sender woke only after the next link opened; one admitted on the live link
    /// goes out.
    #[tokio::test]
    async fn a_frame_tagged_with_an_ended_link_never_goes_out_on_the_next() {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        let stale = peer.link_epoch();
        peer.link_ended();
        let frame = |epoch, line: &str| Outbound { epoch, key: None, line: line.to_owned() };
        peer.out.send(frame(stale, r#"{"jsonrpc":"2.0","method":"stale"}"#)).await.unwrap();
        let live = peer.link_epoch();
        peer.out.send(frame(live, r#"{"jsonrpc":"2.0","method":"live"}"#)).await.unwrap();

        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

        let mut seen = Vec::new();
        while !seen.iter().any(|t: &String| t.contains("\"live\"")) {
            let frame = tokio::time::timeout(Duration::from_secs(5), server.next())
                .await
                .expect("the live frame goes out")
                .expect("the link stays open")
                .unwrap();
            if let Frame::Text(text) = frame {
                seen.push(text.to_string());
            }
        }
        assert!(!seen.iter().any(|t| t.contains("\"stale\"")), "a stale frame went out: {seen:?}");
        serving.abort();
    }

    /// Review of #24797 at f2e68a4: a peer's request was refused with a send that had no time
    /// limit, so a peer that asks and never reads held the link's loop, pings and all, for good.
    #[tokio::test]
    async fn a_peer_that_asks_and_never_reads_loses_the_link() {
        let (tx, _rx) = mpsc::channel(8);
        let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
        let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
        timings.ping_every = Duration::from_millis(200);
        timings.ping_misses = 2;
        timings.send = Duration::from_millis(400);
        let (ours, theirs) = tokio::io::duplex(1024);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
        let asking = tokio::spawn(async move {
            for i in 0u64.. {
                let ask =
                    Message::request(json!(i), method::MUX_GITHUB_ACTION, json!({})).to_line();
                if server.send(Frame::Text(ask.trim_end().to_owned().into())).await.is_err() {
                    break;
                }
            }
        });
        let ended = tokio::time::timeout(Duration::from_secs(10), serving)
            .await
            .expect("the link ends instead of hanging");
        assert!(ended.unwrap().is_err());
        asking.abort();
    }
}

#[cfg(test)]
mod watch_order_tests {
    use super::*;
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

    /// A `session_changed` the peer sends right after its `_acpmux/watch` reply is newer than
    /// the reply's list, so it reaches the hub after the list: a purge of a listed session
    /// leaves no row behind, where a list that came second put the purged row back.
    #[tokio::test]
    async fn a_purge_sent_right_after_the_watch_reply_lands_after_its_list() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-po");
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, dir.path()).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        let (tx, mut rx) = mpsc::channel(64);
        let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());

        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
        // The peer answers every request; its watch reply lists m1, and the purge of m1
        // follows it in the same write.
        let fake = tokio::spawn(async move {
            let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
            while let Some(Ok(frame)) = server.next().await {
                let Frame::Text(text) = frame else { continue };
                let msg: Value = serde_json::from_str(&text).unwrap();
                let Some(id) = msg.get("id").cloned() else { continue };
                let watch = msg["method"] == method::MUX_WATCH;
                let result = if watch { json!({"sessions": [row]}) } else { json!({}) };
                let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                if !watch {
                    server.send(Frame::Text(reply.to_string().into())).await.unwrap();
                    continue;
                }
                let purge = json!({"jsonrpc": "2.0", "method": method::MUX_SESSION_CHANGED,
                    "params": {"kind": "purged", "seq": 2, "session": {"sessionId": "m1"}}});
                server.feed(Frame::Text(reply.to_string().into())).await.unwrap();
                server.send(Frame::Text(purge.to_string().into())).await.unwrap();
            }
        });

        let mut seen = Vec::new();
        let (mut connected, mut purged) = (false, false);
        while !(connected && purged) {
            let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), rx.recv())
                .await
                .expect("the handshake settles and the purge comes")
                .expect("the link stays open");
            connected |= matches!(notice, PeerNotice::Connected);
            purged |=
                matches!(&notice, PeerNotice::SessionChanged { kind, .. } if kind == "purged");
            seen.push(notice);
        }
        let at = |want: fn(&PeerNotice) -> bool| seen.iter().position(want).unwrap();
        let list = at(|n| matches!(n, PeerNotice::Sessions(_)));
        let purge = at(|n| matches!(n, PeerNotice::SessionChanged { .. }));
        let ready = at(|n| matches!(n, PeerNotice::Connected));
        assert!(list < purge, "the list came after a newer purge: {seen:?}");
        assert!(list < ready, "connected before the list: {seen:?}");

        // The hub applies them in the order the link gave them; a second Connected is a
        // barrier: once it settled, every notice before it was applied.
        let mut settled = peer.settled();
        for notice in seen.into_iter().chain([PeerNotice::Connected]) {
            hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(5), settled.wait_for(|n| *n >= 2))
            .await
            .expect("the hub applies the notices")
            .unwrap();
        let rows = hub.remote_sessions();
        assert!(rows.is_empty(), "the purged row came back: {rows:?}");
        serving.abort();
        fake.abort();
    }
}

/// Every dial on this thread fails at once, with no socket, and is recorded, so a test drives
/// the whole run loop (`Peer::run`) under paused time and reads when each attempt went.
#[cfg(test)]
pub(crate) mod test_dial {
    use std::cell::RefCell;

    /// One dial: its monotonic instant and its wall-clock millisecond.
    pub(crate) type Attempt = (tokio::time::Instant, u64);

    thread_local!(static ATTEMPTS: RefCell<Option<Vec<Attempt>>> = const { RefCell::new(None) });

    pub(crate) fn refuse_all() {
        ATTEMPTS.with(|a| *a.borrow_mut() = Some(Vec::new()));
    }

    /// The dials so far; dials keep failing.
    pub(crate) fn attempts() -> Vec<Attempt> {
        ATTEMPTS.with(|a| a.borrow().clone().unwrap_or_default())
    }

    /// Dials go out for real again.
    pub(crate) fn clear() {
        ATTEMPTS.with(|a| *a.borrow_mut() = None);
    }

    pub(super) fn refused() -> bool {
        ATTEMPTS.with(|a| {
            let mut a = a.borrow_mut();
            let Some(list) = a.as_mut() else { return false };
            list.push((tokio::time::Instant::now(), crate::store::now_ms()));
            true
        })
    }
}
