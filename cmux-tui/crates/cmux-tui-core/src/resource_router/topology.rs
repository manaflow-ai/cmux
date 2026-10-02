use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{Value, json};

use super::{
    ParsedResourceRequest, expected_revision, find_snapshot, mutation_result, optional_string,
    required_string, required_u64, resource_operation_error, validation_error,
};
use crate::resource::{RequestEnvelope, ResourceError, ResourceOperation};
use crate::resource_api::public_session_snapshot;
use crate::{Mux, ResolvedResourcePath, ResourceSelectors, ResourceTarget, WorkspaceMutation};

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceList
            | ResourceOperation::WorkspaceGet
            | ResourceOperation::WorkspaceCreate
            | ResourceOperation::WorkspaceRename
            | ResourceOperation::WorkspaceMove
            | ResourceOperation::WorkspaceFocus
            | ResourceOperation::WorkspaceClose
            | ResourceOperation::WorkspaceRun
            | ResourceOperation::WorkspaceLayoutApply
            | ResourceOperation::ScreenList
            | ResourceOperation::ScreenGet
            | ResourceOperation::ScreenCreate
            | ResourceOperation::ScreenRename
            | ResourceOperation::ScreenFocus
            | ResourceOperation::ScreenClose
            | ResourceOperation::ScreenLayoutExport
            | ResourceOperation::ScreenLayoutUndo
            | ResourceOperation::PaneList
            | ResourceOperation::PaneGet
            | ResourceOperation::PaneCreate
            | ResourceOperation::PaneSplit
            | ResourceOperation::PaneRename
            | ResourceOperation::PaneFocus
            | ResourceOperation::PaneFocusDirection
            | ResourceOperation::PaneNeighborGet
            | ResourceOperation::PaneSwap
            | ResourceOperation::PaneZoom
            | ResourceOperation::PaneSplitRatioSet
            | ResourceOperation::PaneViewportWidthSet
            | ResourceOperation::PaneClose
            | ResourceOperation::PaneRun
            | ResourceOperation::TabList
            | ResourceOperation::TabGet
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TabCreateBrowser
            | ResourceOperation::TabRename
            | ResourceOperation::TabMove
            | ResourceOperation::TabFocus
            | ResourceOperation::TabClose
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    match request.envelope.operation {
        ResourceOperation::WorkspaceList => list_resources(
            mux,
            &request.selectors,
            ResourceTarget::Session,
            "workspaces",
            "workspace.list",
        ),
        ResourceOperation::WorkspaceGet => {
            get_resource(mux, &request.selectors, ResourceTarget::Workspace, "workspaces")
        }
        ResourceOperation::ScreenList => {
            let scope = optional_scope(&request.selectors, ResourceTarget::Workspace);
            list_resources(mux, &request.selectors, scope, "screens", "screen.list")
        }
        ResourceOperation::ScreenGet => {
            get_resource(mux, &request.selectors, ResourceTarget::Screen, "screens")
        }
        ResourceOperation::ScreenLayoutExport => {
            Ok(get_resource(mux, &request.selectors, ResourceTarget::Screen, "screens")?["layout"]
                .clone())
        }
        ResourceOperation::PaneList => {
            let scope = optional_scope(&request.selectors, ResourceTarget::Screen);
            list_resources(mux, &request.selectors, scope, "panes", "pane.list")
        }
        ResourceOperation::PaneGet => {
            get_resource(mux, &request.selectors, ResourceTarget::Pane, "panes")
        }
        ResourceOperation::PaneNeighborGet => pane_neighbor(mux, request),
        ResourceOperation::TabList => {
            let scope = optional_scope(&request.selectors, ResourceTarget::Pane);
            list_resources(mux, &request.selectors, scope, "tabs", "tab.list")
        }
        ResourceOperation::TabGet => {
            get_resource(mux, &request.selectors, ResourceTarget::Tab, "tabs")
        }
        ResourceOperation::WorkspaceCreate => create_workspace(mux, request),
        ResourceOperation::WorkspaceRename => rename_workspace(mux, request),
        ResourceOperation::WorkspaceMove => move_workspace(mux, request),
        operation => dispatch_exact_topology_mutation(mux, operation, request),
    }
}

fn optional_scope(selectors: &ResourceSelectors, deepest: ResourceTarget) -> ResourceTarget {
    match deepest {
        ResourceTarget::Pane if selectors.pane.is_some() => ResourceTarget::Pane,
        ResourceTarget::Pane | ResourceTarget::Screen if selectors.screen.is_some() => {
            ResourceTarget::Screen
        }
        ResourceTarget::Pane | ResourceTarget::Screen | ResourceTarget::Workspace
            if selectors.workspace.is_some() =>
        {
            ResourceTarget::Workspace
        }
        _ => ResourceTarget::Session,
    }
}

fn list_resources(
    mux: &Mux,
    selectors: &ResourceSelectors,
    scope: ResourceTarget,
    collection: &str,
    operation: &str,
) -> Result<Value, ResourceError> {
    let path = mux.resolve_resource_path(scope, selectors)?;
    let snapshot = public_session_snapshot(mux)?;
    let path_index = SnapshotPathIndex::new(&snapshot);
    let values = snapshot[collection]
        .as_array()
        .ok_or_else(|| malformed_collection(operation, collection))?
        .iter()
        .filter(|value| path_index.contains(collection, value, &path))
        .cloned()
        .collect();
    Ok(Value::Array(values))
}

fn malformed_collection(operation: &str, collection: &str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        "public snapshot collection is malformed",
        json!({"collection":collection}),
    )
}

struct SnapshotPathIndex<'a> {
    workspace_by_screen: HashMap<&'a str, &'a str>,
    screen_by_pane: HashMap<&'a str, &'a str>,
    pane_by_tab: HashMap<&'a str, &'a str>,
}

impl<'a> SnapshotPathIndex<'a> {
    fn new(snapshot: &'a Value) -> Self {
        let workspace_by_screen = snapshot["screens"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|screen| Some((screen["id"].as_str()?, screen["workspace_id"].as_str()?)))
            .collect();
        let screen_by_pane = snapshot["panes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|pane| Some((pane["id"].as_str()?, pane["screen_id"].as_str()?)))
            .collect();
        let pane_by_tab = snapshot["tabs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|tab| Some((tab["id"].as_str()?, tab["pane_id"].as_str()?)))
            .collect();
        Self { workspace_by_screen, screen_by_pane, pane_by_tab }
    }

    fn contains(&self, collection: &str, value: &Value, path: &ResolvedResourcePath) -> bool {
        if collection == "terminals" {
            let has_structural_scope = path.workspace.is_some()
                || path.screen.is_some()
                || path.pane.is_some()
                || path.tab.is_some();
            if !has_structural_scope {
                return true;
            }
            let tabs = value["tab_ids"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .chain(value["tab_id"].as_str());
            return tabs.into_iter().any(|tab| self.tab_matches_path(tab, path));
        }
        let id = value["id"].as_str();
        let (workspace, screen, pane, tab) = match collection {
            "workspaces" => (id, None, None, None),
            "screens" => (value["workspace_id"].as_str(), id, None, None),
            "panes" => {
                let screen = value["screen_id"].as_str();
                (screen.and_then(|id| self.workspace_by_screen.get(id).copied()), screen, id, None)
            }
            "tabs" => {
                let pane = value["pane_id"].as_str();
                let screen = pane.and_then(|id| self.screen_by_pane.get(id).copied());
                (screen.and_then(|id| self.workspace_by_screen.get(id).copied()), screen, pane, id)
            }
            "browsers" => {
                let tab = value["tab_id"].as_str();
                let pane = tab.and_then(|id| self.pane_by_tab.get(id).copied());
                let screen = pane.and_then(|id| self.screen_by_pane.get(id).copied());
                (screen.and_then(|id| self.workspace_by_screen.get(id).copied()), screen, pane, tab)
            }
            _ => return false,
        };
        path.workspace.as_ref().is_none_or(|id| workspace == Some(id.as_str()))
            && path.screen.as_ref().is_none_or(|id| screen == Some(id.as_str()))
            && path.pane.as_ref().is_none_or(|id| pane == Some(id.as_str()))
            && path.tab.as_ref().is_none_or(|id| tab == Some(id.as_str()))
    }

    fn tab_matches_path(&self, tab: &str, path: &ResolvedResourcePath) -> bool {
        let pane = self.pane_by_tab.get(tab).copied();
        let screen = pane.and_then(|id| self.screen_by_pane.get(id).copied());
        let workspace = screen.and_then(|id| self.workspace_by_screen.get(id).copied());
        path.workspace.as_ref().is_none_or(|id| workspace == Some(id.as_str()))
            && path.screen.as_ref().is_none_or(|id| screen == Some(id.as_str()))
            && path.pane.as_ref().is_none_or(|id| pane == Some(id.as_str()))
            && path.tab.as_ref().is_none_or(|id| tab == id.as_str())
    }
}

fn get_resource(
    mux: &Mux,
    selectors: &ResourceSelectors,
    target: ResourceTarget,
    collection: &str,
) -> Result<Value, ResourceError> {
    let path = mux.resolve_resource_path(target, selectors)?;
    let id = match target {
        ResourceTarget::Workspace => path.workspace.as_ref().map(ToString::to_string),
        ResourceTarget::Screen => path.screen.as_ref().map(ToString::to_string),
        ResourceTarget::Pane => path.pane.as_ref().map(ToString::to_string),
        ResourceTarget::Tab => path.tab.as_ref().map(ToString::to_string),
        _ => None,
    }
    .ok_or_else(|| ResourceError::not_found(collection.trim_end_matches('s'), "<resolved>"))?;
    find_snapshot(&public_session_snapshot(mux)?, collection, &id)
}

fn pane_neighbor(mux: &Mux, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let direction = required_string(&request.fields, "direction")?;
    let neighbor = mux
        .resource_pane_neighbor_selected(&request.selectors, direction)
        .map_err(resource_operation_error)?;
    let pane = neighbor
        .map(|id| find_snapshot(&public_session_snapshot(mux)?, "panes", id.as_str()))
        .transpose()?;
    Ok(json!({"pane":pane}))
}

/// `workspace.create`. An `ephemeral` workspace is marked in the
/// transaction that creates it: the empty path writes the flag with the
/// creation patch, the terminal path with the staged workspace row (the
/// field stays in the stored intent and its fingerprint). No observer sees
/// the workspace without the flag.
fn create_workspace(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let initial_content = required_string(&request.fields, "initial_content")?;
    if initial_content != "empty" {
        return dispatch_exact_topology_mutation(mux, ResourceOperation::WorkspaceCreate, request);
    }
    let ephemeral = request.fields.get("ephemeral").and_then(Value::as_bool).unwrap_or(false);
    let mutation = mutation(&request.envelope)?;
    let correlation_key =
        request.fields.get("correlation_key").and_then(Value::as_str).unwrap_or(&mutation.id);
    let commit = mux
        .resource_create_empty_workspace_selected(
            request.selectors,
            optional_string(&request.fields, "name")?,
            correlation_key,
            expected_revision(&request.fields)?,
            &mutation,
            ephemeral,
        )
        .map_err(resource_operation_error)?;
    let workspace_id = result_id(&commit.result, "workspace.create", "workspace")?;
    mutation_result(
        mux,
        json!({"kind":"workspace","workspace_id":workspace_id}),
        commit.revision,
        commit.replayed,
    )
}

fn rename_workspace(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let mutation = mutation(&request.envelope)?;
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

fn move_workspace(mux: &Arc<Mux>, request: ParsedResourceRequest) -> Result<Value, ResourceError> {
    let mutation = mutation(&request.envelope)?;
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

fn dispatch_exact_topology_mutation(
    mux: &Arc<Mux>,
    operation: ResourceOperation,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let mutation = mutation(&request.envelope)?;
    let expected_revision = expected_revision(&request.fields)?;
    let commit = mux
        .resource_topology_operation(
            operation,
            request.selectors,
            request.fields,
            expected_revision,
            &mutation,
        )
        .map_err(resource_operation_error)?;
    match operation {
        ResourceOperation::WorkspaceFocus | ResourceOperation::WorkspaceLayoutApply => {
            snapshot_mutation_result(mux, commit, &super::operation_name(operation), "workspace")
        }
        ResourceOperation::ScreenRename
        | ResourceOperation::ScreenFocus
        | ResourceOperation::ScreenLayoutUndo => {
            snapshot_mutation_result(mux, commit, &super::operation_name(operation), "screen")
        }
        ResourceOperation::PaneRename
        | ResourceOperation::PaneFocus
        | ResourceOperation::PaneFocusDirection
        | ResourceOperation::PaneSwap
        | ResourceOperation::PaneZoom
        | ResourceOperation::PaneSplitRatioSet
        | ResourceOperation::PaneViewportWidthSet => {
            snapshot_mutation_result(mux, commit, &super::operation_name(operation), "pane")
        }
        ResourceOperation::TabRename | ResourceOperation::TabMove | ResourceOperation::TabFocus => {
            snapshot_mutation_result(mux, commit, &super::operation_name(operation), "tab")
        }
        ResourceOperation::WorkspaceClose
        | ResourceOperation::ScreenClose
        | ResourceOperation::PaneClose
        | ResourceOperation::TabClose => {
            mutation_result(mux, json!({}), commit.revision, commit.replayed)
        }
        ResourceOperation::WorkspaceCreate
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::ScreenCreate
        | ResourceOperation::PaneCreate
        | ResourceOperation::PaneSplit
        | ResourceOperation::PaneRun
        | ResourceOperation::TabCreateTerminal
        | ResourceOperation::TabCreateBrowser => {
            mutation_result(mux, commit.result, commit.revision, commit.replayed)
        }
        _ => Err(ResourceError::operation_failed(
            super::operation_name(operation),
            "topology mutation returned through the wrong result path",
            json!({}),
        )),
    }
}

fn snapshot_mutation_result(
    mux: &Mux,
    commit: crate::workspace_registry::ResourcePatchCommit,
    operation: &str,
    result_field: &str,
) -> Result<Value, ResourceError> {
    let id = result_id(&commit.result, operation, result_field)?;
    let value = commit.result["public_value"].clone();
    if !value.is_object() || value["id"].as_str() != Some(id) {
        return Err(ResourceError::operation_failed(
            operation,
            "topology commit omitted its exact public result",
            json!({"field":"public_value","id":id}),
        ));
    }
    mutation_result(mux, value, commit.revision, commit.replayed)
}

fn result_id<'a>(
    result: &'a Value,
    operation: &str,
    field: &str,
) -> Result<&'a str, ResourceError> {
    result[field].as_str().ok_or_else(|| {
        ResourceError::operation_failed(
            operation,
            "topology commit omitted its public identity",
            json!({"field":field}),
        )
    })
}

fn mutation(envelope: &RequestEnvelope) -> Result<WorkspaceMutation, ResourceError> {
    WorkspaceMutation::new(
        envelope.idempotency_key.clone().expect("catalog-validated mutations have a key"),
        "resource-api",
    )
    .map_err(resource_operation_error)
}

#[cfg(test)]
#[path = "topology_tests.rs"]
mod tests;
