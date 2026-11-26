//! Being ported (step A in progress).

use crate::ops::OpError;
use serde_json::Value;

/// Not ported yet.
pub fn rows_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn ordered_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn time_key_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn note_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn accept_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn seed_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn edit_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}
