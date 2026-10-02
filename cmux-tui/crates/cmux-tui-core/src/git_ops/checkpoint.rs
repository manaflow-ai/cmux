//! `git.checkpoint.create|get|list|pin|unpin`: immutable repository
//! checkpoints the session host captures without changing HEAD, the index or
//! the worktree, published as `refs/cmux/checkpoints/<worktree>/<id>`.

#[cfg(test)]
mod tests;

use std::sync::Arc;

use serde_json::{Value, json};

use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::GitCheckpointCreate
            | ResourceOperation::GitCheckpointGet
            | ResourceOperation::GitCheckpointList
            | ResourceOperation::GitCheckpointPin
            | ResourceOperation::GitCheckpointUnpin
    )
}

pub(super) fn dispatch(
    _mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    Err(ResourceError::operation_failed(
        request.envelope.operation.wire_name(),
        "git checkpoints are not implemented yet",
        json!({}),
    ))
}
