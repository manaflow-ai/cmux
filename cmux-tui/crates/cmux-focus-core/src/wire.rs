//! The JSON requests the app sends over the app FFI for the per-key rules
//! (`cmux_layout_reducer_json` operations `focus_type_ahead`,
//! `focus_child_window_key`) and their responses. The focus machine itself
//! is a handle with typed events and replies (the FFI crate's `focus`
//! module), not JSON.

use crate::child_window::{self, Decision, Facts};
use crate::event::FocusEvent;
use crate::reducer;
use crate::state::FocusState;
use crate::type_ahead::TypeAheadQueue;
use serde::{Deserialize, Serialize};

// Compatibility for app builds pinned before the handle ABI: the old
// whole-state JSON ops (`focus_reduce`, `focus_changes_view`). Delete them
// once the app's CCmuxAppFFI pin uses `cmux_focus_*` (bead cx-8w027.2).

#[derive(Debug, Deserialize)]
pub struct ReduceRequest {
    pub state: FocusState,
    pub event: FocusEvent,
}

pub fn reduce(request: ReduceRequest) -> serde_json::Value {
    let mut state = request.state;
    state.derive();
    let mut effects = Vec::new();
    match request.event {
        FocusEvent::Topology { topology } => {
            reducer::set_topology(&mut state, topology, &mut effects);
        }
        event => {
            reducer::reduce(&mut state, &event, &mut effects);
        }
    }
    serde_json::json!({"state": state.export(), "effects": effects})
}

#[derive(Debug, Deserialize)]
pub struct ChangesViewRequest {
    pub event: FocusEvent,
}

pub fn changes_view(request: &ChangesViewRequest) -> serde_json::Value {
    serde_json::json!({"changesView": request.event.changes_view()})
}

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
