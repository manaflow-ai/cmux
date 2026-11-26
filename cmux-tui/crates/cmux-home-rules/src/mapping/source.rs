//! Being ported (step A in progress).

use crate::ops::OpError;
use serde_json::Value;

/// Not ported yet.
pub fn conversation_event_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn rejection_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn request_limits_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn search_hits_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn session_step_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}
