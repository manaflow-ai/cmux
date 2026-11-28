//! Wallpaper tint, live wallpaper picks and backdrop rules (time of day, sun, placement).
//!
//! Ops: `wallpaper.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `wallpaper.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
