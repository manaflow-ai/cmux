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
//!
//! Source verbs (the chat leaves here), by tab, never by session id:
//! - `agent-transfer-begin {surface, interrupt?}` answers `{transfer_id,
//!   manifest}`. The bundle's `manifest.json` is served without its absolute
//!   `source` paths (the manifest's size for it is the stripped size).
//! - `agent-transfer-read {transfer_id, path, offset, limit?}` pages a bundle
//!   file of a move begun through this daemon.
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
    moves: Mutex<HashMap<String, Move>>,
    calls: AtomicUsize,
}

/// A guarded receive: what its finish uses.
struct Receive {
    cwd: String,
    touched: Instant,
}

/// A move out begun through this daemon.
struct Move {
    /// `manifest.json` without its `source` paths, when the bundle has one.
    manifest: Option<Arc<Vec<u8>>>,
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

    /// The move, when this daemon began it; `None` for any other id.
    fn moving(&self, transfer_id: &str) -> Option<Option<Arc<Vec<u8>>>> {
        let mut moves = lock(&self.moves);
        let entry = moves.get_mut(transfer_id)?;
        entry.touched = Instant::now();
        Some(entry.manifest.clone())
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
        }
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
    Receive { manifest: Map<String, Value>, guard: Value, cwd: String },
    Write { receive_id: String, path: String, offset: u64, data: String },
    Finish { receive_id: String, cwd: String, name: Option<String> },
    Begin { session: String, interrupt: bool },
    Read { transfer_id: String, path: String, offset: u64, limit: u64 },
    ReadStripped { manifest: Arc<Vec<u8>>, offset: u64, limit: u64 },
    Commit { session: String, transfer_id: String, to: Value },
    Abort { session: String, transfer_id: String },
}

fn prepare(mux: &Mux, verb: Verb) -> Result<Prepared, Failure> {
    let transfers = &mux.agent_transfers;
    Ok(match verb {
        Verb::Receive(ReceiveParams { manifest, cwd }) => {
            let host = transfers.host().ok_or(Refusal::Unavailable)?;
            let (guard, cwd) = guard_for(&host, &cwd)?;
            Prepared::Receive { manifest, guard, cwd }
        }
        Verb::Write(WriteParams { receive_id, path, offset, data }) => {
            if !is_bundle_path(&path) || !page_data_len(&data).is_some_and(|n| n <= MAX_PAGE_BYTES)
            {
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
            Prepared::Finish { receive_id, cwd, name }
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
            let stripped = transfers.moving(&transfer_id).ok_or(Refusal::UnknownTransfer)?;
            match stripped {
                Some(manifest) if path == MANIFEST => {
                    Prepared::ReadStripped { manifest, offset, limit }
                }
                _ => Prepared::Read { transfer_id, path, offset, limit },
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
    if let Prepared::ReadStripped { manifest, offset, limit } = &prepared {
        return Ok(page_of(manifest, *offset, *limit));
    }
    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| Refusal::Unavailable)?;
    let call = |method: &str, params: Value, timeout: Duration| -> Result<Value, Failure> {
        Ok(link.call(method, params, timeout)?)
    };
    let transfers = &mux.agent_transfers;
    match prepared {
        Prepared::Receive { manifest, guard, cwd } => {
            let params = json!({"manifest": manifest, "guard": guard});
            let answer = call("_acpmux/transfer_receive", params, CALL_TIMEOUT)?;
            let receive_id = answer["receiveId"].as_str().filter(|id| is_plain_id(id));
            let (Some(receive_id), true) = (receive_id, answer["guarded"] == json!(true)) else {
                return Err(Refusal::Unguarded.into());
            };
            let mut receives = lock(&transfers.receives);
            if AgentTransfers::full(&mut receives, MAX_RECEIVES, |r| r.touched) {
                return Err(Refusal::Limit.into());
            }
            receives.insert(receive_id.to_owned(), Receive { cwd, touched: Instant::now() });
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
            let session = call("_acpmux/transfer_finish", params, FINISH_TIMEOUT)?;
            lock(&transfers.receives).remove(&receive_id);
            Ok(json!({"session": session}))
        }
        Prepared::Begin { session, interrupt } => {
            let params = json!({"sessionId": session, "interrupt": interrupt});
            let mut manifest = call("_acpmux/transfer_begin", params, BEGIN_TIMEOUT)?;
            let transfer_id = manifest["transferId"]
                .as_str()
                .filter(|id| is_plain_id(id))
                .ok_or(Refusal::Refused)?
                .to_owned();
            let stripped = match strip_bundle_manifest(&call, &transfer_id, &mut manifest) {
                Ok(stripped) => stripped,
                Err(failure) => {
                    // The chat must not stay frozen for a move nobody can read.
                    let params = json!({"sessionId": session, "transferId": transfer_id});
                    let _ = call("_acpmux/transfer_abort", params, CALL_TIMEOUT);
                    return Err(failure);
                }
            };
            let entry = Move { manifest: stripped.map(Arc::new), touched: Instant::now() };
            lock(&transfers.moves).insert(transfer_id.clone(), entry);
            Ok(json!({"transfer_id": transfer_id, "manifest": manifest}))
        }
        Prepared::Read { transfer_id, path, offset, limit } => {
            let params =
                json!({"transferId": transfer_id, "path": path, "offset": offset, "limit": limit});
            let page = call("_acpmux/transfer_read", params, CALL_TIMEOUT)?;
            Ok(json!({"data": page["data"], "next": page["next"], "eof": page["eof"]}))
        }
        Prepared::ReadStripped { .. } => Err(Refusal::BadRequest.into()),
        Prepared::Commit { session, transfer_id, to } => {
            let params = json!({"sessionId": session, "transferId": transfer_id, "to": to});
            call("_acpmux/transfer_commit", params, CALL_TIMEOUT)?;
            lock(&transfers.moves).remove(&transfer_id);
            Ok(json!({"committed": true}))
        }
        Prepared::Abort { session, transfer_id } => {
            let params = json!({"sessionId": session, "transferId": transfer_id});
            call("_acpmux/transfer_abort", params, CALL_TIMEOUT)?;
            lock(&transfers.moves).remove(&transfer_id);
            Ok(json!({"aborted": true}))
        }
    }
}

/// Reads the bundle's `manifest.json` (acpmux `hub/transfer.rs` export),
/// drops every absolute `source` path of its native files (the target's
/// import does not use them), and sets the stripped size in `manifest`.
/// `None` when the bundle has no `manifest.json`.
fn strip_bundle_manifest(
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    transfer_id: &str,
    manifest: &mut Value,
) -> Result<Option<Vec<u8>>, Failure> {
    let files = manifest["files"].as_array_mut().ok_or(Refusal::Refused)?;
    let Some(entry) = files.iter_mut().find(|file| file["path"] == json!(MANIFEST)) else {
        return Ok(None);
    };
    let size = entry["size"].as_u64().filter(|size| *size <= MAX_PAGE_BYTES as u64);
    let size = size.ok_or(Refusal::Refused)?;
    let params =
        json!({"transferId": transfer_id, "path": MANIFEST, "offset": 0, "limit": size.max(1)});
    let page = call("_acpmux/transfer_read", params, CALL_TIMEOUT)?;
    let bytes = page["data"]
        .as_str()
        .and_then(|data| BASE64.decode(data).ok())
        .filter(|bytes| bytes.len() as u64 == size)
        .ok_or(Refusal::Refused)?;
    let mut bundle: Value = serde_json::from_slice(&bytes).map_err(|_| Refusal::Refused)?;
    if let Some(native) = bundle.get_mut("native").and_then(Value::as_array_mut) {
        for file in native.iter_mut().filter_map(Value::as_object_mut) {
            file.remove("source");
        }
    }
    let stripped = serde_json::to_vec_pretty(&bundle).map_err(|_| Refusal::Refused)?;
    entry["size"] = json!(stripped.len());
    Ok(Some(stripped))
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
