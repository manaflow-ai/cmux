//! Toasts: CmuxNextDesign/Toast (queue, timing, placement, dedupe).
//!
//! Ops: `toast.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `toast.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
