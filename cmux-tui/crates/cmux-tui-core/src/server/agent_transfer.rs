//! Guarded chat moves between daemons (`agent-transfer-v1`, cmuxterm-hq#1874
//! slice 1): a trusted local client (the app's Move to Cloud pump) moves an
//! agent chat from one daemon's acpmux to another's. This daemon forwards
//! acpmux's `acpmux.transfer.v1` calls (`_acpmux/transfer_*`, local socket
//! only) to its own acpmux as a local client, and every receive it forwards
//! carries a guard this daemon builds itself; no acpmux port is opened.
//!
//! Target verbs (the chat arrives here):
//! - `agent-transfer-receive {manifest, cwd}`: `_acpmux/transfer_receive
//!   {manifest, guard}`, answers `{receive_id, session_id}`. The guard:
//!   on a cmux Cloud host `{control:"peer", roots:[canonical $HOME/work]}`;
//!   on any other host (a Mac taking a chat back) `{control:"web",
//!   roots:[cwd]}`, where `cwd` must be an existing folder strictly under
//!   `$HOME` that is not under a dot folder of `$HOME`. Either way `cwd` must
//!   canonicalize under the roots. acpmux must answer `guarded: true` (an
//!   acpmux that ignores the guard is refused). The guard and the canonical
//!   folder are kept per receive in memory.
//! - `agent-transfer-write {receive_id, path, offset, data}`: one page.
//! - `agent-transfer-finish {receive_id, name?}`: imports the chat in the
//!   receive's own folder (`cwd` is never taken here). The session id
//!   acpmux answers is remembered as landed here (`landed.rs`), so
//!   `new-conversation-tab` may file it under this store's `registry:`
//!   host. While the call runs
//!   (from the moment acpmux is reached until it returns, on every path) a
//!   receive-abort of it answers that the landing cannot be told yet.
//! - `agent-transfer-receive-abort {receive_id}`: forgets the receive and has
//!   acpmux forget its move (`_acpmux/transfer_forget` with the transfer and
//!   session ids of the receive's own manifest): acpmux drops the receive's
//!   files and refuses that move from then on. A receive its finish ended
//!   (settled) can still be asked, so a pump that lost the finish answer
//!   learns whether the chat landed (`landed`) before it commits or aborts
//!   the source. A receive acpmux answered here stays askable after it was
//!   dropped and after this daemon restarts (`askable.rs`: the 40 most
//!   recent, 24 h each, on disk when the session has a state folder), so a
//!   restart between a finish and the pump's question does not leave the
//!   move unresolved.
//!
//! Machine kind: receive and finish read `agent-session-start`'s host gate
//! at each call and refuse on a team VM and on a Cloud VM of unknown kind
//! (hq-84). A peer-control chat keeps its policy and mode and runs its queue
//! at once, so it may only land on a Mac or a personal Cloud VM.
//!
//! Source verbs (the chat leaves here), by tab, never by session id:
//! - `agent-transfer-source {surface}` answers `{session}`, the session the
//!   tab's store record names, read here without reaching acpmux (attaching
//!   would mark the chat seen), so a pump can tell the tab still shows the
//!   chat its recorded move took.
//! - `agent-transfer-begin {surface, interrupt?}` answers `{transfer_id,
//!   source_session, manifest}` (`source_session` as `agent-transfer-source`). The bundle's `manifest.json` is served without its absolute
//!   `source` paths, and its `session.json` without the source machine's
//!   launch settings (env, argv, harness roots, preset, tags; its `cwd`
//!   stays, the target's finish replaces it); the manifest lists their
//!   scrubbed sizes. With `ask_first: true` the chat is first narrowed here
//!   to an asking policy, rules and mode (`ask_first.rs`), so a Mac's guard
//!   that refused it takes it.
//! - `agent-transfer-read {transfer_id, path, offset, limit?}` pages a bundle
//!   file the begin manifest of a move begun through this daemon lists.
//! - `agent-transfer-commit {surface, transfer_id, to}` and
//!   `agent-transfer-abort {surface, transfer_id}`.
//!
//! Who: trusted local (Unix) connections that are not remote clients, the
//! test `agent-session-attach` uses. The remote relay (`cmux link`) runs
//! before this handler and does not list these verbs (default deny); a
//! WebSocket or stamped client gets one generic refusal before its frame is
//! read. A frame with `guard`, `roots`, `control`, `env`, `mcpServers`,
//! `sessionId`, a command-bearing param or any other unknown param is
//! refused before anything reaches acpmux.
//!
//! Bounds: pages of at most [`MAX_PAGE_BYTES`] (acpmux's own page size), 16
//! receives and 16 moves remembered (24 h each), 8 calls at once.

use crate::panic_free::JsonFields;
use cmux_threads::sync::{Mutex, RwLock};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use super::agent_session_attach::agent_session_start::vm_word;
use super::remote_relay::gate::COMMAND_PARAMS;
use super::responses::send_response_with_details;
use super::routes::{Route, RouteLine, RouteName};
use super::{FrameStage, MessageWriter, Response, SurfaceId};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;

mod bundle;
use bundle::{is_bundle_path, page_data_len, page_of, scrub_bundle};
/// `access-request-v1`, served on a Cloud host as this is.
pub mod access_requests;
/// `agent-update-v1`, the same kind of trusted local acpmux client.
pub mod agent_update;
mod ask_first;
mod askable;
mod guard;
use guard::{guard_for, is_chat_name, is_plain_id, plain_cwd};
mod landed;
pub(super) mod state_file;

pub const AGENT_TRANSFER_CAPABILITY: &str = "agent-transfer-v1";
/// `vm_kind` on `agent-transfer-receive` and `agent-transfer-finish`: the
/// caller's word that the Cloud API answered `vmKind: "owner"` for it on
/// its link, which a chat move onto a Cloud VM needs.
pub const AGENT_TRANSFER_VM_KIND_CAPABILITY: &str = "agent-transfer-vm-kind-v1";

/// The largest page of bundle data a write takes or a read answers.
pub(crate) const MAX_PAGE_BYTES: usize = 4 << 20;
const DEFAULT_READ: u64 = 1 << 20;
const MAX_RECEIVES: usize = 16;
/// Settled receives kept for a pump's question (the oldest goes first).
const MAX_SETTLED: usize = 16;
/// A receive-abort's answer when nothing was forgotten: the receive stays
/// and whether the chat landed is unknown.
static UNKNOWN_LANDING: std::sync::LazyLock<Value> =
    std::sync::LazyLock::new(|| json!({"dropped": false, "forgotten": false, "landed": null}));
const MAX_MOVES: usize = 16;
const MAX_CALLS: usize = 8;
/// A receive or move not touched that long is forgotten (acpmux sweeps its
/// own files after the same time).
const STALE: Duration = Duration::from_secs(24 * 3600);
const MAX_PATH_BYTES: usize = 4096;
const MAX_TO_BYTES: usize = 4096;
const CALL_TIMEOUT: Duration = Duration::from_secs(15);
/// A begin may stop a running turn (acpmux waits up to 20 s for it).
const BEGIN_TIMEOUT: Duration = Duration::from_secs(30);
/// A finish imports the chat (and may replace a moved-away copy).
const FINISH_TIMEOUT: Duration = Duration::from_secs(60);

/// Frame params refused on every verb (the guard is the daemon's own).
const FORBIDDEN_PARAMS: &[&str] =
    &["guard", "roots", "control", "env", "mcpServers", "sessionId", "session_id"];

/// What machine this daemon takes chats on, as the binary reads it at start
/// (never from a request).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentTransferHost {
    /// A cmux Cloud host (the `fs-v1` test): chats arrive under
    /// `$HOME/work`, controlled by the peer that sent them.
    pub cloud: bool,
    /// This user's home.
    pub home: PathBuf,
}

/// The host and the receives and moves running through this daemon.
#[derive(Default)]
pub(crate) struct AgentTransfers {
    host: RwLock<Option<AgentTransferHost>>,
    receives: Mutex<HashMap<String, Receive>>,
    /// Receives a finish ended: only a receive-abort still names them.
    settled: Mutex<HashMap<String, Settled>>,
    moves: Mutex<HashMap<String, Move>>,
    /// Chats a finish here landed (`landed.rs`).
    landed: landed::Landed,
    /// Receives a receive-abort may still name after a restart (`askable.rs`).
    askable: askable::Askable,
    calls: AtomicUsize,
    /// Update Everything's agent CLI updates (`agent_update.rs`).
    updates: agent_update::AgentUpdates,
}

/// A guarded receive: what its finish uses.
struct Receive {
    cwd: String,
    /// The move and chat its manifest names (what a forget drops).
    moved: Moved,
    touched: Instant,
    /// A finish of it is running: whether the chat lands is not known yet.
    finishing: bool,
}

/// A receive its finish ended (it landed, or it never can).
struct Settled {
    moved: Moved,
    touched: Instant,
}

/// A move's id and its chat's session id, from a receive's manifest.
#[derive(Clone)]
struct Moved {
    transfer_id: String,
    session_id: String,
}

/// A move's listed bundle paths, each with the scrubbed bytes served for it
/// (none: read from acpmux).
type BundleFiles = HashMap<String, Option<Arc<Vec<u8>>>>;

/// A move out begun through this daemon.
struct Move {
    /// Every bundle path its begin manifest listed, with the scrubbed bytes
    /// served for `manifest.json` and `session.json`.
    files: BundleFiles,
    touched: Instant,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

impl AgentTransfers {
    fn host(&self) -> Option<AgentTransferHost> {
        self.host.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn receive_cwd(&self, receive_id: &str) -> Option<String> {
        let mut receives = lock(&self.receives);
        let receive = receives.get_mut(receive_id)?;
        receive.touched = Instant::now();
        Some(receive.cwd.clone())
    }

    /// Marks the receive's finish as running (or done, `false`).
    fn set_finishing(&self, receive_id: &str, finishing: bool) {
        if let Some(receive) = lock(&self.receives).get_mut(receive_id) {
            receive.finishing = finishing;
        }
    }
}

/// Held while a finish call runs: the receive answers "cannot say yet" to a
/// receive-abort until it drops, on every path (an answer, an error, a
/// panic). A finish that settled the receive leaves nothing to clear.
struct Finishing<'a> {
    transfers: &'a AgentTransfers,
    receive_id: &'a str,
}

impl<'a> Finishing<'a> {
    fn start(transfers: &'a AgentTransfers, receive_id: &'a str) -> Self {
        transfers.set_finishing(receive_id, true);
        Self { transfers, receive_id }
    }
}

impl Drop for Finishing<'_> {
    fn drop(&mut self) {
        self.transfers.set_finishing(self.receive_id, false);
    }
}

impl AgentTransfers {
    /// The scrubbed bytes of `path` (or none: read it from acpmux) when
    /// this daemon began the move and its manifest lists `path`.
    fn listed(&self, transfer_id: &str, path: &str) -> Result<Option<Arc<Vec<u8>>>, Refusal> {
        let mut moves = lock(&self.moves);
        let entry = moves.get_mut(transfer_id).ok_or(Refusal::UnknownTransfer)?;
        entry.touched = Instant::now();
        entry.files.get(path).cloned().ok_or(Refusal::BadRequest)
    }

    /// Ends the receive `receive_id`, keeping what a receive-abort asks.
    fn settle(&self, receive_id: &str) {
        let Some(receive) = lock(&self.receives).remove(receive_id) else { return };
        let mut settled = lock(&self.settled);
        settled.retain(|_, entry| entry.touched.elapsed() < STALE);
        while settled.len() >= MAX_SETTLED {
            let oldest = settled.iter().min_by_key(|(_, entry)| entry.touched);
            let Some(oldest) = oldest.map(|(id, _)| id.clone()) else { break };
            settled.remove(&oldest);
        }
        settled.insert(
            receive_id.to_owned(),
            Settled { moved: receive.moved, touched: Instant::now() },
        );
    }

    /// What a receive-abort does: forget a live receive's move (the receive
    /// taken out, so no write or finish reaches it) or a settled one's (kept,
    /// so the question can be asked again), or answer "cannot say yet" while
    /// the receive's finish runs.
    fn take_for_abort(&self, receive_id: &str) -> Option<Prepared> {
        {
            let mut receives = lock(&self.receives);
            if receives.get(receive_id).is_some_and(|r| r.finishing) {
                return Some(Prepared::Answer(UNKNOWN_LANDING.clone()));
            }
            if let Some(receive) = receives.remove(receive_id) {
                let moved = receive.moved.clone();
                let receive_id = receive_id.to_owned();
                return Some(Prepared::Forget { receive_id, moved, live: Some(receive) });
            }
        }
        let mut settled = lock(&self.settled);
        let entry = settled.get_mut(receive_id).filter(|e| e.touched.elapsed() < STALE)?;
        entry.touched = Instant::now();
        let moved = entry.moved.clone();
        Some(Prepared::Forget { receive_id: receive_id.to_owned(), moved, live: None })
    }

    /// Puts back a live receive whose forget did not happen, so it can be
    /// asked again (a settled one was never taken out).
    fn restore(&self, receive_id: String, live: Option<Receive>) {
        if let Some(receive) = live {
            lock(&self.receives).insert(receive_id, receive);
        }
    }

    fn full<T>(map: &mut HashMap<String, T>, cap: usize, touched: impl Fn(&T) -> Instant) -> bool {
        map.retain(|_, value| touched(value).elapsed() < STALE);
        map.len() >= cap
    }
}

impl Mux {
    /// The machine this daemon takes moved chats on (the binary's Cloud host
    /// test and `$HOME`). Until it is set, the verbs answer
    /// `agent_transfer.unavailable` and `agent-transfer-v1` is not advertised.
    pub fn set_agent_transfer_host(&self, host: Option<AgentTransferHost>) {
        *self.agent_transfers.host.write().unwrap_or_else(|e| e.into_inner()) = host;
    }

    /// True on a cmux Cloud host, as the binary set it at start
    /// (`access-request-v1` is served there only).
    pub(crate) fn on_cloud_host(&self) -> bool {
        self.agent_transfers.host().is_some_and(|host| host.cloud)
    }

    /// True with an acpmux socket path and a host.
    pub(crate) fn serves_agent_transfer(&self) -> bool {
        self.serves_agent_session_attach() && self.agent_transfers.host().is_some()
    }
}

// MARK: Requests

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceiveParams {
    manifest: Map<String, Value>,
    cwd: String,
    /// The Cloud API's `vmKind` for the caller (only `owner` counts; an
    /// explicit `null` is a word, and refuses).
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WriteParams {
    receive_id: String,
    path: String,
    offset: u64,
    data: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FinishParams {
    receive_id: String,
    #[serde(default)]
    name: Option<String>,
    /// As the receive's.
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceiveAbortParams {
    receive_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceParams {
    surface: SurfaceId,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BeginParams {
    surface: SurfaceId,
    #[serde(default)]
    interrupt: bool,
    #[serde(default)]
    ask_first: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadParams {
    transfer_id: String,
    path: String,
    offset: u64,
    #[serde(default)]
    limit: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommitParams {
    surface: SurfaceId,
    transfer_id: String,
    to: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AbortParams {
    surface: SurfaceId,
    transfer_id: String,
}

/// The `agent-transfer-*` commands, decoded by their `cmd`; spec/sdk-schema.json
/// types each variant (check-sdk-schema.py compares the fields).
#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum Verb {
    #[serde(rename = "agent-transfer-receive")]
    Receive(ReceiveParams),
    #[serde(rename = "agent-transfer-write")]
    Write(WriteParams),
    #[serde(rename = "agent-transfer-finish")]
    Finish(FinishParams),
    #[serde(rename = "agent-transfer-receive-abort")]
    ReceiveAbort(ReceiveAbortParams),
    #[serde(rename = "agent-transfer-begin")]
    Begin(BeginParams),
    #[serde(rename = "agent-transfer-read")]
    Read(ReadParams),
    #[serde(rename = "agent-transfer-commit")]
    Commit(CommitParams),
    #[serde(rename = "agent-transfer-abort")]
    Abort(AbortParams),
    #[serde(rename = "agent-transfer-source")]
    Source(SourceParams),
}

impl Verb {
    /// The verb of a frame (its `cmd` and params, `id` taken out); `None` for
    /// a forbidden, unknown or malformed param or an unknown verb.
    fn parse(frame: Map<String, Value>) -> Option<Self> {
        if frame.keys().any(|key| {
            FORBIDDEN_PARAMS.contains(&key.as_str()) || COMMAND_PARAMS.contains(&key.as_str())
        }) {
            return None;
        }
        serde_json::from_value(Value::Object(frame)).ok()
    }
}

/// Refusal codes (`error_code`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    NotTrusted,
    Unavailable,
    BadRequest,
    OutsideRoots,
    UnknownTab,
    UnknownReceive,
    UnknownTransfer,
    Unguarded,
    Limit,
    Timeout,
    Refused,
    /// `agent-session-start`'s code: this daemon runs on a team VM.
    TeamVmBlocked,
    /// `agent-session-start`'s code: a Cloud VM of unknown kind.
    HostUnverified,
}

impl Refusal {
    fn code(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_transfer.not_trusted",
            Self::Unavailable => "agent_transfer.unavailable",
            Self::BadRequest => "agent_transfer.bad_request",
            Self::OutsideRoots => "agent_transfer.outside_roots",
            Self::UnknownTab => "agent_transfer.unknown_tab",
            Self::UnknownReceive => "agent_transfer.unknown_receive",
            Self::UnknownTransfer => "agent_transfer.unknown_transfer",
            Self::Unguarded => "agent_transfer.unguarded",
            Self::Limit => "agent_transfer.limit",
            Self::Timeout => "agent_transfer.timeout",
            Self::Refused => "agent_transfer.refused",
            Self::TeamVmBlocked => "agent_session.team_vm_blocked",
            Self::HostUnverified => "agent_session.host_unverified",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent transfer needs a trusted local connection",
            Self::Unavailable => "this daemon has no acpmux or host to move chats with",
            Self::BadRequest => "bad request",
            Self::OutsideRoots => "the folder is not one this daemon takes moved chats in",
            Self::UnknownTab => "not an agent tab with a session in this daemon",
            Self::UnknownReceive => "no such receive on this daemon",
            Self::UnknownTransfer => "no such move on this daemon",
            Self::Unguarded => "acpmux did not apply the receive guard",
            Self::Limit => "too many chat moves at once",
            Self::Timeout => "acpmux did not answer in time",
            Self::Refused => "acpmux refused the request",
            Self::TeamVmBlocked => "agent chats cannot be moved onto a team VM",
            Self::HostUnverified => {
                "this machine cannot tell whether it is a team VM, so it takes no moved chat"
            }
        }
    }
}

/// `agent-session-start`'s machine kind gate, read again at each call, with
/// the call's own `vm_kind`.
fn host_gate(mux: &Mux, vm_kind: Option<&str>) -> Result<(), Refusal> {
    use super::agent_session_attach::Refusal as Start;
    match mux.agent_host_gate(vm_kind) {
        Ok(()) => Ok(()),
        Err(Start::TeamVmBlocked) => Err(Refusal::TeamVmBlocked),
        Err(_) => Err(Refusal::HostUnverified),
    }
}

/// Whether a finish outcome ends its receive: a success, or a failure no
/// retry changes (anything but a timeout, a busy or gone acpmux, or pages
/// still missing, `transfer.incomplete`).
fn ends_receive(outcome: &Result<Value, Failure>) -> bool {
    match outcome {
        Ok(_) => true,
        Err(Failure::Refusal(refusal)) => {
            !matches!(refusal, Refusal::Timeout | Refusal::Unavailable | Refusal::Limit)
        }
        Err(Failure::Acpmux(message)) => !message.starts_with("transfer.incomplete"),
        Err(Failure::Moving(..)) => true,
    }
}

/// A refusal, or acpmux's own error (its message reaches the trusted client,
/// so the pump can tell an incomplete bundle from an existing chat).
enum Failure {
    Refusal(Refusal),
    Acpmux(String),
    /// A begin of a chat already in a move: acpmux's `transfer.moving`, with
    /// that move's id (`error_details.transfer_id`), so a pump that lost its
    /// begin answer can resolve the move it began.
    Moving(String, String),
}

impl From<Refusal> for Failure {
    fn from(refusal: Refusal) -> Self {
        Self::Refusal(refusal)
    }
}

impl From<LinkError> for Failure {
    fn from(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::Refusal(Refusal::Unavailable),
            LinkError::Timeout => Self::Refusal(Refusal::Timeout),
            LinkError::Busy => Self::Refusal(Refusal::Limit),
            LinkError::MethodNotFound(message) => Self::Acpmux(message),
            LinkError::Rpc(message, data) => {
                let moving = data.field("transferId").as_str().filter(|id| is_plain_id(id));
                match moving {
                    Some(id) if message.starts_with("transfer.moving") => {
                        Self::Moving(message, id.to_owned())
                    }
                    _ => Self::Acpmux(message),
                }
            }
        }
    }
}

/// The `cmd` names this module answers (server/routes.rs); access requests
/// and agent updates have their own routes.
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Prefix("agent-transfer-")],
    stage: FrameStage::AgentTransfer,
    entry: handle,
}];

/// Answers a line whose `cmd` starts with `agent-transfer-` (the route found
/// it by name). The line's one decode is its `Value`, which gives every
/// reply the `id` as written, a refused one too, and then the typed
/// [`Verb`]. `None` only for a line with no `Value` (a number past `f64`, a
/// lone surrogate); the `Command` parse answers it. Remote-relay
/// connections never get here.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let Ok(Value::Object(mut object)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    let id = object.remove("id");
    // Trust first: an untrusted client gets one answer whatever it sent.
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Refusal::NotTrusted.into())));
    }
    let Some(verb) = Verb::parse(object) else {
        return Some(reply(writer, id, Err(Refusal::BadRequest.into())));
    };
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Refusal::Unavailable.into())));
    };
    // The call slot first: a prepared receive-abort has already taken its
    // receive, which a refusal here would lose.
    let transfers = &mux.agent_transfers;
    if transfers.calls.fetch_add(1, Ordering::AcqRel) >= MAX_CALLS {
        transfers.calls.fetch_sub(1, Ordering::AcqRel);
        return Some(reply(writer, id, Err(Refusal::Limit.into())));
    }
    // Checks that need no acpmux answer here, before a worker or a link.
    let prepared = match prepare(mux, verb) {
        Ok(prepared) => prepared,
        Err(failure) => {
            transfers.calls.fetch_sub(1, Ordering::AcqRel);
            return Some(reply(writer, id, Err(failure)));
        }
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    // The transfer waits on acpmux (`request_wait.rs`).
    let posted = mux.post_request_wait(move || {
        let result = run(&worker_mux, &socket, prepared);
        worker_mux.agent_transfers.calls.fetch_sub(1, Ordering::AcqRel);
        reply(&worker_writer, worker_id, result);
    });
    if posted.is_err() {
        transfers.calls.fetch_sub(1, Ordering::AcqRel);
        return Some(reply(writer, id, Err(Refusal::Limit.into())));
    }
    Some(true)
}

/// What the request thread decided: a verb ready to run, or a receive
/// whose folder the worker resolves on disk ([`guarded`]) before anything
/// reaches acpmux.
enum Unresolved {
    Ready(Prepared),
    Receive { manifest: Map<String, Value>, host: AgentTransferHost, cwd: String, moved: Moved },
}

/// A verb with everything the daemon decides filled in.
enum Prepared {
    Receive {
        manifest: Map<String, Value>,
        guard: Value,
        cwd: String,
        moved: Moved,
    },
    /// `_acpmux/transfer_forget` of a receive's move; `live` is the receive
    /// taken out for it (put back if the forget does not happen).
    Forget {
        receive_id: String,
        moved: Moved,
        live: Option<Receive>,
    },
    Write {
        receive_id: String,
        path: String,
        offset: u64,
        data: String,
    },
    Finish {
        receive_id: String,
        cwd: String,
        name: Option<String>,
    },
    Begin {
        session: String,
        interrupt: bool,
        ask_first: bool,
    },
    Read {
        transfer_id: String,
        path: String,
        offset: u64,
        limit: u64,
    },
    /// Answered by the daemon itself (a scrubbed page, a dropped receive).
    Answer(Value),
    Commit {
        session: String,
        transfer_id: String,
        to: Value,
    },
    Abort {
        session: String,
        transfer_id: String,
    },
}

fn prepare(mux: &Mux, verb: Verb) -> Result<Unresolved, Failure> {
    let transfers = &mux.agent_transfers;
    Ok(Unresolved::Ready(match verb {
        Verb::Receive(ReceiveParams { manifest, cwd, vm_kind }) => {
            let host = transfers.host().ok_or(Refusal::Unavailable)?;
            host_gate(mux, vm_word(&vm_kind))?;
            if !plain_cwd(&cwd) {
                return Err(Refusal::BadRequest.into());
            }
            // Before acpmux makes a receive, so a refused one leaves nothing
            // there (calls racing past this overshoot by at most MAX_CALLS).
            if AgentTransfers::full(&mut lock(&transfers.receives), MAX_RECEIVES, |r| r.touched) {
                return Err(Refusal::Limit.into());
            }
            let id = |key: &str| {
                manifest
                    .get(key)
                    .and_then(Value::as_str)
                    .filter(|id| is_plain_id(id))
                    .map(str::to_owned)
            };
            let (Some(transfer_id), Some(session_id)) = (id("transferId"), id("sessionId")) else {
                return Err(Refusal::BadRequest.into());
            };
            let moved = Moved { transfer_id, session_id };
            return Ok(Unresolved::Receive { manifest, host, cwd, moved });
        }
        Verb::Write(WriteParams { receive_id, path, offset, data }) => {
            if !is_bundle_path(&path) || page_data_len(&data).is_none_or(|n| n > MAX_PAGE_BYTES) {
                return Err(Refusal::BadRequest.into());
            }
            transfers.receive_cwd(&receive_id).ok_or(Refusal::UnknownReceive)?;
            Prepared::Write { receive_id, path, offset, data }
        }
        Verb::Finish(FinishParams { receive_id, name, vm_kind }) => {
            if name.as_deref().is_some_and(|name| !is_chat_name(name)) {
                return Err(Refusal::BadRequest.into());
            }
            let cwd = transfers.receive_cwd(&receive_id).ok_or(Refusal::UnknownReceive)?;
            if let Err(refusal) = host_gate(mux, vm_word(&vm_kind)) {
                // A team VM stays one: the receive can never finish here.
                if refusal == Refusal::TeamVmBlocked {
                    transfers.settle(&receive_id);
                }
                return Err(refusal.into());
            }
            Prepared::Finish { receive_id, cwd, name }
        }
        Verb::ReceiveAbort(ReceiveAbortParams { receive_id }) => {
            // Without this entry no write or finish reaches the receive; acpmux
            // drops its files and refuses the move from now on (its forget).
            match transfers.take_for_abort(&receive_id) {
                Some(prepared) => prepared,
                // Not held in memory (this daemon restarted, or its receive
                // was dropped): the recorded move of a receive acpmux
                // answered here, asked again (acpmux's forget is idempotent).
                None => {
                    let moved = mux.askable_receive(&receive_id).ok_or(Refusal::UnknownReceive)?;
                    Prepared::Forget { receive_id, moved, live: None }
                }
            }
        }
        Verb::Begin(BeginParams { surface, interrupt, ask_first }) => {
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            if AgentTransfers::full(&mut lock(&transfers.moves), MAX_MOVES, |m| m.touched) {
                return Err(Refusal::Limit.into());
            }
            Prepared::Begin { session, interrupt, ask_first }
        }
        Verb::Read(ReadParams { transfer_id, path, offset, limit }) => {
            let limit = limit.unwrap_or(DEFAULT_READ);
            if !is_bundle_path(&path) || !(1..=MAX_PAGE_BYTES as u64).contains(&limit) {
                return Err(Refusal::BadRequest.into());
            }
            match transfers.listed(&transfer_id, &path)? {
                Some(bytes) => Prepared::Answer(page_of(&bytes, offset, limit)),
                None => Prepared::Read { transfer_id, path, offset, limit },
            }
        }
        Verb::Commit(CommitParams { surface, transfer_id, to }) => {
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            if !is_plain_id(&transfer_id) || to.to_string().len() > MAX_TO_BYTES {
                return Err(Refusal::BadRequest.into());
            }
            Prepared::Commit { session, transfer_id, to }
        }
        Verb::Source(SourceParams { surface }) => {
            // The tab's own store record, read without reaching acpmux.
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            Prepared::Answer(json!({"session": session}))
        }
        Verb::Abort(AbortParams { surface, transfer_id }) => {
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            if !is_plain_id(&transfer_id) {
                return Err(Refusal::BadRequest.into());
            }
            Prepared::Abort { session, transfer_id }
        }
    }))
}

/// The tab's bound acpmux session, if `surface` is an agent tab of this
/// store with one (as `agent-session-attach` resolves it).
fn tab_session(mux: &Mux, surface: SurfaceId) -> Option<String> {
    let runtime = mux.surface(surface)?;
    match mux.conversation_tab_of(&runtime)? {
        ConversationTabRecord::AgentSession { session: Some(session), .. } => Some(session),
        _ => None,
    }
}

// MARK: Calls

/// A receive with its guard built: the folder resolved on disk, on the
/// worker (the request thread never touches the disk).
fn guarded(unresolved: Unresolved) -> Result<Prepared, Failure> {
    match unresolved {
        Unresolved::Ready(prepared) => Ok(prepared),
        Unresolved::Receive { manifest, host, cwd, moved } => {
            let (guard, cwd) = guard_for(&host, &cwd)?;
            Ok(Prepared::Receive { manifest, guard, cwd, moved })
        }
    }
}

fn run(mux: &Mux, socket: &Path, unresolved: Unresolved) -> Result<Value, Failure> {
    let prepared = guarded(unresolved)?;
    if let Prepared::Answer(answer) = prepared {
        return Ok(answer);
    }
    let link = match AcpmuxLink::connect(socket, |_| {}) {
        Ok(link) => link,
        Err(_) => {
            if let Prepared::Forget { receive_id, live, .. } = prepared {
                mux.agent_transfers.restore(receive_id, live);
            }
            return Err(Refusal::Unavailable.into());
        }
    };
    let call = |method: &str, params: Value, timeout: Duration| -> Result<Value, Failure> {
        Ok(link.call(method, params, timeout)?)
    };
    let transfers = &mux.agent_transfers;
    match prepared {
        Prepared::Receive { manifest, guard, cwd, moved } => {
            let params = json!({"manifest": manifest, "guard": guard});
            let answer = call("_acpmux/transfer_receive", params, CALL_TIMEOUT)?;
            let receive_id = answer.field("receiveId").as_str().filter(|id| is_plain_id(id));
            let (Some(receive_id), true) = (receive_id, *answer.field("guarded") == json!(true))
            else {
                return Err(Refusal::Unguarded.into());
            };
            // Before the pump learns the receive: it can always ask about it.
            mux.remember_askable_receive(receive_id, &moved);
            let entry = Receive { cwd, moved, touched: Instant::now(), finishing: false };
            lock(&transfers.receives).insert(receive_id.to_owned(), entry);
            Ok(json!({"receive_id": receive_id, "session_id": answer.field("sessionId")}))
        }
        Prepared::Write { receive_id, path, offset, data } => {
            let params = json!({"receiveId": receive_id, "path": path, "offset": offset,
                                "data": data});
            let answer = call("_acpmux/transfer_write", params, CALL_TIMEOUT)?;
            Ok(json!({"next": answer.field("next")}))
        }
        Prepared::Finish { receive_id, cwd, name } => {
            let mut params = json!({"receiveId": receive_id, "cwd": cwd});
            if let Some(name) = name {
                params.insert("name", json!(name));
            }
            // Only once acpmux is reached: a finish that never ran leaves
            // the receive askable.
            let finishing = Finishing::start(transfers, &receive_id);
            let finished = call("_acpmux/transfer_finish", params, FINISH_TIMEOUT);
            if ends_receive(&finished) {
                transfers.settle(&receive_id);
            }
            drop(finishing);
            let session = finished?;
            // acpmux's own answer, never a client's id: this machine's chat now.
            if let Some(landed) = session.field("sessionId").as_str() {
                mux.remember_landed_agent_session(landed);
            }
            Ok(json!({"session": session}))
        }
        Prepared::Begin { session, interrupt, ask_first } => {
            if ask_first {
                ask_first::narrow(&call, &session)?;
            }
            let source_session = session.clone();
            let params = json!({"sessionId": session, "interrupt": interrupt});
            let mut manifest = call("_acpmux/transfer_begin", params, BEGIN_TIMEOUT)?;
            let transfer_id = manifest
                .field("transferId")
                .as_str()
                .filter(|id| is_plain_id(id))
                .ok_or(Refusal::Refused)?
                .to_owned();
            let files = match scrub_bundle(&call, &transfer_id, &mut manifest) {
                Ok(files) => files,
                Err(failure) => {
                    // The chat must not stay frozen for a move nobody can read.
                    let params = json!({"sessionId": session, "transferId": transfer_id});
                    let _ = call("_acpmux/transfer_abort", params, CALL_TIMEOUT);
                    return Err(failure);
                }
            };
            let entry = Move { files, touched: Instant::now() };
            lock(&transfers.moves).insert(transfer_id.clone(), entry);
            // The chat is leaving this machine: no new tab of it may name it.
            mux.forget_landed_agent_session(&source_session);
            mux.control_clients.agent_sessions.known_children.forget(&source_session);
            Ok(json!({"transfer_id": transfer_id, "source_session": source_session,
                       "manifest": manifest}))
        }
        Prepared::Read { transfer_id, path, offset, limit } => {
            let params =
                json!({"transferId": transfer_id, "path": path, "offset": offset, "limit": limit});
            let page = call("_acpmux/transfer_read", params, CALL_TIMEOUT)?;
            Ok(
                json!({"data": page.field("data"), "next": page.field("next"), "eof": page.field("eof")}),
            )
        }
        Prepared::Answer(answer) => Ok(answer),
        Prepared::Forget { receive_id, moved: Moved { transfer_id, session_id }, live } => {
            let params = json!({"transferId": transfer_id, "sessionId": session_id});
            Ok(match call("_acpmux/transfer_forget", params, CALL_TIMEOUT) {
                Ok(answer) => {
                    json!({"dropped": true, "forgotten": true, "landed": answer.field("landed")})
                }
                Err(_) => {
                    // Not forgotten: the receive stays askable, the landing unknown.
                    transfers.restore(receive_id, live);
                    UNKNOWN_LANDING.clone()
                }
            })
        }
        Prepared::Commit { session, transfer_id, to } => {
            let params = json!({"sessionId": session, "transferId": transfer_id, "to": to});
            call("_acpmux/transfer_commit", params, CALL_TIMEOUT)?;
            lock(&transfers.moves).remove(&transfer_id);
            mux.forget_landed_agent_session(&session);
            mux.control_clients.agent_sessions.known_children.forget(&session);
            Ok(json!({"committed": true}))
        }
        Prepared::Abort { session, transfer_id } => {
            let params = json!({"sessionId": session, "transferId": transfer_id});
            let aborted = call("_acpmux/transfer_abort", params, CALL_TIMEOUT);
            // Forgotten either way: a move acpmux will not abort committed
            // or was never this chat's, and no read of it should go on.
            lock(&transfers.moves).remove(&transfer_id);
            aborted?;
            Ok(json!({"aborted": true}))
        }
    }
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Failure>) -> bool {
    let mut details = None;
    let (data, error, code) = match result {
        Ok(data) => (Some(data), None, None),
        Err(Failure::Refusal(refusal)) => {
            (None, Some(refusal.message().to_string()), Some(refusal.code()))
        }
        Err(Failure::Acpmux(message)) => (
            None,
            Some(format!("{}: {message}", Refusal::Refused.message())),
            Some(Refusal::Refused.code()),
        ),
        Err(Failure::Moving(message, transfer_id)) => {
            details = Some(json!({"transfer_id": transfer_id}));
            (
                None,
                Some(format!("{}: {message}", Refusal::Refused.message())),
                Some(Refusal::Refused.code()),
            )
        }
    };
    send_response_with_details(
        writer,
        Response {
            id,
            ok: data.is_some(),
            data,
            error,
            error_code: code.map(str::to_owned),
            error_delivery: None,
        },
        None,
        None,
        details,
    )
}

#[cfg(test)]
#[path = "agent_transfer_tests.rs"]
mod tests;
