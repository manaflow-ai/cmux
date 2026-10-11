//! `workspace.rename` and `workspace.move`, which resolve their workspace
//! by selector and return the committed workspace snapshot.

use super::*;

pub(super) fn rename_workspace(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let mutation = mutation(&request)?;
    let commit = mux
        .resource_rename_workspace_selected(
            request.selectors,
            required_string(&request.fields, "name")?.to_string(),
            None,
            expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    snapshot_mutation_result(mux, commit, "workspace.rename", "workspace")
}

pub(super) fn move_workspace(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let mutation = mutation(&request)?;
    let index = required_u64(&request.fields, "index")?
        .try_into()
        .map_err(|_| validation_error("workspace index exceeds usize", json!({})))?;
    let commit = mux
        .resource_move_workspace_selected(
            request.selectors,
            index,
            None,
            expected_revision(&request.fields)?,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    snapshot_mutation_result(mux, commit, "workspace.move", "workspace")
}
