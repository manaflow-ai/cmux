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
    /// Full session list from `_acpmux/watch` or a single `session_changed`.
    Sessions(Vec<Value>),
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
    /// Requests bound to the link's connection (a `session/load`, an attach), by pending key:
    /// the line to send again on the next link when this one switches paths under them.
    /// Each with the link epoch it last went out on: only one sent on an earlier link is sent
    /// again, never one the new link already carries.
    switch_retry: StdMutex<HashMap<String, (String, u64)>>,
    /// The link ended to switch paths; its bound requests go again on the next link.
    switched: AtomicBool,
    /// The pending keys of requests sent on both paths.
    dual_keys: StdMutex<HashSet<String>>,
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
    link_epoch: AtomicU64,
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
    /// Whether the peer answers a watch's `known` with a delta, and the rows the last list read
    /// held (`watch_delta.rs`).
    watch_delta: AtomicBool,
    known: StdMutex<crate::watch_delta::Known>,
    /// Whether the list `known` holds was read with tools: a delta is asked for the same way.
    known_tools: AtomicBool,
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
    pub(crate) fn cache_is_dirty(&self) -> bool {
        self.cache_dirty_seq.load(Ordering::Acquire)
            != self.cache_flushed_seq.load(Ordering::Acquire)
    }

    pub fn new(
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        notices: mpsc::Sender<(String, u64, PeerNotice)>,
    ) -> Arc<Self> {
        let (out, out_rx) = mpsc::channel(1024);
        Arc::new(Self {
            scope: cmux_scope::Scope::new("acpmux peer"),
            name: name.to_owned(),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::SeqCst),
            url: url.to_owned(),
            token,
            peer_token,
            tunnel: Mutex::new(None),
            wireguard: std::sync::OnceLock::new(),
            #[cfg(feature = "hub-carrier")]
            hub_carrier: std::sync::OnceLock::new(),
            link_host: std::sync::OnceLock::new(),
            explicit_route: AtomicBool::new(false),
            link_socket: std::sync::OnceLock::new(),
            paths: StdMutex::new(None),
            serving: StdMutex::new(None),
            switch_wanted: AtomicBool::new(false),
            probing: AtomicBool::new(false),
            answering: carriers::Answering::default(),
            last_good: std::sync::OnceLock::new(),
            shadow: StdMutex::new(None),
            dual_sessions: StdMutex::new(HashSet::new()),
            dual_merge: Mutex::new(dual::Merger::default()),
            token_paths: StdMutex::new(HashMap::new()),
            replaying: StdMutex::new(HashMap::new()),
            switch_retry: StdMutex::new(HashMap::new()),
            switched: AtomicBool::new(false),
            dual_keys: StdMutex::new(HashSet::new()),
            dual_nonce: uuid::Uuid::now_v7().simple().to_string(),
            dual_frames: AtomicU64::new(0),
            dual_stats: dual::DualStats::default(),
            out,
            out_rx: Mutex::new(Some(out_rx)),
            next_id: AtomicI64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
            on_wire: Default::default(),
            prompts: Default::default(),
            connected: AtomicBool::new(false),
            rows_ready: AtomicBool::new(false),
            rows_link: AtomicU64::new(0),
            listed_links: StdMutex::new(std::collections::VecDeque::new()),
            open: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            facts: StdMutex::new(carrier::LinkFacts::default()),
            remote_version: StdMutex::new(None),
            row_pages_for: StdMutex::new(None),
            served_as: StdMutex::new(None),
            person_instance: StdMutex::new(None),
            trust_gate: AtomicBool::new(false),
            vm_boundary: AtomicBool::new(false),
            github_broker: AtomicBool::new(false),
            github_slots: crate::github_broker::owner_slots(name),
            github_link: AtomicU64::new(0),
            github_revoked: tokio::sync::Notify::new(),
            github_app: std::sync::OnceLock::new(),
            file_put: AtomicBool::new(false),
            file_put_chunks: AtomicBool::new(false),
            media_read: AtomicBool::new(false),
            link_epoch: AtomicU64::new(0),
            subagent_transcript: AtomicBool::new(false),
            native_history: AtomicBool::new(false),
            session_auth: AtomicBool::new(false),
            features: StdMutex::new(Vec::new()),
            session_resume_link: AtomicU64::new(0),
            session_messages: AtomicBool::new(false),
            person_stop: AtomicBool::new(false),
            withheld: AtomicBool::new(false),
            presented: StdMutex::new(None),
            read_tokens: tokens::TokenCache::default(),
            linked_once: AtomicBool::new(false),
            slow_banner: AtomicBool::new(false),
            admitting: AtomicBool::new(false),
            attached: StdMutex::new(HashMap::new()),
            marks: AtomicU64::new(0),
            cursors: StdMutex::new(HashMap::new()),
            baselined: StdMutex::new(HashSet::new()),
            attach_retries: StdMutex::new(HashSet::new()),
            replay_highwater: StdMutex::new(HashMap::new()),
            replay_tail: StdMutex::new(HashMap::new()),
            notices,
            stop: AtomicBool::new(false),
            retry_immediately: AtomicBool::new(false),
            stop_signal: Notify::new(),
            stop_changed: tokio::sync::watch::channel(false).0,
            wanted: Default::default(),
            settled: tokio::sync::watch::channel(0).0,
            link: StdMutex::new(Link::default()),
            states: StdMutex::new(None),
            timings: LinkTimings::from_env(),
            silence: StdMutex::new(None),
            cache_saved_at: AtomicU64::new(0),
            cache_saved_outage: AtomicBool::new(false),
            cache_write_pending: AtomicBool::new(false),
            cache_dirty_seq: AtomicU64::new(0),
            cache_flushed_seq: AtomicU64::new(0),
            remote_rows_epoch: AtomicU64::new(0),
            remote_purge_fences: StdMutex::new(HashSet::new()),
            outage_ended: AtomicBool::new(false),
            purge_tombstones: Default::default(),
            health: StdMutex::new(None),
            health_asking: AtomicBool::new(false),
            watch_key: StdMutex::new(None),
            pipelined_key: StdMutex::new(None),
            pipelines: AtomicBool::new(false),
            watch_delta: AtomicBool::new(false),
            known: StdMutex::new(crate::watch_delta::Known::default()),
            known_tools: AtomicBool::new(false),
            received: ReceivedBytes::default(),
        })
    }

    pub(crate) fn set_wireguard(
        &self,
        transport: Arc<crate::wireguard::Transport>,
        address: std::net::SocketAddr,
    ) {
        let _ = self.wireguard.set((transport, address));
    }

    /// What the current (or last) link received (`ReceivedBytes`).
    pub fn received(&self) -> &ReceivedBytes {
        &self.received
    }

    pub fn link(&self) -> Link {
        self.link.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn with_silence<T>(&self, f: impl FnOnce(&mut SilenceBudget) -> T) -> T {
        let mut budget = self.silence.lock().unwrap_or_else(|e| e.into_inner());
        f(budget.get_or_insert_with(|| SilenceBudget::new(&self.timings)))
    }

    /// Every change of the link's state goes through here, so each one sends its note
    /// (`report_states`) from the code that made it: no timer, no polling, no repeats.
    fn with_link<T>(&self, f: impl FnOnce(&mut Link) -> T) -> T {
        let mut link = self.link.lock().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut link);
        self.note_state(&link);
        out
    }

    /// This instance speaks for its name in `states` (the hub's, `Hub::spawn_peer`) from now
    /// on: its state now, then each change (`_acpmux/peer_state_changed`). Once it is replaced
    /// or removed, `states` drops what it says.
    pub fn report_states(&self, states: Arc<crate::peer_states::PeerStates>) {
        let link = self.link.lock().unwrap_or_else(|e| e.into_inner());
        states.register(&self.name, self.generation, self.observed(&link));
        *self.states.lock_or_recover() = Some(states);
    }

    /// Called with `link` locked, so the notes go out in the order of the changes.
    fn note_state(&self, link: &Link) {
        // A stopped instance's link going down is not news: its replacement or its removal
        // speaks for the name next.
        if self.stop.load(Ordering::SeqCst) {
            return;
        }
        let Some(states) = self.states.lock_or_recover().clone() else { return };
        states.changed(&self.name, self.generation, self.observed(link));
    }

    fn observed(&self, link: &Link) -> crate::peer_states::Observed {
        let error = self.last_error.lock_or_recover().clone();
        let state = link.state();
        let mut facts = self.facts.lock_or_recover();
        let (whole, since) = facts.observe(state, crate::store::now_ms());
        crate::peer_states::Observed {
            link: whole,
            carrier: facts.live_carrier(state),
            cause: carrier::cause(whole, error.as_deref()),
            since,
            next_retry_at: link.retry_at.filter(|_| !link.is_ready()),
            last_seen: link.last_seen,
            error,
        }
    }

    /// The carrier this attempt runs over (`carrier` while its link is open).
    fn carried_by(&self, by: crate::protocol::peer_state::Carrier) {
        let mut facts = self.facts.lock_or_recover();
        facts.carrier = Some(by);
        // The upgrade went through, so the token was taken.
        facts.refused = false;
    }

    /// The peer refused this attempt's token: the link is `authFailed` until one is taken.
    fn token_refused(&self) {
        self.facts.lock_or_recover().refused = true;
    }

    pub fn state(&self) -> PeerState {
        self.link().state()
    }

    /// Carry the live instance being replaced. Replacing a peer is an explicit retry,
    /// including when that instance never reached it; automatic boot uses the cache path.
    pub fn seed_last_seen(&self, last_seen: Option<u64>) {
        self.retry_immediately.store(true, Ordering::SeqCst);
        self.with_link(|l| l.seed(last_seen));
    }

    /// What its last handshake would have said of attachments: a test's peer that never ran.
    #[cfg(test)]
    pub(crate) fn seed_send_attach(&self, takes: bool) {
        let mut features = self.features.lock_or_recover();
        features.retain(|f| f != crate::attach::FEATURE);
        if takes {
            features.push(crate::attach::FEATURE.to_owned());
        }
    }

    /// What its last handshake listed (`lists`): a test's peer that never ran.
    #[cfg(test)]
    pub(crate) fn seed_features(&self, features: &[&str]) {
        *self.features.lock_or_recover() = features.iter().map(|f| (*f).to_owned()).collect();
    }

    pub(crate) fn seed_cached_link(
        &self,
        last_seen: Option<u64>,
        down_since: Option<u64>,
        next_retry_at: Option<u64>,
    ) {
        self.with_link(|l| {
            l.seed(last_seen);
            l.seed_outage(down_since);
            if l.attempts == 0 && !l.is_ready() {
                l.next_retry_at = next_retry_at;
            }
        });
    }

    /// Restore explicit outage age independently of a possibly old session-cache lastSeen.
    #[cfg(test)]
    pub(crate) fn seed_outage(&self, down_since: Option<u64>) {
        self.with_link(|l| l.seed_outage(down_since));
    }

    /// One failed connect attempt, counted as `finish_link` counts it.
    #[cfg(test)]
    pub(crate) fn count_failed_attempt(&self) {
        self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after));
    }

    /// The refusal for a request while the link is down (`peer_link.rs`).
    pub fn unreachable_error(&self) -> RpcError {
        let error = self.last_error.lock().unwrap_or_else(|e| e.into_inner()).clone();
        crate::peer_link::unreachable_error(
            &self.name,
            &self.link(),
            error.as_deref(),
            crate::store::now_ms(),
        )
    }

    /// Receives every later settled connect attempt.
    pub fn settled(&self) -> tokio::sync::watch::Receiver<u64> {
        self.settled.subscribe()
    }

    /// The hub applied a connect outcome (sessions listed, or the error).
    pub fn mark_settled(&self) {
        self.settled.send_modify(|count| *count += 1);
    }

    /// Every explicit stop/replacement, including one with no connect attempt in flight.
    pub(crate) fn stopped(&self) -> tokio::sync::watch::Receiver<bool> {
        self.stop_changed.subscribe()
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        // Its own tasks stop with it; the hub's shutdown joins them (`close_tasks`).
        self.scope.token().cancel();
        self.stop_changed.send_replace(true);
        self.link_ended();
        // Stores a permit when `serve` is not waiting yet.
        self.stop_signal.notify_one();
        if let Ok(mut t) = self.tunnel.try_lock() {
            if let Some(child) = t.as_mut() {
                let _ = child.start_kill();
            }
            *t = None;
        }
    }

    /// Cancel this peer's own tasks and join them within `within` (the hub's shutdown).
    pub(crate) async fn close_tasks(&self, within: std::time::Duration) -> cmux_scope::CloseReport {
        self.scope.close(within).await
    }

    /// `ssh://user@host[:port]` -> (ssh destination, remote port); None for
    /// any other scheme and for an ssh URL `ssh_target` refuses.
    fn ssh_parts(&self) -> Option<(String, u16)> {
        let t = ssh_target(&self.url).ok()?;
        Some((t.destination, t.port))
    }

    /// Open an `ssh -W` stdio channel to the peer's WebSocket port. The
    /// connection runs over ssh's stdin and stdout, so there is no local port
    /// to wait for: the WebSocket handshake itself says whether it works.
    async fn open_tunnel(
        &self,
    ) -> Result<
        (
            tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>,
            u16,
            ssh_errors::Capture,
        ),
        String,
    > {
        let (_, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        // Under the tunnel lock, which `stop` takes to end the tunnel: a stop before this point
        // spawns nothing, and one while this holds the lock is seen below once the child is in.
        let mut tunnel = self.tunnel.lock().await;
        if self.stop.load(Ordering::SeqCst) {
            return Err("peer stopped".to_owned());
        }
        let (child, stream, _, errors) = self.spawn_tunnel()?;
        // Replacing the previous channel ends its ssh process.
        *tunnel = Some(child);
        if self.stop.load(Ordering::SeqCst) {
            if let Some(mut child) = tunnel.take() {
                let _ = child.start_kill();
            }
            return Err("peer stopped".to_owned());
        }
        Ok((stream, remote_port, errors))
    }

    /// Spawn an `ssh -W` stdio channel to the peer's WebSocket port, owned by the caller (it
    /// ends when dropped). `open_tunnel` keeps the link's in `tunnel`; a path probe keeps its own.
    #[allow(clippy::type_complexity)]
    fn spawn_tunnel(
        &self,
    ) -> Result<
        (
            tokio::process::Child,
            tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>,
            u16,
            ssh_errors::Capture,
        ),
        String,
    > {
        let (host, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        let mut child = self
            .ssh_command()
            .args(tunnel_argv(&host, remote_port, self.ssh_connect_secs()))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("spawn ssh: {e}"))?;
        let errors = ssh_errors::Capture::start(child.stderr.take());
        let stdout = child.stdout.take().ok_or_else(|| "ssh stdout".to_owned())?;
        let stdin = child.stdin.take().ok_or_else(|| "ssh stdin".to_owned())?;
        Ok((child, tokio::io::join(stdout, stdin), remote_port, errors))
    }

    /// End the owned ssh tunnel process, if any.
    async fn end_tunnel(&self) {
        if let Some(mut child) = self.tunnel.lock().await.take() {
            let _ = child.start_kill();
        }
    }

    /// ssh's ConnectTimeout for the next attempt. Short, so an attempt sent into a dead network
    /// gives up within a few seconds and the next one starts soon after the network is back;
    /// long while a message wakes the machine (its route may resume a paused one) or after the
    /// host was too slow to send its banner in time (a loaded host; reset once a link is ready).
    fn ssh_connect_secs(&self) -> u64 {
        if self.waking() || self.slow_banner.load(Ordering::SeqCst) {
            SSH_CONNECT_SLOW_SECS
        } else {
            SSH_CONNECT_SECS
        }
    }

    fn note_ssh_failure(&self, reason: Option<&str>) {
        if reason == Some(ssh_errors::BANNER_TIMEOUT) {
            self.slow_banner.store(true, Ordering::SeqCst);
        }
    }

    /// The dashboard token (configured, else the remote daemon's own) and
    /// the remote daemon's peer token of this launch (configured, else none
    /// when the remote has none: an older daemon serves this one as Web),
    /// read over the same ssh access at each connect.
    async fn remote_tokens(&self) -> Result<(String, Option<String>), String> {
        let (host, _) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        if let (Some(t), Some(p)) = (&self.token, &self.peer_token) {
            return Ok((t.clone(), Some(p.clone())));
        }
        let mut child = self
            .ssh_command()
            .args(read_config_argv(&host, self.ssh_connect_secs()))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("read remote config: {e}"))?;
        let errors = ssh_errors::Capture::start(child.stderr.take());
        let read = tokio::time::timeout(self.timings.connect, child.wait_with_output());
        // A stop ends the read (its ssh is killed on drop), so no tunnel follows it.
        let out = tokio::select! {
            out = read => out,
            _ = self.stop_signal.notified() => {
                // Put the permit back for `run` and `serve`, which wait on it too.
                self.stop_signal.notify_one();
                return Err("peer stopped".to_owned());
            }
        };
        let out = out
            .map_err(|_| {
                format!(
                    "reading the remote config timed out after {}s",
                    self.timings.connect.as_secs()
                )
            })?
            .map_err(|e| format!("read remote config: {e}"))?;
        // The read ends with the token `cat`, which fails when there is no
        // token: only an empty answer is a failed ssh.
        if out.stdout.is_empty() && !out.status.success() {
            let reason = errors.finish().await;
            self.note_ssh_failure(reason);
            return Err(ssh_errors::describe(
                format!("ssh to {host} failed ({})", out.status),
                reason,
            ));
        }
        let (config, peer) = split_remote_read(&out.stdout);
        let peer = self.peer_token.clone().or(peer);
        if let Some(t) = &self.token {
            return Ok((t.clone(), peer));
        }
        let remote = remote_daemon_config(config).map_err(|why| match why {
            RemoteConfigError::Unreadable => {
                format!("remote {host} has no readable ~/.acpmux/config.json")
            }
            RemoteConfigError::NoToken => format!("remote {host} config has no websocket token"),
        })?;
        Ok((remote.token, peer))
    }

    /// `remote_tokens`, read again (`TOKEN_REREADS`) while the remote has
    /// no peer token: a daemon that is starting listens a few seconds before
    /// it writes `run/peer.token`, and the one that stopped removed its own.
    /// A connect inside that window would be served as Web, holding every
    /// prompt to the Web's rules until the link next drops. A remote too old
    /// to make a token has none after the rereads and is served as Web.
    async fn remote_tokens_settled(&self) -> Result<(String, Option<String>), String> {
        const STOPPED: &str = "peer stopped";
        if self.stop.load(Ordering::SeqCst) {
            return Err(STOPPED.to_owned());
        }
        let mut tokens = self.remote_tokens().await?;
        for wait in TOKEN_REREADS {
            if tokens.1.is_some() {
                break;
            }
            if !self.reread_wait(wait).await {
                return Err(STOPPED.to_owned());
            }
            tokens = self.remote_tokens().await?;
        }
        self.read_tokens.keep(&tokens);
        Ok(tokens)
    }

    /// The tokens for a connect: the last read's (`peer_tokens.rs`), else a read; true when
    /// they came from the last read, so a refusal reads again.
    async fn connect_tokens(&self) -> Result<(tokens::Tokens, bool), String> {
        if (self.token.is_none() || self.peer_token.is_none())
            && let Some(kept) = self.read_tokens.get()
        {
            return Ok((kept, true));
        }
        Ok((self.remote_tokens_settled().await?, false))
    }

    /// A replacement of the same peer (`Hub::spawn_peer`) skips the read the old one made.
    pub(crate) fn carry_read_tokens(&self, old: &Peer) {
        if old.url == self.url && old.token == self.token && old.peer_token == self.peer_token {
            self.read_tokens.carry(&old.read_tokens);
        }
    }

    /// Sleeps `wait` before a token reread; false, at once, when the peer
    /// stops (before or during it), so no further ssh read is made.
    async fn reread_wait(&self, wait: Duration) -> bool {
        if self.stop.load(Ordering::SeqCst) {
            return false;
        }
        tokio::select! {
            _ = tokio::time::sleep(wait) => {}
            _ = self.stop_signal.notified() => {
                // Put the permit back for `run` and `serve`, which wait on it too.
                self.stop_signal.notify_one();
            }
        }
        !self.stop.load(Ordering::SeqCst)
    }

    /// Why an `ssh://` connection the remote served as Web should connect
    /// again: the remote has a peer token now that this connection did not
    /// present (it restarted between the token read and the handshake, or
    /// had not written its token yet). One read per such connection, and
    /// rereads (`TOKEN_REREADS`) while the remote has no token (it is
    /// restarting, or wrote it after this connection's last read), all
    /// before the link is admitted, so a live link is never torn down for a
    /// late token; None when it was served as a peer, when a read fails, on
    /// stop, or when the remote still has no token or the same one (it
    /// serves this daemon as Web for another reason, and reconnecting would
    /// not change that).
    async fn stale_token(&self) -> Option<String> {
        self.ssh_parts()?;
        let served_as_web =
            self.served_as.lock().unwrap_or_else(|e| e.into_inner()).as_deref() == Some("remote");
        if !served_as_web {
            return None;
        }
        let presented = self.presented.lock().unwrap_or_else(|e| e.into_inner()).clone();
        // What it presented did not make it a peer: the next connect reads again, or takes
        // what this read finds.
        self.read_tokens.forget();
        if self.stop.load(Ordering::SeqCst) {
            return None;
        }
        let (mut token, mut now) = self.remote_tokens().await.ok()?;
        for wait in TOKEN_REREADS {
            if now.is_some() {
                break;
            }
            if !self.reread_wait(wait).await {
                return None;
            }
            (token, now) = self.remote_tokens().await.ok()?;
        }
        if now != presented {
            self.read_tokens.keep(&(token, now.clone()));
        }
        (now.is_some() && now != presented).then(|| {
            "the peer served this daemon as remote, and it has a new peer token; reconnecting"
                .to_owned()
        })
    }

    /// How the peer said at its last handshake that it serves this daemon: `peer`, `remote`
    /// (as a Web client), or None from a peer too old to say.
    pub fn served_as(&self) -> Option<String> {
        self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn remote_build(&self) -> Option<String> {
        self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone())
    }

    /// The daemon run the peer named at its last handshake.
    pub fn person_instance(&self) -> Option<String> {
        self.person_instance.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Set before the peer runs (`Hub::spawn_peer`), from its config or lease.
    pub fn set_vm_boundary(&self, on: bool) {
        self.vm_boundary.store(on, Ordering::SeqCst);
    }

    /// Whether this caller opts its remote chains on the peer out of the sandbox.
    pub fn vm_boundary(&self) -> bool {
        self.vm_boundary.load(Ordering::SeqCst)
    }

    /// From its config (`Hub::spawn_peer`, a reload): whether this Mac lends the peer its
    /// GitHub login. Read again for each action, so turning it off holds at once.
    pub fn set_github_broker(&self, on: bool) {
        self.github_broker.store(on, Ordering::SeqCst);
        if !on {
            self.github_revoked.notify_waiters();
        }
    }

    /// Whether this Mac lends the peer GitHub now: its config says so, and the link is one an
    /// on-path machine cannot pose as (`lends_over`).
    pub fn github_broker(&self) -> bool {
        self.github_broker.load(Ordering::SeqCst) && lends_over(&self.url)
    }

    /// The hub's lent cmux sign-in (`github_app_token.rs`).
    pub fn set_github_app(&self, app: Arc<crate::github_app_token::AppLease>) {
        let _ = self.github_app.set(app);
    }

    /// Whether the link `link` (the epoch it was read on) takes a GitHub action now: lent, the
    /// peer not stopped, `link` still the live one, and its handshake finished with the peer
    /// serving this daemon as a peer (not Web), so nothing sent before or around it is.
    fn github_ready(&self, link: u64) -> bool {
        self.github_broker()
            && !self.stop.load(Ordering::SeqCst)
            && self.link_epoch() == link
            && self.github_link.load(Ordering::SeqCst) == link + 1
    }

    /// The peer's daemon asked for a GitHub action (`github_broker.rs`) and `admit_owner` let it
    /// in on `link` (the epoch it was read on): run it, and answer on that link, never on a
    /// later one.
    fn serve_github_action(
        self: &Arc<Self>,
        id: Value,
        params: Value,
        slot: tokio::sync::OwnedSemaphorePermit,
        link: u64,
    ) {
        let me = self.clone();
        let epoch = link;
        // Taken before the task runs and held until its answer is queued: the link does not
        // move to a faster path while it runs (`Peer::switch_due`), for at most the action's
        // own budget.
        let answering = self.answering.start(crate::github_broker::ACTION_BUDGET);
        let scope = &self.scope;
        // The slot is held until the answer is queued, within the request budget: at most
        // `OWNER_SLOTS` of these tasks exist per peer name, across reconnects, even when the link
        // stops reading.
        scope.spawn_until_cancelled("peer-github-action", async move {
            // Lending that ends while it runs (`githubBroker` off, the peer removed, the link
            // ended) stops it: its `gh` is killed (`kill_on_drop`), and a link still up is told.
            let revoked = me.github_revoked.notified();
            tokio::pin!(revoked);
            revoked.as_mut().enable();
            // Lending that ended between the admission and here (the link ended, the peer was
            // stopped or removed, `githubBroker` off) starts nothing.
            if !me.github_ready(epoch) {
                return;
            }
            let app = me.github_app.get().map(Arc::as_ref);
            let reply = tokio::select! {
                reply = crate::github_broker::serve_owner(&me.name, params, app) => reply,
                () = &mut revoked => {
                    let Err(e) = crate::github_broker::admit_owner(&me.name, false, &me.github_slots) else {
                        return;
                    };
                    Err(e)
                }
            };
            let msg = match reply {
                Ok(v) => Message::ok(id, v),
                Err(e) => Message::err(id, e),
            };
            let reply_to = Some(crate::rpc::method::MUX_GITHUB_ACTION);
            if let Ok(line) = msg.bounded_line_replying(reply_to) {
                let frame = Outbound { epoch, key: None, line };
                let _ = tokio::time::timeout(me.timings.request, me.out.send(frame)).await;
            }
            drop(answering);
            drop(slot);
        });
    }

    /// Which connection to the peer this is: it changes when a connection ends or the peer stops.
    pub fn link_epoch(&self) -> u64 {
        self.link_epoch.load(Ordering::SeqCst)
    }

    /// A connection to the peer ended: what the peer kept for it is gone.
    pub(crate) fn link_ended(&self) {
        self.features.lock_or_recover().clear();
        self.link_epoch.fetch_add(1, Ordering::SeqCst);
        self.github_revoked.notify_waiters();
    }

    /// The hub applied a `Connected` notice of this peer: the rows are now those its link listed
    /// at that handshake. A notice no link queued (a test's) stands for the live link.
    pub(crate) fn note_rows_applied(&self) {
        let link = self.listed_links.lock_or_recover().pop_front();
        let link = link.unwrap_or_else(|| self.link_epoch());
        self.rows_link.store(link + 1, Ordering::SeqCst);
    }

    /// The link is ready and the hub applied the session list it sent at its own handshake, so
    /// its notices keep the rows current. A link that dropped and came back reads false until
    /// the new link's list is applied: until then the rows are the link before's.
    pub fn rows_current(&self) -> bool {
        self.ready() && self.rows_link.load(Ordering::SeqCst) == self.link_epoch() + 1
    }

    /// The WebSocket is open and the handshake has not finished.
    pub fn handshaking(&self) -> bool {
        self.open.load(Ordering::SeqCst) && !self.connected.load(Ordering::SeqCst)
    }

    pub fn summary(&self) -> Value {
        let link = self.link();
        let observed = self.observed(&link);
        let (health, health_at) = self.health_summary();
        let paths = self.paths_view();
        json!({
            "name": self.name,
            "url": self.url,
            "connected": self.connected.load(Ordering::SeqCst),
            "handshaking": self.handshaking(),
            "error": self.last_error.lock_or_recover().clone(),
            "remoteVersion": self.remote_version.lock_or_recover().as_ref().map(|(v, _)| v.clone()),
            "remoteBuild": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b.clone()),
            "localBuild": crate::hub::build(),
            "servedAs": self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            "peerTokenWithheld": self.withheld.load(Ordering::SeqCst),
            "canonicalEndpoint": canonical_endpoint(&self.url),
            "outdated": self.remote_version.lock_or_recover().as_ref().map(|(_, b)| b != crate::hub::build()).unwrap_or(false),
            "state": link.state().as_str(),
            "link": observed.link,
            "carrier": observed.carrier,
            "cause": observed.cause,
            "since": observed.since,
            "nextRetryAt": observed.next_retry_at,
            "lastSeen": link.last_seen,
            "downSince": link.down_since,
            "attempts": link.attempts,
            "health": health,
            "healthAt": health_at,
            "paths": paths,
        })
    }

    /// Remember that local clients want this session's stream, so it is
    /// re-attached after a reconnect. True when it was not marked yet; a mark already there is
    /// renewed, since this caller now relies on it.
    pub fn mark_attached(&self, session_id: &str) -> bool {
        // The ticket is taken under the lock, so a later mark always holds a newer one.
        let mut marks = self.attached.lock_or_recover();
        let ticket = self.marks.fetch_add(1, Ordering::SeqCst) + 1;
        let new = marks.insert(session_id.to_owned(), ticket).is_none();
        if new {
            // The stream starts now: its baseline is settled by the attach that follows.
            self.cursors.lock_or_recover().entry(session_id.to_owned()).or_insert(0);
        }
        new
    }

    /// Forget the replay baseline of an attachment whose first baseline request failed. The
    /// mark stays (`attach_hidden`): the next link attaches it without history, which sets a
    /// fresh baseline.
    pub fn clear_attached(&self, session_id: &str) {
        self.replay_highwater.lock_or_recover().remove(session_id);
        self.cursors.lock_or_recover().remove(session_id);
        self.baselined.lock_or_recover().remove(session_id);
    }

    /// The link's own attach of the peer's chat `id` ([`hidden_attach`]), marked already. Its
    /// error goes to the log at warn: a chat whose attach failed got no stream, and said
    /// nothing of why. One the peer refused ([`refuses_attach`]: the chat is gone there, or the
    /// peer takes no such attach) is no longer marked, so no reconnect asks for it again and the
    /// next prompt attaches it anew, unless a client marked it again while this attach was out:
    /// that client relies on the mark. Any other failure (the link dropped, a timeout, a full
    /// queue) keeps the mark, and is tried again on the same link while it stays up
    /// ([`Self::retry_attach`]); the next link's handshake attaches it again in any case. Its
    /// answer, on the link it went out on, is the chat's replay baseline.
    pub async fn attach_hidden(self: &Arc<Self>, id: &str) -> Result<Value, RpcError> {
        let link = self.link_epoch();
        let attached = self.attach_hidden_on(id, link).await;
        if let Err(e) = &attached
            && !refuses_attach(e)
        {
            self.retry_attach(id, link);
        }
        attached
    }

    /// One [`Self::attach_hidden`] on link `link`, with no retry.
    async fn attach_hidden_on(&self, id: &str, link: u64) -> Result<Value, RpcError> {
        let ticket = self.attached.lock_or_recover().get(id).copied();
        let attached = self.request_on(method::MUX_ATTACH, hidden_attach(id), Some(link)).await;
        match &attached {
            Ok(page) if self.link_epoch() == link => self.note_hidden_attach_page(id, page),
            Ok(_) => self.clear_attached(id),
            Err(e) => {
                self.clear_attached(id);
                let refused = refuses_attach(e);
                if refused {
                    let mut marks = self.attached.lock_or_recover();
                    if marks.get(id).copied() == ticket {
                        marks.remove(id);
                    }
                }
                tracing::warn!(peer = %self.name, session = %id, refused, "the peer's chat was not attached, so it streams nothing until it is again: {}", e.message);
            }
        }
        attached
    }

    /// Chat `id`'s attach on link `link` failed without the peer refusing it (it timed out, the
    /// queue was full): it streams nothing on this link, and a Cloud chat's output would just
    /// stop until the next reconnect. It is attached again on the same link, after each of
    /// [`ATTACH_RETRY_AFTER`] in turn, and once it is, its clients are told to read what they
    /// missed ([`Self::tell_reattached`]). It stops when the link ends (the next link's
    /// handshake attaches the chat), when the chat is no longer marked or the peer refuses it,
    /// when another attach gave the chat a stream meanwhile, or after the last retry; the mark
    /// stays for the next link.
    pub(crate) fn retry_attach(self: &Arc<Self>, id: &str, link: u64) {
        if !self.attach_wanted(id, link)
            || !self.attach_retries.lock_or_recover().insert(id.to_owned())
        {
            return;
        }
        let (me, id) = (self.clone(), id.to_owned());
        self.scope.spawn_until_cancelled("peer-attach-retry", async move {
            for (n, after) in ATTACH_RETRY_AFTER.iter().enumerate() {
                tokio::time::sleep(*after).await;
                if !me.attach_wanted(&id, link) {
                    break;
                }
                match me.attach_hidden_on(&id, link).await {
                    Ok(_) => {
                        if me.link_epoch() == link {
                            me.tell_reattached(&id, link).await;
                        }
                        break;
                    }
                    Err(e) if refuses_attach(&e) => break,
                    Err(_) if n + 1 == ATTACH_RETRY_AFTER.len() => {
                        tracing::warn!(peer = %me.name, session = %id, "the peer's chat was not attached after {} retries; the next link attaches it", n + 1);
                    }
                    Err(_) => {}
                }
            }
            me.attach_retries.lock_or_recover().remove(&id);
        });
    }

    /// Whether chat `id`, whose attach on link `link` failed, still needs it: that link is up, the
    /// chat is still marked, and no attach since gave it a stream (which sets its cursor again).
    fn attach_wanted(&self, id: &str, link: u64) -> bool {
        self.link_epoch() == link
            && self.connected.load(Ordering::SeqCst)
            && self.attached.lock_or_recover().contains_key(id)
            && !self.cursors.lock_or_recover().contains_key(id)
    }

    /// Chat `sid` was attached again without history on link `link` ([`REATTACHED_NOTICE`]).
    async fn tell_reattached(&self, sid: &str, link: u64) {
        let notice = PeerNotice::Notification {
            method: REATTACHED_NOTICE.to_owned(),
            params: json!({"sessionId": sid}),
            link,
        };
        let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
    }

    /// Advance the reconnect cursor from a page returned by `_acpmux/attach`.
    /// The page's `lastSeq` includes records filtered out by `kinds`, so only
    /// the records actually delivered to the client may advance the cursor.
    /// An empty page settles the baseline at its `pageThrough` (it holds every record through
    /// it), so a chat first read with nothing in it is replayed after a reconnect; the caller
    /// passes one only when the page held everything asked for (`server/peer_forward.rs`). A
    /// page that says neither settles nothing.
    pub fn note_attached_page(&self, session_id: &str, page: &Value) {
        let seq = page_max_seq(page).or_else(|| page.get("pageThrough").and_then(Value::as_u64));
        if let Some(seq) = seq {
            self.note_baseline(session_id, seq);
        }
    }

    /// Record an explicit `afterSeq` baseline together with the delivered page.
    /// An empty page still means the caller has already consumed everything
    /// through that sequence.
    pub fn note_attached_page_after(&self, session_id: &str, after: u64, page: &Value) {
        let seq = page_max_seq(page).unwrap_or(after).max(after);
        self.note_baseline(session_id, seq);
    }

    /// A hidden attach deliberately reads no history. Its snapshot is the
    /// stream baseline even when the page has no events. Keep a newer live cursor
    /// if notifications raced the response; never move beyond the peer's snapshot.
    pub fn note_hidden_attach_page(&self, session_id: &str, page: &Value) {
        // Older peers may sample lastSeq after the page. It cannot establish a
        // no-history baseline without risking a live event lost in that interval.
        let Some(seq) = page.get("pageThrough").and_then(Value::as_u64) else {
            return;
        };
        self.note_baseline(session_id, seq);
    }

    /// Move a marked chat's cursor up to `seq`. A fresh client can read ahead while older
    /// clients still need the replay gap, so a chat being replayed keeps its cursor.
    fn note_baseline(&self, session_id: &str, seq: u64) {
        let replay = self.replay_highwater.lock_or_recover();
        if replay.contains_key(session_id)
            || !self.attached.lock_or_recover().contains_key(session_id)
        {
            return;
        }
        self.cursors
            .lock_or_recover()
            .entry(session_id.to_owned())
            .and_modify(|cursor| *cursor = (*cursor).max(seq))
            .or_insert(seq);
        self.baselined.lock_or_recover().insert(session_id.to_owned());
    }

    /// Advance the cursor for a live event sent on this peer link.
    fn note_live(&self, params: &Value) {
        let Some(id) = params.get("sessionId").and_then(Value::as_str) else { return };
        let seq = params
            .get("seq")
            .and_then(Value::as_u64)
            .or_else(|| params.pointer("/_meta/acpmux/seq").and_then(Value::as_u64));
        let Some(seq) = seq else { return };
        if let Some(cursor) = self.cursors.lock_or_recover().get_mut(id) {
            *cursor = (*cursor).max(seq);
        }
    }

    /// This link's deadlines (`peer_link.rs`).
    pub fn timings(&self) -> LinkTimings {
        self.timings
    }

    /// How many requests wait for the peer's answer now.
    pub async fn pending_requests(&self) -> usize {
        self.pending.lock().await.len()
    }

    pub async fn request(&self, m: &str, params: Value) -> Result<Value, RpcError> {
        self.request_on(m, params, None).await
    }

    /// `request` on the link of epoch `epoch` only, when the caller read it before (it labels
    /// what the answer holds with it, `hub/peer_snapshot.rs`): unreachable once that link ended.
    pub async fn request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        // Read before the check: `run` moves the epoch on before it fails what
        // waits, so a request that is registered after that sees the change.
        // One of any link that is bound to its connection goes again on the next link when
        // this one switches paths under it (`resend_switched`).
        let retry = epoch.is_none() && dual::bound(m);
        let epoch = epoch.unwrap_or_else(|| self.link_epoch());
        if !self.connected.load(Ordering::SeqCst) || self.admitting.load(Ordering::SeqCst) {
            return Err(self.unreachable_error());
        }
        self.send_request_with(m, params, Some(epoch), ListKey::None, retry).await
    }

    /// Sends `m` on the link of epoch `epoch` (any link when None), with no check that the
    /// handshake finished: the handshake's own requests go out through here.
    async fn link_request_on(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
    ) -> Result<Value, RpcError> {
        self.send_request(m, params, epoch, ListKey::None).await
    }

    /// [`Self::link_request_on`] for the handshake's watch list on link `link`, its
    /// `_acpmux/watch` or a page after it: the reader takes the reply's rows (`watch_key`).
    async fn watch_request_on(&self, m: &str, params: Value, link: u64) -> Result<Value, RpcError> {
        self.send_request(m, params, Some(link), ListKey::Watch).await
    }

    async fn send_request(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
        list: ListKey,
    ) -> Result<Value, RpcError> {
        self.send_request_with(m, params, epoch, list, false).await
    }

    /// [`Self::send_request`]; `retry`: sent again on the next link if this one switches paths
    /// before it answers (`switch_retry`).
    async fn send_request_with(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
        list: ListKey,
        retry: bool,
    ) -> Result<Value, RpcError> {
        // One deadline from here: a request that waits for room in the queue (a stalled link,
        // or a full queue ahead of it) times out on the schedule of one the peer is slow to
        // answer, never later.
        let started = tokio::time::Instant::now();
        let turn_wait = waits_on_turn(m)
            || (m == method::MUX_DISPATCH
                && params.get("durable").and_then(Value::as_bool) == Some(true)
                && params.get("wait").and_then(Value::as_bool) == Some(true));
        // A forwarded session/new gets its dedicated start hazard envelope as
        // well as the generic request budget. Keep the larger one so a caller
        // cannot reintroduce the old short start cutoff through
        // `ACPMUX_PEER_REQUEST_SECS`.
        let budget = self.timings.request.max(if m == method::SESSION_NEW {
            self.timings.start
        } else {
            Duration::ZERO
        });
        let deadline = started + budget;
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let key = Value::from(id).to_string();
        self.pending.lock().await.insert(key.clone(), tx);
        if let Some(session) = params.get("sessionId").and_then(Value::as_str) {
            self.replay_tail.lock_or_recover().remove(session);
        }
        // A load streams its chat's history: until it answers, the replay goes to the hub as
        // it comes, never through the merger's drop below the cursor
        // (`Peer::replay_start`).
        let replaying = match params.get("sessionId").and_then(Value::as_str) {
            Some(session) if dual::replays(m) => Some(self.replay_start(session).await),
            _ => None,
        };
        if m == method::SESSION_PROMPT
            && let (Some(session), Some(prompt)) = (
                params.get("sessionId").and_then(Value::as_str),
                params.pointer("/_meta/acpmux/promptId").and_then(Value::as_str),
            )
        {
            self.prompts.lock_or_recover().insert(
                key.clone(),
                PendingPrompt {
                    session: session.to_owned(),
                    prompt: prompt.to_owned(),
                    accepted: false,
                },
            );
        }
        // A request that times out, or whose caller stops waiting, takes its
        // entry with it rather than leaving it until the connection drops.
        let _forget = ForgetPending {
            pending: self.pending.clone(),
            on_wire: self.on_wire.clone(),
            prompts: self.prompts.clone(),
            key: Some(key.clone()),
        };
        // The link it was admitted on went down before it was registered: `run`
        // already failed what waited, and the next link drops its frame, so a
        // prompt (which has no deadline) would wait for good.
        if epoch.is_some_and(|e| e != self.link_epoch() || !self.open.load(Ordering::SeqCst)) {
            return Err(self.unreachable_error());
        }
        // Only on its own link, checked again under the lock: a request of a link gone down
        // (whose task may still run after its abort) never takes the key of the next link's
        // list. The next handshake sets its key after the epoch moved on, under the same lock.
        if list != ListKey::None {
            let mut held = self.watch_key.lock_or_recover();
            if epoch.is_some_and(|e| e != self.link_epoch()) {
                return Err(self.unreachable_error());
            }
            *held = Some(key.clone());
            if list == ListKey::Pipelined {
                *self.pipelined_key.lock_or_recover() = Some(key.clone());
            }
        }
        // Only this link stamps a `dualId` (`peer_dual.rs`).
        let mut params = params;
        dual::drop_foreign_id(&mut params);
        // One frame larger than the peer reads with would drop the link and every chat on it.
        let line = Message::request(id, m, params).bounded_line().map_err(RpcError::too_large)?;
        let tag = epoch.unwrap_or_else(|| self.link_epoch());
        // Bound to the link's connection: sent again on the next link if this one switches
        // paths before it answers, never raced on two (`Peer::resend_switched`).
        let _retry = retry.then(|| {
            self.switch_retry.lock_or_recover().insert(key.clone(), (line.clone(), tag));
            ForgetRetry { peer: self, key: key.clone() }
        });
        let frame = Outbound { epoch: tag, key: Some(key), line };
        match tokio::time::timeout_at(deadline, self.out.send(frame)).await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => {
                return Err(RpcError::internal(format!("peer {} connection closed", self.name)));
            }
            Err(_) => return Err(queue_timed_out(&self.name, started.elapsed())),
        }
        // A prompt or a wait answers when the peer's turn ends, however long that is; the
        // keepalive drops a link that stops answering. Accepted prompts retain their caller
        // across that drop; a forwarder whose client left drops it (`server/peer_forward.rs`).
        let answer =
            if turn_wait { Ok(rx.await) } else { tokio::time::timeout_at(deadline, rx).await };
        // Its replay came before its answer on the link: the cursor is past it now.
        if let Some(mark) = replaying {
            mark.finish().await;
        }
        match answer {
            // A full disk the peer reports is the peer's, not this machine's (`recovery.rs`).
            // No display line of the peer's own reaches this daemon's clients, on any route that
            // returns a peer's reply or its error's data (`hub::drop_display_lines`).
            Ok(Ok(r)) => r
                .map(|mut result| {
                    crate::hub::drop_display_lines(&mut result);
                    result
                })
                .map_err(|mut e| {
                    crate::recovery::annotate_peer(&mut e, &self.name);
                    if let Some(data) = e.data.as_mut() {
                        crate::hub::drop_display_lines(data);
                    }
                    e
                }),
            Ok(Err(_)) => {
                Err(RpcError::internal(format!("peer {} dropped the request", self.name)))
            }
            Err(_) => Err(RpcError::internal(format!(
                "peer {} timed out after {}s",
                self.name,
                started.elapsed().as_secs()
            ))),
        }
    }

    /// After a link that switched paths: the requests bound to the old link's connection that
    /// it never answered, sent again on link `link` (`switch_retry`).
    async fn resend_switched(&self, link: u64) {
        let lines: Vec<(String, String)> = {
            let pending = self.pending.lock().await;
            let mut retry = self.switch_retry.lock_or_recover();
            retry.retain(|key, _| pending.contains_key(key));
            // Only those the earlier link carried: one made on this link went out on it already.
            retry
                .iter_mut()
                .filter(|(_, (_, sent_on))| *sent_on < link)
                .map(|(key, (line, sent_on))| {
                    *sent_on = link;
                    (key.clone(), line.clone())
                })
                .collect()
        };
        for (key, line) in lines {
            tracing::debug!(peer = %self.name, key = %key, "sending a bound request again after a path switch");
            if self.out.send(Outbound { epoch: link, key: Some(key), line }).await.is_err() {
                return;
            }
        }
    }

    /// The peer accepted a prompt (`_acpmux/prompt_accepted`, on the link or the shadow): a
    /// drop of the link from now on recovers its caller rather than failing it.
    fn note_prompt_accepted(&self, p: &Value) {
        let mut prompts = self.prompts.lock_or_recover();
        for prompt in prompts.values_mut() {
            if p.get("sessionId").and_then(Value::as_str) == Some(&prompt.session)
                && p.get("promptId").and_then(Value::as_str) == Some(&prompt.prompt)
            {
                prompt.accepted = true;
            }
        }
    }

    pub async fn notify(&self, m: &str, mut params: Value) -> Result<(), RpcError> {
        dual::drop_foreign_id(&mut params);
        // Read before the check, as in `request`: a frame tagged with a link
        // that went down is dropped by `serve`, never sent on the next one.
        let epoch = self.link_epoch();
        if !self.connected.load(Ordering::SeqCst) || self.admitting.load(Ordering::SeqCst) {
            return Err(self.unreachable_error());
        }
        let line = Message::notification(m, params).bounded_line().map_err(RpcError::too_large)?;
        let started = tokio::time::Instant::now();
        let frame = Outbound { epoch, key: None, line };
        match tokio::time::timeout(self.timings.request, self.out.send(frame)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(_)) => Err(RpcError::internal(format!("peer {} connection closed", self.name))),
            Err(_) => Err(queue_timed_out(&self.name, started.elapsed())),
        }
    }

    /// Run the connect loop until `stop`.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = Backoff::default();
        let Some(mut out_rx) = self.out_rx.lock().await.take() else {
            // A second run: the first owns the outbound queue and the link.
            tracing::warn!(peer = %self.name, "peer link already running");
            return;
        };
        if !self.retry_immediately.load(Ordering::SeqCst)
            && let Some(wait) = self.link().parked_retry_wait(crate::store::now_ms())
        {
            let reason = format!("peer unavailable; next automatic retry in {}s", wait.as_secs());
            *self.last_error.lock_or_recover() = Some(reason.clone());
            self.with_link(|_| ());
            // Settle startup watchers now; no SSH is spawned just because this daemon updated.
            let _ = self
                .notices
                .send((self.name.clone(), self.generation, PeerNotice::Disconnected(reason)))
                .await;
            // Sleep-aware, like the reconnect backoff: a wake past the saved deadline tries now.
            if matches!(self.wait_backoff(wait).await, BackoffWait::Stopped) {
                return;
            }
        }
        while !self.stop.load(Ordering::SeqCst) {
            let outcome = self.connect_once(&mut out_rx).await;
            let restarting = matches!(&outcome, Ok(LinkEnd::Restarting | LinkEnd::Switching));
            let was_ready = self.link().is_ready();
            let notice = self.finish_link(outcome, &mut backoff);
            // A ready link that just died (a dropped network, a wake from sleep) redials at once:
            // chats are open on it. Only with no failure counted since its backoff last started
            // over, so a link that drops after each handshake waits its backoff from the second.
            let redial_now = was_ready && backoff.failures() == 0;
            // A peer down for a day or more is parked on an hourly retry (`PeerLink::retry_delay`).
            // Scheduled before the notice goes out: the hub saves `next_retry_at` to the peer
            // cache while handling it, so a daemon restart mid-wait keeps the parked deadline.
            let delay = (!restarting).then(|| {
                self.with_link(|l| {
                    let now = crate::store::now_ms();
                    let delay = l.schedule_retry(&mut backoff, now, crate::peer_link::jitter());
                    // Reported only (`nextRetryAt`): the wait below keeps its own delay.
                    let waits = if redial_now { Duration::ZERO } else { delay };
                    l.retry_at = Some(now.saturating_add(waits.as_millis() as u64));
                    delay
                })
            });
            if let Some(notice) = notice {
                let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
            }
            self.fail_link_requests(&mut out_rx).await;
            if self.stop.load(Ordering::SeqCst) {
                break;
            }
            // One immediate attempt for this Close 1012. If that attempt fails, it follows
            // the unchanged real-failure backoff; restarting is not a persistent retry mode.
            let Some(delay) = delay else {
                continue;
            };
            let delay = if redial_now { Duration::ZERO } else { delay };
            match self.wait_backoff(delay).await {
                BackoffWait::Done => {}
                // The network that failed before the sleep may take a moment to come back: the
                // next attempts are quick ones again.
                BackoffWait::Woke => backoff.reset(),
                BackoffWait::Stopped => break,
            }
        }
        // Stopping during backoff (or before the loop starts) also retires
        // accepted callers retained by the previous link. No reconnect owns them now.
        self.fail_link_requests(&mut out_rx).await;
    }

    /// Publish the link ending before settling requests. Restart neither increments failed
    /// attempts nor draws from backoff; it starts backoff over when the previous link was stable.
    fn finish_link(
        &self,
        outcome: Result<LinkEnd, String>,
        backoff: &mut Backoff,
    ) -> Option<PeerNotice> {
        *self.last_error.lock_or_recover() = outcome.as_ref().err().cloned();
        if matches!(&outcome, Ok(LinkEnd::Switching)) {
            // Another path of this peer answers: like a restart, its rows stay usable and the
            // next connect runs at once, but the remote's tokens are still good, and the backoff
            // stays as it is.
            self.switched.store(true, Ordering::SeqCst);
            self.link_ending(true);
            self.link_ended();
            self.open.store(false, Ordering::SeqCst);
            self.connected.store(false, Ordering::SeqCst);
            self.with_link(|l| l.restarting(crate::store::now_ms()));
            return Some(PeerNotice::Restarting);
        }
        self.link_ending(matches!(&outcome, Ok(LinkEnd::Restarting)));
        // The epoch moves first: a finishing handshake cannot leave a dead link ready.
        self.link_ended();
        self.open.store(false, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
        if matches!(&outcome, Ok(LinkEnd::Restarting)) {
            // The peer's daemon restarts (an update): a stable link's backoff starts over, as at
            // its drop, or each restart's failures add up and the next waits out a minute.
            let now = crate::store::now_ms();
            if self.link().ready_for(now).is_some_and(|up| up >= self.timings.stable_after) {
                backoff.reset();
            }
            self.with_link(|l| l.restarting(now));
            // Its next launch writes a new peer token.
            self.read_tokens.forget();
            return Some(PeerNotice::Restarting);
        }
        // A genuinely stable link starts failure backoff over; a flapping one does not.
        if self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after)) {
            backoff.reset();
        }
        outcome.err().map(PeerNotice::Disconnected)
    }

    /// The link ended. A request that never went out on it (still queued, or waiting for room
    /// in the queue) fails as not sent (`peer_unreachable`, retryable), and its frame is dropped,
    /// never sent on the next link. One that went out fails as `peer_disconnected`: the peer
    /// may have run it. An accepted prompt instead keeps its original waiter for recovery.
    async fn fail_link_requests(&self, out_rx: &mut mpsc::Receiver<Outbound>) {
        let mut pending = self.pending.lock().await;
        while out_rx.try_recv().is_ok() {}
        let on_wire = std::mem::take(&mut *self.on_wire.lock_or_recover());
        // A link that switched paths keeps the requests bound to its connection: the next link
        // sends them again (`resend_switched`).
        let switched = self.switched.swap(false, Ordering::SeqCst);
        if !switched {
            self.switch_retry.lock_or_recover().clear();
        }
        let mut survivors = HashMap::new();
        for (key, tx) in pending.drain() {
            // An accepted prompt is recovered on the next link; a request sent on both paths
            // waits for the other path's answer (`peer_dual.rs`).
            if !self.stop.load(Ordering::SeqCst)
                && !tx.is_closed()
                && (self.prompts.lock_or_recover().get(&key).is_some_and(|p| p.accepted)
                    || self.dual_carried(&key)
                    || (switched && self.switch_retry.lock_or_recover().contains_key(&key)))
            {
                survivors.insert(key, tx);
                continue;
            }
            let _ = tx.send(Err(if on_wire.contains(&key) {
                RpcError::internal("peer disconnected").with_data(json!({
                    "reason": "peer_disconnected",
                    "detail": "the request went out before the link dropped; the peer may have run it",
                    "peer": self.name,
                }))
            } else {
                self.unreachable_error()
            }));
        }
        *pending = survivors;
    }

    /// Rebind the original caller to the ledger's result, never resend its prompt.
    /// Replays chat `sid` of link `link` from `cursor`, page by page, before the link is
    /// ready: its records go through the hub as live events would. A chat that fails loses
    /// its baseline and is attached without history after connect (`attach_hidden`).
    async fn replay_chat(&self, sid: String, cursor: u64, link: u64) -> Result<(), RpcError> {
        let mut after = cursor;
        let mut rewound = false;
        loop {
            // Pin every bounded page to this connection. Replay its records through
            // the same hub path as live events before releasing this session's gate.
            let ticket = self.attached.lock_or_recover().get(&sid).copied();
            let page = match self
                .link_request_on(method::MUX_ATTACH, hidden_attach_after(&sid, after), Some(link))
                .await
            {
                Ok(page) => page,
                // One chat must not fail replay and reconnect every other chat forever.
                // It loses its baseline and is attached without history after connect,
                // as `attach_hidden` does; one the peer refused is no longer marked,
                // unless a client marked it again meanwhile.
                Err(e) => {
                    let refused = refuses_attach(&e);
                    tracing::warn!(peer = %self.name, session = %sid, refused, "the peer's chat was not replayed: {}", e.message);
                    self.clear_attached(&sid);
                    if refused {
                        let mut marks = self.attached.lock_or_recover();
                        if marks.get(&sid).copied() == ticket {
                            marks.remove(&sid);
                        }
                    }
                    break;
                }
            };
            // A restored journal may be shorter than the copy we saw on
            // the previous link. Reset both cursors before requesting its
            // bounded pages, or every new live event below `after` is lost.
            if page.get("lastSeq").and_then(Value::as_u64).is_some_and(|last| last < after) {
                if rewound {
                    tracing::warn!(peer = %self.name, session = %sid, "the peer's journal kept moving backwards during replay");
                    self.clear_attached(&sid);
                    break;
                }
                let mut highwater = self.replay_highwater.lock_or_recover();
                self.cursors.lock_or_recover().insert(sid.clone(), 0);
                // Replayed from its start: 0 is its baseline now.
                self.baselined.lock_or_recover().insert(sid.clone());
                highwater.insert(sid.clone(), 0);
                after = 0;
                rewound = true;
                continue;
            }
            let mut progressed = false;
            if let Some(events) = page.get("events").and_then(Value::as_array) {
                for event in events {
                    if let Some(seq) = event.get("seq").and_then(Value::as_u64) {
                        progressed |= seq > after;
                        after = after.max(seq);
                    }
                    if self
                        .notices
                        .send((
                            self.name.clone(),
                            self.generation,
                            PeerNotice::Notification {
                                method: method::MUX_EVENT.to_owned(),
                                params: event.clone(),
                                link,
                            },
                        ))
                        .await
                        .is_err()
                    {
                        return Err(RpcError::internal("peer replay notice channel closed"));
                    }
                    self.note_live(event);
                }
            }
            let caught_up = {
                let mut highwater = self.replay_highwater.lock_or_recover();
                let caught_up = page.get("hasMore") != Some(&Value::Bool(true))
                    && highwater.get(&sid).copied().unwrap_or(after) <= after;
                if caught_up {
                    highwater.remove(&sid);
                    self.replay_tail.lock_or_recover().insert(sid.clone(), after);
                }
                caught_up
            };
            if caught_up {
                break;
            }
            if !progressed {
                tracing::warn!(peer = %self.name, session = %sid, "a replay page made no progress");
                self.clear_attached(&sid);
                break;
            }
        }
        Ok(())
    }

    async fn recover_prompts(&self, link: u64) -> Result<(), RpcError> {
        let prompts: Vec<_> = self
            .prompts
            .lock_or_recover()
            .iter()
            .filter(|(_, p)| p.accepted)
            .map(|(k, p)| (k.clone(), p.clone()))
            .collect();
        for (key, prompt) in prompts {
            if !self.pending.lock().await.contains_key(&key) {
                continue;
            }
            let id: Value =
                serde_json::from_str(&key).map_err(|e| RpcError::internal(e.to_string()))?;
            let line = Message::request(id, method::MUX_WAIT,
                json!({"sessionId": prompt.session, "promptId": prompt.prompt, "until": ["promptOutcome"]}))
                .bounded_line().map_err(RpcError::too_large)?;
            self.out
                .send(Outbound { epoch: link, key: Some(key), line })
                .await
                .map_err(|_| RpcError::internal("peer connection closed"))?;
        }
        Ok(())
    }

    /// One link: dial this peer's paths (`peer_carriers.rs`), the one that carried it last
    /// first and each other one `STAGGER` later, and serve the first that opens until it ends.
    async fn connect_once(
        self: &Arc<Self>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String> {
        use crate::peer_paths::Via;
        self.facts.lock_or_recover().refused = false;
        #[cfg(test)]
        if test_dial::refused() {
            return Err("refused (test)".into());
        }
        let (via, opened) = self.open_first().await?;
        // A losing ssh attempt's process ends now.
        if via != Via::Ssh {
            self.end_tunnel().await;
        }
        *self.presented.lock().unwrap_or_else(|e| e.into_inner()) = opened.presented;
        self.carried_by(via.carrier().wire());
        self.set_serving(Some(via));
        self.start_probes();
        let heard = Some(opened.heard);
        let end = match opened.ws {
            carriers::OpenedWs::Boxed(ws) => self.serve_heard(*ws, out_rx, heard).await,
            carriers::OpenedWs::Url(ws) => self.serve_heard(*ws, out_rx, heard).await,
        };
        self.set_serving(None);
        self.dual_link_ended();
        let end = match (end, opened.ssh_errors) {
            (Err(error), Some(errors)) => {
                // End the owned SSH process now, including when its next attempt is an hour away.
                self.end_tunnel().await;
                let reason = errors.finish().await;
                self.note_ssh_failure(reason);
                Err(ssh_errors::describe(error, reason))
            }
            (end, errors) => {
                if errors.is_some() {
                    self.end_tunnel().await;
                }
                end
            }
        };
        match end {
            // The path died while another answers: the link moves there without an outage.
            Err(error) if !self.stop.load(Ordering::SeqCst) => {
                self.path_failed(via);
                if self.another_path_alive(via) && self.link().is_ready() {
                    tracing::info!(peer = %self.name, via = via.as_str(), "the link's path failed ({error}); moving to another path");
                    return Ok(LinkEnd::Switching);
                }
                Err(error)
            }
            end => end,
        }
    }

    fn ws_request(
        &self,
        url: &str,
        token: Option<&str>,
        peer_token: Option<&str>,
    ) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, String> {
        // A peer URL saved with `?token=` in it: the listener takes the token
        // only from a header, so it moves there and out of the URL.
        let (url, query_token) = lift_query_token(url);
        let token = token.or(query_token.as_deref());
        let mut req = url.as_str().into_client_request().map_err(|e| e.to_string())?;
        if let Some(t) = token {
            req.headers_mut().insert(
                "authorization",
                format!("Bearer {t}").parse().map_err(|_| "bad token".to_owned())?,
            );
        }
        if let Some(p) = peer_token {
            req.headers_mut().insert(
                crate::server::peer_auth::HEADER,
                p.parse().map_err(|_| "bad peer token".to_owned())?,
            );
        }
        Ok(req)
    }

    /// Run one connected WebSocket until it closes; its silence is counted from its frames.
    #[cfg(test)]
    async fn serve<S>(
        self: &Arc<Self>,
        ws: tokio_tungstenite::WebSocketStream<S>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        self.serve_heard(ws, out_rx, None).await
    }

    /// Run one connected WebSocket until it closes. With `heard` (its transport's reads), the
    /// link is silent only while no byte arrives, so a large frame on a slow link keeps it up.
    async fn serve_heard<S>(
        self: &Arc<Self>,
        ws: tokio_tungstenite::WebSocketStream<S>,
        out_rx: &mut mpsc::Receiver<Outbound>,
        heard: Option<crate::peer_link::Heard>,
    ) -> Result<LinkEnd, String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        use tokio_tungstenite::tungstenite::Message as Frame;
        let (mut sink, mut source) = ws.split();
        // Open, not connected: callers' requests are refused until the handshake finished
        // (`connected`), and only the handshake's own go out on this link (`link`).
        let link = self.link_epoch();
        self.admitting.store(true, Ordering::SeqCst);
        self.open.store(true, Ordering::SeqCst);
        // Gate existing streams before initialize/watch or outcome recovery can
        // produce events. A live record must not move the replay cursor past a gap.
        let replay_cursors =
            replayable(&self.cursors.lock_or_recover(), &self.baselined.lock_or_recover());
        *self.replay_highwater.lock_or_recover() = replay_cursors.into_iter().collect();
        self.replay_tail.lock_or_recover().clear();
        *self.last_error.lock_or_recover() = None;
        self.received.reset();
        self.with_link(|l| l.opened(crate::store::now_ms()));
        tracing::info!(peer = %self.name, "link open to {}; handshaking", lift_query_token(&self.url).0);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let (stale_tx, mut stale_rx) = oneshot::channel::<String>();
        // Whether the handshake kept the watch it sent with `initialize` (`pipelined_key`).
        let (kept_tx, mut kept_rx) = oneshot::channel::<bool>();
        *self.pipelined_key.lock_or_recover() = None;
        let mut handshake = tokio::spawn(async move {
            let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": crate::hub::VERSION},
                // Large replies (the session list) may come compressed (`frame_compress.rs`).
                "_meta": {"acpmux": {"compression": crate::frame_compress::offer()}}});
            // This Mac lends the peer its GitHub login (`hub/github_owner.rs` on the peer).
            if me.github_broker() {
                hello.set_path(&["_meta", "acpmux", "githubBroker"], json!(true));
            }
            // The watch goes out with `initialize`, not a round trip after it, when the last link
            // says which it will be (`pipelined_watch`); its reply waits in the reader until the
            // initialize reply says it was the one to ask (`keep_pipelined`).
            let pipelined = me.pipelined_watch();
            let sent = futures::future::maybe_done(async {
                let params = pipelined.clone()?;
                Some(
                    me.send_request(method::MUX_WATCH, params, Some(link), ListKey::Pipelined)
                        .await,
                )
            });
            tokio::pin!(sent);
            let init = me.link_request_on(method::INITIALIZE, hello, Some(link));
            tokio::pin!(init);
            // Polled in this order: `initialize` is queued first.
            let init = std::future::poll_fn(|cx| {
                let init = std::future::Future::poll(init.as_mut(), cx);
                let _ = std::future::Future::poll(sent.as_mut(), cx);
                init
            })
            .await?;
            let v = init
                .pointer("/_meta/acpmux/version")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_owned();
            let b = init
                .pointer("/_meta/acpmux/build")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            let build = (b != "unknown").then(|| b.clone());
            *me.remote_version.lock_or_recover() = Some((v, b));
            *me.served_as.lock().unwrap_or_else(|e| e.into_inner()) =
                init.pointer("/_meta/acpmux/origin").and_then(Value::as_str).map(str::to_owned);
            // Before any session is watched or attached on this link.
            if let Some(why) = me.stale_token().await {
                let _ = stale_tx.send(why);
                return Ok(());
            }
            me.admitting.store(false, Ordering::SeqCst);
            *me.person_instance.lock().unwrap_or_else(|e| e.into_inner()) = init
                .pointer("/_meta/acpmux/personInstance")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let lists = |feature: &str| {
                init.pointer("/_meta/acpmux/features")
                    .and_then(Value::as_array)
                    .is_some_and(|features| features.iter().any(|f| f.as_str() == Some(feature)))
            };
            let advertised = lists("trustGate")
                || init.pointer("/_meta/acpmux/trustGate").and_then(Value::as_bool) == Some(true);
            me.trust_gate.store(advertised, Ordering::SeqCst);
            let set =
                |flag: &AtomicBool, feature: &str| flag.store(lists(feature), Ordering::SeqCst);
            set(&me.file_put, crate::hub::FILE_PUT_FEATURE);
            set(&me.file_put_chunks, crate::hub::file_uploads::CHUNKS_FEATURE);
            set(&me.media_read, crate::hub::MEDIA_READ_FEATURE);
            set(&me.subagent_transcript, crate::hub::SUBAGENT_TRANSCRIPT_FEATURE);
            set(&me.native_history, crate::hub::NATIVE_HISTORY_FEATURE);
            set(&me.session_auth, crate::hub::session_auth::FEATURE);
            set(&me.person_stop, crate::hub::cancel::PERSON_STOP_FEATURE);
            set(&me.watch_delta, crate::watch_delta::FEATURE);
            set(&me.pipelines, HANDSHAKE_PIPELINE_FEATURE);
            // The rest are read from the list (`lists`): attachments, uploads, upload status,
            // and holding a prompt for the owner.
            let listed = init.pointer("/_meta/acpmux/features").and_then(Value::as_array);
            let listed = listed.into_iter().flatten().filter_map(Value::as_str);
            *me.features.lock_or_recover() = listed.map(str::to_owned).collect();
            // Whether this daemon takes this link as its peer principal (`peer_dual.rs`):
            // its own answer on this connection, read again on each link.
            if let Some(via) = me.serving() {
                let principal = init.pointer("/_meta/acpmux/dualPrincipal");
                me.note_token_path(via, principal == Some(&Value::Bool(true)));
            }
            let resumes = lists(crate::server::SESSION_RESUME_FEATURE);
            me.session_resume_link.store(if resumes { link + 1 } else { 0 }, Ordering::SeqCst);
            let messages = init
                .pointer("/_meta/acpmux/capabilities")
                .and_then(Value::as_array)
                .is_some_and(|ids| {
                    ids.iter().any(|id| id.as_str() == Some(crate::capabilities::SESSION_MESSAGES))
                });
            me.session_messages.store(messages, Ordering::SeqCst);
            let kept = me.keep_pipelined(pipelined.as_ref(), build.as_ref());
            let _ = kept_tx.send(kept);
            let mut sent = if kept {
                sent.as_mut().await;
                sent.as_mut().take_output().flatten()
            } else {
                None
            };
            // The reader published the reply's list (`watch_key`), so Connected follows it.
            // Without tools: an inventory is read per session, on an attachment (whose
            // `session_changed` notices carry it) or `_acpmux/info`, never in the list. With
            // them one host's list was 23 MB for 3,700 rows (2026-10-31), past the message
            // limit, and every link to it built and was refused one list before reading it
            // again without them; without them 16.6 MB. A delta is asked for as the list it
            // patches was read (`known_tools`).
            let watch = |tools: bool| json!({"enabled": true, "withTools": tools});
            let row_pages = build.is_some() && *me.row_pages_for.lock_or_recover() == build;
            // A link that read the list before reads only what changed since (`watch_delta.rs`),
            // with or without tools as that list was: a daemon serving it as a peer answers
            // with a delta (`first_watch`). One too large to send is read as the whole list is.
            let mut answered = None;
            if let Some((asked, tools)) =
                me.first_watch(build.as_ref()).filter(|(asked, _)| asked.get("known").is_some())
            {
                match me.watch_first(asked, link, sent.take()).await {
                    Err(e) if too_large(&e) => {
                        tracing::warn!(peer = %me.name, "the watch delta is too large ({}); reading the whole list", e.message);
                    }
                    answer => answered = Some((answer?, tools)),
                }
            }
            let first = if answered.is_some() {
                answered
            } else if row_pages {
                tracing::info!(peer = %me.name, "the watch list needed pages of rows last time; reading it so");
                me.watch_row_pages(link).await?;
                None
            } else {
                match me.watch_first(watch(false), link, sent.take()).await {
                    // A peer from before #28182 sends a whole list in one message or not at
                    // all (cosmic-gray's NIGHTLY, 16.4 MB without tools, on 2026-10-30): it is
                    // read in pages of a count of rows, which such a peer serves.
                    Err(e) if too_large(&e) => {
                        tracing::warn!(peer = %me.name, "the watch list is too large ({}); reading it in pages", e.message);
                        me.watch_row_pages(link).await?;
                        *me.row_pages_for.lock_or_recover() = build.clone();
                        None
                    }
                    answer => Some((answer?, false)),
                }
            };
            // A list too large for one message comes in pages (a peer served as Web, over
            // plain ws://, gets the whole list): every page is read before the link connects,
            // and the reader publishes the list once, whole, after the last.
            let tools = first.as_ref().is_some_and(|(_, tools)| *tools);
            if let Some((first, tools)) = first {
                me.watch_pages(first, tools, link).await?;
            }
            // Read whole (its last page too, or the delta): the next delta is asked for as this
            // list was read (`watch_delta.rs`).
            me.known_tools.store(tools, Ordering::SeqCst);
            me.recover_prompts(link).await?;
            let attached =
                replayable(&me.cursors.lock_or_recover(), &me.baselined.lock_or_recover());
            // Forwarders can register an attachment during the handshake before
            // request_on refuses their request. Gate those sessions too, without
            // replacing high-water marks already observed on this connection.
            {
                let mut highwater = me.replay_highwater.lock_or_recover();
                for (sid, cursor) in &attached {
                    highwater.entry(sid.clone()).or_insert(*cursor);
                }
            }
            // Several chats at once, each page by page: a reconnect with many chats waits one
            // round trip per page of the longest, not per page of all of them in turn.
            let replays = futures::stream::iter(attached)
                .map(|(sid, cursor)| me.replay_chat(sid, cursor, link))
                .buffer_unordered(REATTACHES_AT_ONCE);
            tokio::pin!(replays);
            while let Some(replayed) = replays.next().await {
                replayed?;
            }

            // Connected only now, and ready with it, so its state note follows `connected`.
            // Admit new requests only after all replay pages have reached subscribers.
            // Otherwise a fresh attach can return those pages before replay emits them again.
            // `run` moves the epoch on before it clears `connected` and takes the link down, so
            // a link that dropped meanwhile is seen here: it is not made ready again, and never
            // left reading connected.
            let live = me.with_link(|l| {
                let live = me.link_epoch() == link;
                if live {
                    me.connected.store(true, Ordering::SeqCst);
                    me.linked_once.store(true, Ordering::SeqCst);
                    me.slow_banner.store(false, Ordering::SeqCst);
                    l.ready(crate::store::now_ms());
                }
                live
            });
            if !live || me.link_epoch() != link {
                me.connected.store(false, Ordering::SeqCst);
                return Ok(());
            }
            let (frames, text) = me.received.read();
            tracing::info!(
                peer = %me.name,
                frame_bytes = frames,
                text_bytes = text,
                "connected to {}",
                lift_query_token(&me.url).0
            );
            me.listed_links.lock_or_recover().push_back(link);
            let _ = me.notices.send((me.name.clone(), me.generation, PeerNotice::Connected)).await;
            // The path it is ready on is the one to dial first next time, also after a restart.
            me.note_ready_path();
            // What the last link bound to its connection and never answered, on this one.
            me.resend_switched(link).await;
            // Several at once: a chat the peer is slow on holds up no other's stream, and a
            // link with many chats does not fill its send queue with them.
            // Chats with a cursor were replayed above; the rest have no baseline yet.
            let attached: Vec<String> = {
                let marks = me.attached.lock_or_recover();
                let cursors = me.cursors.lock_or_recover();
                let baselined = me.baselined.lock_or_recover();
                let replayed = |sid: &String| {
                    cursors.get(sid).is_some_and(|c| *c > 0 || baselined.contains(sid))
                };
                marks.keys().filter(|sid| !replayed(sid)).cloned().collect()
            };
            // Each starts its stream anew at the peer's present, so what the peer sent since the
            // last link is a hole: its clients are told they lagged, and read it themselves.
            let (peer, epoch) = (&me, link);
            futures::stream::iter(attached.iter())
                .for_each_concurrent(REATTACHES_AT_ONCE, |sid| async move {
                    if peer.attach_hidden(sid).await.is_ok() && peer.link_epoch() == epoch {
                        peer.tell_reattached(sid, epoch).await;
                    }
                })
                .await;
            me.refresh_health();
            Ok::<(), RpcError>(())
        });

        // Keepalive: a ping each interval; any byte is an answer. A peer
        // silent for the whole silence budget (`SilenceBudget`: longer for one
        // that answers late), or one that stops reading so a send cannot go
        // out within the send budget, is dropped and reconnected; one interval
        // of silence only marks it degraded.
        let timings = self.timings;
        let (was, silence) = self.with_silence(|b| {
            let was = b.current();
            b.opened(tokio::time::Instant::now());
            (was, b.current())
        });
        if silence != was {
            tracing::info!(peer = %self.name, "silence budget {}s (was {}s; a link dropped for silence opened again: the peer is slow, not gone)", silence.as_secs(), was.as_secs());
        }
        // The first read's gap is the connect, not an answer.
        if let Some(heard) = &heard {
            heard.take_gap();
        }
        let mut frame_gap = Duration::ZERO;
        let budget = timings.send;
        let mut ping = tokio::time::interval_at(
            tokio::time::Instant::now() + timings.ping_every,
            timings.ping_every,
        );
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut last_frame = tokio::time::Instant::now();
        let mut stale_settled = false;
        let mut handshake_ended = false;
        let mut ticks: u64 = 0;
        // Moved on by each page of a watch list read in pages, up to `HANDSHAKE_MOST` in all: a
        // peer that paces its lists still links, one that stops answering does not hold it.
        let handshake_started = tokio::time::Instant::now();
        let handshake_deadline = tokio::time::sleep(timings.handshake);
        tokio::pin!(handshake_deadline);
        // After this computer slept, the link's monotonic timers say its last frame came moments
        // ago, while its ssh tunnel has often died: a ping goes out at once, and the link is
        // dropped (and redialed) when nothing answers within `WAKE_PROBE`, rather than after the
        // ssh keepalive or the whole silence budget. Stops with the link.
        let mut wake_watch = SleepWatch::now();
        let mut wake_check = tokio::time::interval_at(
            tokio::time::Instant::now() + SleepWatch::EVERY,
            SleepWatch::EVERY,
        );
        wake_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut wake_probe: Option<tokio::time::Instant> = None;
        // The clocks are read before every write too, not only on `wake_check`'s tick: after a wake
        // the regular ping's tick may be served first, and its write must be held to the probe's
        // deadline, never the whole send budget.
        macro_rules! check_wake {
            () => {
                if let Some(slept) = wake_watch.check() {
                    tracing::info!(peer = %self.name, "this computer slept {}s; checking the link", slept.as_secs());
                    // One deadline for the ping to go out and its answer to come back.
                    let deadline = tokio::time::Instant::now() + WAKE_PROBE;
                    match tokio::time::timeout_at(deadline, sink.send(Frame::Ping(Vec::new().into()))).await {
                        Ok(Ok(())) => wake_probe = Some(deadline),
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(stopped_reading(WAKE_PROBE)),
                    }
                }
            };
        }
        // The rows of a watch list read in pages so far, and the changes the peer sent
        // meanwhile: published once the last page is in, the list first. A link that drops
        // before then publishes neither, so the hub keeps its last whole list.
        let mut paged: Option<(Vec<Value>, Vec<PeerNotice>)> = None;
        // A reply to this daemon's request: a watch list's (`watch_key`) is published here, before
        // the next frame is read.
        macro_rules! watch_reply {
            ($key:expr, $reply:expr, $tx:expr) => {{
                let (key, reply, tx): (
                    String,
                    Result<Value, RpcError>,
                    oneshot::Sender<Result<Value, RpcError>>,
                ) = ($key, $reply, $tx);
                let watch = self.watch_key.lock_or_recover().take_if(|k| *k == key).is_some();
                // The handshake's last step answered on this link, as a peer serving
                // this daemon: GitHub actions are taken from here on, and the
                // added machine asks only after sending this answer
                // (`hub/github_owner.rs`).
                if watch && reply.is_ok() && self.served_as().as_deref() == Some("peer") {
                    self.github_link.store(link + 1, Ordering::SeqCst);
                }
                if let (true, Ok(list)) = (watch, &reply) {
                    let (mut rows, held) = paged.take().unwrap_or_default();
                    rows.extend(watch_sessions(list));
                    // The whole list a delta stands for; the rows of a whole list,
                    // kept for the next link's delta (`watch_delta.rs`).
                    let delta = crate::watch_delta::read_delta(list).map(|(_, removed)| removed);
                    let last = matches!(page_cursor(list), Ok(None));
                    match delta {
                        Some(removed) => {
                            rows = self
                                .known
                                .lock_or_recover()
                                .patched(std::mem::take(&mut rows), &removed)
                        }
                        None if last => self.known.lock_or_recover().listed(&rows),
                        None => {}
                    }
                    match page_cursor(list) {
                        // More pages: the handshake asks for them.
                        Ok(Some(_)) => {
                            paged = Some((rows, held));
                            let until = (tokio::time::Instant::now() + timings.handshake)
                                .min(handshake_started + HANDSHAKE_MOST.max(timings.handshake));
                            handshake_deadline.as_mut().reset(until);
                        }
                        // A bad cursor: the handshake fails and the link drops.
                        Err(_) => {}
                        Ok(None) => {
                            let mut stopped = false;
                            for notice in std::iter::once(PeerNotice::Sessions(rows)).chain(held) {
                                if self
                                    .notices
                                    .send((self.name.clone(), self.generation, notice))
                                    .await
                                    .is_err()
                                {
                                    stopped = true;
                                    break;
                                }
                            }
                            if stopped {
                                break Ok(LinkEnd::Stopped);
                            }
                        }
                    }
                }
                let _ = tx.send(reply);
            }};
        }
        // The reply to the watch sent with `initialize`, held until the handshake settles it.
        let mut pipelined: Option<(
            String,
            Result<Value, RpcError>,
            oneshot::Sender<Result<Value, RpcError>>,
        )> = None;
        let mut pipelined_settled = false;
        // GitHub actions the peer asked for after the held watch reply: the peer asks only after
        // sending that answer (`hub/github_owner.rs`), so they wait for the handshake to settle
        // it, and are admitted or refused then, in order. At most `OWNER_SLOTS` wait; any more
        // are judged at once, as they would be anyway.
        let mut deferred_github: Vec<(Value, Option<Value>)> = Vec::new();
        // A request from the peer for a GitHub action, admitted or refused on this link now.
        macro_rules! github_request {
            // `$link` is the reader loop's label, named at the call (labels are hygienic).
            ($link:lifetime, $id:expr, $params:expr) => {{
                let (id, params): (Value, Option<Value>) = ($id, $params);
                // Refused here, before anything is spawned, unless this Mac lends the peer
                // GitHub, the handshake on this link finished, and a slot is free.
                let admitted = crate::github_broker::admit_owner(&self.name, self.github_ready(link), &self.github_slots);
                match admitted {
                    Ok(slot) => self.serve_github_action(id, params.unwrap_or(Value::Null), slot, link),
                    Err(e) => {
                        // Bounded like any frame: a peer that asks and never reads cannot hold
                        // this loop.
                        let refusal = Frame::Text(Message::err(id, e).to_value().to_string().into());
                        match tokio::time::timeout(budget, sink.send(refusal)).await {
                            Ok(Ok(())) => {}
                            Ok(Err(e)) => break $link Err(e.to_string()),
                            Err(_) => break $link Err(stopped_reading(budget)),
                        }
                    }
                }
            }};
        }
        let result = 'link: loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(LinkEnd::Stopped);
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(LinkEnd::Stopped),
                _ = wake_check.tick() => check_wake!(),
                _ = tokio::time::sleep_until(wake_probe.unwrap_or_else(tokio::time::Instant::now)), if wake_probe.is_some() => {
                    break Err(format!("no answer {}s after this computer woke", WAKE_PROBE.as_secs()));
                }
                // Once only. A watch the handshake dropped is never published, and the changes
                // held after it wait for the list asked for instead (`paged`).
                kept = &mut kept_rx, if !pipelined_settled => {
                    pipelined_settled = true;
                    if let Some((key, reply, tx)) = pipelined.take()
                        && kept == Ok(true)
                    {
                        watch_reply!(key, reply, tx);
                    }
                    for (id, params) in std::mem::take(&mut deferred_github) {
                        github_request!('link, id, params);
                    }
                }
                // Once only: a finished oneshot is not polled again.
                stale = &mut stale_rx, if !stale_settled => {
                    stale_settled = true;
                    if let Ok(why) = stale {
                        break Err(why);
                    }
                }
                // A handshake that ended without making the link ready ends the link now, with
                // why: a step the peer refused (or that failed on this link), a stale token, a
                // link that dropped meanwhile, or a task that panicked. The deadline below would
                // only say the handshake timed out.
                ended = &mut handshake, if !handshake_ended => {
                    handshake_ended = true;
                    match ended {
                        Ok(Err(e)) => break Err(format!("handshake failed: {}", e.message)),
                        Err(e) => break Err(format!("handshake failed: {e}")),
                        Ok(Ok(())) if !self.link().is_ready() => {
                            // The stale-token path sends its reason before it returns.
                            if !stale_settled && let Ok(why) = stale_rx.try_recv() {
                                break Err(why);
                            }
                            break Err("handshake ended before the link was ready".to_owned());
                        }
                        Ok(Ok(())) => {}
                    }
                }
                _ = &mut handshake_deadline, if !self.link().is_ready() => {
                    break Err(timed_out(handshake_started));
                }
                _ = ping.tick() => {
                    // The selector moved the session to a faster path: the link moves while no
                    // request is out on it.
                    self.paths_tick();
                    if self.link().is_ready() && self.switch_due() {
                        break Ok(LinkEnd::Switching);
                    }
                    let now = tokio::time::Instant::now();
                    let gap = heard.as_ref().map_or_else(|| std::mem::take(&mut frame_gap), Heard::take_gap);
                    let (was, silence) = self.with_silence(|b| {
                        let was = b.current();
                        b.answered_after(gap, now);
                        b.settle(now);
                        (was, b.current())
                    });
                    if silence != was {
                        tracing::info!(peer = %self.name, "silence budget {}s (was {}s; longest wait for an answer {}ms)", silence.as_secs(), was.as_secs(), gap.as_millis());
                    }
                    let silent = heard.as_ref().map_or(last_frame.elapsed(), |h| h.silent().min(last_frame.elapsed()));
                    if silent >= silence {
                        self.with_silence(|b| b.dropped(now));
                        break Err(format!("peer stopped answering ({}s without a frame)", silent.as_secs()));
                    }
                    if silent >= timings.ping_every {
                        self.with_link(Link::overdue);
                    }
                    check_wake!();
                    let until = write_deadline(tokio::time::Instant::now(), budget, wake_probe);
                    // Stamped, so its pong measures this path's round trip (`peer_paths.rs`).
                    match tokio::time::timeout_at(until, sink.send(Frame::Ping(carriers::ping_stamp().into()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(write_late(budget, wake_probe)),
                    }
                    ticks += 1;
                    if ticks.is_multiple_of(health::HEALTH_EVERY) && self.link().is_ready() {
                        self.refresh_health();
                    }
                }
                frame = source.next() => {
                    let Some(frame) = frame else { break Err("peer closed the connection".to_owned()) };
                    let frame = match frame { Ok(f) => f, Err(e) => break Err(e.to_string()) };
                    // `select!` is unbiased: a frame read as the deadline passes may not finish
                    // the handshake (or move the deadline on past its cap).
                    if !self.link().is_ready() && handshake_deadline.is_elapsed() {
                        break Err(timed_out(handshake_started));
                    }
                    frame_gap = frame_gap.max(last_frame.elapsed());
                    last_frame = tokio::time::Instant::now();
                    wake_probe = None;
                    self.with_link(|l| l.heard(crate::store::now_ms()));
                    let (text, compressed) = match frame {
                        tokio_tungstenite::tungstenite::Message::Text(t) => {
                            self.received.add(t.len(), t.len());
                            (t.to_string(), false)
                        }
                        // Asked for in `initialize` (`frame_compress.rs`). One that does not
                        // inflate would lose a reply its caller waits on: the link starts over.
                        Frame::Binary(b) => match crate::frame_compress::inflate(&b, crate::server::WS_MAX_MESSAGE_BYTES) {
                            Ok(text) => {
                                self.received.add(b.len(), text.len());
                                (text, true)
                            }
                            Err(e) => break Err(e),
                        },
                        Frame::Close(Some(close)) if close.code == tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode::Restart => {
                            break Ok(LinkEnd::Restarting);
                        }
                        Frame::Close(_) => break Err("peer closed the connection".to_owned()),
                        Frame::Pong(payload) => {
                            if let (Some(rtt), Some(via)) = (carriers::pong_rtt(&payload), self.serving()) {
                                self.path_pong(via, rtt);
                            }
                            continue;
                        }
                        _ => continue,
                    };
                    let msg = match Message::parse(&text) {
                        Ok(msg) => msg,
                        // Only large messages are compressed, and a reply among them would be
                        // lost while its caller waits: the link starts over, as for a frame
                        // that does not inflate.
                        Err(e) if compressed => break Err(format!("a compressed frame is not a JSON-RPC message: {e}")),
                        Err(_) => continue,
                    };
                    match msg {
                        Message::Response { id, result, error } => {
                            let key = id.to_string();
                            // Not held while a notice waits for room: a caller registers under it.
                            let tx = self.pending.lock().await.remove(&key);
                            self.on_wire.lock_or_recover().remove(&key);
                            self.dual_keys.lock_or_recover().remove(&key);
                            let Some(tx) = tx else { continue };
                            let reply = match error { Some(e) => Err(e), None => Ok(result.unwrap_or(Value::Null)) };
                            // A watch sent with `initialize` waits for the handshake to read that
                            // reply, and the changes after it wait with it (`paged`).
                            if self.pipelined_key.lock_or_recover().as_deref() == Some(key.as_str()) {
                                paged.get_or_insert_default();
                                pipelined = Some((key, reply, tx));
                                continue;
                            }
                            watch_reply!(key, reply, tx);
                        }
                        Message::Notification { method: m, params } => {
                            let p = params.unwrap_or(Value::Null);
                            if matches!(m.as_str(), method::MUX_EVENT | method::SESSION_UPDATE) {
                                let mut highwater = self.replay_highwater.lock_or_recover();
                                let id = p.get("sessionId").and_then(Value::as_str);
                                let seq = p.get("seq").and_then(Value::as_u64)
                                    .or_else(|| p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64));
                                if let (Some(id), Some(seq)) = (id, seq)
                                    && let Some(high) = highwater.get_mut(id)
                                {
                                    *high = (*high).max(seq);
                                    continue;
                                }
                                drop(highwater);
                            }
                            // Record before publishing the acceptance: a link can drop before the
                            // hub consumes its notice, but the original client still owns the turn.
                            if m == method::MUX_PROMPT_ACCEPTED {
                                self.note_prompt_accepted(&p);
                            }
                            let cursor_event = matches!(m.as_str(), method::MUX_EVENT | method::SESSION_UPDATE)
                                .then(|| {
                                    let id = p.get("sessionId")?.as_str()?.to_owned();
                                    let seq = p.get("seq").and_then(Value::as_u64)
                                        .or_else(|| p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64))?;
                                    Some((id, seq))
                                }).flatten();
                            // A live frame can have been queued before the final replay page,
                            // yet be read after the gate opens. Its sequence already arrived.
                            if let Some((id, seq)) = &cursor_event {
                                let replayed = {
                                    let mut tails = self.replay_tail.lock_or_recover();
                                    match tails.get(id) {
                                        Some(tail) if *seq > 0 && tail >= seq => true,
                                        Some(_) => { tails.remove(id); false }
                                        None => false,
                                    }
                                };
                                if replayed {
                                    continue;
                                }
                                // Sent on two paths while this one was in doubt: one merger
                                // hands each event to the hub once and in order, and moves the
                                // cursor as it does (`peer_dual.rs`).
                                let link = self.link_epoch();
                                let merged =
                                    self.merge_event(id, *seq, m, p, dual::Source::Link, link).await;
                                if merged == dual::Merged::Closed {
                                    break Ok(LinkEnd::Stopped);
                                }
                                continue;
                            }
                            // Only the link itself says a chat was attached again.
                            if m == REATTACHED_NOTICE {
                                continue;
                            }
                            let notice = if m == method::MUX_SESSION_CHANGED {
                                let session = p.get("session").cloned().unwrap_or(Value::Null);
                                // Remote session_changed notifications carry the
                                // peer name at the top level; older summaries
                                // also carry it inside `session`.
                                if p.get("peer").and_then(Value::as_str).is_some()
                                    || is_mirrored_session(&session)
                                {
                                    continue;
                                }
                                PeerNotice::SessionChanged {
                                    session,
                                    kind: p.get("kind").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    seq: p.get("seq").and_then(Value::as_u64).unwrap_or(0),
                                }
                            } else {
                                PeerNotice::Notification { method: m, params: p, link: self.link_epoch() }
                            };
                            // A change during a paged watch list goes after that list.
                            if let (Some((_, held)), PeerNotice::SessionChanged { .. }) = (paged.as_mut(), &notice) {
                                held.push(notice);
                                continue;
                            }
                            if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
                                break Ok(LinkEnd::Stopped);
                            }
                            if let Some((id, seq)) = cursor_event
                                && let Some(last) = self.cursors.lock_or_recover().get_mut(&id)
                            { *last = (*last).max(seq); }
                        }
                        Message::Request { id, method: m, params } if m == method::MUX_GITHUB_ACTION => {
                            // Asked after the watch reply the handshake holds: it waits for that
                            // reply to be settled (`deferred_github`).
                            if pipelined.is_some()
                                && !pipelined_settled
                                && deferred_github.len() < crate::github_broker::OWNER_SLOTS
                            {
                                deferred_github.push((id, params));
                                continue;
                            }
                            github_request!('link, id, params);
                        }
                        Message::Request { id, .. } => {
                            // Any other request from the peer: the broker's is the only one.
                            let refusal = Frame::Text(
                                Message::err(id, RpcError::method_not_found("client-side request")).to_value().to_string().into(),
                            );
                            match tokio::time::timeout(budget, sink.send(refusal)).await {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => break Err(e.to_string()),
                                Err(_) => break Err(stopped_reading(budget)),
                            }
                        }
                    }
                }
                line = out_rx.recv() => {
                    let Some(Outbound { epoch, key, line }) = line else { break Ok(LinkEnd::Stopped) };
                    // Admitted on a link that went down: its caller was failed
                    // with that link, so it never goes out on this one.
                    if epoch != self.link_epoch() {
                        continue;
                    }
                    // Before the frame is marked: a link a wake check drops never had it.
                    check_wake!();
                    // Marked before the write: a frame that is partly written may still run.
                    let prompt_key = key.as_ref();
                    if let Some(key) = prompt_key {
                        self.on_wire.lock_or_recover().insert(key.clone());
                    }
                    let text = line.trim_end_matches('\n').to_owned();
                    // While this path is in doubt the frame goes on another path too.
                    let text = self.dual_copy(text, prompt_key.map(String::as_str), link);
                    let until = write_deadline(tokio::time::Instant::now(), budget, wake_probe);
                    match tokio::time::timeout_at(until, sink.send(Frame::Text(text.into()))).await {
                        Ok(Ok(())) => {
                            // Once the prompt frame reaches the socket, the remote may have
                            // accepted it even if its acceptance notification is still queued
                            // behind the frame that caused this link to drop. Retain it for the
                            // durable outcome lookup across reconnects.
                            if let Some(key) = prompt_key
                                && let Some(prompt) = self.prompts.lock_or_recover().get_mut(key)
                            {
                                prompt.accepted = true;
                            }
                        }
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(write_late(budget, wake_probe)),
                    }
                }
            }
        };
        handshake.abort();
        result
    }
}

/// Whether GitHub may be lent over a link to `url`: ssh (what Add Machine saves) or TLS, or a
/// plain WebSocket only on this machine's loopback. Over plain `ws://` to another host the
/// handshake that makes a link a peer could come from anything on the path.
fn lends_over(url: &str) -> bool {
    let Ok(u) = reqwest::Url::parse(url) else { return false };
    let host = u.host_str().unwrap_or("").trim_start_matches('[').trim_end_matches(']');
    match u.scheme() {
        "ssh" => ssh_target(url).is_ok(),
        "wss" => true,
        "ws" => {
            host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
        }
        _ => false,
    }
}

/// How many of a link's chats its handshake attaches again at once after a reconnect.
const REATTACHES_AT_ONCE: usize = 16;

/// How long a link waits before each attach it tries again after one failed on it
/// ([`Peer::retry_attach`]): about a minute in all, then the chat waits for the next link.
const ATTACH_RETRY_AFTER: [Duration; 6] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
    Duration::from_secs(16),
    Duration::from_secs(30),
];

/// The chats a reconnect replays from their cursor. A cursor still at 0 has no baseline yet
/// unless a page settled it (`baselined`: the chat held nothing then); one with none (its first
/// attach did not answer, or an older peer gave no `pageThrough`) would send its whole history
/// again as live events if replayed, so it is attached without history after connect.
fn replayable(cursors: &HashMap<String, u64>, baselined: &HashSet<String>) -> Vec<(String, u64)> {
    cursors
        .iter()
        .filter(|(sid, c)| **c > 0 || baselined.contains(*sid))
        .map(|(sid, c)| (sid.clone(), *c))
        .collect()
}

/// The greatest event sequence an `_acpmux/attach` page holds, if it holds any.
fn page_max_seq(page: &Value) -> Option<u64> {
    page.get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| e.get("seq").and_then(Value::as_u64))
        .max()
}

/// Whether the peer itself refused an attach (`Peer::attach_hidden`): the chat is not there, or
/// the peer takes no such request. The link's own failures (dropped, timed out, too large, a
/// full queue) are internal errors or carry `peer_unreachable` / `peer_disconnected`, never
/// these codes.
pub(crate) fn refuses_attach(e: &RpcError) -> bool {
    matches!(e.code, -32002 | -32601 | -32602)
}

/// The sessions an `_acpmux/watch` reply lists, without the rows the peer itself mirrors.
fn watch_sessions(reply: &Value) -> Vec<Value> {
    reply
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|session| session.is_object() && !is_mirrored_session(session))
        .cloned()
        .collect()
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

    /// [`Self::watch_request_on`], asked again after the wait a peer's `list.paced` refusal
    /// names (a pre-#28182 peer refuses a list it would make wait more than 30 s). The
    /// handshake's deadline bounds the retries.
    /// The first `_acpmux/watch` a handshake asks for, and whether with tools, as the link knows
    /// the peer now: a delta of the list the last link read when the peer serves this daemon as
    /// a peer and answers with one, else the whole list without tools; None when the list is
    /// read in pages of rows (`build` needed them last time).
    fn first_watch(&self, build: Option<&String>) -> Option<(Value, bool)> {
        let watch = |tools: bool| json!({"enabled": true, "withTools": tools});
        let delta =
            self.watch_delta.load(Ordering::SeqCst) && self.served_as().as_deref() == Some("peer");
        let known = delta.then(|| self.known.lock_or_recover().to_param());
        if let Some(known) = known.filter(|k| k.as_object().is_some_and(|k| !k.is_empty())) {
            let tools = self.known_tools.load(Ordering::SeqCst);
            let mut asked = watch(tools);
            asked.set("known", known);
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
}

/// Drops a bound request's line from `switch_retry` once its caller has its answer or left.
struct ForgetRetry<'a> {
    peer: &'a Peer,
    key: String,
}

impl Drop for ForgetRetry<'_> {
    fn drop(&mut self) {
        self.peer.switch_retry.lock_or_recover().remove(&self.key);
    }
}

impl Drop for ForgetPending {
    fn drop(&mut self) {
        let Some(key) = self.key.take() else { return };
        self.on_wire.lock_or_recover().remove(&key);
        self.prompts.lock_or_recover().remove(&key);
        if let Ok(mut map) = self.pending.try_lock() {
            map.remove(&key);
        } else if let Ok(rt) = tokio::runtime::Handle::try_current() {
            let pending = self.pending.clone();
            rt.spawn(async move {
                pending.lock().await.remove(&key);
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
