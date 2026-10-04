//! The agent-session port (plans/cmux-next/chief-mac.md section 2,
//! `AgentSessionPort`): a JSON-RPC connection to the acpmux hub. The daemon
//! binary supplies the implementation (the Rust acpmux client over the hub
//! socket); tests supply a fake. This file also holds the connect sequence
//! that both TypeScript and Rust hosts run on every acpmux connect.

use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::acp::{AcpmuxEvent, SessionSummary};
use cmux_chief::rules::MUX_SESSION_NAME;
use cmux_chief::{HostState, Input};
use serde_json::{Value, json};

/// How a request ended without a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentError {
    /// The hub answered with an error.
    Rejected { message: String },
    /// The connection closed before the answer.
    Closed,
}

impl std::fmt::Display for AgentError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rejected { message } => formatter.write_str(message),
            Self::Closed => formatter.write_str("acpmux connection closed"),
        }
    }
}

pub type AgentReply = Box<dyn FnOnce(Result<Value, AgentError>) + Send>;

/// What a connection reports besides request answers.
#[derive(Debug, Clone, PartialEq)]
pub enum AgentNotice {
    Notification {
        method: String,
        params: Value,
    },
    /// The connection ended. Sent once, after every pending reply was called.
    Closed,
}

/// One open hub connection. `request` never blocks: `reply` runs once, on
/// any thread, with the answer, the hub's error, or `Closed` when the
/// connection ends first (every pending reply is called on close).
pub trait AgentConnection: Send + Sync {
    fn request(&self, method: &str, params: Value, reply: AgentReply);
    /// Ends the connection; pending replies get `Closed`, then `Closed` is noticed.
    fn close(&self);
}

/// Opens hub connections, starting the hub when its socket does not answer.
pub trait AgentConnector: Send + Sync {
    fn connect(
        &self,
        notices: Box<dyn Fn(AgentNotice) + Send + Sync>,
    ) -> anyhow::Result<Arc<dyn AgentConnection>>;
}

/// The settings the connect sequence needs for a new `mux` session.
#[derive(Debug, Clone)]
pub(super) struct SessionSpec {
    pub(super) cwd: String,
    pub(super) harness: String,
    pub(super) policy: String,
}

/// A blocking request bounded by `deadline`. A request that misses it closes
/// the connection (the caller connects again).
pub(super) fn call(
    connection: &Arc<dyn AgentConnection>,
    method: &str,
    params: Value,
    deadline: Instant,
) -> anyhow::Result<Value> {
    let (sender, receiver) = mpsc::channel();
    connection.request(method, params, Box::new(move |answer| drop(sender.send(answer))));
    let remaining = deadline.saturating_duration_since(Instant::now());
    match receiver.recv_timeout(remaining) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(anyhow::anyhow!("{method}: {error}")),
        Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
            connection.close();
            anyhow::bail!("{method}: no answer before the connect deadline")
        }
    }
}

/// The `acpmux_connected` input of one connect: ensure the `mux` session,
/// watch, read the log identity, attach from the saved cursor (from 0 for a
/// log host.json does not know, or after `cursor_future`).
pub(super) fn connect_sequence(
    connection: &Arc<dyn AgentConnection>,
    spec: &SessionSpec,
    state: &HostState,
    deadline: Instant,
) -> anyhow::Result<Input> {
    let (session_id, created) = ensure_session(connection, spec, deadline)?;
    let watched = call(connection, "_acpmux/watch", json!({"enabled": true}), deadline)?;
    let sessions = match watched.get("sessions") {
        Some(Value::Array(_)) => parse_sessions(&watched),
        _ => parse_sessions(&call(connection, "_acpmux/sessions", json!({}), deadline)?),
    };
    let first = call(
        connection,
        "_acpmux/events",
        json!({"sessionId": session_id, "afterSeq": 0, "limit": 1}),
        deadline,
    )?;
    let log_id = first
        .get("events")
        .and_then(|events| events.get(0))
        .and_then(|event| event.get("at"))
        .and_then(cmux_chief::acp::lenient_count_value);
    // A host.json without acpmuxLog (from before it existed) adopts this identity: no replay from 0.
    let known = state.mux_session_id.as_deref() == Some(session_id.as_str())
        && match (log_id, state.acpmux_log) {
            (Some(id), Some(saved)) => id == saved,
            _ => true,
        };
    let after = if known { state.acpmux_seq } else { 0 };
    let (events, cursor_reset) = attach(connection, &session_id, after, deadline)?;
    Ok(Input::AcpmuxConnected {
        session_id,
        sessions,
        events,
        cursor_reset,
        log_id: log_id.map(Value::from),
        created,
    })
}

fn ensure_session(
    connection: &Arc<dyn AgentConnection>,
    spec: &SessionSpec,
    deadline: Instant,
) -> anyhow::Result<(String, bool)> {
    let listed = parse_sessions(&call(connection, "_acpmux/sessions", json!({}), deadline)?);
    if let Some(existing) = listed.into_iter().find(|session| session.name == MUX_SESSION_NAME) {
        return Ok((existing.session_id, false));
    }
    let params = json!({
        "cwd": spec.cwd,
        "mcpServers": [],
        "_meta": {"acpmux": {"name": MUX_SESSION_NAME, "harness": spec.harness, "policy": spec.policy}},
    });
    let created = call(connection, "session/new", params, deadline)?;
    let session_id = created
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("session/new returned no sessionId"))?;
    Ok((session_id.to_owned(), true))
}

fn attach(
    connection: &Arc<dyn AgentConnection>,
    session_id: &str,
    after: u64,
    deadline: Instant,
) -> anyhow::Result<(Vec<AcpmuxEvent>, bool)> {
    let params =
        |after: u64| json!({"sessionId": session_id, "afterSeq": after, "limit": 1_000_000});
    match call(connection, "_acpmux/attach", params(after), deadline) {
        Ok(attached) => Ok((parse_events(&attached), false)),
        // The log is shorter than the saved cursor (a re-imported session):
        // replay it all; the core treats this as a reset.
        Err(error) if after > 0 && error.to_string().contains("cursor_future") => {
            let attached = call(connection, "_acpmux/attach", params(0), deadline)?;
            Ok((parse_events(&attached), true))
        }
        Err(error) => Err(error),
    }
}

fn parse_sessions(result: &Value) -> Vec<SessionSummary> {
    let list = result.get("sessions").cloned().unwrap_or(Value::Null);
    serde_json::from_value(list).unwrap_or_default()
}

pub(super) fn parse_events(result: &Value) -> Vec<AcpmuxEvent> {
    let list = result.get("events").cloned().unwrap_or(Value::Null);
    serde_json::from_value(list).unwrap_or_default()
}

/// A hub notification as a core input (`None` for one the core does not read).
pub(super) fn notice_input(method: &str, params: &Value) -> Option<Input> {
    match method {
        "_acpmux/event" => {
            Some(Input::AcpmuxEvent { event: serde_json::from_value(params.clone()).ok()? })
        }
        "session/update" => Some(Input::AcpmuxEvent { event: event_from_update(params) }),
        "_acpmux/session_changed" => Some(Input::SessionChanged {
            session: serde_json::from_value(params.get("session")?.clone()).ok()?,
        }),
        "_acpmux/permission_pending" => Some(Input::PermissionPending {
            session_id: params.get("sessionId")?.as_str()?.to_owned(),
            permission_id: params.get("permissionId")?.as_str()?.to_owned(),
            request: params.get("request").cloned().unwrap_or_else(|| json!({})),
        }),
        _ => None,
    }
}

/// A live ACP `session/update` in the shape acpmux records it in its log, so
/// replay and live events fold the same way (TypeScript `eventFromUpdate`).
fn event_from_update(params: &Value) -> AcpmuxEvent {
    let meta = params.pointer("/_meta/acpmux");
    let kind = params.pointer("/update/sessionUpdate").and_then(Value::as_str).unwrap_or("");
    let raw = json!({
        "sessionId": params.get("sessionId").filter(|id| id.is_string()),
        "seq": meta.and_then(|meta| meta.get("seq")).cloned().unwrap_or(json!(0)),
        "at": meta.and_then(|meta| meta.get("at")).cloned(),
        "dir": "in",
        "kind": kind,
        "msg": {"params": params},
    });
    serde_json::from_value(raw).expect("an event object always reads")
}

/// Notifications that arrive before the connect input are held, then sent
/// after it (the TypeScript host's `held`).
#[derive(Default)]
pub(super) struct NoticeGate {
    held: Mutex<Option<Vec<AgentNotice>>>,
}

impl NoticeGate {
    pub(super) fn new() -> Arc<Self> {
        Arc::new(Self { held: Mutex::new(Some(Vec::new())) })
    }

    /// Holds `notice` while the gate is shut; else hands it back.
    pub(super) fn hold(&self, notice: AgentNotice) -> Option<AgentNotice> {
        let mut held = self.held.lock().unwrap();
        match held.as_mut() {
            Some(list) => {
                list.push(notice);
                None
            }
            None => Some(notice),
        }
    }

    /// Opens the gate under `deliver`, so no live notice passes the held ones.
    pub(super) fn open(&self, mut deliver: impl FnMut(AgentNotice)) {
        let mut held = self.held.lock().unwrap();
        for notice in held.take().unwrap_or_default() {
            deliver(notice);
        }
    }
}

/// The reconnect backoff: doubles to `max`, and starts over after a
/// connection that lived longer than `max`.
#[derive(Debug, Clone, Copy)]
pub(super) struct Backoff {
    pub(super) initial: Duration,
    pub(super) max: Duration,
}
