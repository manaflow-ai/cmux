//! Being ported (step A in progress).

use crate::ops::OpError;
use serde_json::Value;

/// Not ported yet.
pub fn live_event_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn run_changed_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn talk_rows_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}

/// Not ported yet.
pub fn agent_run_op(_request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not ported yet".into()))
}
