//! Motion choices CmuxNextDesign/Motion makes on top of cmux-motion (gates, pairs, paths, settle, nudge).
//!
//! Ops: `motion.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `motion.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
