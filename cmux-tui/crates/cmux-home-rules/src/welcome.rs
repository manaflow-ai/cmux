//! The `welcome` area's ops (see the crate docs for what it covers).

use crate::ops::OpError;
use serde_json::Value;

/// This area's op names (without the `welcome.` prefix).
pub const OPS: &[&str] = &[];

/// Runs `welcome.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let _ = (name, request);
    Err(OpError::Unknown)
}
