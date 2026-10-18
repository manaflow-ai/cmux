//! The JSON requests the app sends over the app FFI
//! (`cmux_layout_reducer_json` operations `focus_reduce`,
//! `focus_changes_view`, `focus_type_ahead`, `focus_child_window_key`) and
//! their responses. One call per event or key, synchronous, no I/O.

use crate::child_window::{self, Decision, Facts};
use crate::event::{FocusEffect, FocusEvent};
use crate::reducer;
use crate::state::FocusState;
use crate::type_ahead::TypeAheadQueue;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct ReduceRequest {
    pub state: FocusState,
    pub event: FocusEvent,
}

#[derive(Debug, Serialize)]
pub struct ReduceResponse {
    pub state: FocusState,
    pub effects: Vec<FocusEffect>,
}

pub fn reduce(request: &ReduceRequest) -> ReduceResponse {
    let (state, effects) = reducer::reduce(&request.state, &request.event);
    ReduceResponse { state, effects }
}

#[derive(Debug, Deserialize)]
pub struct ChangesViewRequest {
    pub event: FocusEvent,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangesViewResponse {
    pub changes_view: bool,
}

pub fn changes_view(request: &ChangesViewRequest) -> ChangesViewResponse {
    ChangesViewResponse { changes_view: request.event.changes_view() }
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
