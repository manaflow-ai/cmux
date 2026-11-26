//! Window press routing, focus route, click trace, resize bands, full-screen titlebar press.
//!
//! Ops: `window.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `window.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
