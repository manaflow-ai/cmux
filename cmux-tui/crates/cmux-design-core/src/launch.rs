//! The launch reveal: CmuxNextDesign/Launch (first frame gate, page deferral, reveal).
//!
//! Ops: `launch.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `launch.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
