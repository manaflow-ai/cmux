//! Work in progress: filled in by the next commit.

use crate::ops::OpError;
use serde_json::Value;

pub(super) fn call(_name: &str, _request: &Value) -> Result<Value, OpError> {
    Err(OpError::Invalid("not yet ported".into()))
}
