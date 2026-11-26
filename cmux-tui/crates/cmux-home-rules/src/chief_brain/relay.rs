//! `ChiefProfilePageRelay`'s rules (which calls it relays, which need the person's
//! gesture, when a relay connection is reused or retried) and `PageCallDeadline`'s
//! answer-once race.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// `ChiefProfilePageRelay.operations`.
pub const OPERATIONS: &[&str] = &[
    "chief.profile.list",
    "chief.profile.get",
    "chief.profile.create",
    "chief.profile.update",
    "chief.profile.delete",
    "chief.profile.avatar.get",
    "chief.profile.avatar.set",
    "chief.profile.history",
    "chief.profile.undo",
];

/// `ChiefProfilePageRelay.gestureFields`.
pub const GESTURE_FIELDS: &[&str] = &[
    "effort",
    "harness",
    "harnesses",
    "instructions",
    "locked",
    "model",
    "personality",
    "self_edit",
    "tools",
];

/// `ChiefProfilePageRelay.callDeadline`, in seconds.
pub const CALL_DEADLINE_SECS: f64 = 16.0;

/// `needsGesture(_:params:)`.
pub fn needs_gesture(operation: &str, params: &Map<String, Value>) -> bool {
    match operation {
        "chief.profile.create" | "chief.profile.delete" | "chief.profile.undo" => true,
        "chief.profile.update" => params.keys().any(|k| GESTURE_FIELDS.contains(&k.as_str())),
        _ => false,
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteRequest {
    pub operation: String,
    #[serde(default)]
    pub params: Map<String, Value>,
    /// The page's gesture event time.
    pub gesture_event: Option<f64>,
    /// The gesture a call already spent.
    pub spent_gesture: Option<f64>,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteReply {
    /// A Chief profile operation (else Swift throws `unknown_op`).
    pub known: bool,
    /// Send it as the person's (`claim: user` with a confirmation token).
    pub gesture: bool,
    /// The relay's `spentGesture` after this call.
    pub spent_gesture: Option<f64>,
    pub deadline_secs: f64,
}

/// `send`'s first lines: the operation check and the gesture.
pub fn route(r: &RouteRequest) -> RouteReply {
    let known = OPERATIONS.contains(&r.operation.as_str());
    let gesture = known
        && needs_gesture(&r.operation, &r.params)
        && r.gesture_event.is_some()
        && r.gesture_event != r.spent_gesture;
    RouteReply {
        known,
        gesture,
        spent_gesture: if gesture { r.gesture_event } else { r.spent_gesture },
        deadline_secs: CALL_DEADLINE_SECS,
    }
}

/// `isConnectionLost(_:)` on a `DaemonError` case name.
pub fn is_connection_lost(error: &str) -> bool {
    matches!(error, "notConnected" | "connectionClosed" | "daemonShutdown")
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryRequest {
    /// The attempt that failed (1 or 2).
    pub attempt: u32,
    /// The `DaemonError` case.
    pub error: String,
    /// The failed call used the relay's current connection.
    #[serde(default)]
    pub used_current: bool,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetryReply {
    /// Try again on a new connection (else throw: the error, or `notConnected` after the last attempt).
    pub retry: bool,
    /// Drop the relay connection first.
    pub drop_relay: bool,
}

/// `call`'s catch: a lost connection on the first attempt goes again on a new one.
pub fn retry(r: &RetryRequest) -> RetryReply {
    let retry = r.attempt == 1 && is_connection_lost(&r.error);
    RetryReply { retry, drop_relay: retry && r.used_current }
}

/// `OwnerKey`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerKey {
    pub socket: String,
    pub pid: i32,
    pub generation: Value,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub pid: i32,
    pub generation: Value,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownRelay {
    pub owner: OwnerKey,
    #[serde(default)]
    pub ready: bool,
    pub identity: Option<Identity>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReuseRequest {
    pub owner: OwnerKey,
    pub relay: Option<KnownRelay>,
    /// The owner a connect in flight is for.
    pub starting: Option<OwnerKey>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Reuse {
    /// Use the relay connection there is.
    Reuse,
    /// Wait for the connect in flight.
    JoinStarting,
    /// Connect a new relay connection.
    Connect,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReuseReply {
    pub reuse: Reuse,
}

/// `relayConnection(_:)`'s choice.
pub fn reuse(r: &ReuseRequest) -> Reuse {
    if let Some(relay) = &r.relay
        && relay.owner == r.owner
        && relay.ready
        && relay
            .identity
            .as_ref()
            .is_some_and(|i| i.pid == r.owner.pid && i.generation == r.owner.generation)
    {
        return Reuse::Reuse;
    }
    if r.starting.as_ref() == Some(&r.owner) { Reuse::JoinStarting } else { Reuse::Connect }
}

/// A connect finished: it is the relay only while it is still the one in flight.
pub fn connect_counts(started_for: &OwnerKey, starting: Option<&OwnerKey>) -> bool {
    starting == Some(started_for)
}

// MARK: PageCallDeadline

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CallState {
    /// The call has answered (the continuation is gone).
    pub answered: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CallEvent {
    /// The work returned or threw.
    Finished,
    /// The deadline passed.
    Deadline,
    /// The caller's task was cancelled.
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CallAnswer {
    /// The work's result.
    Result,
    /// `onTimeout()`'s error (`PageAnswerDeadline`: nil).
    TimedOut,
    /// `CancellationError`.
    Cancelled,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallReply {
    pub state: CallState,
    /// Answer the caller with this, cancel the work and the timer. None: drop the event.
    pub answer: Option<CallAnswer>,
}

/// `PageCallDeadline.answer`'s race: the first of the work, the deadline and a cancel answers.
pub fn call_step(state: CallState, event: CallEvent) -> CallReply {
    if state.answered {
        return CallReply { state, answer: None };
    }
    CallReply {
        state: CallState { answered: true },
        answer: Some(match event {
            CallEvent::Finished => CallAnswer::Result,
            CallEvent::Deadline => CallAnswer::TimedOut,
            CallEvent::Cancelled => CallAnswer::Cancelled,
        }),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CallRequest {
    #[serde(default)]
    pub state: CallState,
    pub event: CallEvent,
}
