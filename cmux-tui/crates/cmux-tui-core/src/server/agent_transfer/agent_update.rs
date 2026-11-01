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
//!   ok, version?, error?}], threads_restarted, threads_after_turn,
//!   threads_failed, threads_error?}`:
//!   acpmux's `_acpmux/harness/update {ids}` (each named harness that is
//!   still outdated, updated now and waited for), then with
//!   `continue_threads` its `_acpmux/sessions/restart_harness` for the
//!   harnesses that ended up current: their chats restart on the new
//!   version and resume the same conversation, a chat in a turn when the
//!   turn ends; a chat acpmux could not restart counts in `threads_failed`
//!   (the first one's reason in `threads_error`); when that restart call
//!   fails the updates still answer, with `threads_error` and no thread
//!   counted. When acpmux is not running it is
//!   started (as `agent-session-start` starts it). Only when the running
//!   acpmux does not know the update method (an acpmux from before it) is it
//!   handed off to the installed binary's build: stopped with its agents kept
//!   running (`acp daemon shutdown --keep-agents`), then started again under
//!   the start lock, so the new acpmux adopts every agent; one that still
//!   does not know the method is `agent_update.acpmux_unavailable`. Another
//!   build that knows the method is used as it runs, so an apply never moves
//!   acpmux to an older build. One apply at a time.
//!
//! Who: trusted local (Unix) connections only, as `agent-session-attach`.
//! The remote relay (`remote_relay/gate.rs`, the conversations-only
//! `cmux link` entry) runs before this handler and does not list these verbs
//! (default deny); a WebSocket client is refused here. Unknown params are a
//! bad request; `ids` are only names acpmux matches against its own rows.

use crate::panic_free::JsonFields;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::mux::Mux;
use crate::server::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use crate::server::agent_session_attach::agent_session_start;
use crate::server::responses::send_response;
use crate::server::{MessageWriter, Response};

pub const AGENT_UPDATE_CAPABILITY: &str = "agent-update-v1";
pub const AGENT_UPDATE_OWNER_CAPABILITY: &str = "agent-update-owner-v1";

/// Replaces this machine's acpmux with the installed binary's build, keeping
/// its agents running for the new one to adopt (blocking).
pub type AcpmuxHandoff = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;

const PLAN: &str = "agent-update-plan";
const APPLY: &str = "agent-update-apply";
const MAX_IDS: usize = 64;
const MAX_ID_BYTES: usize = 128;
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// acpmux's first health check runs every harness's `--version` and sign-in
/// check.
const HEALTH_TIMEOUT: Duration = Duration::from_secs(60);
/// Each updater may run 15 minutes (acpmux `harness_health/auto.rs`), one
/// after another; a margin for acpmux's own checks around them, and a cap.
const UPDATE_PER_ID: Duration = Duration::from_secs(15 * 60);
const UPDATE_MARGIN: Duration = Duration::from_secs(5 * 60);
const UPDATE_CAP: Duration = Duration::from_secs(2 * 60 * 60);
/// Every idle chat's harness spawns and loads its conversation again.
const RESTART_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// Programs that raise rights (acpmux `harness_health/auto.rs` ELEVATING).
const ELEVATING: [&str; 4] = ["sudo", "doas", "su", "pkexec"];
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// The binary's acpmux handoff, and whether an apply runs.
#[derive(Default)]
pub(crate) struct AgentUpdates {
    handoff: Mutex<Option<AcpmuxHandoff>>,
    applying: AtomicBool,
}

/// Holds the one apply slot until dropped (also on a panic).
struct ApplySlot(Arc<Mux>);

impl Drop for ApplySlot {
    fn drop(&mut self) {
        self.0.agent_transfers.updates.applying.store(false, Ordering::Release);
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
    OwnerMismatch,
    Unavailable,
    BadRequest,
    Busy,
    AcpmuxUnavailable,
    Timeout,
    Refused,
    BadList,
}

impl Failure {
    fn code(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_update.not_trusted",
            Self::OwnerMismatch => "agent_update.owner_mismatch",
            Self::Unavailable => "agent_update.unavailable",
            Self::BadRequest => "agent_update.bad_request",
            Self::Busy => "agent_update.busy",
            Self::AcpmuxUnavailable => "agent_update.acpmux_unavailable",
            Self::Timeout => "agent_update.timeout",
            Self::Refused => "agent_update.refused",
            Self::BadList => "agent_update.bad_list",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent updates need a trusted local connection",
            Self::OwnerMismatch => self.code(),
            Self::Unavailable => "this daemon has no acpmux",
            Self::BadRequest => "bad request",
            Self::Busy => "an agent update is already running on this machine",
            Self::AcpmuxUnavailable => {
                "acpmux is not running on this machine and could not be started"
            }
            Self::Timeout => "acpmux did not answer in time",
            Self::Refused => "acpmux refused the request",
            Self::BadList => "acpmux's session list could not be read whole",
        }
    }

    fn of(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::AcpmuxUnavailable,
            LinkError::Timeout => Self::Timeout,
            LinkError::Busy => Self::Busy,
            LinkError::Rpc(..) | LinkError::MethodNotFound(_) => Self::Refused,
            LinkError::BadList(_) => Self::BadList,
        }
    }
}

/// Handles an `agent-update-*` frame of a local connection; `None` for any
/// other frame. Remote-relay connections never get here.
pub(in crate::server) fn try_handle(
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
    let expected_machine = object.remove("expected_machine_id");
    let expects_owner = expected_machine.is_some();
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
    // A condition on this exact daemon, never a selector. Check it before
    // consulting its socket, starting acpmux, or reserving the apply slot.
    if let Some(expected) = expected_machine {
        let Value::String(expected) = expected else {
            return Some(reply(writer, id, Err(Failure::BadRequest)));
        };
        let Ok(expected) = crate::resource::MachinePublicId::parse(expected) else {
            return Some(reply(writer, id, Err(Failure::BadRequest)));
        };
        if expected != mux.machine_public_id {
            return Some(reply(writer, id, Err(Failure::OwnerMismatch)));
        }
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Failure::Unavailable)));
    };
    let slot = match verb {
        Verb::Plan => None,
        Verb::Apply(_) => {
            if mux.agent_transfers.updates.applying.swap(true, Ordering::AcqRel) {
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
            }
            .map(|mut value| {
                if expects_owner {
                    value.insert("machine", json!(worker_mux.machine_public_id));
                }
                value
            });
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
    let sessions =
        link.call_whole_list("_acpmux/sessions", json!({}), CALL_TIMEOUT).map_err(Failure::of)?;
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
                    out.insert(key, json!(text));
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
    let plan = &row.field("update");
    let program = plan.field("argv").get(0).and_then(Value::as_str).unwrap_or_default();
    let name = Path::new(program).file_name().and_then(|n| n.to_str()).unwrap_or(program);
    *row.field("outdated") == json!(true)
        && *plan.field("elevated") == json!(false)
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
        match summary.field("status").as_str() {
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
    summary.field("tags").get("cmux.chief").is_some()
        || text("name").starts_with("optchat-")
        || text("harness").starts_with("optchat-compact-")
}

// MARK: Apply

fn apply(mux: &Arc<Mux>, socket: &Path, params: ApplyParams) -> Result<Value, Failure> {
    let mut link =
        agent_session_start::connect(mux, socket).map_err(|_| Failure::AcpmuxUnavailable)?;
    let timeout = update_timeout(params.ids.len());
    let ids = json!({"ids": params.ids});
    let mut answer = link.call("_acpmux/harness/update", ids.clone(), timeout);
    // Only an acpmux from before the update method is handed off: one of
    // another build that knows it is used as it runs (never a downgrade).
    if matches!(answer, Err(LinkError::MethodNotFound(_))) {
        let handoff =
            mux.agent_transfers.updates.handoff.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let run = handoff.ok_or(Failure::AcpmuxUnavailable)?;
        // The link closes before the old acpmux stops.
        link.close();
        link = agent_session_start::restart_with(mux, socket, &*run)
            .ok_or(Failure::AcpmuxUnavailable)?;
        answer = link.call("_acpmux/harness/update", ids, timeout);
        // The restarted acpmux must know the method.
        if matches!(answer, Err(LinkError::MethodNotFound(_))) {
            return Err(Failure::AcpmuxUnavailable);
        }
    }
    let answer = answer.map_err(Failure::of)?;
    let results: Vec<Value> = answer
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| {
            let mut out =
                json!({"id": result.get("id")?.as_str()?, "ok": *result.field("ok") == true});
            for key in ["version", "error"] {
                if let Some(text) = result.get(key).and_then(Value::as_str) {
                    out.insert(key, json!(text));
                }
            }
            Some(out)
        })
        .collect();
    let current: Vec<&Value> = results
        .iter()
        .filter(|result| *result.field("ok") == true)
        .map(|result| result.field("id"))
        .collect();
    let mut out = json!({"results": results, "threads_restarted": 0, "threads_after_turn": 0,
                         "threads_failed": 0});
    if params.continue_threads && !current.is_empty() {
        // The updates happened: a restart that fails is reported beside them.
        match link.call(
            "_acpmux/sessions/restart_harness",
            json!({"harnesses": current}),
            RESTART_TIMEOUT,
        ) {
            Ok(moved) => {
                out.insert(
                    "threads_restarted",
                    json!(moved.field("restarted").as_u64().unwrap_or(0)),
                );
                out.insert(
                    "threads_after_turn",
                    json!(moved.field("after_turn").as_u64().unwrap_or(0)),
                );
                // A chat acpmux could not restart keeps its old agent: counted, with why.
                let failed = moved.field("failed").as_u64().unwrap_or(0);
                out.insert("threads_failed", json!(failed));
                if failed > 0 {
                    let why = moved
                        .field("errors")
                        .get(0)
                        .and_then(|error| error.get("error"))
                        .and_then(Value::as_str)
                        .unwrap_or("a chat did not restart");
                    out.insert("threads_error", json!(why));
                }
            }
            Err(error) => out.insert("threads_error", json!(Failure::of(error).message())),
        }
    }
    Ok(out)
}

/// The update call's bound for `ids` updaters run one after another.
fn update_timeout(ids: usize) -> Duration {
    let count = u32::try_from(ids.max(1)).unwrap_or(u32::MAX);
    UPDATE_PER_ID.saturating_mul(count).saturating_add(UPDATE_MARGIN).min(UPDATE_CAP)
}

impl Mux {
    pub(crate) fn acpmux_handoff(&self) -> Option<AcpmuxHandoff> {
        self.agent_transfers.updates.handoff.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// How the machine's acpmux is handed off to the installed binary's
    /// build (`cmux acp daemon shutdown --keep-agents`, then `cmux acp daemon
    /// start`) when it does not know the update method. Without one such an
    /// acpmux is `agent_update.acpmux_unavailable`.
    pub fn set_acpmux_handoff(&self, handoff: Option<AcpmuxHandoff>) {
        *self.agent_transfers.updates.handoff.lock().unwrap_or_else(|e| e.into_inner()) = handoff;
    }

    /// True when the daemon serves `agent-update-v1`: as attach, an acpmux
    /// socket path.
    pub(crate) fn serves_agent_update(&self) -> bool {
        self.serves_agent_session_attach()
    }
}

#[cfg(all(test, unix))]
#[path = "agent_update_owner_tests.rs"]
mod owner_tests;
