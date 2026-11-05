//! `workspace.rename` and `workspace.move`, which resolve their workspace
//! by selector and return the committed workspace snapshot. A move also
//! moves the workspace in the sidebar document
//! (`state::sidebar_doc_workspace_move`).

use super::*;

pub(super) fn rename_workspace(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let mutation = mutation(&request)?;
    let name_authority = crate::resource_name::WorkspaceNameUpdate::parse(&request.fields)
        .map_err(resource_operation_error)?;
    // A release keeps the current name, so it may omit one.
    let name = if name_authority.releases() && !request.fields.contains_key("name") {
        None
    } else {
        Some(required_string(&request.fields, "name")?.to_string())
    };
    let commit = mux
        .resource_rename_workspace_selected(
            request.selectors,
            name,
            name_authority,
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
    // The sidebar shows the sidebar document's order, not the session's
    // (#29875): move the workspace there too, to the same `index` of
    // `workspace.list`. A failure is the request's error, never a silent
    // success with the sidebar unchanged: a retry replays the committed
    // session move and runs the sidebar move again under its own key.
    if let Some(workspace) = commit.result["workspace"].as_str() {
        mux.state_workspace_sidebar_move(&mutation, workspace, index)
            .map_err(resource_operation_error)?;
    }
    snapshot_mutation_result(mux, commit, "workspace.move", "workspace")
}

#[cfg(test)]
mod workspace_name_tests;
