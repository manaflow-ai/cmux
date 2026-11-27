//! The JSON requests the app sends over the app FFI for the per-key rules
//! (`cmux_layout_reducer_json` operations `focus_type_ahead`,
//! `focus_child_window_key`, `focus_escape_exit`, `focus_work_context`), the per-agent-event cursor visibility rule
//! (`agent_cursor_visibility`) and the input invariants of the debug
//! monitor, `debug.focus` and the journal replay (`focus_input_world`,
//! `focus_input_step`, `focus_debug_window`), and their responses. The focus machine itself
//! is a handle with typed events and replies (the FFI crate's `focus`
//! module), not JSON.

use crate::agent_cursor_visibility::{self, Snapshot, Visibility};
use crate::child_window::{self, Decision, Facts};
use crate::escape_exit::{self, EscapeExit};
use crate::event::{FocusEvent, Responder};
use crate::invariants::{self, Model, Observation, Violation, WorldResult};
use crate::state::Resolved;
use crate::type_ahead::TypeAheadQueue;
use crate::work_context::{self, WorkContextTrail};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TypeAheadOp {
    #[serde(rename_all = "camelCase")]
    Append {
        characters: String,
        surface: String,
        now_ns: i64,
    },
    DeleteBackward {
        surface: String,
    },
    #[serde(rename_all = "camelCase")]
    Take {
        surface: String,
        now_ns: i64,
    },
    Pending {
        surface: String,
    },
}

#[derive(Debug, Deserialize)]
pub struct TypeAheadRequest {
    pub queue: TypeAheadQueue,
    pub op: TypeAheadOp,
}

#[derive(Debug, Serialize)]
pub struct TypeAheadResponse {
    pub queue: TypeAheadQueue,
    /// `take`: the text, when it was not too old.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// `pending`.
    pub pending: bool,
}

pub fn type_ahead(request: &TypeAheadRequest) -> TypeAheadResponse {
    let mut queue = request.queue.clone();
    let mut text = None;
    let mut pending = false;
    match &request.op {
        TypeAheadOp::Append { characters, surface, now_ns } => {
            queue.append(characters, surface, *now_ns);
        }
        TypeAheadOp::DeleteBackward { surface } => queue.delete_backward(surface),
        TypeAheadOp::Take { surface, now_ns } => text = queue.take(surface, *now_ns),
        TypeAheadOp::Pending { surface } => pending = queue.pending(surface),
    }
    TypeAheadResponse { queue, text, pending }
}

#[derive(Debug, Deserialize)]
pub struct ChildWindowKeyRequest {
    pub facts: Facts,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChildWindowKeyResponse {
    pub decision: Decision,
    pub should_reclaim: bool,
}

pub fn child_window_key(request: &ChildWindowKeyRequest) -> ChildWindowKeyResponse {
    ChildWindowKeyResponse {
        decision: child_window::decide(&request.facts),
        should_reclaim: child_window::should_reclaim(&request.facts),
    }
}

/// `focus_input_world`: every model and world check over one observation.
pub fn input_world(observation: &Observation) -> WorldResult {
    invariants::world(observation)
}

#[derive(Debug, Deserialize)]
pub struct InputStepRequest {
    pub old: Model,
    pub event: FocusEvent,
    pub new: Model,
    #[serde(default)]
    pub window: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct InputStepResponse {
    pub violations: Vec<Violation>,
}

/// `focus_input_step`: the model and transition checks of one reduction.
pub fn input_step(request: &InputStepRequest) -> InputStepResponse {
    InputStepResponse {
        violations: invariants::step(
            &request.old,
            &request.event,
            &request.new,
            request.window.as_deref(),
        ),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugWindowRequest {
    pub resolved: Resolved,
    /// The tab whose Chromium page window has the keys.
    #[serde(default)]
    pub child_page: Option<String>,
    /// The app-wide focused Ghostty terminal tabs.
    #[serde(default)]
    pub ghostty: Vec<String>,
    /// This window's tabs.
    #[serde(default)]
    pub own_tabs: HashSet<String>,
    #[serde(default)]
    pub is_key: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugWindowResponse {
    /// The responder the platform should report (W1), when one is expected.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_responder: Option<Responder>,
    /// The kind name of the resolved target.
    pub kind: String,
    /// The Ghostty problem, when Ghostty and the focus disagree.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ghostty_mismatch: Option<String>,
}

/// `focus_debug_window`: `debug.focus`'s per-window checks.
pub fn debug_window(request: &DebugWindowRequest) -> DebugWindowResponse {
    DebugWindowResponse {
        expected_responder: invariants::expected_responder(
            &request.resolved,
            request.child_page.as_deref(),
        ),
        kind: request.resolved.kind(),
        ghostty_mismatch: request.resolved.ghostty_mismatch(
            &request.ghostty,
            &request.own_tabs,
            request.is_key,
        ),
    }
}

/// `agent_cursor_visibility`: the target tab id and the snapshot the app
/// took when the agent input event arrived. The answer is a
/// [`Visibility`]: `{"kind":"visible","window","viewport","clip","zoom","scale"}`,
/// `{"kind":"hidden","window","anchor","rect"}` or `{"kind":"notDrawn","reason"}`.
#[derive(Debug, Deserialize)]
pub struct AgentCursorVisibilityRequest {
    pub target: String,
    pub snapshot: Snapshot,
}

pub fn agent_cursor_visibility(request: &AgentCursorVisibilityRequest) -> Visibility {
    agent_cursor_visibility::resolve(&request.target, &request.snapshot)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EscapeExitRequest {
    #[serde(default)]
    pub gesture: EscapeExit,
    /// The key-down; none resets the gesture.
    #[serde(default)]
    pub key: Option<escape_exit::Key>,
}

#[derive(Debug, Serialize)]
pub struct EscapeExitResponse {
    pub gesture: EscapeExit,
    /// What the key router does with the key (`pass` for a reset).
    #[serde(flatten)]
    pub outcome: escape_exit::Outcome,
}

/// `focus_escape_exit`: one key-down of browser focus mode's Esc Esc gesture.
pub fn escape_exit(request: &EscapeExitRequest) -> EscapeExitResponse {
    let mut gesture = request.gesture.clone();
    let outcome = match &request.key {
        Some(key) => gesture.handle(key),
        None => {
            gesture.reset();
            escape_exit::Outcome::Pass
        }
    };
    EscapeExitResponse { gesture, outcome }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkContextOp {
    Record { entry: work_context::Entry },
    Forget { tab: String },
    Candidates { target: work_context::Target },
}

#[derive(Debug, Deserialize)]
pub struct WorkContextRequest {
    #[serde(default)]
    pub trail: WorkContextTrail,
    pub op: WorkContextOp,
}

#[derive(Debug, Serialize)]
pub struct WorkContextResponse {
    /// `record`, `forget`: the trail after.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trail: Option<WorkContextTrail>,
    /// `candidates`: the entries the rule reads, in its order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<work_context::Entry>>,
}

/// `focus_work_context`: the work-context trail's ops.
pub fn work_context(request: &WorkContextRequest) -> WorkContextResponse {
    let mut trail = request.trail.clone();
    match &request.op {
        WorkContextOp::Record { entry } => trail.record(entry.clone()),
        WorkContextOp::Forget { tab } => trail.forget(tab),
        WorkContextOp::Candidates { target } => {
            let candidates = trail.candidates(target).into_iter().cloned().collect();
            return WorkContextResponse { trail: None, candidates: Some(candidates) };
        }
    }
    WorkContextResponse { trail: Some(trail), candidates: None }
}
