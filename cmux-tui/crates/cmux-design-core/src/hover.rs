//! Tooltip and hover card rules the app's TooltipPresenter and HoverCards still decide in Swift (the machines are cmux-motion's).
//!
//! Ops: `hover.NAME` (see [`call`]).

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs `hover.NAME`.
pub fn call(name: &str, _request: &Value) -> OpResult {
    let _ = name;
    Err(OpError::Unknown)
}
