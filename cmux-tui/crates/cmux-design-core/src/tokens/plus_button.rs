//! Port pending (swift-out design tokens).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs the `tokens.plus_button_*` ops.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
