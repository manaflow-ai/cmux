//! The `chief_settings` area's ops (see the crate docs for what it covers).

use crate::ops::OpError;
use serde_json::Value;

/// This area's op names (without the `chief_settings.` prefix).
pub const OPS: &[&str] = &[];

/// Runs `chief_settings.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let _ = (name, request);
    Err(OpError::Unknown)
}
