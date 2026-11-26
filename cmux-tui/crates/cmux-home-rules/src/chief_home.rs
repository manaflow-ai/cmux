//! The `chief_home` area's ops (see the crate docs for what it covers).

use crate::ops::OpError;
use serde_json::Value;

/// This area's op names (without the `chief_home.` prefix).
pub const OPS: &[&str] = &[];

/// Runs `chief_home.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let _ = (name, request);
    Err(OpError::Unknown)
}
