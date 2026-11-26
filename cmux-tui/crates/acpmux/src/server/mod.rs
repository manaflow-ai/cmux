//! Client-facing side. acpmux acts as an ACP agent to every connection and
//! adds the `_acpmux/*` extension methods. Transports: Unix socket lines and
//! WebSocket text frames. Both feed `serve_connection`.

use crate::config::PermissionPolicy;
use crate::hub::{EventFilter, Hub, HubEvent, VERSION};
use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;
use crate::rpc::{Message, RpcError, method};
use crate::sender_harness::SocketPeer;
use crate::session_identity::SessionReceipt;
use anyhow::{Context, Result};
use cmux_local_auth::{ListenerPolicy, Refusal};
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::sync::{Semaphore, broadcast, mpsc};
/// Windows: the daemon socket is `cmux::local_socket` (AF_UNIX with its
/// same-user checks), in `windows_socket.rs`.
#[cfg(windows)]
pub use windows_socket::{UnixListener, bind_unix, router_admin, serve_unix};

// One module per line, in alphabetical order (with its attributes above it), so two pull
// requests that each add a module touch different lines and merge without a conflict.
mod account_sign_in;
mod accounts;
#[cfg(test)]
#[path = "ack_latency_bench.rs"]
mod ack_latency_bench;
#[cfg(test)]
#[path = "acp_list_tests.rs"]
mod acp_list_tests;
mod agent_home;
mod agent_login;
mod agent_messages;
mod app_assets;
mod app_reply;
#[cfg(test)]
mod attach_latency_bench;
mod auto_gate;
mod bg_tasks;
pub(crate) mod browser_workspaces;
#[cfg(test)]
#[path = "cancel_classes_tests.rs"]
mod cancel_classes_tests;
#[cfg(test)]
#[path = "cancel_prompt_tests.rs"]
mod cancel_prompt_tests;
pub mod carrier;
mod change_kind;
/// Agent byte channels (design A1, RFD 0164 B9).
pub(crate) mod channels;
mod chat_place;
#[cfg(test)]
#[path = "chat_window_activity_tests.rs"]
mod chat_window_activity_tests;
mod chat_windows;
#[cfg(test)]
#[path = "chatgpt_import_tests.rs"]
mod chatgpt_import_tests;
mod chats;
mod chunk_deltas;
pub(crate) mod client_features;
mod client_request;
#[cfg(test)]
#[path = "compressed_link_tests.rs"]
mod compressed_link_tests;
pub(crate) mod computer_use_relay;
pub mod conn_auth;
#[cfg(test)]
#[path = "connection_token_tests.rs"]
mod connection_token_tests;
pub(crate) mod connections;
pub(crate) mod controls;
pub(crate) mod dual_requests;
mod durable_gate;
mod ephemeral;
mod fanout;
#[cfg(test)]
#[path = "fanout_encode_tests.rs"]
mod fanout_encode_tests;
// Which connections a hub event wakes, and what that costs at 4, 16 and 64 connections.
#[cfg(test)]
#[path = "fanout_interest_tests.rs"]
mod fanout_interest_tests;
mod felt;
mod fill;
mod fix_from_link;
mod follow;
mod fork_through;
mod forum;
mod github_lane;
mod github_prs;
mod goal;
mod harness_admin;
mod harness_enable;
mod held_rows;
pub(crate) mod host_notice;
pub(crate) mod host_power;
mod in_flight;
#[cfg(test)]
#[path = "inbox_gate_tests.rs"]
mod inbox_gate_tests;
pub(crate) mod interest;
mod inventory_watch;
#[cfg(test)]
mod key_route_tests;
mod keys_relay;
mod lane_parent;
#[cfg(test)]
#[path = "latency_gauges_tests.rs"]
mod latency_gauges_tests;
mod link_v2_serve;
#[cfg(test)]
#[path = "list_fit_tests.rs"]
mod list_fit_tests;
#[cfg(test)]
#[path = "list_follow_link_tests.rs"]
mod list_follow_link_tests;
#[cfg(test)]
#[path = "list_pending_tests.rs"]
mod list_pending_tests;
mod list_reply;
#[cfg(test)]
#[path = "list_web_page_tests.rs"]
mod list_web_page_tests;
pub mod local_app;
pub(crate) mod machine_enroll;
mod machine_files_relay;
pub(crate) mod machine_health;
mod machine_join_ssh;
#[cfg(feature = "hub-carrier")]
mod machine_routes;
mod machine_tunnel;
mod mcp_connect;
mod media_forward;
mod memory_inbox;
mod mesh_control_send;
pub mod mesh_relay;
pub(super) mod mesh_send;
#[cfg(test)]
mod message_notice_tests;
#[cfg(test)]
#[path = "mirror_relay_tests.rs"]
mod mirror_relay_tests;
mod models_fanout;
mod move_targets;
mod new_worktree;
#[cfg(test)]
mod nodelay_tests;
#[cfg(test)]
#[path = "omit_time_breakdown_rows_tests.rs"]
mod omit_time_breakdown_rows_tests;
mod outbound;
#[cfg(test)]
mod outbound_queue_tests;
pub(crate) mod outbox;
mod pairing;
mod paused_files;
pub mod peer_auth;
mod peer_forward;
pub(crate) mod peer_status;
pub mod peer_text;
mod pending;
#[cfg(test)]
#[path = "person_prove_tests.rs"]
mod person_prove_tests;
mod place;
mod place_set;
mod plan_build;
mod processes;
mod project_new;
mod prompt_cancel;
mod prompt_coach;
pub(crate) mod queue_gauge;
mod races;
#[cfg(all(test, target_os = "linux"))]
#[path = "reader_bound_bench.rs"]
mod reader_bound_bench;
mod redact;
pub(crate) mod remote_guard;
#[cfg(test)]
#[path = "reply_size_tests.rs"]
mod reply_size_tests;
#[cfg(test)]
mod request_admission_tests;
mod requests;
mod review_queue;
mod routes;
mod run_elsewhere;
mod secrets;
mod send_check;
mod session_auth;
mod session_files;
#[cfg(test)]
#[path = "session_list_pages_tests.rs"]
mod session_list_pages_tests;
pub(crate) mod session_patch;
#[cfg(test)]
#[path = "session_patch_peer_tests.rs"]
mod session_patch_peer_tests;
mod share_host;
pub(crate) mod shutdown_drain;
#[cfg(test)]
#[path = "shutdown_drain_tests.rs"]
mod shutdown_drain_tests;
mod sign_in_follow;
#[cfg(test)]
#[cfg(unix)]
#[path = "socket_access_tests.rs"]
mod socket_access_tests;
pub(crate) mod ssh_carry;
mod stream;
mod stream_cursor;
#[cfg(test)]
#[path = "stream_cursor_tests.rs"]
mod stream_cursor_tests;
mod subsessions;
mod surgery;
/// The stable tailnet node's front on the embedded node (`tailnet.stableNode.enabled`).
#[cfg(all(unix, feature = "tailnet"))]
pub(crate) mod tailnet_front;
/// Owner-only TLS ingress from the embedded tailnet node.
#[cfg(all(unix, feature = "tailnet"))]
pub mod tailnet_ingress;
/// The embedded tailnet listener's lifecycle, a server module (it serves the hub through
/// `tailnet_ingress`; it was `tailnet::embedded_service`). Its file stays where it was: the
/// spawn-owner ratchet (`check-spawn-owner.py`) keeps its row by path and does not follow a move.
#[cfg(all(unix, feature = "tailnet"))]
#[path = "../tailnet/embedded_service.rs"]
pub(crate) mod tailnet_service;
mod team;
mod trigger_authority;
mod trigger_chat;
pub(crate) mod trust_gate;
// What one change costs the watchers at 100, 1,000 and 3,000 sessions (manual).
#[cfg(test)]
#[path = "update_cost_bench.rs"]
mod update_cost_bench;
pub mod upload_frames;
mod vault;
mod view;
mod vm_host;
pub(crate) mod wait;
#[cfg(test)]
#[cfg(unix)]
#[path = "wake_held_tests.rs"]
mod wake_held_tests;
mod web_device;
#[cfg(windows)]
mod windows_socket;
mod workflow_activity;
mod workflow_runs;
mod worktrees;
mod ws_peek;
mod ws_read_ahead;
mod ws_shutdown;
pub(crate) use ws_shutdown::DRAIN_BUDGET as WS_DRAIN_BUDGET;
pub use ws_shutdown::WsShutdown;

/// How one connection receives one attached session's live records.
#[derive(Debug, Clone, Default)]
pub struct SubOpts {
    /// Every record arrives as `_acpmux/event` (agent notifications nested
    /// in `msg`) instead of `session/update` plus `_acpmux/event`.
    pub event_stream: bool,
    /// With `event_stream`, only records this filter passes are sent.
    pub filter: EventFilter,
    /// Attached without showing the chat (`view.rs`).
    pub hidden: bool,
    /// Shows the chat, but its person is not attending (`_acpmux/view` `attending: false`):
    /// counted in `Session::idle` while not `hidden` (`view.rs`).
    pub idle: bool,
    /// A peer's chat, attached through this daemon (`peer_forward.rs`): this daemon's presence
    /// for the same raw id is never its (`hub/presence.rs`).
    pub remote: bool,
    /// Follows the chat's transcript rows (`_acpmux/rows` `follow`): each live record's row
    /// changes go out as `_acpmux/rows_patch` (`rows/serve.rs`).
    pub rows: Option<Arc<crate::rows::Following>>,
    /// Attached with `omitTimeBreakdown: true` (the phone, which draws no breakdown): the chat's
    /// `_acpmux/session_changed` rows to this connection leave `timeBreakdown` out too, as the
    /// attach reply does (`requests/time_breakdown_gate.rs`). A full row of a long chat is mostly
    /// that field (32 KiB of 36 KiB at 3,000 records, the time-away bench).
    pub omit_time_breakdown: bool,
    /// The client draws nothing of the chat while it is `hidden` (`_acpmux/attach`
    /// `quietHidden`, the app's pane): its agent's `session/update` stream is left out until a
    /// view shows it, which then says how much in one `_acpmux/lagged` (`view.rs`).
    pub quiet_hidden: bool,
    /// Stream records left out since the chat was last shown here (`quiet_hidden`).
    pub left_out: u64,
    /// The cursor before the first of them (its seq less one): the show's `_acpmux/lagged` names it
    /// as `afterSeq`, since the turn ends and status records that still went out moved the client's
    /// own cursor past the chunks it never got (`view.rs`).
    pub left_from: u64,
}

/// Whether `conn` attached `session_id` asking for no `timeBreakdown` (`SubOpts`).
fn omits_time_breakdown(conn: &Conn, session_id: &str) -> bool {
    conn.subs.lock_or_recover().get(session_id).is_some_and(|o| o.omit_time_breakdown)
}

/// Which of one chat's `_acpmux/message` records a connection has heard, so each reaches it once.
/// A record comes live, in seq order (`live`), or from this connection's own `session/load`
/// replay (`replay`), which starts a fresh `MessageNotices`: a reopen hears the history again,
/// but not a record the live stream sent during that replay. A peer's chat replays over the one
/// link every viewer here shares: those records come to every viewer as live ones, so a viewer
/// that heard them already hears them no more; the one that asked starts fresh too
/// (`peer_forward.rs`).
/// Each record by its own seq: a replay's older records may come after a newer live one.
/// Bounded: past `MESSAGE_NOTICES_KEPT` seqs, the lowest is dropped and the low-water mark
/// `floor` rises to it. A live record at or below the mark counts as heard (the live stream
/// comes in seq order, so it sent it). A replay record is checked against the kept seqs alone:
/// one the bound forgot may go a second time, never not at all.
#[derive(Default)]
pub(super) struct MessageNotices {
    heard: std::collections::BTreeSet<u64>,
    floor: u64,
}

/// How many heard seqs one chat's `MessageNotices` keeps above its low-water mark.
pub(super) const MESSAGE_NOTICES_KEPT: usize = 4096;

impl MessageNotices {
    /// The replay's notice of record `seq`: sent unless the live stream sent it and it is still
    /// kept. The mark is not applied: the replay's older records may come after the live stream
    /// raised it, never having been sent.
    pub(super) fn replay(&mut self, seq: u64) -> bool {
        if seq == 0 {
            return true;
        }
        let fresh = self.heard.insert(seq);
        self.bound();
        fresh
    }

    /// The live notice of record `seq`: sent unless this connection heard it. A record of no
    /// known seq (0) is always sent.
    pub(super) fn live(&mut self, seq: u64) -> bool {
        if seq == 0 {
            return true;
        }
        if seq <= self.floor || !self.heard.insert(seq) {
            return false;
        }
        self.bound();
        true
    }

    /// Keeps at most `MESSAGE_NOTICES_KEPT` seqs, raising the mark to the ones it drops.
    fn bound(&mut self) {
        while self.heard.len() > MESSAGE_NOTICES_KEPT {
            if let Some(lowest) = self.heard.pop_first() {
                self.floor = self.floor.max(lowest);
            }
        }
    }

    #[cfg(test)]
    fn kept(&self) -> usize {
        self.heard.len()
    }
}

/// A connection's `MessageNotices`, one per chat it hears: by the chat's owner (None for this
/// daemon, Some(peer) for a peer's chat) and raw id. A peer's chat may keep the raw id of one here
/// (an export and import keeps ids), and each counts its own seqs.
#[derive(Default)]
pub(super) struct MessageNoticeBook {
    chats: HashMap<(Option<String>, String), MessageNotices>,
}

impl MessageNoticeBook {
    /// A fresh count for this connection's own reopen of the chat; one raw id is one owner's chat
    /// on a connection (`view::subscribe_remote`), so the other owner's count ends.
    pub(super) fn reopen(&mut self, owner: Option<&str>, id: &str) {
        self.chats.retain(|(_, i), _| i != id);
        self.chats.insert((owner.map(str::to_owned), id.to_owned()), MessageNotices::default());
    }

    /// `MessageNotices::live` for the chat.
    pub(super) fn live(&mut self, owner: Option<&str>, id: &str, seq: u64) -> bool {
        self.chats.entry((owner.map(str::to_owned), id.to_owned())).or_default().live(seq)
    }

    /// `MessageNotices::replay` for the chat; a chat with no count (none reopened) always sends.
    pub(super) fn replay(&mut self, owner: Option<&str>, id: &str, seq: u64) -> bool {
        self.chats.get_mut(&(owner.map(str::to_owned), id.to_owned())).is_none_or(|n| n.replay(seq))
    }

    /// The connection no longer hears the chat.
    pub(super) fn forget(&mut self, owner: Option<&str>, id: &str) {
        self.chats.remove(&(owner.map(str::to_owned), id.to_owned()));
    }

    /// The connection no longer hears raw id `id` from any owner but `keep`.
    pub(super) fn forget_others(&mut self, keep: Option<&str>, id: &str) {
        self.chats.retain(|(o, i), _| i != id || o.as_deref() == keep);
    }
}

/// Only the local byte stream can switch from JSON-RPC to a pipe on its first line.
enum Transport {
    Messages,
    LocalStream {
        /// The verified root peer of a Cloud VM's non-root daemon (daemon/provision.rs).
        provisioner: bool,
    },
}

pub struct Conn {
    /// The owner of this connection's own tasks (each request it sent, a reply waiting for room),
    /// a child of the hub's scope. A request a client sent before it hung up still runs to its
    /// end (a `--no-wait` send is accepted), so the connection's end does not cancel them; the
    /// hub's shutdown does, and joins them.
    scope: cmux_scope::Scope,
    pub id: String,
    /// The listener this connection came in on.
    pub origin: Origin,
    /// The proof it presented (`conn_auth.rs`); what the mode rule reads.
    pub auth: ConnAuth,
    /// The paired machine whose credential it presented (`ConnAuth::Device`
    /// or `ReadOnlyDevice`), from the handshake only, never from a request.
    device: Option<String>,
    /// The person the Cloud carrier attested (`carrier.rs`), from the carrier socket's upgrade
    /// header only, never from a request. Set exactly when `auth` is a carrier proof.
    carrier: Option<carrier::Attested>,
    /// It reads session text raw (`peer_text.rs`): every origin but a peer.
    raw_text: bool,
    name: StdMutex<String>,
    /// Its count in the daemon's unused rule (`daemon/unused_exit.rs`): an `initialize` that says
    /// it only observes marks it, so it keeps nothing once the owner app exited.
    presence: crate::daemon::unused_exit::Presence,
    /// Its outbound queue, bounded in bytes (`outbound.rs`): every line goes there, in order.
    out: Arc<outbound::Outbound>,
    /// Holds its lines until what they may show is durable (`durable_gate.rs`); None without the
    /// event journal.
    gate: Option<Arc<durable_gate::Gate>>,
    /// True once the client stopped sending (its read side ended): it exited or hung up.
    ended: tokio::sync::watch::Sender<bool>,
    /// Per-session preparation cancellation; no capability or owner token is retained.
    preparation_cancels: StdMutex<HashMap<String, tokio::sync::watch::Sender<bool>>>,
    subs: StdMutex<HashMap<String, SubOpts>>,
    /// Where each attached chat's live stream stands, so a lap of the event ring is read back
    /// from the store (`stream_cursor.rs`).
    stream_cursors: stream_cursor::StreamCursors,
    /// The rows of an attached chat's turn-opening records, held so the turn's first output is
    /// not queued behind them (`held_rows.rs`).
    held_rows: held_rows::HeldRows,
    /// The chats attached here that moved to a peer, or are being moved (`follow.rs`).
    follows: follow::Follows,
    /// The chats a `session/load` replayed here: their message notices go once.
    message_notices: StdMutex<MessageNoticeBook>,
    /// Server-derived mailbox identities for this connection's local attachments.
    mailbox_bindings: StdMutex<HashMap<String, SessionReceipt>>,
    controls: controls::Controls,
    /// The sessions this connection's own `session/new` created here, newest last (at most
    /// [`Conn::MAX_CREATED`]): what `_acpmux/side` may tag besides a fork of the chat.
    created: StdMutex<std::collections::VecDeque<String>>,
    /// Which hub events wake its fan-out (`interest.rs`): its attachments, its watch, its chats
    /// activity. Changed beside `subs` and `watch_all`, never instead of them.
    interest: interest::Interest,
    watch_all: AtomicBool,
    watch_tools: AtomicBool,
    /// The client asked, in its `initialize` (`_meta.acpmux.peerRowBatches`), to hear a burst of
    /// one peer's rows as one `_acpmux/peer_rows_changed` (`Events::send_remote_batch`) and
    /// follow the list for them, not one `session_changed` per row.
    peer_row_batches: AtomicBool,
    /// The features its `initialize` listed (`client_features.rs`): a gated notification goes
    /// to it only once it listed the gate.
    client_features: client_features::ClientFeatures,
    /// Compact text chunks on its event streams (`chunk_deltas.rs`), when its `initialize` asked.
    chunk_deltas: chunk_deltas::ChunkDeltas,
    /// The client asked, in its `initialize` (`_meta.acpmux.sessionChangedDelta`), to hear a chat's
    /// row changes after the first as `_acpmux/session_patch`; `sent_rows` keeps what it holds.
    session_delta: AtomicBool,
    sent_rows: StdMutex<session_patch::SentRows>,
    /// The client draws no time breakdown and asked, in its `initialize`
    /// (`_meta.acpmux.omitTimeBreakdown`), for none in any row: its attaches and the
    /// `session_changed` of the chats it attached (`requests/time_breakdown_gate.rs`).
    omit_time_breakdown: AtomicBool,
    /// Other chats' `session_changed` rows left out while every chat this connection attached was
    /// hidden from a client that draws nothing then (`SubOpts::quiet_hidden`, `leaves_out_row`).
    /// Changed under `subs`' lock, so the show that ends it (`view.rs`) sends one `_acpmux/lagged`
    /// with `watch: true` that covers every row left out, and the page reads the list again.
    rows_left_out: AtomicU64,
    watch_inventory: StdMutex<bool>,
    /// The unix socket peer's audit token, read at accept (macOS); what
    /// `_acpmux/person_enroll` checks. None for WebSocket connections.
    peer: Option<cmux_link::app_caller::PeerToken>,
    /// The unix socket peer's pid, read at accept (`SO_PEERCRED`, `LOCAL_PEERPID`), or the daemon's
    /// own outbox: where a send's process chain is walked from and whose check is carried
    /// (`sender_harness::check_trust`), provenance only, never a proof.
    pub(super) socket_peer: crate::sender_harness::SocketPeer,
    transport: Transport,
    /// Requests seen so far (`hub/person.rs`: initialize first, the proof second).
    requests: std::sync::atomic::AtomicU64,
    /// Its first request was an `initialize` that got the person challenge.
    challenged: AtomicBool,
    /// This connection's challenge nonce (`hub/person.rs`).
    pub(super) nonce: String,
    /// It proved the person key for its challenge.
    person: AtomicBool,
    /// A Cloud trigger connection is an explicitly scoped principal. It is
    /// never inferred from the local socket and it cannot become a person.
    /// The scope lives only for this connection and is never persisted.
    trigger: StdMutex<Option<TriggerScope>>,
    /// `_acpmux/person_holds` calls on this connection (`hub/person.rs`).
    pub(super) holds_calls: std::sync::atomic::AtomicU32,
    /// `_acpmux/person_prove` calls on this connection (`hub/person.rs`, at most
    /// `PROVES_PER_CONNECTION`).
    pub(super) prove_calls: std::sync::atomic::AtomicU32,
    /// The acpmux session it runs in, proven at its first `initialize` (`hub/person.rs` (a)).
    caller: std::sync::OnceLock<String>,
    /// The session a first unix `initialize` named with a token that did not prove it.
    pub(super) unproven_caller: std::sync::OnceLock<String>,
    /// What a first unix `initialize` declared about its caller (`cli_caller.rs`); unset for a
    /// client that is no acpmux CLI and declared nothing.
    declared: std::sync::OnceLock<crate::cli_caller::Declared>,
    /// The peers this connection leased (`hub/peer_lease.rs`); None once it
    /// closed, so a lease that settles after the close ends at once.
    peer_leases: StdMutex<Option<Vec<crate::hub::PeerLease>>>,
    /// The ephemeral sessions it created, purged when it closes (`ephemeral.rs`);
    /// None once it closed.
    ephemeral: StdMutex<Option<Vec<String>>>,
    /// The media files it opened (`hub/media_read.rs`), closed when it closes.
    media: crate::hub::media_handles::Handles,
    /// The media files of peers' chats it opened, closed on the peer when it closes
    /// (`media_forward.rs`).
    pub(super) remote_media: media_forward::RemoteMedia,
    /// Requests this daemon sent the client, waiting on its answer (`client_request.rs`).
    client_requests: client_request::ClientRequests,
    /// The client's requests being served, by id, with their slots: what its
    /// `$/cancel_request` finds (`in_flight.rs`).
    in_flight: in_flight::InFlight,
    /// Its windows over the chat index (`chat_windows.rs`).
    chat_windows: chat_windows::ConnWindows,
    /// A WebSocket's compression, which its `initialize` turns on (`frame_compress.rs`); None
    /// on a transport whose writer does not compress.
    wire: Option<Arc<crate::frame_compress::Wire>>,
    /// Who it is to the book of requests sent on two paths (`dual_requests.rs`): only a peer
    /// daemon's own link over the WebSocket listener (its peer token proven at the upgrade) has
    /// one. Every other connection's `dualId` is ignored.
    pub(crate) dual_principal: Option<&'static str>,
    /// This link carries the v2 list stream: its `initialize` reply names `listStream`
    /// (`link_v2.rs`).
    pub(crate) list_stream: bool,
    /// A browser's own enrolled device on the mesh hub (`web_device.rs`): set once, only by
    /// `_acpmux/device_hello` on a web connection the listener token proved, and dropped for
    /// good when the hub revokes it. Its hub reads and prompts go with this client's credential,
    /// never with this daemon's identity (`mesh_read.rs` `read_hub`). The credential lives only
    /// here, in memory, and is wiped when the client is dropped.
    pub(super) device_mesh: StdMutex<web_device::Slot>,
    /// The Origin of the page that opened this `/app/ws` socket, as the upgrade's listener
    /// policy admitted it; None on every other transport. A browser sign-in is bound to it.
    pub(super) page_origin: Option<String>,
    /// This connection's one pending browser email-code sign-in (`web_device.rs`): a new
    /// `_acpmux/browser_sign_in_start` replaces it, `_complete` takes it before it awaits.
    /// Dropped with the connection.
    pub(super) browser_sign_in: StdMutex<Option<cmux_stack_auth::BrowserSignIn>>,
    /// Its fan-out's drain, which a turn's answer waits on (`fanout::Flush`).
    fan_flush: fanout::Flush,
}

/// The only authority a trigger connection carries after platform admission.
/// Every field is pinned to one machine/chat/delivery; no bearer or owner
/// credential is retained here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TriggerScope {
    pub trigger: String,
    pub owner: String,
    pub team: String,
    pub machine: String,
    pub workspace: String,
    pub session: String,
    pub delivery: String,
    pub prompt_hash: String,
    pub cwd: String,
    pub harness: String,
    pub guest_key: String,
}

// Bound only request handlers that do finite work on behalf of the connection.
// A prompt or wait can remain open for an entire agent turn, so counting it
// here would make unrelated prompts fail after an arbitrary burst of work.
const REQUEST_WORK_LIMIT: usize = 64;
const NOTIFICATION_QUEUE_LIMIT: usize = 16;
const NOTIFICATION_WORK_LIMIT: usize = 16;
const NOTIFICATION_WAIT_LIMIT: usize = 64;
const WORK_BACKPRESSURE_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

fn request_uses_work_budget(method: &str) -> bool {
    !matches!(
        method,
        method::SESSION_NEW
            | method::SESSION_LOAD
            | method::SESSION_RESUME
            | method::SESSION_FORK
            | method::SESSION_PROMPT
            | method::MUX_ATTACH
            | method::MUX_WAIT
    )
}

fn try_request_slot(
    slots: &Arc<Semaphore>,
    method: &str,
) -> Result<Option<tokio::sync::OwnedSemaphorePermit>, ()> {
    if !request_uses_work_budget(method) {
        return Ok(None);
    }
    slots.clone().try_acquire_owned().map(Some).map_err(|_| ())
}

fn notification_deadline(method: &str) -> Option<std::time::Duration> {
    (method != crate::rpc::method::SESSION_CANCEL).then_some(WORK_BACKPRESSURE_WAIT)
}

enum NotificationAdmission {
    Accepted,
    Closed,
    Dropped,
}

fn admit_notification(
    tx: &mpsc::Sender<(String, Value)>,
    waiter_slots: &Arc<Semaphore>,
    waits: &mut Vec<tokio::task::JoinHandle<()>>,
    item: (String, Value),
) -> NotificationAdmission {
    waits.retain(|waiter| !waiter.is_finished());
    match tx.try_send(item) {
        Ok(()) => NotificationAdmission::Accepted,
        Err(mpsc::error::TrySendError::Closed(_)) => NotificationAdmission::Closed,
        Err(mpsc::error::TrySendError::Full(item)) => {
            let Ok(waiter_slot) = waiter_slots.clone().try_acquire_owned() else {
                return NotificationAdmission::Dropped;
            };
            let tx = tx.clone();
            waits.push(tokio::spawn(async move {
                let _waiter_slot = waiter_slot;
                // Waiters race with direct sends. This does not affect current
                // handlers: only session/cancel notifications have effects.
                let _ = tx.send(item).await;
            }));
            NotificationAdmission::Accepted
        }
    }
}

fn spawn_notification_worker<F, Fut>(
    mut notifications: mpsc::Receiver<(String, Value)>,
    handler: F,
) -> tokio::task::JoinHandle<()>
where
    F: Fn(String, Value) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    tokio::spawn(async move {
        let mut handlers = tokio::task::JoinSet::new();
        while let Some((notification_method, params)) = notifications.recv().await {
            let handler = handler.clone();
            handlers.spawn(async move {
                if let Some(deadline) = notification_deadline(&notification_method) {
                    let _ =
                        tokio::time::timeout(deadline, handler(notification_method, params)).await;
                } else {
                    // Cancellation must run to completion: Hub::cancel does
                    // cleanup before scheduling its forced turn end.
                    handler(notification_method, params).await;
                }
            });
            if handlers.len() >= NOTIFICATION_WORK_LIMIT {
                let _ = handlers.join_next().await;
            }
        }
        while handlers.join_next().await.is_some() {}
    })
}

impl Conn {
    const MAX_CREATED: usize = 256;

    /// Records a session this connection's `session/new` just created here.
    pub(crate) fn note_created(&self, session: &str) {
        let mut created = self.created.lock().unwrap_or_else(|e| e.into_inner());
        if created.len() >= Self::MAX_CREATED {
            created.pop_front();
        }
        created.push_back(session.to_owned());
    }

    /// True when this connection's own `session/new` created `session` here.
    pub(crate) fn created_here(&self, session: &str) -> bool {
        self.created.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|id| id == session)
    }

    fn preparation_cancel(&self, session: &str) -> tokio::sync::watch::Receiver<bool> {
        self.preparation_cancels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(session.to_owned())
            .or_insert_with(|| tokio::sync::watch::Sender::new(false))
            .subscribe()
    }

    fn cancel_preparation(&self, session: &str) {
        if let Some(cancel) =
            self.preparation_cancels.lock().unwrap_or_else(|e| e.into_inner()).remove(session)
        {
            cancel.send_replace(true);
        }
    }

    /// The proof this connection holds now: its `auth`, or [`ConnAuth::WebDevice`] once a
    /// browser presented its own device (`web_device.rs`). Every rule still reads `auth`.
    pub(super) fn proof(&self) -> ConnAuth {
        if matches!(self.auth, ConnAuth::ListenerToken | ConnAuth::BrowserApp)
            && matches!(
                *self.device_mesh.lock().unwrap_or_else(|e| e.into_inner()),
                web_device::Slot::Device(_)
            )
        {
            return ConnAuth::WebDevice;
        }
        self.auth
    }

    /// A browser on the web listener that presented its own device on this connection
    /// (`web_device.rs`), whether the hub still takes it or revoked it since: its prompts to a
    /// hub-listed chat go to `mesh_read.rs` `prompt`, which answers `device.revoked` for a
    /// revoked one.
    pub(super) fn presented_web_device(&self) -> bool {
        matches!(self.auth, ConnAuth::ListenerToken | ConnAuth::BrowserApp)
            && !matches!(
                *self.device_mesh.lock().unwrap_or_else(|e| e.into_inner()),
                web_device::Slot::Empty
            )
    }

    /// Whether this connection is the person (`hub/person.rs`).
    pub(super) fn is_person(&self) -> bool {
        self.person.load(Ordering::SeqCst) && !self.is_trigger()
    }

    pub(super) fn is_trigger(&self) -> bool {
        self.trigger.lock_or_recover().is_some()
    }

    /// Admit the first verified scope, or require retries to carry the exact
    /// same scope. This prevents a connection from being retargeted between
    /// deliveries while retaining its trigger principal.
    pub(super) fn admit_trigger(&self, scope: TriggerScope) -> Result<(), RpcError> {
        let mut current = self.trigger.lock_or_recover();
        if self.person.load(Ordering::SeqCst) {
            return Err(RpcError::new(-32001, "a person connection cannot become a trigger"));
        }
        match current.as_ref() {
            Some(existing) if existing == &scope => Ok(()),
            Some(_) => Err(RpcError::new(-32001, "trigger scope changed on this connection")),
            None => {
                *current = Some(scope);
                Ok(())
            }
        }
    }

    /// The acpmux session this connection proved it runs in (`hub/person.rs` (a)).
    pub(super) fn caller(&self) -> Option<&str> {
        self.caller.get().map(String::as_str)
    }

    /// Who closes `target` when this connection asks (`close_why.rs`): a peer daemon or remote
    /// client by its paired machine, the app's pane, an agent closing itself, or the local CLI
    /// (with the session it runs in, when it proved one, and its pid).
    pub(super) fn close_actor(&self, target: &str) -> crate::close_why::CloseActor {
        use crate::close_why::CloseActor;
        let pid = match self.socket_peer {
            crate::sender_harness::SocketPeer::Pid(pid) => Some(pid),
            _ => None,
        };
        let caller = self.caller();
        let kind = match self.origin {
            Origin::Peer => "peer",
            Origin::Web => "web",
            Origin::LocalApp => "app",
            Origin::Local if caller == Some(target) => "agent_self",
            Origin::Local => "cli",
        };
        CloseActor::new(kind).session(caller).host(self.device.as_deref()).pid(pid)
    }

    /// Who this connection is in the caller stats (`caller_stats.rs`): its client name, origin,
    /// unix peer pid and the session its first `initialize` named.
    fn stats_caller(&self) -> crate::caller_stats::Caller {
        let pid = match self.socket_peer {
            crate::sender_harness::SocketPeer::Pid(pid) => Some(pid),
            _ => None,
        };
        let session = self.caller.get().map(|id| (id.clone(), true));
        let session = session.or_else(|| self.unproven_caller.get().map(|id| (id.clone(), false)));
        crate::caller_stats::Caller {
            client: self.name.lock_or_recover().clone(),
            origin: origin_usage_key(self.origin),
            pid,
            proven: session.as_ref().is_some_and(|(_, proven)| *proven),
            session: session.map(|(id, _)| id),
        }
    }

    /// What its first `initialize` declared about its caller (`cli_caller.rs`).
    pub(super) fn declared(&self) -> Option<&crate::cli_caller::Declared> {
        self.declared.get()
    }

    /// Whether an unnamed send on it may still be the owner's terminal send: it declared a
    /// terminal, or it is no acpmux CLI and declared nothing (`requests.rs` `owner_terminal`).
    pub(super) fn may_be_owner_terminal(&self) -> bool {
        self.declared().is_none_or(crate::cli_caller::Declared::may_be_owner_terminal)
    }

    /// Whether an agent may be behind it rather than the owner's terminal: it named a session
    /// (proven or not), or it declared no terminal (`cli_caller.rs`). Never for the proven person.
    pub(super) fn agent_side(&self) -> bool {
        !self.is_person()
            && (self.caller().is_some()
                || self.unproven_caller.get().is_some()
                || !self.may_be_owner_terminal())
    }

    /// Whether it proved no session and an agent may be behind it: neither the person's terminal
    /// nor a proven agent (an old acpmux CLI, a shell that declared no terminal, a token this
    /// daemon does not know). Such a connection gets no person verb (team messages, the
    /// person's workflow runs) and no agent's either.
    pub(super) fn unproven_agent(&self) -> bool {
        self.caller().is_none() && self.agent_side()
    }

    /// The refusal of `what` for this connection: `otherwise`, or, for an old acpmux CLI that
    /// proved no session, the one refusal that names it and says which CLI to run
    /// (`cli_caller::old_cli_refused`). A proven agent on an old CLI is refused as any agent: an
    /// update would not change its answer.
    pub(super) fn refusal(
        &self,
        what: &str,
        otherwise: crate::rpc::RpcError,
    ) -> crate::rpc::RpcError {
        let old = self.declared().and_then(crate::cli_caller::Declared::old_client);
        match old.filter(|_| self.caller().is_none()) {
            Some(client) => crate::cli_caller::old_cli_refused(client, what),
            None => otherwise,
        }
    }

    /// The refusal of a verb only the person's own terminal may use, for this connection
    /// ([`Conn::refusal`] of `person_required`).
    pub(super) fn person_only(&self, what: &str) -> crate::rpc::RpcError {
        self.refusal(what, crate::hub::person::person_required(what))
    }

    /// Whether this connection gets the person challenge: the unix socket or the proven local app.
    pub(super) fn challengeable(&self) -> bool {
        matches!(self.origin, Origin::Local | Origin::LocalApp)
    }

    /// The person binding (`hub/person.rs`), in order before the request
    /// runs. A `personKey` in any request is stripped and never read. A
    /// local connection whose FIRST request is `initialize` is challenged;
    /// a later `_acpmux/person_prove` (the second request, or any after it, at most
    /// `PROVES_PER_CONNECTION`) makes it the person when the proof matches its own nonce and
    /// id. Nothing else ever does. A proof checked here, in order, makes the person before the
    /// next request is bound; one that came before this run's key is checked again by its
    /// handler once the key comes (`requests.rs`, `PersonGate::proves_when_keyed`).
    fn bind_person(&self, hub: &Hub, m: &str, params: &mut Option<Value>) {
        let _ = params.as_mut().and_then(crate::hub::person::take_key);
        // Stripped from every request; read from a first unix `initialize` only (person.rs (a)).
        let caller = params.as_mut().and_then(crate::hub::person::take_caller);
        let n = self.requests.fetch_add(1, Ordering::SeqCst) + 1;
        if n == 1 && m == method::INITIALIZE && self.challengeable() {
            self.challenged.store(true, Ordering::SeqCst);
        }
        let first_local = n == 1 && m == method::INITIALIZE && self.origin == Origin::Local;
        if let Some(declared) =
            params.as_ref().filter(|_| first_local).and_then(crate::cli_caller::of_initialize)
        {
            let _ = self.declared.set(declared);
        }
        if let Some((id, token)) = caller.filter(|_| first_local) {
            let proven = hub.proven_caller((id.clone(), token)).is_some();
            let _ = if proven { &self.caller } else { &self.unproven_caller }.set(id);
        }
        if n >= 2 && m == method::MUX_PERSON_PROVE && self.may_prove() {
            let proof = params.as_ref().and_then(|p| p.get("proof")).and_then(Value::as_str);
            if proof.is_some_and(|p| {
                hub.person.proves(self.person_transport(), &self.nonce, &self.id, p)
            }) {
                self.person.store(true, Ordering::SeqCst);
            }
        }
    }

    /// Whether this connection may still try `_acpmux/person_prove`: it was challenged and has
    /// used fewer than `PROVES_PER_CONNECTION` tries. Counts this try.
    fn may_prove(&self) -> bool {
        self.challenged.load(Ordering::SeqCst)
            && self.prove_calls.fetch_add(1, Ordering::SeqCst)
                < crate::hub::person::PROVES_PER_CONNECTION
    }

    /// The transport a person proof on this connection names (`hub/person.rs`).
    pub(super) fn person_transport(&self) -> &'static str {
        match self.origin {
            Origin::LocalApp => crate::hub::person::TRANSPORT_APP,
            _ => crate::hub::person::TRANSPORT_UNIX,
        }
    }

    /// `_acpmux/person_prove`'s answer: whether this connection is the person now. A proof that
    /// `bind_person` could not check (this run holds no key yet, or one the app is replacing)
    /// stays pending until a key it answers is enrolled, then makes the connection the person;
    /// it ends unproven only when the connection closes. Requests run concurrently, so a pending
    /// prove holds nothing else on the connection.
    pub(super) async fn settle_prove(&self, hub: &Hub, params: &Value) -> bool {
        if self.is_person() {
            return true;
        }
        let tried = self.prove_calls.load(Ordering::SeqCst);
        if !self.challenged.load(Ordering::SeqCst)
            || tried == 0
            || tried > crate::hub::person::PROVES_PER_CONNECTION
        {
            return false;
        }
        let Some(proof) = params.get("proof").and_then(Value::as_str) else { return false };
        let keyed =
            hub.person.proves_when_keyed(self.person_transport(), &self.nonce, &self.id, proof);
        tokio::select! {
            () = keyed => self.person.store(true, Ordering::SeqCst),
            () = self.closed() => {}
        }
        self.is_person()
    }

    /// Hold `lease` until this connection closes; ended now if it already did.
    pub(super) fn hold_peer_lease(&self, hub: &Hub, lease: crate::hub::PeerLease) {
        let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        match leases.as_mut() {
            Some(held) => {
                // A renewal supersedes the earlier lease of its name, whose
                // end would be a no-op (another generation holds the name).
                held.retain(|old| old.name != lease.name);
                held.push(lease);
            }
            None => {
                drop(leases);
                hub.end_peer_lease(&lease);
            }
        }
    }

    /// The connection closed: every peer it leased stops.
    fn end_peer_leases(&self, hub: &Hub) {
        let held = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).take();
        for lease in held.unwrap_or_default() {
            hub.end_peer_lease(&lease);
        }
    }

    /// Resolves once the client is gone: nobody reads its replies any more, or it stopped
    /// sending. A unix socket's writer learns of a closed socket only when it writes, so the
    /// read side ending counts too.
    async fn closed(&self) {
        let mut ended = self.ended.subscribe();
        tokio::select! {
            () = self.out.closed() => {}
            _ = ended.wait_for(|ended| *ended) => {}
        }
    }

    fn send(&self, msg: &Message) {
        self.send_replying(msg, None);
    }

    /// The next line may show every change acknowledged so far (`durable_gate.rs`).
    fn raise_gate(&self) {
        if let Some(gate) = &self.gate {
            gate.raise();
        }
    }

    /// A notification line built for every connection that reads it raw (a shared `session/update`,
    /// `HubEvent::update_line`), as `send` would enqueue it for a local connection.
    // perf-hot: 1us acpmux-token-fanout (every streamed token, per attached connection)
    fn send_line(&self, line: &str) {
        self.raise_gate();
        if crate::perf_watch::on() {
            self.perf_bytes(|| crate::rpc::method::SESSION_UPDATE.to_owned(), line.len());
        }
        self.out.push(line.to_owned());
    }

    /// The perf watch's meter (`perf_watch.rs`, on only): `what` went to this client.
    fn perf_bytes(&self, what: impl FnOnce() -> String, bytes: usize) {
        crate::perf_watch::bytes(
            crate::perf_watch::channel_of(self.origin),
            || {
                let name = self.name.lock_or_recover();
                let client = if name.is_empty() { "(unnamed)" } else { name.as_str() };
                format!("{} \u{2192} {client}", what())
            },
            bytes,
        );
    }

    /// [`Self::send`] of the reply to a request whose method is `reply_to`: the size watch names
    /// it (`wire_size.rs`).
    fn send_replying(&self, msg: &Message, reply_to: Option<&str>) {
        self.send_as(msg, reply_to, outbound::Row::None);
    }

    /// [`Self::send`] of a watcher's row of a chat, or of a line that must follow it
    /// (`outbound.rs` [`outbound::Row`]): a newer row replaces one still queued.
    fn send_row(&self, msg: &Message, row: outbound::Row) {
        self.send_as(msg, None, row);
    }

    fn send_as(&self, msg: &Message, reply_to: Option<&str>, row: outbound::Row) {
        self.raise_gate();
        let redacted = if self.origin == Origin::Peer {
            let mut copy = msg.clone();
            let changed = match &mut copy {
                Message::Notification { params: Some(params), .. } => {
                    crate::server::pending::redact_message_hosts(params)
                }
                Message::Response { result: Some(result), .. } => {
                    crate::server::pending::redact_message_hosts(result)
                }
                _ => false,
            };
            changed.then_some(copy)
        } else {
            None
        };
        let base = redacted.as_ref().unwrap_or(msg);
        let masked = (!self.raw_text).then(|| peer_text::masked(base)).flatten();
        let msg = masked.as_ref().unwrap_or(base);
        // No message larger than one frame (`rpc::MAX_MESSAGE_BYTES`): a reply goes as its error,
        // a notification is left out and the client reads again from its last record.
        match msg.bounded_line_replying(reply_to) {
            Ok(line) => {
                if crate::perf_watch::on() {
                    self.perf_bytes(
                        || crate::wire_size::What::of(msg, reply_to).label(),
                        line.len(),
                    );
                }
                // The reply's share of its caller's bytes (`caller_stats.rs`).
                if let (Some(m), Message::Response { .. }) = (reply_to, msg) {
                    crate::caller_stats::global().observe_reply(
                        &self.stats_caller(),
                        m,
                        line.len(),
                    );
                }
                if reply_to == Some(controls::METHOD) {
                    self.controls.reply(self, msg, line);
                } else {
                    self.out.lock().push_row(line, outbound::reply_lane(msg, reply_to), row);
                }
            }
            Err(bytes) => self.left_out_too_large(msg.method(), bytes),
        }
    }

    /// A notification of `bytes`, larger than a frame, was left out (`bounded_line` counted it
    /// and warned of it, at most once a minute per method): the client is told it lagged and
    /// reads again from its last record.
    fn left_out_too_large(&self, method: Option<&str>, bytes: usize) {
        tracing::debug!(conn = %self.id, method = ?method, bytes, "left out a notification too large to send");
        self.out.push(
            Message::notification(
                "_acpmux/lagged",
                json!({"dropped": 1, "reason": "message_too_large"}),
            )
            .to_line(),
        );
    }
    /// The reply for `id` whose result is already serialized (`list_reply.rs`), masked
    /// already for a peer. A `session_changed` notice may go before it: the client keeps each
    /// row with the higher `listSeq` (`hub/row_log.rs`), so no reply is read again or followed by
    /// a lag for it. One larger than a frame goes as its error, as in [`Self::send`].
    /// Whether it went whole into an open queue (not as its too-large error, nor into a queue
    /// whose reader is gone).
    /// `method` is the request's, if known, for the size watch (`wire_size.rs`), which counts
    /// the reply once it goes, never a list left for a newer one.
    /// `claim` takes the request's in-flight entry as the reply is queued, under the outbound
    /// lock (`in_flight.rs`): a cancel that answered it first leaves the reply unsent
    /// (Some(false)), and one read after it finds nothing to answer, so the client never gets
    /// both the list and the cancelled error.
    fn send_serialized(
        &self,
        id: &Value,
        method: Option<&str>,
        claim: Option<&in_flight::Claim>,
        result: Arc<String>,
    ) -> bool {
        // A result past the cap alone is refused before its line is made: no copy of it.
        let (line, bytes, whole) = if result.len() > crate::rpc::MAX_MESSAGE_BYTES {
            let error = Message::err(id.clone(), RpcError::too_large(result.len())).to_line();
            (error, result.len(), false)
        } else {
            let line = list_reply::reply_line_in(id, result);
            let bytes = line.len();
            if bytes <= crate::rpc::MAX_MESSAGE_BYTES {
                (line, bytes, true)
            } else {
                (Message::err(id.clone(), RpcError::too_large(bytes)).to_line(), bytes, false)
            }
        };
        self.raise_gate();
        let mut queue = self.out.lock();
        if claim.is_some_and(|claim| !self.in_flight.claim(claim)) {
            return false;
        }
        let what = method.map_or(crate::wire_size::What::Reply, crate::wire_size::What::ReplyTo);
        crate::wire_size::observe(what, bytes);
        if let Some(m) = method {
            crate::caller_stats::global().observe_reply(&self.stats_caller(), m, bytes);
        }
        // Each client's share of the list it is sent (`list_bytes.rs`), by its name and origin.
        if matches!(method, Some(crate::rpc::method::MUX_WATCH | crate::rpc::method::MUX_SESSIONS))
        {
            let name = self.name.lock_or_recover().clone();
            let name = if name.is_empty() { "(unnamed)" } else { name.as_str() };
            crate::list_bytes::global().observe(&format!("{name} ({:?})", self.origin), bytes);
        }
        // A cheap list read goes ahead of the bulk lane (`outbound.rs`), so a notice may pass it: the
        // client keeps each row with the higher `listSeq` (`hub/row_log.rs`); order does not matter.
        if !queue.push_in(line, outbound::method_lane(method)) {
            return false;
        }
        // The perf watch's meter after the queue's lock: its tail-file append is no wait for the queue.
        drop(queue);
        if crate::perf_watch::on() {
            self.perf_bytes(|| what.label(), bytes);
        }
        whole
    }

    /// [`Self::send`] for a request to the client that must go out after every response and
    /// request queued before it: a GitHub action after the watch answer that opened the Mac's
    /// side (`hub/github_owner.rs`). The queue keeps its lines in order (`outbound.rs`), so it
    /// goes after them; refused, with nothing sent, when the connection ended or the request is
    /// larger than a frame.
    fn send_request_in_order(&self, msg: &Message) -> Result<(), RpcError> {
        self.raise_gate();
        let masked = (!self.raw_text).then(|| peer_text::masked(msg)).flatten();
        let msg = masked.as_ref().unwrap_or(msg);
        let line = msg.bounded_line().map_err(RpcError::too_large)?;
        if self.out.is_closed() || !self.out.push(line) {
            return Err(RpcError::internal("the connection that would answer ended"));
        }
        Ok(())
    }

    fn sub_opts(&self, session_id: &str) -> Option<SubOpts> {
        self.subs.lock_or_recover().get(session_id).cloned()
    }

    /// Whether a live stream record of `session_id` is left out here: its attachment draws nothing
    /// while hidden (`SubOpts::quiet_hidden`) and is hidden now. Counted under the lock
    /// `_acpmux/view` shows it under, so the `_acpmux/lagged` of that show covers every record
    /// left out, and every record after it goes out (`view.rs` `view`).
    // perf-hot: 1us acpmux-token-fanout (every streamed token, per hidden quiet attachment)
    fn leaves_out_hidden(&self, session_id: &str, seq: u64) -> bool {
        let mut subs = self.subs.lock_or_recover();
        match subs.get_mut(session_id) {
            Some(sub) if sub.quiet_hidden && sub.hidden && !sub.remote => {
                if sub.left_out == 0 {
                    sub.left_from = seq.saturating_sub(1);
                }
                sub.left_out += 1;
                true
            }
            _ => false,
        }
    }
    /// Whether another chat's `session_changed` row is left out here: every chat this connection
    /// attached is hidden from a client that draws nothing then (`SubOpts::quiet_hidden`, the
    /// app's pane). The app already holds every list notice from a page out of sight
    /// (`AcpmuxPaneShedding.listNotices`, `setAsleep`), so these rows crossed the socket for
    /// nothing: 205 kB/s with 8 chats streaming and 6 panes hidden (app-stream-bytes, stream
    /// duress). Counted under the lock `_acpmux/view` shows a chat under (`rows_left_out`).
    // perf-hot: 1us acpmux-row-fanout (every row change, per watching connection)
    fn leaves_out_row(&self) -> bool {
        let subs = self.subs.lock_or_recover();
        let mut local = subs.values().filter(|sub| !sub.remote).peekable();
        if local.peek().is_none() || !local.all(|sub| sub.quiet_hidden && sub.hidden) {
            // Out of hiding by a detach or a new attach, not a show (`view.rs` covers a show):
            // the rows left out are owed before this one.
            let rows = self.rows_left_out.swap(0, Ordering::SeqCst);
            if rows > 0 {
                let notice =
                    json!({"dropped": rows, "reason": "hidden", "watch": true, "sessionIds": []});
                self.send(&Message::notification("_acpmux/lagged", notice));
            }
            return false;
        }
        self.rows_left_out.fetch_add(1, Ordering::SeqCst);
        true
    }
    /// This daemon's own chats this connection is attached to.
    fn local_attached_ids(&self) -> Vec<String> {
        let subs = self.subs.lock_or_recover();
        subs.iter().filter(|(_, opts)| !opts.remote).map(|(id, _)| id.clone()).collect()
    }
    pub(super) fn bind_mailbox_receipt(&self, receipt: SessionReceipt) {
        self.mailbox_bindings.lock_or_recover().insert(receipt.mux_session_id.clone(), receipt);
    }
    pub(super) fn mailbox_receipt(&self, session_id: &str) -> Option<SessionReceipt> {
        let key = session_id.strip_prefix("acp:").unwrap_or(session_id);
        self.mailbox_bindings
            .lock_or_recover()
            .values()
            .find(|receipt| key == receipt.mux_session_id || key == receipt.qualified_id())
            .cloned()
    }
    pub(super) fn unbind_mailbox_receipt(&self, session_id: &str) {
        self.mailbox_bindings.lock_or_recover().remove(session_id);
    }
    /// Subscribe with default options; keeps options already set.
    fn subscribe(&self, session_id: &str) -> bool {
        let mut subs = self.subs.lock_or_recover();
        if subs.contains_key(session_id) {
            return false;
        }
        self.interest.attach(session_id);
        subs.insert(session_id.to_owned(), SubOpts::default());
        true
    }

    /// Turns its watch on or off (`_acpmux/watch {enabled}`): off, the other chats' changes no
    /// longer wake its fan-out (`interest.rs`); on, it hears from the next change.
    pub(super) fn set_watching(&self, on: bool) {
        if on {
            self.interest.set_watching(true);
            self.watch_all.store(true, Ordering::SeqCst);
        } else {
            self.watch_all.store(false, Ordering::SeqCst);
            self.interest.set_watching(false);
        }
    }
    fn label(&self) -> String {
        let n = self.name.lock_or_recover().clone();
        if n.is_empty() {
            self.id.clone()
        } else {
            format!("{n}#{}", self.id.get(..6).unwrap_or(self.id.as_str()))
        }
    }
}

// ----------------------------------------------------------------- listen

pub async fn listen_unix(hub: Arc<Hub>, path: PathBuf) -> Result<()> {
    let listener = bind_unix(&path).await?;
    serve_unix(hub, listener).await
}

/// Bind the daemon socket (mode 0600), refusing to steal a live one.
#[cfg(unix)]
pub async fn bind_unix(path: &std::path::Path) -> Result<UnixListener> {
    crate::config::refuse_lost_home(&crate::config::home())?;
    // A configured path longer than sun_path fails here with the path and
    // the limit, never as a bare bind error.
    cmux_unix_socket::check_path(path)?;
    if let Some(parent) = path.parent() {
        // Owner-only when created here, like the /tmp fallback directory; acpmux's own directory
        // that already exists wider is narrowed to it too ([`tighten_socket_dir`]).
        crate::home_fs::create_dir_all(parent, 0o700)?;
        tighten_socket_dir(parent)?;
    }
    if path.exists() {
        // Refuse to steal a live socket.
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            anyhow::bail!("another acpmux daemon owns {}", path.display());
        }
        // A failed connect is not a dead socket: a live daemon whose accept queue is full
        // refuses it too. Only the holder of the lock that serves it may remove it.
        if let Some(pid) = crate::daemon::socket_held_by_other(path) {
            anyhow::bail!(
                "the acpmux daemon pid {pid} holds the lock that serves {}; leaving its socket in place",
                path.display()
            );
        }
        crate::config::refuse_lost_home(&crate::config::home())?;
        crate::home_fs::remove_file(path)?;
    }
    crate::config::refuse_lost_home(&crate::config::home())?;
    let listener = bind_owner_only(path)?;
    tracing::info!("listening on {}", path.display());
    Ok(listener)
}

/// Binds `path` so nobody but this user can ever connect, without touching the process umask:
/// the umask is process-wide, so setting it for one bind made a folder another thread created
/// meanwhile 0600, which nothing can enter (two hub_carrier pipe tests failed with "bind
/// .../acpmux.sock: Permission denied" that way). The socket is bound inside a fresh 0700
/// folder next to `path`, made 0600 there and renamed into place; a bound socket keeps working
/// under its new name. A staging path too long for `sun_path` binds in place, where the 0600
/// chmod follows at once and the peer check at accept ([`peer_uid_allowed`]) holds meanwhile.
#[cfg(unix)]
fn bind_owner_only(path: &std::path::Path) -> Result<UnixListener> {
    use std::os::unix::fs::PermissionsExt;
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let owner_only = || std::fs::Permissions::from_mode(0o600);
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stage = parent.map(|p| p.join(format!(".b{:x}{n:x}", std::process::id())));
    let staged = stage.as_ref().map(|s| s.join("s"));
    let fits = staged.as_ref().is_some_and(|s| cmux_unix_socket::check_path(s).is_ok());
    let (Some(stage), Some(staged), true) = (stage, staged, fits) else {
        let listener =
            UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
        crate::home_fs::set_permissions(path, owner_only())?;
        return Ok(listener);
    };
    crate::home_fs::create_dir(&stage, 0o700)
        .with_context(|| format!("create {}", stage.display()))?;
    let bound = (|| -> Result<UnixListener> {
        // A umask set elsewhere can leave the folder without its search bit; 0700 whatever it was.
        crate::home_fs::set_permissions(&stage, std::fs::Permissions::from_mode(0o700))?;
        let listener =
            UnixListener::bind(&staged).with_context(|| format!("bind {}", path.display()))?;
        crate::home_fs::set_permissions(&staged, owner_only())?;
        crate::home_fs::rename(&staged, path)
            .with_context(|| format!("move the socket to {}", path.display()))?;
        Ok(listener)
    })();
    let _ = crate::home_fs::remove_file(&staged);
    let _ = crate::home_fs::remove_dir(&stage);
    bound
}

/// Narrows `dir`, the daemon socket's directory, to 0700 when it is acpmux's own (its home, or a
/// directory named `acpmux...` such as the `/tmp/acpmux-UID` fallback) and this user owns it:
/// `create_dir_all` leaves a directory that already exists as it was. A directory the person named
/// with `ACPMUX_SOCKET` (their home, a project) is never changed; the socket's own mode and the
/// peer check at accept ([`peer_uid_allowed`]) hold there.
#[cfg(unix)]
fn tighten_socket_dir(dir: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let ours = dir == crate::config::home().as_path()
        || dir.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("acpmux"));
    if !ours {
        return Ok(());
    }
    let Ok(meta) = std::fs::symlink_metadata(dir) else { return Ok(()) };
    // SAFETY: geteuid has no preconditions and cannot fail.
    let own = unsafe { libc::geteuid() };
    if meta.is_dir() && meta.uid() == own && meta.mode() & 0o077 != 0 {
        let mode = meta.mode() & 0o700;
        crate::home_fs::set_permissions(dir, std::fs::Permissions::from_mode(mode))
            .with_context(|| format!("narrow {} to owner-only", dir.display()))?;
    }
    Ok(())
}

/// Whether a unix socket peer with `uid` may talk to the daemon running as `own`: this user, or
/// root (the Cloud machine's provisioner, `daemon/provision.rs`; root opens a 0600 socket anyway).
/// A peer whose uid cannot be read is refused.
#[cfg(unix)]
pub(crate) fn peer_uid_allowed(uid: Option<u32>, own: u32) -> bool {
    uid.is_some_and(|uid| uid == own || uid == 0)
}

#[cfg_attr(not(any(feature = "tailnet", feature = "hub-carrier")), allow(unused_imports))]
pub(crate) use crate::accept_errors::accept_ends_listener;
pub(crate) use crate::accept_errors::accept_retry_delay;

#[cfg(unix)]
pub async fn serve_unix(hub: Arc<Hub>, listener: UnixListener) -> Result<()> {
    serve_unix_with_v2(hub, listener, None).await
}

#[cfg(unix)]
pub async fn serve_unix_with_v2(
    hub: Arc<Hub>,
    listener: UnixListener,
    v2: Option<Arc<acpmux_core::life::V2>>,
) -> Result<()> {
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("accept failed: {e}");
                tokio::time::sleep(accept_retry_delay(&e)).await;
                continue;
            }
        };
        // The socket's mode admits this user only; the peer's uid says so again (one
        // getsockopt, its pid read from the same answer below).
        let cred = stream.peer_cred().ok();
        // SAFETY: geteuid has no preconditions and cannot fail.
        let own = unsafe { libc::geteuid() };
        if !peer_uid_allowed(cred.map(|c| c.uid()), own) {
            tracing::warn!(
                uid = ?cred.map(|c| c.uid()),
                "refused a socket peer that is not this user"
            );
            continue;
        }
        let hub = hub.clone();
        let v2 = v2.clone();
        tokio::spawn(async move {
            // Named by its audit token, read once here, never by pid.
            let peer = {
                use std::os::fd::AsRawFd;
                cmux_link::app_caller::peer_token(stream.as_raw_fd())
            };
            // A root peer of a Cloud machine's daemon may carry the person key (`daemon/provision.rs`).
            let provisioner = crate::daemon::provision::accept_provisioner(&stream);
            let socket_peer = cred
                .and_then(|c| c.pid())
                .and_then(|p| u32::try_from(p).ok())
                .map_or(SocketPeer::Unknown, SocketPeer::Pid);
            stream::serve_stream(hub, stream, peer, provisioner, socket_peer, v2).await;
        });
    }
}

static INDEX_HTML: cmux_embed::PackedStr =
    cmux_embed::packed_str!(include_str!("../../web/index.html"));

/// One TCP port serves both the dashboard page (plain HTTP GET) and the
/// WebSocket protocol. The request head is peeked, never consumed, so the
/// WebSocket handshake still sees the full request.
///
/// Every request passes the localhost listener rule first
/// (plans/cmux-next/identity.md section 4): a loopback `Host`, no foreign
/// `Origin`, and, for the WebSocket, the token, which is mandatory and
/// comes only from a header (`ws_auth.rs`).
pub async fn listen_ws(hub: Arc<Hub>, addr: String, token: String) -> Result<()> {
    let listener = bind_ws(&addr).await?;
    serve_ws(hub, listener, token).await
}

/// Bind the dashboard/WebSocket port on loopback. `127.0.0.1:0` picks a free
/// port; read it back with `local_addr`. A network address is refused
/// (`ws_auth::check_listen`); [`bind_ws_with`] takes the person's opt-in.
pub async fn bind_ws(addr: &str) -> Result<TcpListener> {
    bind_ws_with(addr, false).await
}

/// [`bind_ws`], binding a network (non-loopback) address too when
/// `allow_network` (`--insecure-network-listen`,
/// `websocket.allowInsecureNetwork`).
pub async fn bind_ws_with(addr: &str, allow_network: bool) -> Result<TcpListener> {
    check_listen_address(addr, allow_network).await?;
    let listener = TcpListener::bind(addr).await.with_context(|| format!("bind {addr}"))?;
    let bound = listener.local_addr().with_context(|| format!("bind {addr}"))?;
    // The address that was bound, should a name resolve differently now.
    ws_auth::check_listen(addr, &[bound], allow_network)?;
    if !ws_auth::is_loopback(&bound) {
        tracing::warn!(
            "the web + websocket listener {bound} is on a network address (opted in): plain ws:// sends the listener token in clear"
        );
    }
    tracing::info!("web + websocket listening on {bound}");
    Ok(listener)
}

/// Refuse `addr` before binding it when any address it names is not
/// loopback and the person did not opt in.
pub async fn check_listen_address(addr: &str, allow_network: bool) -> Result<()> {
    if allow_network {
        return Ok(());
    }
    let addrs: Vec<std::net::SocketAddr> = match addr.parse() {
        Ok(one) => vec![one],
        Err(_) => tokio::net::lookup_host(addr).await.map(Iterator::collect).unwrap_or_default(),
    };
    ws_auth::check_listen(addr, &addrs, false)
}
pub use crate::ws_auth::check_listen_address_blocking;

/// The origin of the app's bundled agent pane page (a `cmux-agent` URL
/// scheme handler). A `file://` page would send `Origin: null`, which every
/// localhost listener refuses.
pub const AGENT_PANE_ORIGIN: &str = "cmux-agent://pane";

/// The Origin and Host rule of this listener: its own origin (the
/// dashboard page), the agent pane, and the origins and hosts the config
/// adds (`websocket.allowed_origins`, `websocket.allowed_hosts`). Never
/// `null`. An entry that does not parse is skipped with a warning. The Host
/// rule holds on every bind: a non-loopback `websocket.listen` also accepts
/// IP address literals, and the names clients use must be listed in
/// `websocket.allowed_hosts`.
pub fn listener_policy(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    if !address.ip().is_loopback() && extra_hosts.is_empty() {
        tracing::warn!(
            "websocket.listen {address} is not loopback: clients may connect by IP address only; list host names in websocket.allowedHosts"
        );
    }
    for origin in extra_origins {
        if cmux_local_auth::parse_origin(origin).is_none() {
            tracing::warn!(
                "websocket.allowed_origins: ignoring {origin:?} (not scheme://host[:port])"
            );
        }
    }
    policy_with(address, extra_origins, extra_hosts)
}

/// [`listener_policy`] without its warnings: an origin that does not parse is skipped.
fn policy_with(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    let mut policy =
        ListenerPolicy::for_bind_keeping_host_rule(address).with_origin(AGENT_PANE_ORIGIN);
    for origin in extra_origins {
        if cmux_local_auth::parse_origin(origin).is_some() {
            policy = policy.with_origin(origin);
        }
    }
    for host in extra_hosts {
        policy = policy.with_host(host);
    }
    policy
}

/// The origins and hosts the config adds to the listener now: `websocket.allowedOrigins` (with
/// this run's `--allow-dev-origin`s) and `websocket.allowedHosts`.
async fn configured_extras(hub: &Hub) -> (Vec<String>, Vec<String>) {
    let config = hub.config.read().await;
    let (mut origins, hosts) = config
        .websocket
        .as_ref()
        .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
        .unwrap_or_default();
    origins.extend(config.dev_origins.iter().cloned());
    (origins, hosts)
}

/// [`listener_policy`] as the config has it at this moment, without its start warnings.
async fn configured_policy(hub: &Hub, address: std::net::SocketAddr) -> ListenerPolicy {
    let (extra_origins, extra_hosts) = configured_extras(hub).await;
    policy_with(address, &extra_origins, &extra_hosts)
}

/// Validate a `--allow-dev-origin` value: only a loopback `http` origin with
/// an explicit port (a page dev server on this machine). Anything else is an
/// error, so the flag can never admit a web site.
pub fn dev_origin(value: &str) -> Result<String> {
    let origin = cmux_local_auth::parse_origin(value)
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} is not scheme://host:port"))?;
    let rest = origin
        .strip_prefix("http://")
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} must be http"))?;
    let (host, port) = rest
        .rsplit_once(':')
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} needs a port"))?;
    anyhow::ensure!(
        matches!(host, "127.0.0.1" | "localhost" | "[::1]") && port.parse::<u16>().is_ok(),
        "--allow-dev-origin {value:?} must be a loopback host with a port"
    );
    Ok(origin)
}

/// An accepted web socket streams many small ACP deltas: send each at once (no Nagle delay).
fn tune_ws_socket(stream: &tokio::net::TcpStream) {
    if let Err(e) = stream.set_nodelay(true) {
        tracing::debug!("ws TCP_NODELAY: {e}");
    }
}

pub async fn serve_ws(hub: Arc<Hub>, listener: TcpListener, token: String) -> Result<()> {
    serve_ws_with(hub, listener, token, WsAuth::default()).await
}

/// The proofs a WebSocket connection may present beyond the dashboard
/// token: this launch's LocalApp token (`local_app.rs`) and peer token
/// (`peer_auth.rs`). Without one, no connection gets that origin.
#[derive(Default, Clone)]
pub struct WsAuth {
    pub local_app: Option<Arc<local_app::LocalAppAuth>>,
    pub peer: Option<Arc<peer_auth::PeerAuth>>,
}

/// How long a connection may wait before its first frame decides whether it
/// is the local app (`local_app.rs`); after it, it is remote-origin.
const FIRST_FRAME: std::time::Duration = std::time::Duration::from_secs(10);

/// Bound pre-authentication work separately from the per-connection request budget.
/// A client can otherwise hold a task and file descriptor while it dribbles out
/// an HTTP upgrade request.
const WS_HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const WS_HANDSHAKE_CONCURRENCY: usize = 64;

/// The largest WebSocket frame or message a connection reads. The app's agent pane sends a frame
/// of up to 32 MiB (`AcpmuxPaneMethods.maximumFrameBytes`); a prompt with a few screenshots is
/// past tungstenite's 16 MiB frame default, which ended the read with no log line and reset the
/// socket mid-send ("The agent connection was interrupted", 2026-10-20).
pub const WS_MAX_MESSAGE_BYTES: usize = 64 << 20;

/// The listener's and the peer client's WebSocket limits (`WS_MAX_MESSAGE_BYTES`).
pub fn ws_config() -> tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
    tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(WS_MAX_MESSAGE_BYTES))
        .max_frame_size(Some(WS_MAX_MESSAGE_BYTES))
}

/// `serve_ws` with this launch's LocalApp and peer tokens: a connection
/// that meets every LocalApp condition is served as `Origin::LocalApp`, one
/// that proves the peer token as `Origin::Peer`, any other as `Origin::Web`.
pub async fn serve_ws_with(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    auth: WsAuth,
) -> Result<()> {
    let shutdown = hub.ws_shutdown.clone();
    serve_ws_until(hub, listener, token, auth, shutdown).await
}

/// The daemon's listener: drains established WebSockets with Close 1012 on shutdown.
pub async fn serve_ws_until(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    auth: WsAuth,
    shutdown: WsShutdown,
) -> Result<()> {
    serve_ws_gated(hub, listener, token, auth, shutdown, None).await
}

/// [`serve_ws_until`] with an admission gate: the tailnet listener (`tailnet_carrier.rs`) reads
/// no byte of a connection whose source `whois` does not name a node of this person, and treats
/// one it admits as it does the end of an `ssh -W` tunnel (a loopback source: the peer token is
/// proven over it). Without a gate every connection is as before.
pub async fn serve_ws_gated(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    auth: WsAuth,
    shutdown: WsShutdown,
    gate: Option<Arc<crate::tailnet_carrier::Gate>>,
) -> Result<()> {
    let (shutdown, _draining) = shutdown.listener();
    anyhow::ensure!(!token.is_empty(), "the acpmux web listener needs a token");
    if shutdown.is_requested() {
        return Ok(());
    }
    let bound = listener.local_addr()?;
    // Said once, at start; each connection reads the policy again (`configured_policy`), so a
    // `websocket.allowedHosts` or `allowedOrigins` edit (`acpmux web --tailnet`) applies at the
    // next `_acpmux/reload_config`, with no restart.
    {
        let (extra_origins, extra_hosts) = configured_extras(&hub).await;
        listener_policy(bound, &extra_origins, &extra_hosts);
    }
    // Each handshake checks the token current at that moment: a rotation
    // (`hub/web_token.rs`) applies from the next one on. The daemon set it
    // already; a caller that did not (tests) gets `token`.
    hub.web_token.set_if_unset(token);
    let handshake_slots = Arc::new(Semaphore::new(WS_HANDSHAKE_CONCURRENCY));
    let mut connections = tokio::task::JoinSet::new();
    loop {
        let accepted = tokio::select! {
            biased;
            () = shutdown.requested() => break,
            () = shutdown.normal() => {
                shutdown.close_clients();
                break;
            }
            _ = connections.join_next(), if !connections.is_empty() => continue,
            accepted = listener.accept() => accepted,
        };
        let (stream, peer) = match accepted {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("ws accept failed: {e}");
                tokio::time::sleep(accept_retry_delay(&e)).await;
                continue;
            }
        };
        tune_ws_socket(&stream);
        let handshake_slot = match handshake_slots.clone().try_acquire_owned() {
            Ok(slot) => slot,
            Err(_) => {
                tracing::warn!(peer = %peer, error = "handshake_capacity", "rejecting websocket handshake");
                tokio::spawn(refuse_ws_transport(stream, 503, "handshake_capacity"));
                continue;
            }
        };
        let hub = hub.clone();
        // Read and subscribed before the handshake, so a rotation during it
        // still closes a connection that presented the old token.
        let (token, rotated) = hub.web_token.watch();
        let local_app = auth.local_app.clone();
        let peer_auth = auth.peer.clone();
        let shutdown = shutdown.clone();
        let gate = gate.clone();
        connections.spawn(async move {
            let _handshake_slot = handshake_slot;
            let mut stream = stream;
            let peer = match &gate {
                Some(gate) if gate.admits(peer).await => {
                    std::net::SocketAddr::new(std::net::Ipv4Addr::LOCALHOST.into(), peer.port())
                }
                Some(_) => {
                    tracing::debug!(peer = %peer, "tailnet connection refused: not this person's node");
                    return;
                }
                None => peer,
            };
            // The whole head routes the request (`ws_peek.rs`). Each path checks it: serve_http
            // as it reads, tungstenite as it parses it again for the callback.
            let mut probed = false;
            let (head, read) = loop {
                let (head, read) = match ws_peek::request(&mut stream, peer).await {
                    ws_peek::Request::Head { head, read } => (head, read),
                    ws_peek::Request::TooLarge => {
                        refuse_http(stream, Refusal::MissingHost).await;
                        return;
                    }
                    ws_peek::Request::Gone => return,
                };
                // The cmux link proves this is the listener `listener.json` names before it
                // sends a paired peer's bytes (`listener_record.rs`): it answers the link's
                // challenge under the record's key, for the probe alone, once.
                let Some(answer) = crate::listener_record::probe_answer(&read) else {
                    break (head, read);
                };
                if probed {
                    return;
                }
                probed = true;
                if tokio::io::AsyncWriteExt::write_all(&mut stream, answer.as_bytes())
                    .await
                    .is_err()
                {
                    return;
                }
            };
            let policy = Arc::new(configured_policy(&hub, bound).await);
            if !head.to_ascii_lowercase().contains("upgrade: websocket") {
                serve_http(stream, &head, &policy, peer).await;
                return;
            }
            let stream = ws_peek::Replayed::new(read, stream);
            let expected = token.clone();
            // The upgrade request's Origin headers, for the LocalApp check.
            let seen_origins: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_origins = seen_origins.clone();
            // Its peer token headers, for the Peer check.
            let seen_peer: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_peer = seen_peer.clone();
            // A ticket or a paired machine's credential (`pairing.rs`).
            let admitted: Arc<StdMutex<pairing::Admitted>> = Arc::default();
            let (record_admitted, pairing_hub) = (admitted.clone(), hub.clone());
            let browser_app = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let record_browser_app = browser_app.clone();
            let callback = move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
                                 resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
                let values = |name: &str| {
                    req.headers()
                        .get_all(name)
                        .iter()
                        .map(|value| value.to_str().unwrap_or("\u{0}"))
                        .collect::<Vec<_>>()
                };
                let refuse = |refusal: Refusal| {
                    use tokio_tungstenite::tungstenite::http::{Response, StatusCode};
                    let mut response = Response::new(Some(refusal.reason().to_owned()));
                    *response.status_mut() =
                        StatusCode::from_u16(refusal.status()).unwrap_or(StatusCode::FORBIDDEN);
                    response
                };
                if let Err(refusal) = policy.check(&values("host"), &values("origin")) {
                    return Err(refuse(refusal));
                }
                // The Cloud carrier's header is read on the carrier socket only (`carrier.rs`).
                if !values(carrier::HEADER).is_empty() {
                    return Err(carrier::wrong_socket_response());
                }
                *record_origins.lock().unwrap_or_else(|e| e.into_inner()) =
                    values("origin").into_iter().map(str::to_owned).collect();
                *record_peer.lock().unwrap_or_else(|e| e.into_inner()) =
                    values(peer_auth::HEADER).into_iter().map(str::to_owned).collect();
                // Only a header carries the token, never the URL (`ws_auth.rs`).
                let presented =
                    ws_auth::presented(&values("authorization"), &values("sec-websocket-protocol"))
                        .map_err(refuse)?;
                if req.uri().path() == "/app/ws" {
                    // This capability is useful only here. No dashboard token, pairing ticket,
                    // device credential or extra native proof can admit or promote this socket.
                    cmux_local_auth::check_token(
                        presented.token,
                        &ws_auth::browser_app_token(&expected),
                    ).map_err(refuse)?;
                    record_browser_app.store(true, std::sync::atomic::Ordering::Relaxed);
                } else {
                    let tickets = values(crate::pairing::TICKET_HEADER);
                    let proof = pairing::admit(&pairing_hub, peer, presented.token, &tickets, &expected);
                    *record_admitted.lock().unwrap_or_else(|e| e.into_inner()) = proof.map_err(refuse)?;
                }
                let mut resp = resp;
                if presented.answer_protocol {
                    resp.headers_mut().insert(
                        "sec-websocket-protocol",
                        tokio_tungstenite::tungstenite::http::HeaderValue::from_static(
                            ws_auth::PROTOCOL,
                        ),
                    );
                }
                Ok(resp)
            };
            let mut ws = match tokio::time::timeout(
                WS_HANDSHAKE_TIMEOUT,
                tokio_tungstenite::accept_hdr_async_with_config(
                    stream,
                    callback,
                    Some(ws_config()),
                ),
            )
            .await
            {
                Err(_) => {
                    tracing::warn!(peer = %peer, error = "handshake_timeout", "closing stalled websocket handshake");
                    return;
                }
                Ok(Ok(ws)) => ws,
                Ok(Err(e)) => {
                    tracing::warn!("ws handshake from {peer} rejected: {e}");
                    return;
                }
            };
            // Only the HTTP upgrade is admission-controlled; an established
            // connection is governed by its authenticated request budget.
            drop(_handshake_slot);
            let admitted = std::mem::take(&mut *admitted.lock().unwrap_or_else(|e| e.into_inner()));
            let device = match admitted {
                pairing::Admitted::Ticket(secret) => {
                    let close = tokio::select! {
                        biased;
                        () = shutdown.normal() => true,
                        () = shutdown.closing() => true,
                        () = pairing::serve_redeem(hub, &mut ws, secret) => false,
                    };
                    if close {
                        ws_shutdown::close(&mut ws, shutdown.close_code_restart()).await;
                    }
                    return;
                }
                pairing::Admitted::Device(device) => Some(device),
                pairing::Admitted::Dashboard => None,
            };
            let (sink, mut source) = ws.split();
            let (in_tx, in_rx) = mpsc::channel::<String>(256);
            let (out_tx, out_rx) = mpsc::channel::<String>(4096);
            let mut children = ws_shutdown::Children::new();
            let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
            let wire = Arc::new(crate::frame_compress::Wire::default());
            // A peer link's slot for the v2 list stream; any other connection never fills it.
            let slot = hub.link_v2.slot();
            let writer = tokio::spawn(ws_shutdown::write_link(
                sink,
                out_rx,
                slot.clone(),
                stopped,
                shutdown.clone(),
                wire.clone(),
            ));
            children.track(&writer);
            // The handshake above checked the endpoint's credential: every
            // connection past it is authenticated (`conn_auth.rs`).
            let mut proof = ConnAuth::ListenerToken;
            // The first frame decides LocalApp; it reaches the protocol handler without the token.
            let mut origin = Origin::Web;
            let mut first = None;
            let presented =
                std::mem::take(&mut *seen_peer.lock().unwrap_or_else(|e| e.into_inner()));
            if browser_app.load(std::sync::atomic::Ordering::Relaxed) {
                proof = ConnAuth::BrowserApp;
            } else if let Some(device) = &device {
                (origin, proof) = pairing::origin_of(device);
            } else if peer_auth.as_ref().is_some_and(|a| a.is_peer(peer, &presented)) {
                origin = Origin::Peer;
                proof = ConnAuth::PeerToken;
            } else if let Some(auth) = &local_app {
                let frame = tokio::select! {
                    biased;
                    () = shutdown.closing() => None,
                    frame = async {
                        tokio::time::timeout(FIRST_FRAME, async {
                            while let Some(Ok(frame)) = source.next().await {
                                if let tokio_tungstenite::tungstenite::Message::Text(t) = frame {
                                    return Some(t.to_string());
                                }
                            }
                            None
                        }).await.ok().flatten()
                    } => frame,
                };
                let origins = seen_origins.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let hello = local_app::Hello {
                    listener: bound,
                    peer,
                    origins: &origins,
                    first_frame: frame.as_deref(),
                };
                if auth.is_local_app(&hello) {
                    origin = Origin::LocalApp;
                    proof = ConnAuth::LocalApp;
                } else if auth.from_page(&hello) {
                    // The pane read no token or another launch's: every Claude chat of this
                    // machine refuses it (D13). Said here, so the log explains the refusal.
                    tracing::warn!(
                        "a pane connection from {peer} without this launch's LocalApp token: served as remote-origin"
                    );
                }
                first = frame.map(|f| local_app::strip_token(&f));
            }
            if let Some(first) = first
                && in_tx.send(first).await.is_err()
            {
                return;
            }
            // Binary frames are upload data (`upload_frames.rs`), written in order by their own
            // worker; it refuses them on any connection but the local app's.
            // Answered through the connection's outbound queue once it is made, in order with
            // every other line and counted against its byte bound (`outbound.rs`).
            let (uploads, replies) = tokio::sync::watch::channel(None);
            let frames = Arc::new(upload_frames::spawn(hub.clone(), origin, proof, replies));
            let read_shutdown = shutdown.clone();
            let reader_end = crate::link_v2::ReaderEnd::new(slot.clone());
            let reader = tokio::spawn(async move {
                let _reader_end = reader_end;
                tokio::select! {
                    biased;
                    () = read_shutdown.closing() => {},
                    () = async {
                        // Pings are answered while a frame waits to be taken (`ws_read_ahead.rs`).
                        let ended = ws_read_ahead::read_ahead(source, |frame| {
                            let (frames, in_tx) = (frames.clone(), in_tx.clone());
                            async move {
                                match frame {
                                    // After the frames before it are written (`upload_frames::InFlight`).
                                    tokio_tungstenite::tungstenite::Message::Text(t) => {
                                        frames.in_flight.drained().await;
                                        in_tx.send(t.to_string()).await.is_ok()
                                    }
                                    tokio_tungstenite::tungstenite::Message::Binary(b) => frames.send(b).await,
                                    _ => true,
                                }
                            }
                        })
                        .await;
                        // A read error ends the connection; say why, or the client sees only a reset.
                        if let Some(e) = ended {
                            tracing::warn!("closing a {origin:?} connection from {peer}: {e}");
                        }
                    } => {},
                }
            });
            children.track(&reader);
            // A rotation ends a Web or Peer connection, which presented the
            // dashboard token; a revocation ends a paired machine's, which
            // presented its own. Ending its read half closes `in_rx`, so
            // `serve_connection_with` returns through its own cleanup
            // (detach counts, fan-out task) before the writer sends Close.
            // LocalApp also proved this launch's LocalApp token, so it stays.
            let _open = device.as_ref().map(|d| hub.pairing.opened(&d.id));
            let ends: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
                match &device {
                    Some(d) => Box::pin(hub.pairing.revoked(&d.id)),
                    None => Box::pin(rotated),
                };
            let watcher = matches!(origin, Origin::Web | Origin::Peer).then(|| {
                let read_half = reader.abort_handle();
                tokio::spawn(async move {
                    ends.await;
                    tracing::info!("closing a {origin:?} connection: its credential ended");
                    read_half.abort();
                })
            });
            if let Some(watcher) = &watcher {
                children.track(watcher);
            }
            // The page that opened `/app/ws`: its one Origin header, which `policy.check` admitted
            // above. A browser's sign-in is bound to it (`web_device.rs`); no other socket has one.
            let page_origin = if browser_app.load(std::sync::atomic::Ordering::Relaxed) {
                let origins = seen_origins.lock().unwrap_or_else(|e| e.into_inner());
                match origins.as_slice() {
                    [one] if one.len() <= web_device::MAX_ORIGIN_BYTES => Some(one.clone()),
                    _ => None,
                }
            } else {
                None
            };
            let (origin, proof, device) = match device {
                Some(device) => {
                    let (origin, proof) = pairing::origin_of(&device);
                    (origin, proof, Some(device.id))
                }
                None => (origin, proof, None),
            };
            serve_connection_from(
                hub,
                in_rx,
                out_tx,
                origin,
                proof,
                None,
                Transport::Messages,
                SocketPeer::Unknown,
                device,
                Some(wire),
                None,
                Some(uploads),
                slot,
                page_origin,
            )
            .await;
            if let Some(watcher) = watcher {
                watcher.abort();
            }
            let _ = stop.send(());
            // Its read half may wait on a silent client; the close is ours.
            reader.abort();
            let _ = writer.await;
        });
    }
    // Close admission before clients see 1012, so their immediate retry cannot reconnect to
    // this dying listener. Already accepted upgrades also see the latched shutdown signal.
    ws_shutdown::close_admission(listener);
    shutdown.close_clients();
    if tokio::time::timeout(ws_shutdown::DRAIN_BUDGET, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }
    Ok(())
}

async fn refuse_ws_transport(mut stream: tokio::net::TcpStream, status: u16, error: &str) {
    let reason = match status {
        503 => "Service Unavailable",
        _ => "Bad Request",
    };
    let body = format!("{{\"error\":\"{error}\"}}\n");
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// Check the `Host` and `Origin` values of a complete request head.
fn check_head(policy: &ListenerPolicy, head: &str) -> Result<(), Refusal> {
    let mut hosts = Vec::new();
    let mut origins = Vec::new();
    for line in head.split("\r\n").skip(1) {
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else { continue };
        let name = name.trim();
        if name.eq_ignore_ascii_case("host") {
            hosts.push(value.trim());
        } else if name.eq_ignore_ascii_case("origin") {
            origins.push(value.trim());
        }
    }
    policy.check(&hosts, &origins)
}

async fn refuse_http(mut stream: tokio::net::TcpStream, refusal: Refusal) {
    let status = match refusal.status() {
        401 => "401 Unauthorized",
        _ => "403 Forbidden",
    };
    let body = refusal.reason();
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/plain\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// Minimal HTTP for the dashboard. The whole head passes the listener rule
/// first; then GET / serves the dashboard and /app/ the shipped NEXT pane. The page is
/// static and holds no secret: it reads the token from its URL fragment,
/// which never reaches a server, and its WebSocket presents it.
async fn serve_http(
    mut stream: tokio::net::TcpStream,
    head: &str,
    policy: &ListenerPolicy,
    peer: std::net::SocketAddr,
) {
    if let Err(refusal) = check_head(policy, head) {
        tracing::warn!("web request from {peer} refused: {refusal}");
        refuse_http(stream, refusal).await;
        return;
    }
    let first = head.lines().next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method_ = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let path = target.split_once('?').map_or(target, |(path, _)| path);
    let (status, body, ctype) = if !method_.eq_ignore_ascii_case("get") {
        ("405 Method Not Allowed", b"method not allowed".to_vec(), "text/plain")
    } else if path == "/health" {
        ("200 OK", b"ok".to_vec(), "text/plain")
    } else if path == "/" || path == "/index.html" {
        ("200 OK", INDEX_HTML.inflate().into_bytes(), "text/html; charset=utf-8")
    } else if path.starts_with("/app/") {
        app_assets::serve(path).await
    } else {
        ("404 Not Found", b"not found".to_vec(), "text/plain")
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\ncache-control: no-store\r\nreferrer-policy: no-referrer\r\nx-content-type-options: nosniff\r\nconnection: close\r\n\r\n",
        body.len()
    );
    if stream.write_all(response.as_bytes()).await.is_ok() {
        let _ = stream.write_all(&body).await;
    }
    let _ = stream.shutdown().await;
}

// ------------------------------------------------------------ connection

pub use crate::conn_origin::Origin;

/// A connection from the local Unix socket.
pub async fn serve_connection(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
) {
    serve_connection_with(hub, inbound, out, Origin::Local).await
}

/// An in-process connection (tests, an embedding): the caller vouches for
/// the proof `origin` implies (`ConnAuth::proven_for`). A transport that
/// checks its own proof uses `serve_connection_authed`.
pub async fn serve_connection_with(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
) {
    serve_connection_authed(hub, inbound, out, origin, ConnAuth::proven_for(origin)).await
}

/// The daemon's own outbox delivering a send it kept (`outbox.rs` `attempt_once`): served as
/// `origin` with its proof, and the one local connection whose `senderHarnessChecked` is the
/// daemon's own (`sender_harness::check_trust`).
pub(super) async fn serve_outbox_connection(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
) {
    let auth = ConnAuth::proven_for(origin);
    serve_connection_from(
        hub,
        inbound,
        out,
        origin,
        auth,
        None,
        Transport::Messages,
        SocketPeer::Outbox,
        None,
        None,
        None,
        None,
        None,
        None,
    )
    .await
}

/// A connection with the proof its transport checked. `ConnAuth::None`
/// gets no sessions and no data: its first request is refused and the
/// connection ends (`conn_auth.rs`).
pub async fn serve_connection_authed(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
) {
    serve_connection_from(
        hub,
        inbound,
        out,
        origin,
        auth,
        None,
        Transport::Messages,
        SocketPeer::Unknown,
        None,
        None,
        None,
        None,
        None,
        None,
    )
    .await
}

/// A peer daemon's link served in-process, its writer draining `slot` (`link_v2_tests.rs`).
#[cfg(test)]
pub(crate) async fn serve_peer_link(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    slot: Arc<crate::link_v2::Slot>,
) {
    serve_connection_from(
        hub,
        inbound,
        out,
        Origin::Peer,
        ConnAuth::PeerToken,
        None,
        Transport::Messages,
        SocketPeer::Unknown,
        None,
        None,
        None,
        None,
        Some(slot),
        None,
    )
    .await;
}

/// A paired machine's link served in-process as the WebSocket listener serves it: its role's
/// origin and proof, its writer draining `slot` (`link_v2_tests.rs`).
#[cfg(test)]
pub(crate) async fn serve_device_link(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    slot: Arc<crate::link_v2::Slot>,
    device: crate::pairing::DeviceAuth,
) {
    let (origin, auth) = pairing::origin_of(&device);
    serve_connection_from(
        hub,
        inbound,
        out,
        origin,
        auth,
        None,
        Transport::Messages,
        SocketPeer::Unknown,
        Some(device.id),
        None,
        None,
        None,
        Some(slot),
        None,
    )
    .await;
}

/// The usage-patterns key of a listener.
fn origin_usage_key(origin: Origin) -> &'static str {
    match origin {
        Origin::Local => "local",
        Origin::Web => "web",
        Origin::LocalApp => "app",
        Origin::Peer => "peer",
    }
}

/// `serve_connection_authed` for a unix socket peer named by its audit token.
async fn serve_connection_from(
    hub: Arc<Hub>,
    mut inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
    peer: Option<cmux_link::app_caller::PeerToken>,
    transport: Transport,
    socket_peer: SocketPeer,
    device: Option<String>,
    wire: Option<Arc<crate::frame_compress::Wire>>,
    carrier: Option<carrier::Attested>,
    uploads: Option<upload_frames::Replies>,
    link: Option<Arc<crate::link_v2::Slot>>,
    page_origin: Option<String>,
) {
    // A carrier proof comes with the person the carrier socket read, and only with it.
    let carried = matches!(auth, ConnAuth::CarrierOwner | ConnAuth::CarrierTeam);
    let auth = if carried != carrier.is_some() { ConnAuth::None } else { auth };
    if !auth.authenticated() {
        refuse_unauthenticated(&mut inbound, &out, origin).await;
        return;
    }
    // Counted while it is served: a daemon with none stops once unused (`daemon/unused_exit.rs`).
    let client = crate::daemon::unused_exit::client();
    let raw_text = !peer_text::masks(origin);
    let (out, gate) = outbound::start(&hub.scope, hub.store.durability(), out);
    // The upload worker's answers (`upload_frames.rs`) go into the same queue: it holds no sender
    // of the transport, so the pump stays its only one.
    if let Some(uploads) = &uploads {
        uploads.send_replace(Some(Arc::downgrade(&out)));
    }
    // The listener's own peer link: the only transport with a writer that compresses (`wire`)
    // and a peer token checked at its upgrade; not a paired machine, nor an in-process carrier.
    let dual_principal = (wire.is_some() && auth == ConnAuth::PeerToken && device.is_none())
        .then_some(dual_requests::PEER_LINK);
    // The v2 list stream rides a link transport's connection that v1 answers a peer's watch
    // for, with `list` and `peers` on (`link_v2.rs`). Every other connection drops its frames.
    let mut link_v2 = link
        .filter(|_| origin == Origin::Peer)
        .and_then(|slot| link_v2_serve::Link::serving(&hub, slot));
    // Opt-in usage patterns: connections by listener, and distinct paired machines (an opaque
    // stand-in for the device id, never the id).
    if cmux_usage_patterns::enabled() {
        cmux_usage_patterns::count("acpmux-connection", origin_usage_key(origin));
        if let Some(device) = device.as_deref() {
            cmux_usage_patterns::count("machine", &cmux_usage_patterns::opaque_id(device));
        }
    }
    let (fan_flush, flushes) = fanout::Flush::channel();
    let conn = Arc::new(Conn {
        scope: hub.scope.child("acpmux conn"),
        id: uuid::Uuid::now_v7().to_string(),
        origin,
        auth,
        device,
        carrier,
        raw_text,
        name: StdMutex::new(String::new()),
        presence: client.presence(),
        out,
        gate,
        subs: StdMutex::new(HashMap::new()),
        stream_cursors: Default::default(),
        held_rows: Default::default(),
        follows: Default::default(),
        message_notices: StdMutex::new(MessageNoticeBook::default()),
        mailbox_bindings: StdMutex::new(HashMap::new()),
        controls: Default::default(),
        created: StdMutex::default(),
        interest: interest::Interest::new(hub.fanout_router()),
        watch_all: AtomicBool::new(false),
        watch_tools: AtomicBool::new(false),
        peer_row_batches: AtomicBool::new(false),
        client_features: Default::default(),
        chunk_deltas: Default::default(),
        session_delta: AtomicBool::new(false),
        sent_rows: StdMutex::default(),
        omit_time_breakdown: AtomicBool::new(false),
        rows_left_out: AtomicU64::new(0),
        watch_inventory: StdMutex::new(false),
        peer,
        socket_peer,
        transport,
        requests: std::sync::atomic::AtomicU64::new(0),
        challenged: AtomicBool::new(false),
        nonce: crate::hub::person::new_nonce(),
        person: AtomicBool::new(false),
        trigger: StdMutex::new(None),
        holds_calls: std::sync::atomic::AtomicU32::new(0),
        prove_calls: std::sync::atomic::AtomicU32::new(0),
        caller: std::sync::OnceLock::new(),
        unproven_caller: std::sync::OnceLock::new(),
        declared: std::sync::OnceLock::new(),
        peer_leases: StdMutex::new(Some(Vec::new())),
        ephemeral: StdMutex::new(Some(Vec::new())),
        ended: tokio::sync::watch::Sender::new(false),
        preparation_cancels: StdMutex::new(HashMap::new()),
        media: crate::hub::media_handles::Handles::default(),
        remote_media: media_forward::RemoteMedia::default(),
        client_requests: Default::default(),
        in_flight: in_flight::InFlight::counted(hub.requests_in_flight.clone()),
        chat_windows: Default::default(),
        wire,
        dual_principal,
        list_stream: link_v2.is_some(),
        device_mesh: StdMutex::new(web_device::Slot::Empty),
        page_origin: page_origin.filter(|_| web_device::keeps_page_origin(origin, auth)),
        browser_sign_in: StdMutex::new(None),
        fan_flush,
    });
    if auth == ConnAuth::BrowserApp && !web_device::admit(&hub, &conn, &mut inbound).await {
        return;
    }
    let device_ended = web_device::credential_ended(&hub, &conn);
    tokio::pin!(device_ended);
    queue_gauge::register(&conn);
    // A peer daemon's link mirrors the list and reads it again only when it links again: its
    // list notices are never left out (`outbound.rs`). Named again at its `initialize`.
    conn.out.describe(format!("{} {}", origin_usage_key(origin), conn.id), origin != Origin::Peer);
    tracing::debug!(conn = %conn.id, "client connected");

    let mut fan = fanout::start(hub.clone(), conn.clone(), flushes);
    let request_slots = Arc::new(Semaphore::new(REQUEST_WORK_LIMIT));
    let (notification_tx, notification_rx) =
        mpsc::channel::<(String, Value)>(NOTIFICATION_QUEUE_LIMIT);
    let (cancel_tx, cancel_rx) = mpsc::channel::<(String, Value)>(NOTIFICATION_QUEUE_LIMIT);
    let notification_handler = {
        let hub = hub.clone();
        let conn = conn.clone();
        move |method: String, params| {
            let hub = hub.clone();
            let conn = conn.clone();
            async move { handle_notification(&hub, &conn, &method, params).await }
        }
    };
    let notification_worker =
        spawn_notification_worker(notification_rx, notification_handler.clone());
    // A channel's frames, one at a time in the order they came (`channels.rs`): the worker above
    // runs notifications side by side, which would reorder a byte stream.
    let (channel_tx, channel_worker) = channels::spawn_worker(hub.clone(), conn.clone());
    let cancel_worker = spawn_notification_worker(cancel_rx, notification_handler);

    let notification_waiters = Arc::new(Semaphore::new(NOTIFICATION_WAIT_LIMIT));
    let mut notification_waits: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    let cancel_waiters = Arc::new(Semaphore::new(NOTIFICATION_WAIT_LIMIT));
    let mut cancel_waits: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    let dropped_notifications = Arc::new(AtomicU64::new(0));
    loop {
        // A reader past its byte bound is disconnected (`outbound.rs`): it reads again from its
        // cursor on a new connection, so nothing this one would still ask is answered. So is one
        // whose output ended (its reader gone, the journal's writer ended). So is one whose
        // fan-out task ended (a panic, the hub's feed closed): it would answer requests and never
        // push another record, so an attached client would wait on a chat that never moves. Its
        // reader sees the connection end and attaches again from its cursor.
        let line = tokio::select! {
            biased;
            () = conn.out.closed() => None,
            () = &mut device_ended => None,
            ended = &mut fan => {
                fanout::ended(&conn, ended);
                None
            }
            line = inbound.recv() => line,
        };
        let Some(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        // A v2 frame, known by its first bytes and never parsed into a `Value` (`link_v2.rs`).
        // Its wait for the connection to read the frame before it ends when the link does.
        if crate::link_v2::is_frame_line(&line) {
            // The wait also ends when the transport's reader does (a revoked credential).
            match link_v2.as_mut() {
                Some(link) => {
                    let slot = link.slot();
                    let reader_ended = tokio::select! {
                        biased;
                        () = conn.out.closed() => break,
                        () = slot.reader_ended() => true,
                        () = link.take(&line) => false,
                    };
                    if reader_ended {
                        link.end();
                    }
                }
                None => hub.link_v2.counters.drop_one(),
            }
            continue;
        }
        let line_bytes = line.len();
        let msg = match Message::parse(&line) {
            Ok(m) => m,
            Err(e) => {
                conn.send(&Message::err(Value::Null, e));
                continue;
            }
        };
        match msg {
            // Which of this connection's requests still run (`in_flight.rs` `states`): answered
            // here, in order with the requests read before it, and never queued for a slot, so a
            // client whose slots are all taken by slow requests still gets its proof. Only this
            // connection's own requests, like a `$/cancel_request`: any client may ask.
            Message::Request { id, method: m, .. } if m == method::MUX_REQUEST_STATE => {
                let (running, answered) = conn.in_flight.states();
                conn.send_replying(
                    &Message::ok(id, json!({"running": running, "answered": answered})),
                    Some(&m),
                );
            }
            Message::Request { id, method: m, mut params } => {
                // Every request its caller sent, refused ones too (`caller_stats.rs`); an
                // `initialize` once it named the client, below.
                if m != method::INITIALIZE {
                    crate::caller_stats::global().observe_request(
                        &conn.stats_caller(),
                        &m,
                        line_bytes,
                    );
                }
                // An open of a chat's view is timed from here to its reply (`gauges.attach`).
                let attach_from = crate::gauges::opens_a_chat(&m).then(std::time::Instant::now);
                // Once a local connection has been admitted as a trigger
                // principal it is a single-purpose channel. In particular,
                // the local socket must not keep granting ordinary person
                // RPCs after trigger authentication.
                if conn.is_trigger() && !m.starts_with("trigger/chat.") {
                    conn.send(&Message::err(
                        id,
                        RpcError::new(
                            -32001,
                            "trigger connection accepts trigger/chat operations only",
                        )
                        .with_data(json!({"reason": "trigger.connection_scope"})),
                    ));
                    continue;
                }
                let slot = match try_request_slot(&request_slots, &m) {
                    Ok(slot) => slot,
                    Err(()) => {
                        let error = RpcError::new(-32000, "connection request limit reached")
                            .with_data(json!({
                                "reason": "connection.busy",
                                "retryable": true,
                            }));
                        // In the lane of its method's answer: a busy refusal of a cheap read (the
                        // pane's liveness probe) proves the daemon alive only if it arrives, and
                        // a tool call's refusal is its answer.
                        let reply_to = outbound::reads_ahead(&m).then_some(m.as_str());
                        conn.send_replying(&Message::err(id, error), reply_to);
                        continue;
                    }
                };
                // In order, before the request is spawned: a later request
                // on this connection sees the person decided.
                if m == method::INITIALIZE
                    && conn.origin == Origin::Local
                    && let Some(caller) =
                        params.as_ref().and_then(|p| p.pointer("/_meta/acpmux/callerSession"))
                    && let Some(id) = caller.get("sessionId").and_then(Value::as_str)
                {
                    hub.session_meta(id).await;
                    // Known once adoption has read the earlier run's token (`settle_caller`).
                    if let Some(token) = caller.get("token").and_then(Value::as_str) {
                        hub.settle_caller(id, token).await;
                    }
                }
                // The host's sender token (`sender_token.rs`) leaves the request here, before
                // anything reads, stores, logs or forwards it; only a send's checks see it.
                let sender_token = params.as_mut().and_then(crate::sender_token::take);
                conn.bind_person(&hub, &m, &mut params);
                if m == method::INITIALIZE {
                    requests::note_initialize(&conn, params.as_ref().unwrap_or(&Value::Null));
                }
                // After it named the client: an `initialize` counts under that name.
                if m == method::INITIALIZE {
                    crate::caller_stats::global().observe_request(
                        &conn.stats_caller(),
                        &m,
                        line_bytes,
                    );
                }
                // Before its reply is built: the reply says whether large messages go compressed.
                if m == method::INITIALIZE
                    && let Some(wire) = &conn.wire
                    && crate::frame_compress::offered(params.as_ref())
                {
                    wire.enable();
                }
                // A peer link sent this request on two paths (`dual_requests.rs`): in order, so
                // the copy read first runs it and the other answers with its answer.
                let seen = dual_requests::key_for(conn.dual_principal, &m, params.as_ref());
                let dual_key = seen.as_ref().map(|(key, _)| key.clone());
                let dual = seen.and_then(dual_requests::admit);
                let dual_key = dual_key.filter(|_| dual.is_some());
                // Registered in order, before the request is spawned: a `$/cancel_request` read
                // after it finds it, and taking it frees its slot (`in_flight.rs`).
                let mut ticket = conn.in_flight.begin(&id, &m, slot, dual_key);
                #[cfg(test)]
                cancel_classes_tests::after_begin(&conn);
                let owner = conn.clone();
                let hub = hub.clone();
                let conn = conn.clone();
                owner.scope.spawn_named("conn-request", async move {
                    let perf_started = crate::perf_watch::request_started();
                    let mut first = match dual_requests::before_run(dual).await {
                        Ok(first) => first,
                        Err(answer) => {
                            // A cancel's part on this connection is its own (`dual_requests.rs`).
                            if m == method::SESSION_CANCEL {
                                requests::cancel_on_connection(&hub, &conn, params.as_ref());
                            }
                            if conn.in_flight.finish(&ticket) {
                                conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                            }
                            return;
                        }
                    };
                    // Read after the daemon's stop drained this connection's requests
                    // (`shutdown_drain.rs`): not served, answered as the drained ones were.
                    if ticket.refused() {
                        let answer = Err(shutdown_drain::restarting_error());
                        dual_requests::finish(first, Some(&answer));
                        conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                        return;
                    }
                    // One span per request, with the caller's end-to-end trace id
                    // (`params._meta.traceId`), for the Perfetto trace (`perf_trace.rs`).
                    let rpc_span = crate::perf_trace::request_span(&m, params.as_ref());
                    let route = || {
                        chats::route(&hub, &conn, &m, params.unwrap_or(Value::Null), sender_token)
                    };
                    let cancel =
                        std::mem::replace(&mut ticket.cancel, tokio::sync::oneshot::channel().1);
                    let claim = ticket.claim();
                    let serve = async {
                        let stage = crate::hub::RequestStage::Dispatch;
                        hub.request_hold(stage, &m, &id).await;
                        list_reply::scope(id.clone(), &m, claim, route).await
                    };
                    let serve = tracing::Instrument::instrument(serve, rpc_span);
                    // A cancel of its copy on another connection stops it too (`dual_requests.rs`).
                    let also = first.as_mut().and_then(dual_requests::First::take_stop);
                    let served = crate::request_cancel::until_either(cancel, also, serve).await;
                    // Cancelled: the cancel answered it, and a copy sent on another path gets
                    // that answer too (`dual_requests.rs`).
                    let Some((result, sent)) = served.filter(|_| conn.in_flight.finish(&ticket))
                    else {
                        // Stopped by a cancel of its copy on another connection: this copy's
                        // answer here is still owed, and is the cancel's.
                        if conn.in_flight.finish(&ticket) {
                            let cancelled = Err(crate::request_cancel::cancelled_error());
                            conn.send_replying(
                                &dual_requests::reply(id.clone(), cancelled),
                                Some(&m),
                            );
                        }
                        tracing::debug!(
                            target: crate::request_cancel::LOG_TARGET,
                            conn = %conn.id,
                            id = %id,
                            method = %m,
                            "dropped the answer to a request its client cancelled"
                        );
                        dual_requests::finish(
                            first,
                            Some(&Err(crate::request_cancel::cancelled_error())),
                        );
                        return;
                    };
                    // Opt-in usage patterns: methods this daemon serves (an unknown name a client
                    // made up is no key), `/` as `.` so `_acpmux/chat/list` is one key.
                    if cmux_usage_patterns::enabled()
                        && result.as_ref().err().is_none_or(|e| e.code != -32601)
                    {
                        cmux_usage_patterns::count("acpmux-method", &m.replace('/', "."));
                    }
                    // Its answer went whole into an open queue: one sent as its too-large error, or
                    // to a reader that is gone, opened nothing.
                    let watched = m == method::MUX_WATCH && result.is_ok() && sent == Some(true);
                    // A turn's answer after its updates (`fanout::Flush`).
                    if m == method::SESSION_PROMPT {
                        conn.fan_flush.sent().await;
                    }
                    // A shared session list, sent already as the bytes it was serialized to.
                    if !(sent.is_some() && result.is_ok()) {
                        let answer = result.map_err(|mut e| {
                            // What kind of failure, and what to do (`recovery.rs`).
                            crate::recovery::annotate(&mut e, None);
                            e
                        });
                        dual_requests::finish(first, Some(&answer));
                        conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                    } else {
                        dual_requests::finish(first, None);
                    }
                    crate::perf_watch::request_done(perf_started, &m, conn.origin);
                    if let Some(from) = attach_from {
                        crate::gauges::attach_latency().record(from.elapsed());
                    }
                    // A Mac that lends GitHub counts from here: its watch answer is queued, so
                    // no action reaches it before the answer that opens its side.
                    if watched
                        && conn.watch_all.load(Ordering::SeqCst)
                        && conn.client_requests.lends_github.load(Ordering::SeqCst)
                    {
                        hub.add_github_owner(&conn);
                    }
                });
            }
            // The client gives up on one of its requests: answered as cancelled at once, its
            // slot freed, and its work dropped, which tells the agent or peer it waited on
            // (`request_cancel.rs`). In order: it finds every request read before it. Before
            // every class's own filter (review F3 of #41285): it touches only this connection's
            // own requests, so a read-only machine, a teammate and a trigger may send it.
            Message::Notification { method: m, params } if m == method::CANCEL_REQUEST => {
                if let Some(id) = params.as_ref().and_then(crate::request_cancel::named_id)
                    && let Some((cancelled, dual)) = conn.in_flight.cancel(id)
                {
                    // One copy of a request sent on two paths: the copy that runs stops,
                    // whichever connection it came on, and a later one never runs.
                    if let Some(key) = dual {
                        dual_requests::cancel(&key);
                    }
                    let error = crate::request_cancel::cancelled_error();
                    conn.send_replying(&Message::err(id.clone(), error), Some(&cancelled));
                }
            }
            // A `_acpmux/v2` notification not in a frame line's form is no frame (`link_v2.rs`).
            Message::Notification { method: m, .. } if m == method::MUX_V2 => {
                hub.link_v2.counters.value_parses.fetch_add(1, Ordering::Relaxed);
                hub.link_v2.counters.drop_one();
            }
            // A read-only machine's other notifications (a session cancel) change nothing.
            Message::Notification { .. } if conn.auth == ConnAuth::ReadOnlyDevice => {}
            // A teammate through the carrier stops a turn, nothing else (`carrier.rs`).
            Message::Notification { method: m, params }
                if !carrier::takes_notification(&hub, &conn, &m, params.as_ref()) => {}
            Message::Notification { method: m, params: _ } if conn.is_trigger() => {
                tracing::debug!(conn = %conn.id, method = %m, "ignoring notification on trigger connection");
            }
            // The second copy of a notification a peer link sent on two paths.
            Message::Notification { method: m, params }
                if dual_requests::key_for(conn.dual_principal, m.as_str(), params.as_ref())
                    .is_some_and(|seen| !dual_requests::first_notification(seen)) =>
            {
                if m == method::SESSION_CANCEL {
                    requests::cancel_on_connection(&hub, &conn, params.as_ref());
                }
            }
            // A full channel queue holds this reader: backpressure on the sender, never a
            // dropped or reordered frame.
            Message::Notification { method: m, params } if channels::takes(&m) => {
                if channel_tx.send((m, params.unwrap_or(Value::Null))).await.is_err() {
                    break;
                }
            }
            Message::Notification { method: m, params } => {
                let params = params.unwrap_or(Value::Null);
                if m == method::SESSION_CANCEL {
                    match admit_notification(
                        &cancel_tx,
                        &cancel_waiters,
                        &mut cancel_waits,
                        (method::SESSION_CANCEL.to_owned(), params),
                    ) {
                        NotificationAdmission::Accepted => {}
                        NotificationAdmission::Closed => break,
                        NotificationAdmission::Dropped => {
                            if dropped_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
                                tracing::warn!(conn = %conn.id, "dropping notifications after bounded admission waiters are full");
                            }
                        }
                    }
                    continue;
                }
                match admit_notification(
                    &notification_tx,
                    &notification_waiters,
                    &mut notification_waits,
                    (m, params),
                ) {
                    NotificationAdmission::Accepted => {}
                    NotificationAdmission::Closed => break,
                    NotificationAdmission::Dropped => {
                        if dropped_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
                            tracing::warn!(conn = %conn.id, "dropping notifications after bounded admission waiters are full");
                        }
                    }
                }
            }
            // An answer to a request this daemon sent the client (`client_request.rs`).
            Message::Response { id, result, error } => {
                if !conn.is_trigger() && conn.auth != ConnAuth::CarrierTeam {
                    conn.settle_client_request(&id, result, error);
                }
            }
        }
    }
    conn.ended.send_replace(true);
    // Its listeners go and its channels close on their other side (`channels.rs`).
    channels::conn_ended(&hub, &conn).await;
    // The link's v2 connection ends with it.
    drop(link_v2);
    let preparations: Vec<_> =
        conn.preparation_cancels.lock().unwrap_or_else(|e| e.into_inner()).drain().collect();
    for (session, cancel) in preparations {
        cancel.send_replace(true);
        if let Ok(session) = hub.resolve(&session) {
            session.abandon_prepared_connection(&conn.id);
        }
    }
    // Cancellation has to reach the hub even when ordinary notifications are
    // still draining. Its worker is bounded independently and must never be
    // aborted by connection cleanup.
    for waiter in cancel_waits {
        let _ = waiter.await;
    }
    drop(cancel_tx);
    let _ = cancel_worker.await;
    drop(channel_tx);
    let _ = channel_worker.await;

    let deadline = tokio::time::Instant::now() + WORK_BACKPRESSURE_WAIT;
    let mut waiters = notification_waits.into_iter();
    while let Some(mut waiter) = waiters.next() {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if tokio::time::timeout(remaining, &mut waiter).await.is_err() {
            waiter.abort();
            let _ = waiter.await;
            for waiter in waiters {
                waiter.abort();
                let _ = waiter.await;
            }
            tracing::debug!(conn = %conn.id, "notification admission waiters did not drain");
            break;
        }
    }
    drop(notification_tx);
    let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
    let mut notification_worker = notification_worker;
    if tokio::time::timeout(remaining, &mut notification_worker).await.is_err() {
        notification_worker.abort();
        let _ = notification_worker.await;
    }
    let dropped = dropped_notifications.load(Ordering::Relaxed);
    if dropped > 0 {
        tracing::debug!(conn = %conn.id, dropped, "notification admission drops during connection");
    }
    fan.abort();
    conn.interest.forget();
    conn.media.close_all();
    conn.remote_media.close_all();
    view::release_all(&hub, &conn);
    // Leases first: ending one is cheap and synchronous, while the ephemeral
    // release awaits each session's kill. A leased peer must not keep
    // reconnecting to a forward port its bridge already closed, which another
    // process could bind (`hub/peer_lease.rs`).
    conn.end_peer_leases(&hub);
    // The phones the owner's peer daemon vouched for on this link end with it (fail closed).
    if hub.pairing.unvouch(&conn.id, None, None, 0) {
        hub.hold_policies_again().await;
    }
    ephemeral::release_all(&hub, &conn).await;
    tracing::debug!(conn = %conn.id, "client disconnected");
}

/// An unauthenticated connection: no hub subscription, no session, no
/// data. The first request gets the refusal, then the connection ends.
async fn refuse_unauthenticated(
    inbound: &mut mpsc::Receiver<String>,
    out: &mpsc::Sender<String>,
    origin: Origin,
) {
    tracing::warn!("refusing an unauthenticated {origin:?} connection");
    // Bounded: a client that never sends a request does not hold the task.
    let _ = tokio::time::timeout(FIRST_FRAME, async {
        while let Some(line) = inbound.recv().await {
            match Message::parse(&line) {
                Ok(Message::Request { id, .. }) => {
                    let _ = out.send(Message::err(id, conn_auth::refused()).to_line()).await;
                    return;
                }
                Ok(_) => continue,
                Err(_) if line.trim().is_empty() => continue,
                Err(_) => return,
            }
        }
    })
    .await;
}

/// Turn a hub record into client notifications for one connection. It is called only for the
/// records routed to the connection (`interest.rs`): a record a watcher is sent anything for here
/// must be one `interest::watch_hears` names.
fn deliver(hub: &Hub, conn: &Conn, ev: HubEvent) {
    // The close of one peer's batch of rows (`hub/list_guard.rs` `send_remote_batch`): only a
    // watcher that asked for batches hears it, in place of the rows' `session_changed`.
    if ev.record.kind == crate::hub::PEER_ROWS_CHANGED {
        if let Some(remote) = &ev.remote
            && conn.peer_row_batches.load(Ordering::SeqCst)
            && conn.watch_all.load(Ordering::SeqCst)
            && !view::a_link(conn)
        {
            let mut params = ev.record.msg.clone();
            params.set("peer", json!(remote.peer));
            params.set("listSeq", json!(ev.list_seq));
            conn.send(&Message::notification(method::MUX_PEER_ROWS_CHANGED, params));
        }
        return;
    }
    conn.controls.event(hub, conn, &ev);
    if ev.record.kind == crate::hub::PEER_LAGGED {
        if conn.sub_opts(&ev.session_id).is_some() {
            conn.send(&Message::notification("_acpmux/lagged", ev.record.msg.clone()));
        }
        return;
    }
    // The key of this chat's row in the queue (`outbound::Row`): its id, qualified for a peer's.
    let row_key = || -> Arc<str> {
        match &ev.remote {
            Some(remote) => remote.qualified_id(&ev.session_id).into(),
            None => Arc::from(ev.session_id.as_str()),
        }
    };
    // A chat's cold archive came or went (`hub/cold_archive.rs`): its row's `coldArchive`; or
    // another unlogged row change (`row_notice`). Not a logged record, so nothing but this
    // notice goes out for it.
    if ev.record.dir == crate::hub::COLD_CHANGED {
        held_rows::flush(hub, conn);
        let attached = conn.sub_opts(&ev.session_id).is_some();
        if (attached || conn.watch_all.load(Ordering::SeqCst))
            && let Ok(s) = hub.resolve(&ev.session_id)
        {
            let full = attached || conn.watch_tools.load(Ordering::SeqCst);
            let mut session =
                if full { hub.session_summary(&s) } else { hub.session_list_summary(&s) };
            if conn.omit_time_breakdown.load(Ordering::SeqCst)
                || (attached && omits_time_breakdown(conn, &ev.session_id))
            {
                requests::without_time_breakdown(&mut session);
            }
            let notice = json!({"sessionId": ev.session_id, "kind": ev.record.kind, "recordKind": ev.record.kind, "seq": s.meta().last_seq, "listSeq": ev.list_seq});
            // A patch names the row it builds on, so it is never replaced in the queue.
            if session_patch::send_row(conn, &ev.session_id, full, &session, notice) {
                return;
            }
            let msg = Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": session, "kind": ev.record.kind, "recordKind": ev.record.kind, "seq": s.meta().last_seq, "listSeq": ev.list_seq}),
            );
            // An attached chat's row stays among its updates; a watcher's is its latest state.
            let row = if attached { outbound::Row::None } else { outbound::Row::Latest(row_key()) };
            conn.send_row(&msg, row);
        }
        return;
    }
    chats::push_activity(hub, conn, &ev);
    processes::push_update(conn, &ev);
    let rec = &ev.record;
    // Attached peer updates retain the raw wire id, but also identify its owner and the id its
    // row has here (`qualifiedSessionId`), so clients key live transcripts and prompts by the
    // same route as their session rows. A peer daemon's link names it by its own route.
    let routed = |mut params: Value| {
        // A chat that moved to a peer keeps the shape its records had here (`follow.rs`).
        if ev.remote.is_some() && conn.follows.following(&ev.session_id) {
            return params;
        }
        if conn.origin != Origin::Peer
            && let Some(remote) = &ev.remote
        {
            races::peer::qualify_event(&remote.peer, &mut params);
            params.set("qualifiedSessionId", Value::String(remote.qualified_id(&ev.session_id)));
        }
        if let Some(obj) = params.as_object_mut() {
            obj.remove("peer");
            if let Some(remote) = &ev.remote {
                obj.insert("peer".into(), json!(remote.peer));
            }
        }
        params
    };
    let watching = conn.watch_all.load(Ordering::SeqCst);
    let sub = conn.sub_opts(&ev.session_id);
    let attached = sub.is_some();
    if !watching && !attached {
        return;
    }
    if let Some(sub) = &sub
        && rec.dir != "peer"
    {
        // A session message a `session/load` replay already sent here, as its envelope or its
        // notice, is not sent again (`MessageNotices`); an event stream hears only the kinds it
        // asked for, this notice too.
        let message = rec.dir == "mux" && rec.kind == "_acpmux/message";
        let heard = !sub.event_stream || sub.filter.matches_live(rec);
        let repeat = message && heard && {
            let owner = ev.remote.as_ref().map(|r| r.peer.as_str());
            !conn.message_notices.lock_or_recover().live(owner, &ev.session_id, rec.seq)
        };
        // Whether this record went out (or a replay sent it): a peer daemon's link hears of one
        // that did not by its seq alone (`MUX_UNSENT`).
        let mut sent = repeat || sub.event_stream;
        // The agent's stream to a client that draws nothing of the chat while hidden: left out,
        // and read again from its cursor once shown (`SubOpts::quiet_hidden`). Every other record
        // (status, turn ends, asks, the queue) still goes, so its row and its asks stay current.
        let quiet = sub.quiet_hidden
            && sub.hidden
            && rec.dir == "in"
            && rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
            && (!sub.event_stream || sub.filter.matches_live(rec))
            && conn.leaves_out_hidden(&ev.session_id, rec.seq);
        if repeat || quiet {
            // Sent by the replay, or left out while hidden.
        } else if sub.event_stream {
            if sub.filter.matches_live(rec) {
                let params = routed(event_value(&ev.session_id, rec));
                conn.send(&conn.chunk_deltas.frame(&ev.session_id, params));
            }
        } else {
            // Agent -> client updates as standard ACP notifications.
            if rec.dir == "in"
                && !rec.kind.ends_with(".replay")
                && let Some(m) = rec.msg.get("method").and_then(Value::as_str)
                && m == method::SESSION_UPDATE
            {
                let message = || {
                    hub.session_update_encodes.fetch_add(1, Ordering::Relaxed);
                    let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                    params.set("sessionId", Value::String(ev.session_id.clone()));
                    crate::hub::merge_mux_meta(
                        &mut params,
                        json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind}),
                    );
                    Message::notification(method::SESSION_UPDATE, routed(params))
                };
                if conn.origin == Origin::Peer {
                    // A peer daemon's link redacts and masks per connection (`send_replying`).
                    conn.send(&message());
                } else {
                    // Every other connection reads the line as it is: built once per record,
                    // shared (`HubEvent::update_line`). None: too large for one frame.
                    let line = ev
                        .update_line
                        .get_or_init(|| message().bounded_line_replying(None).ok().map(Arc::from));
                    match line {
                        Some(line) => conn.send_line(line),
                        None => conn.send(&message()),
                    }
                }
                sent = true;
            }
            if rec.dir == "mux" {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    routed(event_value(&ev.session_id, rec)),
                ));
                sent = true;
            }
        }
        // The owner's copy of this chat takes a live record only next to what it covers
        // (`hub/peer_snapshot.rs` `take_record`): without this, the turn's own `session/prompt`
        // stopped it until the next page, so a move during a long turn found a copy without
        // the running turn or the prompts queued behind it.
        if !sent
            && rec.seq > 0
            && conn.origin == Origin::Peer
            && ev.remote.is_none()
            && conn.client_features.hears_any(&[client_features::UNSENT_FEATURE])
        {
            conn.send(&Message::notification(
                method::MUX_UNSENT,
                json!({"sessionId": ev.session_id, "seq": rec.seq}),
            ));
        }
        if message
            && heard
            && !repeat
            && conn.client_features.hears_any(&[crate::capabilities::SESSION_MESSAGES])
        {
            // Routed as the event beside it: a peer's chat id alone may match one here.
            conn.send(&Message::notification(method::MUX_MESSAGE, routed(rec.msg.clone())));
        }
        if rec.dir == "mux" && is_permission_ask(&rec.kind) {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                routed(permission_pending(&ev.session_id, rec, "attach", ev.remote.is_none())),
            ));
        }
        if let Some(following) = &sub.rows
            && !quiet
            && ev.remote.is_none()
            && let Some((notice, params)) = crate::rows::live(hub, &ev.session_id, rec, following)
        {
            conn.send(&Message::notification(notice, params));
        }
    }
    if watching {
        if let Some(remote) = &ev.remote {
            // A peer's prompt the person must answer, for a unix socket or app
            // watcher that did not attach the session (`hub/person.rs` (c)):
            // never relayed on to a Web client or another peer daemon.
            if rec.kind == crate::hub::PEER_PERMISSION_PENDING {
                if !attached && !conn.origin.web_class() {
                    conn.send_row(
                        &Message::notification(
                            method::MUX_PERMISSION_PENDING,
                            peer_permission_pending(&ev.session_id, rec, remote),
                        ),
                        outbound::Row::After(row_key()),
                    );
                }
                return;
            }
            // Peers already filter to the interesting kinds and send a summary. Another
            // daemon's link hears no change of a row this daemon mirrors: the link drops every
            // such row (`peer.rs` `watch_sessions`), so each change of one peer's row went out on
            // every other peer's link for nothing (24 copies of every change with one daemon's
            // 25 peers, 2026-10-30), and the row's origin hears it from its own. A row of a batch
            // reaches a watcher that asked for batches as the batch's one notice, unless this
            // connection attached the row's chat (`send_remote_batch`, `peer_rows_changed`).
            let batched =
                ev.peer_batch && !attached && conn.peer_row_batches.load(Ordering::SeqCst);
            if rec.dir == "peer" && !view::a_link(conn) && !batched {
                held_rows::flush(hub, conn);
                let sid = remote.summary.session_id().unwrap_or(&ev.session_id);
                // The packed row, parsed for this line only (`RemoteRef::summary`).
                let tools = attached || conn.watch_tools.load(Ordering::SeqCst);
                let mut session: Value = serde_json::from_str(&remote.summary.changed_text(tools))
                    .unwrap_or(Value::Null);
                if conn.omit_time_breakdown.load(Ordering::SeqCst) {
                    requests::without_time_breakdown(&mut session);
                }
                let qualified = remote.qualified_id(&ev.session_id);
                if !attached && conn.leaves_out_row() {
                    // Read again with the list once a chat here shows (`leaves_out_row`).
                    session_patch::forget(conn, &qualified);
                    return;
                }
                if rec.kind == "purged" {
                    session_patch::forget(conn, &qualified);
                } else if session.is_object() {
                    let notice = json!({"sessionId": sid, "qualifiedSessionId": qualified, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer, "listSeq": ev.list_seq});
                    if session_patch::send_row(conn, &qualified, tools, &session, notice) {
                        return;
                    }
                }
                let row =
                    if attached { outbound::Row::None } else { outbound::Row::Latest(row_key()) };
                conn.send_row(
                    &Message::notification(
                        method::MUX_SESSION_CHANGED,
                        json!({"sessionId": sid, "qualifiedSessionId": qualified, "session": session, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer, "listSeq": ev.list_seq}),
                    ),
                    row,
                );
            }
            return;
        }
        if rec.dir == "mux" && rec.kind == "purged" {
            held_rows::flush(hub, conn);
            session_patch::forget(conn, &ev.session_id);
            if !attached && conn.leaves_out_row() {
                return;
            }
            // `replaced`: the same chat came back under this id (`Session::replaced`).
            let mut params = json!({"sessionId": ev.session_id, "session": {"sessionId": ev.session_id}, "kind": "purged", "recordKind": "purged", "seq": rec.seq, "listSeq": ev.list_seq});
            if rec.msg.get("replaced") == Some(&Value::Bool(true)) {
                params.set("replaced", Value::Bool(true));
            }
            // A purge is not passed by a newer row (a `replaced` chat starts over after it).
            conn.send_row(
                &Message::notification(method::MUX_SESSION_CHANGED, params),
                outbound::Row::After(row_key()),
            );
            return;
        }
        // A deferred new chat has no attachment yet. Its command publication must still wake
        // the page's read of that chat's command list, including when skills arrive after creation.
        if rec.dir != "mux" && rec.kind != "available_commands_update" {
            return;
        }
        let Some(kind) = change_kind::session_change_kind(&rec.kind) else { return };
        // A chat's command list still wakes its read (above); its asks still go (below).
        let row_left_out =
            !attached && rec.kind != "available_commands_update" && conn.leaves_out_row();
        // A watcher that is not attached still learns a permission is waiting, after the row
        // that recorded it.
        let ask_pending = || {
            if is_permission_ask(&rec.kind) && !attached {
                conn.send_row(
                    &Message::notification(
                        method::MUX_PERMISSION_PENDING,
                        permission_pending(&ev.session_id, rec, "watch", ev.remote.is_none()),
                    ),
                    outbound::Row::After(row_key()),
                );
            }
        };
        if row_left_out {
            session_patch::forget(conn, &ev.session_id);
            ask_pending();
            return;
        }
        // The row of a record that opens a turn waits behind the turn's first output
        // (`held_rows.rs`); any other row goes after the ones held, in row order.
        if attached && held_rows::opens_a_turn(&rec.kind) {
            conn.held_rows.hold(&ev.session_id, &rec.kind, rec.seq, ev.list_seq);
            return;
        }
        held_rows::flush(hub, conn);
        // Built once per record, by the first watcher that sends it, and shared by the others
        // (`HubEvent::row`): with many watchers, each built the whole row again.
        let full = attached || conn.watch_tools.load(Ordering::SeqCst);
        // A full row is mostly its time breakdown (93 of 96 KB on a 2,000-turn chat), sent again
        // on every record of a running turn; a client that draws none shares a row without it.
        let lean = full
            && (conn.omit_time_breakdown.load(Ordering::SeqCst)
                || (attached && omits_time_breakdown(conn, &ev.session_id)));
        let [list_row, full_row, lean_row] = &ev.row.cells;
        let row = if lean {
            lean_row
        } else if full {
            full_row
        } else {
            list_row
        };
        let summary = row.get_or_build(|| {
            let s = hub.resolve(&ev.session_id).ok()?;
            Some(if full {
                let mut summary = hub.session_change_summary(&s);
                if lean {
                    requests::without_time_breakdown(&mut summary);
                }
                summary
            } else {
                hub.session_list_summary(&s)
            })
        });
        if let Some(summary) = summary {
            let notice = json!({"sessionId": ev.session_id, "kind": kind, "recordKind": rec.kind, "seq": rec.seq, "listSeq": ev.list_seq});
            if !session_patch::send_row(conn, &ev.session_id, full, &summary, notice) {
                let row =
                    if attached { outbound::Row::None } else { outbound::Row::Latest(row_key()) };
                conn.send_row(
                    &Message::notification(
                        method::MUX_SESSION_CHANGED,
                        json!({"sessionId": ev.session_id, "session": *summary, "kind": kind, "recordKind": rec.kind, "seq": rec.seq, "listSeq": ev.list_seq}),
                    ),
                    row,
                );
            }
        }
        ask_pending();
    }
}

fn str_param<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

pub(crate) fn session_key(params: &Value) -> Result<&str, RpcError> {
    str_param(params, "sessionId")
        .or_else(|| str_param(params, "session"))
        .or_else(|| str_param(params, "name"))
        .ok_or_else(|| RpcError::invalid_params("sessionId or session is required"))
}

fn mux_meta(params: &Value) -> Option<&Value> {
    params.get("_meta").and_then(|m| m.get("acpmux"))
}

pub(crate) use crate::clock_text::{civil_from_days, iso};
use crate::hub::is_permission_ask;
pub use crate::ws_auth;
pub(crate) use agent_login::claude_machine_login_env;
pub(crate) use change_kind::session_change_kind;
pub use chat_windows::live_tasks as live_chat_window_tasks;
pub(crate) use chats::usage_upload_loop;
pub use conn_auth::ConnAuth;
use lane_parent::lane_parent;
pub(crate) use outbound::is_cheap_read;
pub use pairing::serve_connection_device;
pub(crate) use peer_forward::strip_asks as strip_peer_asks;
pub use pending::{event_value, into_event_value};
use pending::{peer_permission_pending, permission_pending};
pub(crate) use redact::url_without_secrets;
use requests::handle_notification;
pub use requests::{DURABLE_DISPATCH_FEATURE, SESSION_RESUME_FEATURE};
pub(crate) use vault::reply as vault_reply;
pub(crate) use workflow_activity::owner_call as workflow_owner_call;
