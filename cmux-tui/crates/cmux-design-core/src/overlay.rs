//! Overlays: Overlay, FloatingGlass, FloatingPane, FindPill, Quit.
//!
//! Ops: `overlay.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `overlay.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
