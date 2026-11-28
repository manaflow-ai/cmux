//! Derived tokens: density catalog, metrics, group colors, two-tone and frame tone, corner flush, typography.
//!
//! Ops: `tokens.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `tokens.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
