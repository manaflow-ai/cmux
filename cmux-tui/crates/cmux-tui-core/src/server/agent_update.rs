//! Update Everything for agent CLIs (`agent-update-v1`, cx-1mbnu): a trusted
//! local client (the app, on this Mac or through the SSH or Cloud carrier)
//! updates THIS machine's agent CLIs through the machine's own acpmux, of
//! which this daemon is a local (unix socket) client, and moves the
//! machine's chats onto the new versions. No command travels: acpmux builds
//! every update from how the CLI was installed, and never runs one that needs
//! sudo.
//!
//! Verbs (JSON lines, framing of every v12 command):
//! - `agent-update-plan {}` answers `{harnesses: [{id, name?, version?,
//!   latest?}], live_threads, running_threads}`: acpmux's last health check
//!   (`_acpmux/harness/health`) rows that are outdated and whose update needs
//!   no elevated rights, and how many of its chats run an agent (`ready`,
//!   `running`, `waiting`) and how many are in a turn (`running`,
//!   `waiting`), from `_acpmux/sessions`, leaving out chats mirrored from a
//!   peer and the Home Chief's. With nothing on the acpmux socket it answers
//!   no harness and no thread: a plan never starts acpmux.
//! - `agent-update-apply {ids, continue_threads}` answers `{results: [{id,
//!   ok, version?, error?}], threads_restarted, threads_after_turn}`:
//!   acpmux's `_acpmux/harness/update {ids}` (each named harness that is
//!   still outdated, updated now and waited for), then with
//!   `continue_threads` its `_acpmux/sessions/restart_harness` for the
//!   harnesses that ended up current: their chats restart on the new
//!   version and resume the same conversation, a chat in a turn when the
//!   turn ends. When acpmux is not running it is started (as
//!   `agent-session-start` starts it). When the running acpmux is another
//!   build than this binary's, or does not know the update method, it is
//!   first handed off to this binary's build: stopped with its agents kept
//!   running (`acp daemon shutdown --keep-agents`), then started again, so
//!   the new acpmux adopts every agent. One apply at a time.
//!
//! Who: trusted local (Unix) connections only, as `agent-session-attach`.
//! The remote relay (`remote_relay/gate.rs`, the conversations-only
//! `cmux link` entry) runs before this handler and does not list these verbs
//! (default deny); a WebSocket client is refused here. Unknown params are a
//! bad request; `ids` are only names acpmux matches against its own rows.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use super::agent_session_attach::agent_session_start;
use super::responses::send_response;
use super::{MessageWriter, Response};
use crate::mux::Mux;

pub const AGENT_UPDATE_CAPABILITY: &str = "agent-update-v1";

/// Replaces this machine's acpmux with the binary's own build, keeping its
/// agents running for the new one to adopt (blocking).
pub type AcpmuxHandoff = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;

const PLAN: &str = "agent-update-plan";
const APPLY: &str = "agent-update-apply";
const MAX_IDS: usize = 64;
const MAX_ID_BYTES: usize = 128;
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// acpmux's first health check runs every harness's `--version` and sign-in
/// check.
const HEALTH_TIMEOUT: Duration = Duration::from_secs(60);
/// Each updater may run 15 minutes (acpmux `harness_health/auto.rs`).
const UPDATE_TIMEOUT: Duration = Duration::from_secs(30 * 60);
/// Every idle chat's harness spawns and loads its conversation again.
const RESTART_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// Programs that raise rights (acpmux `harness_health/auto.rs` ELEVATING).
const ELEVATING: [&str; 4] = ["sudo", "doas", "su", "pkexec"];
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// This binary's acpmux build and its handoff, and whether an apply runs.
#[derive(Default)]
pub(crate) struct AgentUpdates {
    handoff: Mutex<Option<(String, AcpmuxHandoff)>>,
    applying: AtomicBool,
}

/// Holds the one apply slot until dropped (also on a panic).
struct ApplySlot(Arc<Mux>);

impl Drop for ApplySlot {
    fn drop(&mut self) {
        self.0.agent_updates.applying.store(false, Ordering::Release);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanParams {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApplyParams {
    ids: Vec<String>,
    #[serde(default)]
    continue_threads: bool,
}

impl ApplyParams {
    fn valid(&self) -> bool {
        self.ids.len() <= MAX_IDS
            && self.ids.iter().all(|id| {
                (1..=MAX_ID_BYTES).contains(&id.len()) && !id.chars().any(char::is_control)
            })
    }
}

enum Verb {
    Plan,
    Apply(ApplyParams),
}

/// Refusal codes (`error_code`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Failure {
    NotTrusted,
    Unavailable,
    BadRequest,
    Busy,
    AcpmuxUnavailable,
    Timeout,
    Refused,
}

impl Failure {
    fn code(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_update.not_trusted",
            Self::Unavailable => "agent_update.unavailable",
            Self::BadRequest => "agent_update.bad_request",
            Self::Busy => "agent_update.busy",
            Self::AcpmuxUnavailable => "agent_update.acpmux_unavailable",
            Self::Timeout => "agent_update.timeout",
            Self::Refused => "agent_update.refused",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent updates need a trusted local connection",
            Self::Unavailable => "this daemon has no acpmux",
            Self::BadRequest => "bad request",
            Self::Busy => "an agent update is already running on this machine",
            Self::AcpmuxUnavailable => {
                "acpmux is not running on this machine and could not be started"
            }
            Self::Timeout => "acpmux did not answer in time",
            Self::Refused => "acpmux refused the request",
        }
    }

    fn of(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::AcpmuxUnavailable,
            LinkError::Timeout => Self::Timeout,
            LinkError::Busy => Self::Busy,
            LinkError::Rpc(..) => Self::Refused,
        }
    }
}

/// Handles an `agent-update-*` frame of a local connection; `None` for any
/// other frame. Remote-relay connections never get here.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"agent-update-") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let cmd = match object.remove("cmd") {
        Some(Value::String(cmd)) if cmd == PLAN || cmd == APPLY => cmd,
        _ => return None,
    };
    let id = object.remove("id");
    // Trust first: an untrusted client gets one answer whatever it sent.
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Failure::NotTrusted)));
    }
    let params = Value::Object(object);
    let verb = match cmd.as_str() {
        PLAN => serde_json::from_value::<PlanParams>(params).ok().map(|_| Verb::Plan),
        _ => serde_json::from_value::<ApplyParams>(params)
            .ok()
            .filter(ApplyParams::valid)
            .map(Verb::Apply),
    };
    let Some(verb) = verb else {
        return Some(reply(writer, id, Err(Failure::BadRequest)));
    };
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Failure::Unavailable)));
    };
    let slot = match verb {
        Verb::Plan => None,
        Verb::Apply(_) => {
            if mux.agent_updates.applying.swap(true, Ordering::AcqRel) {
                return Some(reply(writer, id, Err(Failure::Busy)));
            }
            Some(ApplySlot(mux.clone()))
        }
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-update".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = match verb {
                Verb::Plan => plan(&socket),
                Verb::Apply(params) => apply(&worker_mux, &socket, params),
            };
            drop(slot);
            reply(&worker_writer, worker_id, result);
        });
    // A failed spawn drops the closure and with it the slot.
    if spawned.is_err() {
        return Some(reply(writer, id, Err(Failure::Busy)));
    }
    Some(true)
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Failure>) -> bool {
    let response = match result {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(failure) => Response {
            id,
            ok: false,
            data: None,
            error: Some(failure.message().to_string()),
            error_code: Some(failure.code().to_string()),
            error_delivery: None,
        },
    };
    send_response(writer, response)
}

// MARK: Plan

fn plan(socket: &Path) -> Result<Value, Failure> {
    // Nothing listens: no acpmux, so nothing to update and no chat.
    let Ok(link) = AcpmuxLink::connect(socket, |_| {}) else {
        return Ok(json!({"harnesses": [], "live_threads": 0, "running_threads": 0}));
    };
    let health =
        link.call("_acpmux/harness/health", json!({}), HEALTH_TIMEOUT).map_err(Failure::of)?;
    let sessions = link.call("_acpmux/sessions", json!({}), CALL_TIMEOUT).map_err(Failure::of)?;
    // Display names are a nicety: a catalog that does not answer leaves them out.
    let catalog = link.call("_acpmux/harnesses", json!({}), CALL_TIMEOUT).unwrap_or_default();
    drop(link);
    let harnesses: Vec<Value> = health
        .get("harnesses")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|row| updatable(row))
        .filter_map(|row| {
            let id = row.get("id").and_then(Value::as_str)?;
            let mut out = json!({"id": id});
            let name = catalog.pointer(&format!("/harnesses/{}/displayName", pointer_key(id)));
            for (key, value) in
                [("name", name), ("version", row.get("version")), ("latest", row.get("latest"))]
            {
                if let Some(text) = value.and_then(Value::as_str) {
                    out[key] = json!(text);
                }
            }
            Some(out)
        })
        .collect();
    let (live, running) = threads(&sessions);
    Ok(json!({"harnesses": harnesses, "live_threads": live, "running_threads": running}))
}

/// acpmux's own rule (`harness_health::auto::updatable`) over a health row:
/// outdated, with an update plan that needs no elevated rights and whose
/// program does not raise them.
fn updatable(row: &Value) -> bool {
    let plan = &row["update"];
    let program = plan["argv"].get(0).and_then(Value::as_str).unwrap_or_default();
    let name = Path::new(program).file_name().and_then(|n| n.to_str()).unwrap_or(program);
    row["outdated"] == json!(true)
        && plan["elevated"] == json!(false)
        && !program.is_empty()
        && !ELEVATING.contains(&name)
}

/// `id` as one JSON pointer segment.
fn pointer_key(id: &str) -> String {
    id.replace('~', "~0").replace('/', "~1")
}

/// Chats with a running agent, and those in a turn, of a `_acpmux/sessions`
/// answer: none mirrored from a peer, none of the Home Chief's.
fn threads(sessions: &Value) -> (usize, usize) {
    let list = sessions.get("sessions").unwrap_or(sessions);
    let (mut live, mut running) = (0, 0);
    for summary in list.as_array().into_iter().flatten() {
        if summary.get("peer").is_some_and(|peer| !peer.is_null()) || is_chief(summary) {
            continue;
        }
        match summary["status"].as_str() {
            Some("ready") => live += 1,
            Some("running" | "waiting") => {
                live += 1;
                running += 1;
            }
            _ => {}
        }
    }
    (live, running)
}

/// A Home Chief session (acpmux `hub/route_switch.rs` is_chief, the app's
/// `AcpmuxSessionCensus.isChief`).
fn is_chief(summary: &Value) -> bool {
    let text = |key: &str| summary[key].as_str().unwrap_or_default();
    summary["tags"].get("cmux.chief").is_some()
        || text("name").starts_with("optchat-")
        || text("harness").starts_with("optchat-compact-")
}

// MARK: Apply

fn apply(mux: &Arc<Mux>, socket: &Path, params: ApplyParams) -> Result<Value, Failure> {
    let link = agent_session_start::connect(mux, socket).map_err(|_| Failure::AcpmuxUnavailable)?;
    let handoff = mux.agent_updates.handoff.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let (mut link, mut handed) = (link, false);
    if let Some((build, run)) = &handoff {
        let status = link.call("_acpmux/status", json!({}), CALL_TIMEOUT).map_err(Failure::of)?;
        if status.get("build").and_then(Value::as_str) != Some(build.as_str()) {
            link = hand_off(link, socket, run)?;
            handed = true;
        }
    }
    let ids = json!({"ids": params.ids});
    let mut answer = link.call("_acpmux/harness/update", ids.clone(), UPDATE_TIMEOUT);
    // An acpmux from before the update method (acpmux `RpcError::method_not_found`).
    let unknown = matches!(&answer, Err(LinkError::Rpc(message, _))
        if message.starts_with("Method not found"));
    if unknown
        && !handed
        && let Some((_, run)) = &handoff
    {
        link = hand_off(link, socket, run)?;
        answer = link.call("_acpmux/harness/update", ids, UPDATE_TIMEOUT);
    }
    let answer = answer.map_err(Failure::of)?;
    let results: Vec<Value> = answer
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| {
            let mut out = json!({"id": result.get("id")?.as_str()?, "ok": result["ok"] == true});
            for key in ["version", "error"] {
                if let Some(text) = result.get(key).and_then(Value::as_str) {
                    out[key] = json!(text);
                }
            }
            Some(out)
        })
        .collect();
    let current: Vec<&Value> =
        results.iter().filter(|result| result["ok"] == true).map(|result| &result["id"]).collect();
    let (mut restarted, mut after_turn) = (0, 0);
    if params.continue_threads && !current.is_empty() {
        let moved = link
            .call(
                "_acpmux/sessions/restart_harness",
                json!({"harnesses": current}),
                RESTART_TIMEOUT,
            )
            .map_err(Failure::of)?;
        restarted = moved["restarted"].as_u64().unwrap_or(0);
        after_turn = moved["after_turn"].as_u64().unwrap_or(0);
    }
    Ok(json!({
        "results": results,
        "threads_restarted": restarted,
        "threads_after_turn": after_turn,
    }))
}

/// Stops the running acpmux with its agents kept and starts this binary's
/// build, which adopts them; a link to the new one.
fn hand_off(
    link: Arc<AcpmuxLink>,
    socket: &Path,
    run: &AcpmuxHandoff,
) -> Result<Arc<AcpmuxLink>, Failure> {
    // Dropping the link closes it before the old acpmux stops.
    drop(link);
    run().map_err(|error| {
        eprintln!("cmux-tui: acpmux handoff for an agent update failed: {error}");
        Failure::AcpmuxUnavailable
    })?;
    AcpmuxLink::connect(socket, |_| {}).map_err(|_| Failure::AcpmuxUnavailable)
}

impl Mux {
    /// This binary's acpmux build (acpmux `BUILD`) and how it hands the
    /// machine's acpmux off to it (`cmux acp daemon shutdown --keep-agents`,
    /// then `cmux acp daemon start`). Without one an apply uses the acpmux
    /// that runs, whatever its build.
    pub fn set_acpmux_handoff(&self, handoff: Option<(String, AcpmuxHandoff)>) {
        *self.agent_updates.handoff.lock().unwrap_or_else(|e| e.into_inner()) = handoff;
    }

    /// True when the daemon serves `agent-update-v1`: as attach, an acpmux
    /// socket path.
    pub(crate) fn serves_agent_update(&self) -> bool {
        self.serves_agent_session_attach()
    }
}
