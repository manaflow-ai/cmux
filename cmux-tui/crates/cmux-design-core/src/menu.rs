//! Menu look and sizing: GlassMenu, MenuLook, MenuTextSize.
//!
//! Ops: `menu.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `menu.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
