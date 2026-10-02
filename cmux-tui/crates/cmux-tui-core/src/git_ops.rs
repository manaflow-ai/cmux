//! `git.diff` and `git.status`: read-only git reads of the repository a path
//! or a terminal's working directory is in.

#[cfg(test)]
mod tests;

use std::sync::Arc;

use serde_json::{Value, json};

use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(operation, ResourceOperation::GitDiff | ResourceOperation::GitStatus)
}

pub(crate) fn dispatch(
    _mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    Err(ResourceError::operation_failed(
        format!("{:?}", request.envelope.operation),
        "git reads are not implemented yet",
        json!({}),
    ))
}
