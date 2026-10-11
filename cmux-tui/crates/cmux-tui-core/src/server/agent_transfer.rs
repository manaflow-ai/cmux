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
//!   receive's own folder (`cwd` is never taken here).
//! - `agent-transfer-receive-abort {receive_id}`: forgets the receive and has
//!   acpmux forget its move (`_acpmux/transfer_forget` with the transfer and
//!   session ids of the receive's own manifest): acpmux drops the receive's
//!   files and refuses that move from then on. A receive its finish ended
//!   (settled) can still be asked, so a pump that lost the finish answer
//!   learns whether the chat landed (`landed`) before it commits or aborts
//!   the source.
//!
//! Machine kind: receive and finish read `agent-session-start`'s host gate
//! at each call and refuse on a team VM and on a Cloud VM of unknown kind
//! (hq-84). A peer-control chat keeps its policy and mode and runs its queue
//! at once, so it may only land on a Mac or a personal Cloud VM.
//!
//! Source verbs (the chat leaves here), by tab, never by session id:
//! - `agent-transfer-begin {surface, interrupt?}` answers `{transfer_id,
//!   manifest}`. The bundle's `manifest.json` is served without its absolute
//!   `source` paths, and its `session.json` without the source machine's
//!   launch settings (env, argv, harness roots, preset, tags; its `cwd`
//!   stays, the target's finish replaces it); the manifest lists their
//!   scrubbed sizes.
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

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use super::remote_relay::gate::COMMAND_PARAMS;
use super::{MessageWriter, Response, SurfaceId, send_response};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;

pub const AGENT_TRANSFER_CAPABILITY: &str = "agent-transfer-v1";

/// The largest page of bundle data a write takes or a read answers.
pub(crate) const MAX_PAGE_BYTES: usize = 4 << 20;
const DEFAULT_READ: u64 = 1 << 20;
const MAX_RECEIVES: usize = 16;
/// Settled receives kept for a pump's question (the oldest goes first).
const MAX_SETTLED: usize = 16;
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
const THREAD_STACK_BYTES: usize = 256 * 1024;
const MANIFEST: &str = "manifest.json";
const SESSION: &str = "session.json";
/// `session.json` keys (acpmux `SessionMeta`, camelCase and old aliases)
/// that carry the source machine's launch settings.
const SESSION_LAUNCH_KEYS: &[&str] = &[
    "sessionEnv",
    "session_env",
    "harnessArgv",
    "harness_argv",
    "agent_argv",
    "harnessRoots",
    "harness_roots",
    "preset",
    "tags",
];

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
    calls: AtomicUsize,
}

/// A guarded receive: what its finish uses.
struct Receive {
    cwd: String,
    /// The move and chat its manifest names (what a forget drops).
    moved: Moved,
    touched: Instant,
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
        settled.insert(receive_id.to_owned(), Settled { moved: receive.moved, touched: Instant::now() });
    }

    /// The move a receive-abort forgets: a live receive's (dropped here) or
    /// a settled one's (kept, so the question can be asked again).
    fn take_for_abort(&self, receive_id: &str) -> Option<Moved> {
        if let Some(receive) = lock(&self.receives).remove(receive_id) {
            return Some(receive.moved);
        }
        let mut settled = lock(&self.settled);
        let entry = settled.get_mut(receive_id).filter(|e| e.touched.elapsed() < STALE)?;
        entry.touched = Instant::now();
        Some(entry.moved.clone())
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
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceiveAbortParams {
    receive_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BeginParams {
    surface: SurfaceId,
    #[serde(default)]
    interrupt: bool,
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

enum Verb {
    Receive(ReceiveParams),
    Write(WriteParams),
    Finish(FinishParams),
    ReceiveAbort(ReceiveAbortParams),
    Begin(BeginParams),
    Read(ReadParams),
    Commit(CommitParams),
    Abort(AbortParams),
}

impl Verb {
    fn parse(cmd: &str, params: Map<String, Value>) -> Option<Self> {
        if params.keys().any(|key| {
            FORBIDDEN_PARAMS.contains(&key.as_str()) || COMMAND_PARAMS.contains(&key.as_str())
        }) {
            return None;
        }
        let params = Value::Object(params);
        use serde_json::from_value;
        Some(match cmd {
            "agent-transfer-receive" => Self::Receive(from_value(params).ok()?),
            "agent-transfer-write" => Self::Write(from_value(params).ok()?),
            "agent-transfer-finish" => Self::Finish(from_value(params).ok()?),
            "agent-transfer-receive-abort" => Self::ReceiveAbort(from_value(params).ok()?),
            "agent-transfer-begin" => Self::Begin(from_value(params).ok()?),
            "agent-transfer-read" => Self::Read(from_value(params).ok()?),
            "agent-transfer-commit" => Self::Commit(from_value(params).ok()?),
            "agent-transfer-abort" => Self::Abort(from_value(params).ok()?),
            _ => return None,
        })
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

/// `agent-session-start`'s machine kind gate, read again at each call.
fn host_gate(mux: &Mux) -> Result<(), Refusal> {
    use super::agent_session_attach::Refusal as Start;
    match mux.agent_host_gate() {
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
    }
}

/// A refusal, or acpmux's own error (its message reaches the trusted client,
/// so the pump can tell an incomplete bundle from an existing chat).
enum Failure {
    Refusal(Refusal),
    Acpmux(String),
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
            LinkError::Rpc(message) => Self::Acpmux(message),
        }
    }
}

/// Handles an `agent-transfer-*` frame of a local connection; `None` for any
/// other frame. Remote-relay connections never get here.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"agent-transfer-") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let cmd = match object.remove("cmd") {
        Some(Value::String(cmd)) if cmd.starts_with("agent-transfer-") => cmd,
        _ => return None,
    };
    let id = object.remove("id");
    // Trust first: an untrusted client gets one answer whatever it sent.
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Refusal::NotTrusted.into())));
    }
    let Some(verb) = Verb::parse(&cmd, object) else {
        return Some(reply(writer, id, Err(Refusal::BadRequest.into())));
    };
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Refusal::Unavailable.into())));
    };
    // Checks that need no acpmux answer here, before a worker or a link.
    let prepared = match prepare(mux, verb) {
        Ok(prepared) => prepared,
        Err(failure) => return Some(reply(writer, id, Err(failure))),
    };
    let transfers = &mux.agent_transfers;
    if transfers.calls.fetch_add(1, Ordering::AcqRel) >= MAX_CALLS {
        transfers.calls.fetch_sub(1, Ordering::AcqRel);
        return Some(reply(writer, id, Err(Refusal::Limit.into())));
    }
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-transfer".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = run(&worker_mux, &socket, prepared);
            worker_mux.agent_transfers.calls.fetch_sub(1, Ordering::AcqRel);
            reply(&worker_writer, worker_id, result);
        });
    if spawned.is_err() {
        transfers.calls.fetch_sub(1, Ordering::AcqRel);
        return Some(reply(writer, id, Err(Refusal::Limit.into())));
    }
    Some(true)
}

/// A verb with everything the daemon decides filled in.
enum Prepared {
    Receive {
        manifest: Map<String, Value>,
        guard: Value,
        cwd: String,
        moved: Moved,
    },
    /// `_acpmux/transfer_forget` of a dropped receive's move.
    Forget(Moved),
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

fn prepare(mux: &Mux, verb: Verb) -> Result<Prepared, Failure> {
    let transfers = &mux.agent_transfers;
    Ok(match verb {
        Verb::Receive(ReceiveParams { manifest, cwd }) => {
            let host = transfers.host().ok_or(Refusal::Unavailable)?;
            host_gate(mux)?;
            let (guard, cwd) = guard_for(&host, &cwd)?;
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
            Prepared::Receive { manifest, guard, cwd, moved }
        }
        Verb::Write(WriteParams { receive_id, path, offset, data }) => {
            if !is_bundle_path(&path) || page_data_len(&data).is_none_or(|n| n > MAX_PAGE_BYTES) {
                return Err(Refusal::BadRequest.into());
            }
            transfers.receive_cwd(&receive_id).ok_or(Refusal::UnknownReceive)?;
            Prepared::Write { receive_id, path, offset, data }
        }
        Verb::Finish(FinishParams { receive_id, name }) => {
            if name.as_deref().is_some_and(|name| !is_chat_name(name)) {
                return Err(Refusal::BadRequest.into());
            }
            let cwd = transfers.receive_cwd(&receive_id).ok_or(Refusal::UnknownReceive)?;
            if let Err(refusal) = host_gate(mux) {
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
            Prepared::Forget(transfers.take_for_abort(&receive_id).ok_or(Refusal::UnknownReceive)?)
        }
        Verb::Begin(BeginParams { surface, interrupt }) => {
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            if AgentTransfers::full(&mut lock(&transfers.moves), MAX_MOVES, |m| m.touched) {
                return Err(Refusal::Limit.into());
            }
            Prepared::Begin { session, interrupt }
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
        Verb::Abort(AbortParams { surface, transfer_id }) => {
            let session = tab_session(mux, surface).ok_or(Refusal::UnknownTab)?;
            if !is_plain_id(&transfer_id) {
                return Err(Refusal::BadRequest.into());
            }
            Prepared::Abort { session, transfer_id }
        }
    })
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

// MARK: The guard

/// The receive guard and the canonical folder for `cwd` on `host`.
fn guard_for(host: &AgentTransferHost, cwd: &str) -> Result<(Value, String), Failure> {
    let path = Path::new(cwd);
    if cwd.is_empty() || cwd.len() > MAX_PATH_BYTES || !path.is_absolute() {
        return Err(Refusal::BadRequest.into());
    }
    let home = std::fs::canonicalize(&host.home).map_err(|_| Refusal::Unavailable)?;
    let folder = std::fs::canonicalize(path)
        .ok()
        .filter(|folder| folder.is_dir())
        .ok_or(Refusal::OutsideRoots)?;
    let (control, root) = if host.cloud {
        let root = std::fs::canonicalize(home.join("work"))
            .ok()
            .filter(|root| root.is_dir())
            .ok_or(Refusal::OutsideRoots)?;
        ("peer", root)
    } else {
        // Strictly under home, and not in a dot folder of home.
        let rel = folder.strip_prefix(&home).map_err(|_| Refusal::OutsideRoots)?;
        let first = rel.components().next();
        let plain = matches!(first, Some(Component::Normal(name))
            if !name.to_string_lossy().starts_with('.'));
        if !plain {
            return Err(Refusal::OutsideRoots.into());
        }
        ("web", folder.clone())
    };
    if !folder.starts_with(&root) {
        return Err(Refusal::OutsideRoots.into());
    }
    let text = |path: &Path| path.to_str().map(str::to_owned).ok_or(Refusal::BadRequest);
    let guard = json!({"control": control, "roots": [text(&root)?]});
    Ok((guard, text(&folder)?))
}

/// A bundle file path: relative plain components only.
fn is_bundle_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= MAX_PATH_BYTES
        && Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
}

/// The bytes padded base64 `data` decodes to (acpmux checks the alphabet).
fn page_data_len(data: &str) -> Option<usize> {
    if !data.len().is_multiple_of(4) {
        return None;
    }
    let padding = data.bytes().rev().take(2).filter(|b| *b == b'=').count();
    Some(data.len() / 4 * 3 - padding)
}

/// An acpmux receive or transfer id (a UUID): 1 to 128 of `[A-Za-z0-9_-]`.
fn is_plain_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A chat name for finish: 1 to 128 bytes, no control characters (acpmux
/// checks the rest).
fn is_chat_name(name: &str) -> bool {
    (1..=128).contains(&name.len()) && !name.chars().any(char::is_control)
}

// MARK: Calls

fn run(mux: &Mux, socket: &Path, prepared: Prepared) -> Result<Value, Failure> {
    if let Prepared::Answer(answer) = prepared {
        return Ok(answer);
    }
    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| Refusal::Unavailable)?;
    let call = |method: &str, params: Value, timeout: Duration| -> Result<Value, Failure> {
        Ok(link.call(method, params, timeout)?)
    };
    let transfers = &mux.agent_transfers;
    match prepared {
        Prepared::Receive { manifest, guard, cwd, moved } => {
            let params = json!({"manifest": manifest, "guard": guard});
            let answer = call("_acpmux/transfer_receive", params, CALL_TIMEOUT)?;
            let receive_id = answer["receiveId"].as_str().filter(|id| is_plain_id(id));
            let (Some(receive_id), true) = (receive_id, answer["guarded"] == json!(true)) else {
                return Err(Refusal::Unguarded.into());
            };
            let entry = Receive { cwd, moved, touched: Instant::now() };
            lock(&transfers.receives).insert(receive_id.to_owned(), entry);
            Ok(json!({"receive_id": receive_id, "session_id": answer["sessionId"]}))
        }
        Prepared::Write { receive_id, path, offset, data } => {
            let params = json!({"receiveId": receive_id, "path": path, "offset": offset,
                                "data": data});
            let answer = call("_acpmux/transfer_write", params, CALL_TIMEOUT)?;
            Ok(json!({"next": answer["next"]}))
        }
        Prepared::Finish { receive_id, cwd, name } => {
            let mut params = json!({"receiveId": receive_id, "cwd": cwd});
            if let Some(name) = name {
                params["name"] = json!(name);
            }
            let finished = call("_acpmux/transfer_finish", params, FINISH_TIMEOUT);
            if ends_receive(&finished) {
                transfers.settle(&receive_id);
            }
            Ok(json!({"session": finished?}))
        }
        Prepared::Begin { session, interrupt } => {
            let params = json!({"sessionId": session, "interrupt": interrupt});
            let mut manifest = call("_acpmux/transfer_begin", params, BEGIN_TIMEOUT)?;
            let transfer_id = manifest["transferId"]
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
            Ok(json!({"transfer_id": transfer_id, "manifest": manifest}))
        }
        Prepared::Read { transfer_id, path, offset, limit } => {
            let params =
                json!({"transferId": transfer_id, "path": path, "offset": offset, "limit": limit});
            let page = call("_acpmux/transfer_read", params, CALL_TIMEOUT)?;
            Ok(json!({"data": page["data"], "next": page["next"], "eof": page["eof"]}))
        }
        Prepared::Answer(answer) => Ok(answer),
        Prepared::Forget(Moved { transfer_id, session_id }) => {
            let params = json!({"transferId": transfer_id, "sessionId": session_id});
            // Dropped here either way; an acpmux without forget sweeps the
            // receive's files after 24 h.
            Ok(match call("_acpmux/transfer_forget", params, CALL_TIMEOUT) {
                Ok(answer) => {
                    json!({"dropped": true, "forgotten": true, "landed": answer["landed"]})
                }
                Err(_) => json!({"dropped": true, "forgotten": false, "landed": null}),
            })
        }
        Prepared::Commit { session, transfer_id, to } => {
            let params = json!({"sessionId": session, "transferId": transfer_id, "to": to});
            call("_acpmux/transfer_commit", params, CALL_TIMEOUT)?;
            lock(&transfers.moves).remove(&transfer_id);
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

/// Every path the begin `manifest` lists, with scrubbed copies of the
/// bundle's `manifest.json` (no absolute `source` paths of native files) and
/// `session.json` (no launch settings: [`SESSION_LAUNCH_KEYS`]; its `cwd`
/// stays, as the target's import needs a folder and its finish replaces
/// it). Names compare case-insensitively (a case-insensitive disk serves
/// `Session.json` for `session.json`), and the manifest lists the scrubbed
/// sizes. The import uses neither removed part.
fn scrub_bundle(
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    transfer_id: &str,
    manifest: &mut Value,
) -> Result<BundleFiles, Failure> {
    let entries = manifest["files"].as_array_mut().ok_or(Refusal::Refused)?;
    let mut files = HashMap::new();
    for entry in entries.iter_mut() {
        let path = entry["path"].as_str().filter(|path| is_bundle_path(path));
        let path = path.ok_or(Refusal::Refused)?.to_owned();
        let scrubbed = if path.eq_ignore_ascii_case(MANIFEST) || path.eq_ignore_ascii_case(SESSION)
        {
            let bytes = scrubbed_file(call, transfer_id, &path, entry["size"].as_u64())?;
            entry["size"] = json!(bytes.len());
            Some(Arc::new(bytes))
        } else {
            None
        };
        files.insert(path, scrubbed);
    }
    Ok(files)
}

/// One bundle JSON file read whole from acpmux and scrubbed.
fn scrubbed_file(
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    transfer_id: &str,
    path: &str,
    size: Option<u64>,
) -> Result<Vec<u8>, Failure> {
    let size = size.filter(|size| *size <= MAX_PAGE_BYTES as u64).ok_or(Refusal::Refused)?;
    let params =
        json!({"transferId": transfer_id, "path": path, "offset": 0, "limit": size.max(1)});
    let page = call("_acpmux/transfer_read", params, CALL_TIMEOUT)?;
    let bytes = page["data"]
        .as_str()
        .and_then(|data| BASE64.decode(data).ok())
        .filter(|bytes| bytes.len() as u64 == size)
        .ok_or(Refusal::Refused)?;
    let mut value: Value = serde_json::from_slice(&bytes).map_err(|_| Refusal::Refused)?;
    if path.eq_ignore_ascii_case(MANIFEST) {
        if let Some(native) = value.get_mut("native").and_then(Value::as_array_mut) {
            for file in native.iter_mut().filter_map(Value::as_object_mut) {
                file.remove("source");
            }
        }
    } else if let Some(meta) = value.as_object_mut() {
        for key in SESSION_LAUNCH_KEYS {
            meta.remove(*key);
        }
    } else {
        return Err(Refusal::Refused.into());
    }
    Ok(serde_json::to_vec_pretty(&value).map_err(|_| Refusal::Refused)?)
}

/// A `transfer_read` page of `bytes`, as acpmux answers one.
fn page_of(bytes: &[u8], offset: u64, limit: u64) -> Value {
    let len = bytes.len() as u64;
    let start = offset.min(len);
    let end = start.saturating_add(limit).min(len);
    let data = BASE64.encode(&bytes[start as usize..end as usize]);
    json!({"data": data, "next": end, "eof": end == len})
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Failure>) -> bool {
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
    };
    send_response(
        writer,
        Response {
            id,
            ok: data.is_some(),
            data,
            error,
            error_code: code.map(str::to_owned),
            error_delivery: None,
        },
    )
}

#[cfg(test)]
#[path = "agent_transfer_tests.rs"]
mod tests;
