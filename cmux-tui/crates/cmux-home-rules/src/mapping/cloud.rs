//! Being ported (step A in progress).

use crate::ops::OpError;
use serde_json::Value;

/// Not ported yet.
pub fn identity_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn participant_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn message_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn summary_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn entry_summary_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn parts_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn snapshot_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn missing_heads_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn participant_record_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}
