//! The JSON requests the app sends over the app FFI for the per-key rules
//! (`cmux_layout_reducer_json` operations `focus_type_ahead`,
//! `focus_child_window_key`) and their responses. The focus machine itself
//! is a handle with typed events and replies (the FFI crate's `focus`
//! module), not JSON.

use crate::child_window::{self, Decision, Facts};
use crate::type_ahead::TypeAheadQueue;
use serde::{Deserialize, Serialize};

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
