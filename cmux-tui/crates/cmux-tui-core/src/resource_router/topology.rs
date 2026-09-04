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

fn create_workspace(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let initial_content = required_string(&request.fields, "initial_content")?;
    if initial_content != "empty" {
        return dispatch_exact_topology_mutation(mux, ResourceOperation::WorkspaceCreate, request);
    }
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
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Barrier, Mutex, mpsc};
    use std::time::{Duration, Instant};

    use super::*;
    use crate::SurfaceOptions;
    use crate::resource::{
        EnvelopeType, MachinePublicId, PanePublicId, RequestId, ScreenPublicId, SessionPublicId,
        TabPublicId, TerminalPublicId, WorkspacePublicId,
    };

    fn mux() -> Arc<Mux> {
        Mux::new_for_test("topology-router", SurfaceOptions::default())
    }

    fn parsed(
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        fields: Value,
        key: Option<&str>,
    ) -> ParsedResourceRequest {
        ParsedResourceRequest {
            envelope: RequestEnvelope {
                protocol: crate::resource::PROTOCOL.to_string(),
                envelope_type: EnvelopeType::Request,
                id: RequestId::parse("topology-test").unwrap(),
                operation,
                params: json!({}),
                idempotency_key: key.map(str::to_string),
            },
            selectors,
            fields: fields.as_object().unwrap().clone(),
        }
    }

    fn session_selectors() -> ResourceSelectors {
        ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..Default::default()
        }
    }

    fn selectors(
        workspace: Option<&str>,
        screen: Option<&str>,
        pane: Option<&str>,
        tab: Option<&str>,
    ) -> ResourceSelectors {
        ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: workspace.map(str::to_string),
            screen: screen.map(str::to_string),
            pane: pane.map(str::to_string),
            tab: tab.map(str::to_string),
            ..Default::default()
        }
    }

    fn terminal_selectors(terminal: &TerminalPublicId) -> ResourceSelectors {
        let mut selectors = session_selectors();
        selectors.terminal = Some(terminal.to_string());
        selectors
    }

    fn public_id(prefix: &str, index: usize) -> String {
        format!("{prefix}_{index:032x}")
    }

    fn resolved_path(
        workspace: Option<&str>,
        screen: Option<&str>,
        pane: Option<&str>,
        tab: Option<&str>,
    ) -> ResolvedResourcePath {
        ResolvedResourcePath {
            machine: MachinePublicId::parse(public_id("machine", 1)).unwrap(),
            session: Some(SessionPublicId::parse(public_id("session", 1)).unwrap()),
            workspace: workspace.map(|id| WorkspacePublicId::parse(id.to_string()).unwrap()),
            screen: screen.map(|id| ScreenPublicId::parse(id.to_string()).unwrap()),
            pane: pane.map(|id| PanePublicId::parse(id.to_string()).unwrap()),
            tab: tab.map(|id| TabPublicId::parse(id.to_string()).unwrap()),
            terminal: None,
            browser: None,
        }
    }

    fn terminal_workspace(mux: &Arc<Mux>, key: &str) -> Value {
        dispatch(
            mux,
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"terminal","name":key}),
                Some(key),
            ),
        )
        .unwrap()
    }

    #[test]
    fn thousand_resource_path_filter_builds_ancestry_once_and_stays_exact() {
        const RESOURCE_COUNT: usize = 1_000;
        const SCREENS_PER_WORKSPACE: usize = 10;

        let workspaces = (0..RESOURCE_COUNT / SCREENS_PER_WORKSPACE)
            .map(|index| json!({"id":public_id("ws", index)}))
            .collect::<Vec<_>>();
        let screens = (0..RESOURCE_COUNT)
            .map(|index| {
                json!({
                    "id":public_id("screen", index),
                    "workspace_id":public_id("ws", index / SCREENS_PER_WORKSPACE),
                })
            })
            .collect::<Vec<_>>();
        let panes = (0..RESOURCE_COUNT)
            .map(|index| {
                json!({
                    "id":public_id("pane", index),
                    "screen_id":public_id("screen", index),
                })
            })
            .collect::<Vec<_>>();
        let tabs = (0..RESOURCE_COUNT)
            .map(|index| {
                json!({
                    "id":public_id("tab", index),
                    "pane_id":public_id("pane", index),
                })
            })
            .collect::<Vec<_>>();
        let terminals = (0..RESOURCE_COUNT)
            .map(|index| {
                json!({
                    "id":public_id("term", index),
                    "tab_id":public_id("tab", index),
                })
            })
            .collect::<Vec<_>>();
        let snapshot = json!({
            "workspaces":workspaces,
            "screens":screens,
            "panes":panes,
            "tabs":tabs,
            "terminals":terminals,
        });

        // The three topology-sized indexes are built once. Every result below
        // then performs a fixed number of hash lookups instead of rebuilding
        // all three maps for each of the 1,000 candidates.
        let index = SnapshotPathIndex::new(&snapshot);
        assert_eq!(index.workspace_by_screen.len(), RESOURCE_COUNT);
        assert_eq!(index.screen_by_pane.len(), RESOURCE_COUNT);
        assert_eq!(index.pane_by_tab.len(), RESOURCE_COUNT);

        let target = 427;
        let workspace_id = public_id("ws", target / SCREENS_PER_WORKSPACE);
        let screen_id = public_id("screen", target);
        let pane_id = public_id("pane", target);
        let tab_id = public_id("tab", target);
        let terminal_values = snapshot["terminals"].as_array().unwrap();
        let workspace_path = resolved_path(Some(&workspace_id), None, None, None);

        let workspace_matches = terminal_values
            .iter()
            .filter(|value| index.contains("terminals", value, &workspace_path))
            .count();
        assert_eq!(workspace_matches, SCREENS_PER_WORKSPACE);

        let exact_path =
            resolved_path(Some(&workspace_id), Some(&screen_id), Some(&pane_id), Some(&tab_id));
        let exact_matches = terminal_values
            .iter()
            .filter(|value| index.contains("terminals", value, &exact_path))
            .collect::<Vec<_>>();
        assert_eq!(exact_matches.len(), 1);
        assert_eq!(exact_matches[0]["id"], public_id("term", target));

        let wrong_workspace = public_id("ws", target / SCREENS_PER_WORKSPACE + 1);
        let mismatched_path =
            resolved_path(Some(&wrong_workspace), Some(&screen_id), Some(&pane_id), Some(&tab_id));
        assert!(!index.contains("terminals", exact_matches[0], &mismatched_path,));

        let second_target = target + SCREENS_PER_WORKSPACE;
        let second_workspace = public_id("ws", second_target / SCREENS_PER_WORKSPACE);
        let second_screen = public_id("screen", second_target);
        let second_pane = public_id("pane", second_target);
        let second_tab = public_id("tab", second_target);
        let multiview = json!({
            "id":public_id("term", RESOURCE_COUNT + 1),
            "tab_id":tab_id,
            "tab_ids":[tab_id, second_tab],
        });
        assert!(index.contains("terminals", &multiview, &workspace_path));
        assert!(index.contains(
            "terminals",
            &multiview,
            &resolved_path(
                Some(&second_workspace),
                Some(&second_screen),
                Some(&second_pane),
                Some(&second_tab),
            ),
        ));

        let detached = json!({
            "id":public_id("term", RESOURCE_COUNT + 2),
            "tab_id":Value::Null,
            "tab_ids":[],
        });
        assert!(index.contains("terminals", &detached, &resolved_path(None, None, None, None)));
        assert!(!index.contains("terminals", &detached, &workspace_path));
    }

    #[test]
    fn handles_every_public_topology_operation() {
        for operation in [
            ResourceOperation::WorkspaceList,
            ResourceOperation::WorkspaceGet,
            ResourceOperation::WorkspaceCreate,
            ResourceOperation::WorkspaceRename,
            ResourceOperation::WorkspaceMove,
            ResourceOperation::WorkspaceFocus,
            ResourceOperation::WorkspaceClose,
            ResourceOperation::WorkspaceRun,
            ResourceOperation::WorkspaceLayoutApply,
            ResourceOperation::ScreenList,
            ResourceOperation::ScreenGet,
            ResourceOperation::ScreenCreate,
            ResourceOperation::ScreenRename,
            ResourceOperation::ScreenFocus,
            ResourceOperation::ScreenClose,
            ResourceOperation::ScreenLayoutExport,
            ResourceOperation::ScreenLayoutUndo,
            ResourceOperation::PaneList,
            ResourceOperation::PaneGet,
            ResourceOperation::PaneCreate,
            ResourceOperation::PaneSplit,
            ResourceOperation::PaneRename,
            ResourceOperation::PaneFocus,
            ResourceOperation::PaneFocusDirection,
            ResourceOperation::PaneNeighborGet,
            ResourceOperation::PaneSwap,
            ResourceOperation::PaneZoom,
            ResourceOperation::PaneSplitRatioSet,
            ResourceOperation::PaneViewportWidthSet,
            ResourceOperation::PaneClose,
            ResourceOperation::PaneRun,
            ResourceOperation::TabList,
            ResourceOperation::TabGet,
            ResourceOperation::TabCreateTerminal,
            ResourceOperation::TabCreateBrowser,
            ResourceOperation::TabRename,
            ResourceOperation::TabMove,
            ResourceOperation::TabFocus,
            ResourceOperation::TabClose,
        ] {
            assert!(handles(operation), "{operation:?}");
        }
        assert!(!handles(ResourceOperation::TerminalGet));
    }

    #[test]
    fn empty_workspace_create_replays_and_lists_exact_snapshot() {
        let mux = mux();
        let request = || {
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"empty","name":" exact "}),
                Some("workspace-once"),
            )
        };
        let first = dispatch(&mux, request()).unwrap();
        let replay = dispatch(&mux, request()).unwrap();
        assert_eq!(first["value"]["kind"], "workspace");
        assert_eq!(first["replayed"], false);
        assert_eq!(replay["value"], first["value"]);
        assert_eq!(replay["replayed"], true);

        let listed = dispatch(
            &mux,
            parsed(ResourceOperation::WorkspaceList, session_selectors(), json!({}), None),
        )
        .unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["name"], " exact ");
        assert!(listed[0]["id"].as_str().unwrap().starts_with("ws_"));
        assert!(listed[0].get("key").is_none());
    }

    #[test]
    fn workspace_rename_replay_returns_the_original_value_after_a_later_rename() {
        let mux = mux();
        let created = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"empty","name":"before"}),
                Some("rename-replay-create"),
            ),
        )
        .unwrap();
        let workspace = created["value"]["workspace_id"].as_str().unwrap();
        let original_request = || {
            parsed(
                ResourceOperation::WorkspaceRename,
                selectors(Some(workspace), None, None, None),
                json!({"name":"original committed name"}),
                Some("rename-replay-original"),
            )
        };

        let original = dispatch(&mux, original_request()).unwrap();
        dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceRename,
                selectors(Some(workspace), None, None, None),
                json!({"name":"later name"}),
                Some("rename-replay-later"),
            ),
        )
        .unwrap();
        let replay = dispatch(&mux, original_request()).unwrap();

        assert_eq!(original["value"]["name"], "original committed name");
        assert_eq!(replay["value"], original["value"]);
        assert_eq!(replay["revision"], original["revision"]);
        assert_eq!(replay["replayed"], true);
        let current = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceGet,
                selectors(Some(workspace), None, None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(current["name"], "later name");
        mux.shutdown();
    }

    #[test]
    fn workspace_move_replay_returns_the_original_index_after_a_later_move() {
        let mux = mux();
        let mut workspace_ids = Vec::new();
        for index in 0..3 {
            let created = dispatch(
                &mux,
                parsed(
                    ResourceOperation::WorkspaceCreate,
                    session_selectors(),
                    json!({"initial_content":"empty","name":format!("workspace {index}")}),
                    Some(&format!("move-replay-create-{index}")),
                ),
            )
            .unwrap();
            workspace_ids.push(created["value"]["workspace_id"].as_str().unwrap().to_string());
        }
        let workspace = &workspace_ids[0];
        let original_request = || {
            parsed(
                ResourceOperation::WorkspaceMove,
                selectors(Some(workspace), None, None, None),
                json!({"index":2}),
                Some("move-replay-original"),
            )
        };

        let original = dispatch(&mux, original_request()).unwrap();
        dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceMove,
                selectors(Some(workspace), None, None, None),
                json!({"index":0}),
                Some("move-replay-later"),
            ),
        )
        .unwrap();
        let replay = dispatch(&mux, original_request()).unwrap();

        assert_eq!(original["value"]["index"], 2);
        assert_eq!(replay["value"], original["value"]);
        assert_eq!(replay["revision"], original["revision"]);
        assert_eq!(replay["replayed"], true);
        let current = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceGet,
                selectors(Some(workspace), None, None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(current["index"], 0);
        mux.shutdown();
    }

    #[test]
    fn workspace_rename_replay_survives_a_later_delete() {
        let mux = mux();
        let created = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"empty","name":"before delete"}),
                Some("delete-replay-create"),
            ),
        )
        .unwrap();
        let workspace = created["value"]["workspace_id"].as_str().unwrap();
        let rename_request = || {
            parsed(
                ResourceOperation::WorkspaceRename,
                selectors(Some(workspace), None, None, None),
                json!({"name":"committed before delete"}),
                Some("delete-replay-rename"),
            )
        };

        let renamed = dispatch(&mux, rename_request()).unwrap();
        dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceClose,
                selectors(Some(workspace), None, None, None),
                json!({}),
                Some("delete-replay-close"),
            ),
        )
        .unwrap();
        let replay = dispatch(&mux, rename_request()).unwrap();

        assert_eq!(renamed["value"]["name"], "committed before delete");
        assert_eq!(replay["value"], renamed["value"]);
        assert_eq!(replay["revision"], renamed["revision"]);
        assert_eq!(replay["replayed"], true);
        assert!(
            dispatch(
                &mux,
                parsed(
                    ResourceOperation::WorkspaceGet,
                    selectors(Some(workspace), None, None, None),
                    json!({}),
                    None,
                ),
            )
            .is_err()
        );
        mux.shutdown();
    }

    #[test]
    fn browser_create_without_a_workspace_publishes_one_complete_batch() {
        let mux = mux();
        let request = || {
            parsed(
                ResourceOperation::TabCreateBrowser,
                session_selectors(),
                json!({"url":"about:blank#single-batch"}),
                Some("browser-single-batch"),
            )
        };

        let created = dispatch(&mux, request()).unwrap();
        assert_eq!(created["replayed"], false);
        assert_eq!(created["revision"], "1");
        let snapshot = public_session_snapshot(&mux).unwrap();
        assert_eq!(snapshot["session"]["revision"], "1");
        assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["browsers"].as_array().unwrap().len(), 1);
        assert_eq!(mux.resource_events_after(0).unwrap().batches.len(), 1);

        let replay = dispatch(&mux, request()).unwrap();
        assert_eq!(replay["value"], created["value"]);
        assert_eq!(replay["revision"], created["revision"]);
        assert_eq!(replay["replayed"], true);
        assert_eq!(mux.resource_events_after(0).unwrap().batches.len(), 1);
        mux.shutdown();
    }

    #[test]
    fn topology_closes_leave_terminal_lifetime_stream_unchanged() {
        for (operation, selector_field) in [
            (ResourceOperation::WorkspaceClose, "workspace_id"),
            (ResourceOperation::ScreenClose, "screen_id"),
            (ResourceOperation::PaneClose, "pane_id"),
            (ResourceOperation::TabClose, "tab_id"),
        ] {
            let mux = mux();
            let created = terminal_workspace(&mux, &format!("atomic-{selector_field}"));
            let id = created["value"][selector_field].as_str().unwrap();
            let selectors = match operation {
                ResourceOperation::WorkspaceClose => selectors(Some(id), None, None, None),
                ResourceOperation::ScreenClose => selectors(None, Some(id), None, None),
                ResourceOperation::PaneClose => selectors(None, None, Some(id), None),
                ResourceOperation::TabClose => selectors(None, None, None, Some(id)),
                _ => unreachable!(),
            };
            let key = format!("atomic-close-{selector_field}");
            let before_resource = mux.with_state(|state| state.resource_revision);
            let before_workspace = mux.with_state(|state| state.workspace_revision);
            let before_terminal = mux.terminal_registry_snapshot().unwrap().revision;
            let request = || parsed(operation, selectors.clone(), json!({}), Some(&key));

            let closed = dispatch(&mux, request()).unwrap();
            assert_eq!(closed["replayed"], false, "{operation:?}");
            assert_eq!(
                mux.with_state(|state| state.resource_revision),
                before_resource + 1,
                "{operation:?} public revision"
            );
            assert_eq!(
                mux.resource_events_after(before_resource).unwrap().batches.len(),
                1,
                "{operation:?} public events"
            );
            let expected_workspace =
                before_workspace + u64::from(operation == ResourceOperation::WorkspaceClose);
            assert_eq!(
                mux.with_state(|state| state.workspace_revision),
                expected_workspace,
                "{operation:?} workspace revision"
            );
            if operation == ResourceOperation::WorkspaceClose {
                let event = mux
                    .workspace_registry_event(expected_workspace)
                    .unwrap()
                    .expect("workspace close event");
                assert_eq!(event.kind, "workspace-closed");
                assert_eq!(event.mutation_id, key);
            }
            let (terminal_snapshot, terminal_events) =
                mux.terminal_registry_events_page(before_terminal).unwrap();
            assert_eq!(terminal_snapshot.revision, before_terminal, "{operation:?}");
            assert!(terminal_events.is_empty(), "{operation:?}");

            let replay = dispatch(&mux, request()).unwrap();
            assert_eq!(replay["replayed"], true, "{operation:?}");
            assert_eq!(replay["revision"], closed["revision"], "{operation:?}");
            assert_eq!(mux.resource_events_after(before_resource).unwrap().batches.len(), 1);
            assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, before_terminal);
            mux.shutdown();
        }
    }

    #[test]
    fn pane_close_detaches_views_without_settling_terminal_exit_waits() {
        let mux = mux();
        let created = terminal_workspace(&mux, "pane-close-exit-waits");
        let screen_id = created["value"]["screen_id"].as_str().unwrap();
        let first_pane_id = created["value"]["pane_id"].as_str().unwrap();
        let first_terminal =
            TerminalPublicId::parse(created["value"]["terminal_id"].as_str().unwrap()).unwrap();
        let second = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabCreateTerminal,
                selectors(None, None, Some(first_pane_id), None),
                json!({}),
                Some("pane-close-second-terminal"),
            ),
        )
        .unwrap();
        let second_terminal =
            TerminalPublicId::parse(second["value"]["terminal_id"].as_str().unwrap()).unwrap();
        let unrelated = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneCreate,
                selectors(None, Some(screen_id), None, None),
                json!({}),
                Some("pane-close-unrelated-terminal"),
            ),
        )
        .unwrap();
        let unrelated_terminal =
            TerminalPublicId::parse(unrelated["value"]["terminal_id"].as_str().unwrap()).unwrap();

        mux.reset_terminal_exit_state_query_count_for_test();
        let (settled_tx, settled_rx) = mpsc::channel();
        for terminal_id in
            [first_terminal.clone(), second_terminal.clone(), unrelated_terminal.clone()]
        {
            let waiting_mux = mux.clone();
            let settled_tx = settled_tx.clone();
            std::thread::spawn(move || {
                let result = waiting_mux.wait_for_terminal_exit(&terminal_id, None);
                let _ = settled_tx.send((terminal_id, result));
            });
        }
        drop(settled_tx);

        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&first_terminal) != 1
            || mux.terminal_exit_waiter_count_for_test(&second_terminal) != 1
            || mux.terminal_exit_waiter_count_for_test(&unrelated_terminal) != 1
            || mux.terminal_exit_state_query_count_for_test() != 3
        {
            assert!(Instant::now() < waiting_deadline, "exit waits did not subscribe");
            std::thread::yield_now();
        }

        dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneClose,
                selectors(None, None, Some(first_pane_id), None),
                json!({}),
                Some("close-pane-with-exit-waits"),
            ),
        )
        .unwrap();
        assert!(settled_rx.recv_timeout(Duration::from_millis(100)).is_err());
        assert_eq!(mux.terminal_exit_state_query_count_for_test(), 3);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&first_terminal), 1);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&second_terminal), 1);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&unrelated_terminal), 1);

        for (index, expected_terminal) in
            [first_terminal, second_terminal, unrelated_terminal].into_iter().enumerate()
        {
            crate::resource_router::dispatch_resource_request(
                &mux,
                parsed(
                    ResourceOperation::TerminalClose,
                    terminal_selectors(&expected_terminal),
                    json!({}),
                    Some(&format!("explicit-close-after-pane-detach-{index}")),
                ),
            )
            .unwrap();
            let (terminal_id, result) = settled_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("explicit terminal close stranded its exit wait");
            assert_eq!(terminal_id, expected_terminal);
            let error = result.unwrap_err();
            let resource = error
                .downcast_ref::<ResourceError>()
                .expect("explicit terminal close returns a typed resource error");
            assert_eq!(resource.code, "terminal.closed");
            assert_eq!(resource.details["terminal_id"], terminal_id.as_str());
            assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);
        }
        assert_eq!(mux.terminal_exit_state_query_count_for_test(), 6);
        mux.shutdown();
    }

    #[test]
    fn topology_close_commit_failure_leaves_every_projection_live_and_fences_replay() {
        let mux = mux();
        let created = terminal_workspace(&mux, "atomic-close-rollback");
        let workspace = created["value"]["workspace_id"].as_str().unwrap();
        let before_resource = mux.with_state(|state| state.resource_revision);
        let before_workspace = mux.with_state(|state| state.workspace_revision);
        let before_terminal = mux.terminal_registry_snapshot().unwrap().revision;
        mux.set_resource_patch_failure_for_test(true);

        let error = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceClose,
                selectors(Some(workspace), None, None, None),
                json!({}),
                Some("atomic-close-rollback-effect"),
            ),
        )
        .unwrap_err();
        assert_eq!(error.code, "mutation.indeterminate");
        mux.set_resource_patch_failure_for_test(false);

        let replay = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceClose,
                selectors(Some(workspace), None, None, None),
                json!({}),
                Some("atomic-close-rollback-effect"),
            ),
        )
        .unwrap_err();
        assert_eq!(replay.code, "mutation.indeterminate");

        assert_eq!(mux.with_state(|state| state.resource_revision), before_resource);
        assert_eq!(mux.with_state(|state| state.workspace_revision), before_workspace);
        assert_eq!(mux.terminal_registry_snapshot().unwrap().revision, before_terminal);
        assert!(mux.resource_events_after(before_resource).unwrap().batches.is_empty());
        assert!(mux.workspace_registry_event(before_workspace + 1).unwrap().is_none());
        assert!(mux.terminal_registry_events_page(before_terminal).unwrap().1.is_empty());
        let snapshot = public_session_snapshot(&mux).unwrap();
        assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["terminals"].as_array().unwrap().len(), 1);
        mux.shutdown();
    }

    #[test]
    fn workspace_get_accepts_direct_id_without_repeating_ancestors() {
        let mux = mux();
        let created = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"empty","name":"direct"}),
                Some("workspace-direct"),
            ),
        )
        .unwrap();
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let selected = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some(workspace.clone()),
            ..Default::default()
        };
        let value =
            dispatch(&mux, parsed(ResourceOperation::WorkspaceGet, selected, json!({}), None))
                .unwrap();
        assert_eq!(value["id"], workspace);
        assert_eq!(value["name"], "direct");
    }

    #[test]
    fn terminal_backed_workspace_create_is_exact_and_replay_safe() {
        let mux = mux();
        let reservations = Arc::new(Mutex::new(Vec::new()));
        let observed = Arc::clone(&reservations);
        let inspected_mux = Arc::clone(&mux);
        mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new(move |terminal_id| {
            let lifecycle = inspected_mux
                .resource_terminal_lifecycle_for_test(terminal_id)
                .unwrap()
                .expect("reservation hook observes a durable terminal");
            observed.lock().unwrap().push((terminal_id.to_string(), lifecycle));
        })));
        let request = || {
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"terminal","name":"effect"}),
                Some("workspace-terminal-once"),
            )
        };
        let first = dispatch(&mux, request()).unwrap();
        let replay = dispatch(&mux, request()).unwrap();
        assert_eq!(first["value"]["kind"], "terminal");
        assert_eq!(first["revision"], "1");
        assert_eq!(first["replayed"], false);
        assert_eq!(replay["value"], first["value"]);
        assert_eq!(replay["revision"], first["revision"]);
        assert_eq!(replay["replayed"], true);
        let reservations = reservations.lock().unwrap();
        assert_eq!(reservations.len(), 1, "replay must not reserve or spawn another host");
        let (host_id, (lifecycle_at_spawn, incarnation_at_spawn)) = &reservations[0];
        assert_eq!(lifecycle_at_spawn, "launching");
        assert_eq!(incarnation_at_spawn, &None);
        assert_eq!(host_id.len(), 32);
        assert_ne!(first["value"]["terminal_id"].as_str().unwrap(), host_id);
        let (final_lifecycle, final_incarnation) = mux
            .resource_terminal_lifecycle_for_test(host_id)
            .unwrap()
            .expect("created terminal keeps its durable registry row");
        assert_eq!(final_lifecycle, "running");
        assert!(final_incarnation.is_some());
        drop(reservations);
        mux.set_resource_terminal_reservation_hook_for_test(None);
        for field in ["workspace_id", "screen_id", "pane_id", "tab_id", "terminal_id"] {
            assert!(first["value"][field].as_str().is_some(), "{field}");
        }
        let snapshot = public_session_snapshot(&mux).unwrap();
        assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["screens"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["panes"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["tabs"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["terminals"].as_array().unwrap().len(), 1);
        assert_eq!(mux.resource_event_epoch(), 1);
        let events = mux.resource_events_after(0).unwrap();
        assert_eq!(events.batches.len(), 1);
        assert_eq!(events.batches[0].revision, 1);
    }

    #[test]
    fn terminal_creation_retries_one_shot_projection_failure_without_a_second_batch() {
        let mux = mux();
        mux.set_resource_patch_failures_remaining_for_test(1);
        let request = || {
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({
                    "initial_content":"terminal",
                    "name":"projection retry",
                    "correlation_key":"projection-retry-correlation",
                }),
                Some("projection-retry-attempt"),
            )
        };

        let created = dispatch(&mux, request()).unwrap();
        assert_eq!(created["revision"], "1");
        assert_eq!(created["replayed"], false);
        assert_eq!(mux.resource_event_epoch(), 1);
        let events = mux.resource_events_after(0).unwrap();
        assert_eq!(events.batches.len(), 1);
        assert_eq!(events.batches[0].revision, 1);
        let replay = dispatch(&mux, request()).unwrap();
        assert_eq!(replay["value"], created["value"]);
        assert_eq!(replay["revision"], "1");
        assert_eq!(replay["replayed"], true);
        assert_eq!(mux.resource_event_epoch(), 1);
        assert_eq!(mux.resource_events_after(0).unwrap().batches.len(), 1);
        assert_eq!(
            mux.resource_creation_resolution("projection-retry-correlation").unwrap()["state"],
            "created"
        );
        mux.shutdown();
    }

    #[test]
    fn concurrent_correlated_creations_serialize_before_their_durable_reservations() {
        let mux = mux();
        let reservation_calls = Arc::new(AtomicUsize::new(0));
        let first_reservation = Arc::new(Barrier::new(2));
        let release_first = Arc::new(Barrier::new(2));
        mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new({
            let reservation_calls = Arc::clone(&reservation_calls);
            let first_reservation = Arc::clone(&first_reservation);
            let release_first = Arc::clone(&release_first);
            move |_| {
                if reservation_calls.fetch_add(1, Ordering::AcqRel) == 0 {
                    first_reservation.wait();
                    release_first.wait();
                }
            }
        })));

        let (started_tx, started_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        let first = {
            let mux = Arc::clone(&mux);
            let result_tx = result_tx.clone();
            std::thread::spawn(move || {
                started_tx.send("first").unwrap();
                result_tx
                    .send(dispatch(
                        &mux,
                        parsed(
                            ResourceOperation::WorkspaceCreate,
                            session_selectors(),
                            json!({
                                "initial_content":"terminal",
                                "name":"concurrent first",
                                "correlation_key":"concurrent-first-correlation",
                            }),
                            Some("concurrent-first-attempt"),
                        ),
                    ))
                    .unwrap();
            })
        };
        assert_eq!(started_rx.recv_timeout(Duration::from_secs(1)).unwrap(), "first");
        first_reservation.wait();

        let second = {
            let mux = Arc::clone(&mux);
            std::thread::spawn(move || {
                result_tx
                    .send(dispatch(
                        &mux,
                        parsed(
                            ResourceOperation::WorkspaceCreate,
                            session_selectors(),
                            json!({
                                "initial_content":"terminal",
                                "name":"concurrent second",
                                "correlation_key":"concurrent-second-correlation",
                            }),
                            Some("concurrent-second-attempt"),
                        ),
                    ))
                    .unwrap();
            })
        };
        assert!(
            result_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "the second creation completed while the first reservation was staged"
        );
        assert_eq!(
            reservation_calls.load(Ordering::Acquire),
            1,
            "the second creation reserved durable identity before the first settled"
        );
        release_first.wait();

        let mut revisions = [
            result_rx.recv_timeout(Duration::from_secs(5)).unwrap().unwrap()["revision"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap(),
            result_rx.recv_timeout(Duration::from_secs(5)).unwrap().unwrap()["revision"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap(),
        ];
        first.join().unwrap();
        second.join().unwrap();
        revisions.sort_unstable();
        assert_eq!(revisions, [1, 2]);
        assert_eq!(reservation_calls.load(Ordering::Acquire), 2);
        assert_eq!(mux.resource_event_epoch(), 2);
        assert_eq!(mux.resource_events_after(0).unwrap().batches.len(), 2);
        for correlation in ["concurrent-first-correlation", "concurrent-second-correlation"] {
            assert_eq!(mux.resource_creation_resolution(correlation).unwrap()["state"], "created");
        }
        mux.set_resource_terminal_reservation_hook_for_test(None);
        mux.shutdown();
    }

    #[test]
    fn every_terminal_topology_effect_reserves_before_spawn() {
        let mux = mux();
        let reservations = Arc::new(Mutex::new(Vec::new()));
        let observed = Arc::clone(&reservations);
        let inspected_mux = Arc::clone(&mux);
        mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new(move |terminal_id| {
            let lifecycle = inspected_mux
                .resource_terminal_lifecycle_for_test(terminal_id)
                .unwrap()
                .expect("reservation hook observes a durable terminal");
            observed.lock().unwrap().push((terminal_id.to_string(), lifecycle));
        })));

        let created = terminal_workspace(&mux, "all-terminal-effects");
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let workspace_run = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceRun,
                selectors(Some(&workspace), None, None, None),
                json!({"shell":"printf workspace-run"}),
                Some("all-workspace-run"),
            ),
        )
        .unwrap();
        let screen = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenCreate,
                selectors(Some(&workspace), None, None, None),
                json!({"name":"reserved-screen"}),
                Some("all-screen-create"),
            ),
        )
        .unwrap();
        let screen_id = screen["value"]["screen_id"].as_str().unwrap().to_string();
        let pane = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneCreate,
                selectors(None, Some(&screen_id), None, None),
                json!({}),
                Some("all-pane-create"),
            ),
        )
        .unwrap();
        let pane_id = pane["value"]["pane_id"].as_str().unwrap().to_string();
        let split = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneSplit,
                selectors(None, None, Some(&pane_id), None),
                json!({"direction":"right","viewport_width":0.5}),
                Some("all-pane-split"),
            ),
        )
        .unwrap();
        let pane_run = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneRun,
                selectors(None, None, Some(&pane_id), None),
                json!({"shell":"printf pane-run"}),
                Some("all-pane-run"),
            ),
        )
        .unwrap();
        let tab = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabCreateTerminal,
                selectors(None, None, Some(&pane_id), None),
                json!({"name":"reserved-tab"}),
                Some("all-tab-create"),
            ),
        )
        .unwrap();
        let values = [&created, &workspace_run, &screen, &pane, &split, &pane_run, &tab];
        for value in values {
            assert_eq!(value["value"]["kind"], "terminal");
        }
        let resource_revisions = values
            .iter()
            .map(|value| value["revision"].as_str().unwrap().parse::<u64>().unwrap())
            .collect::<Vec<_>>();
        assert!(
            resource_revisions.windows(2).all(|pair| pair[1] == pair[0] + 1),
            "terminal lifecycle commits must not consume public resource revisions"
        );

        let reservations = reservations.lock().unwrap();
        assert_eq!(reservations.len(), 7);
        let mut host_ids =
            reservations.iter().map(|(terminal_id, _)| terminal_id).collect::<Vec<_>>();
        host_ids.sort();
        host_ids.dedup();
        assert_eq!(host_ids.len(), 7);
        for (terminal_id, (lifecycle, incarnation)) in reservations.iter() {
            assert_eq!(lifecycle, "launching");
            assert_eq!(incarnation, &None);
            let (final_lifecycle, final_incarnation) = mux
                .resource_terminal_lifecycle_for_test(terminal_id)
                .unwrap()
                .expect("created terminal keeps its durable registry row");
            assert_eq!(final_lifecycle, "running");
            assert!(final_incarnation.is_some());
        }
        drop(reservations);
        mux.set_resource_terminal_reservation_hook_for_test(None);
        assert_eq!(
            public_session_snapshot(&mux).unwrap()["terminals"].as_array().unwrap().len(),
            7
        );
        let snapshot = public_session_snapshot(&mux).unwrap();
        let created_screen = snapshot["screens"]
            .as_array()
            .unwrap()
            .iter()
            .find(|candidate| candidate["id"] == screen_id)
            .unwrap();
        assert_eq!(created_screen["layout"]["root"]["kind"], "viewport");
        assert_eq!(created_screen["layout"]["root"]["columns"][1]["width"], 0.5);
    }

    #[test]
    fn topology_create_focus_rename_and_close_round_trip() {
        let mux = mux();
        let created = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceCreate,
                session_selectors(),
                json!({"initial_content":"terminal","name":"round-trip"}),
                Some("round-workspace"),
            ),
        )
        .unwrap();
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let workspace_selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some(workspace),
            ..Default::default()
        };
        let screen = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenCreate,
                workspace_selectors,
                json!({"name":"second"}),
                Some("round-screen"),
            ),
        )
        .unwrap();
        let screen_id = screen["value"]["screen_id"].as_str().unwrap().to_string();
        let pane_id = screen["value"]["pane_id"].as_str().unwrap().to_string();
        let screen_selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            screen: Some(screen_id.clone()),
            ..Default::default()
        };
        let renamed = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenRename,
                screen_selectors.clone(),
                json!({"name":"renamed"}),
                Some("round-rename"),
            ),
        )
        .unwrap();
        assert_eq!(renamed["value"]["id"], screen_id);
        assert_eq!(renamed["value"]["name"], "renamed");

        let pane_selectors = ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            pane: Some(pane_id),
            ..Default::default()
        };
        let split = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneSplit,
                pane_selectors,
                json!({"direction":"left","ratio":0.4}),
                Some("round-split"),
            ),
        )
        .unwrap();
        assert_eq!(split["value"]["kind"], "terminal");
        assert_ne!(split["value"]["pane_id"], screen["value"]["pane_id"]);

        let closed = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenClose,
                screen_selectors,
                json!({}),
                Some("round-close"),
            ),
        )
        .unwrap();
        assert_eq!(closed["value"], json!({}));
        assert!(
            public_session_snapshot(&mux).unwrap()["screens"]
                .as_array()
                .unwrap()
                .iter()
                .all(|value| value["id"] != screen_id)
        );
    }

    #[test]
    fn direct_screen_pane_and_tab_ids_scope_reads_without_ancestor_repetition() {
        let mux = mux();
        let created = terminal_workspace(&mux, "direct-descendants");
        let workspace = created["value"]["workspace_id"].as_str().unwrap();
        let screen = created["value"]["screen_id"].as_str().unwrap();
        let pane = created["value"]["pane_id"].as_str().unwrap();
        let tab = created["value"]["tab_id"].as_str().unwrap();

        let screen_value = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenGet,
                selectors(None, Some(screen), None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(screen_value["id"], screen);
        assert_eq!(screen_value["workspace_id"], workspace);

        let pane_value = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneGet,
                selectors(None, None, Some(pane), None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(pane_value["id"], pane);
        assert_eq!(pane_value["screen_id"], screen);

        let tab_value = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabGet,
                selectors(None, None, None, Some(tab)),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(tab_value["id"], tab);
        assert_eq!(tab_value["pane_id"], pane);

        let screens = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenList,
                selectors(Some(workspace), None, None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        let panes = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneList,
                selectors(None, Some(screen), None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        let tabs = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabList,
                selectors(None, None, Some(pane), None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(screens.as_array().unwrap().len(), 1);
        assert_eq!(panes.as_array().unwrap().len(), 1);
        assert_eq!(tabs.as_array().unwrap().len(), 1);
    }

    #[test]
    fn final_source_tab_move_collapses_source_pane_and_replays() {
        let mux = mux();
        let created = terminal_workspace(&mux, "structural-tab-move");
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
        let target_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
        let split = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneSplit,
                selectors(None, None, Some(&target_pane), None),
                json!({"direction":"right","ratio":0.5}),
                Some("structural-split"),
            ),
        )
        .unwrap();
        let source_pane = split["value"]["pane_id"].as_str().unwrap().to_string();
        let tab = split["value"]["tab_id"].as_str().unwrap().to_string();
        assert_ne!(source_pane, target_pane);

        let move_request = || {
            parsed(
                ResourceOperation::TabMove,
                selectors(None, None, None, Some(&tab)),
                json!({
                    "destination_workspace":workspace,
                    "destination_screen":screen,
                    "destination_pane":target_pane,
                    "index":1,
                }),
                Some("structural-move"),
            )
        };
        let moved = dispatch(&mux, move_request()).unwrap();
        let replay = dispatch(&mux, move_request()).unwrap();
        assert_eq!(moved["value"]["id"], tab);
        assert_eq!(moved["value"]["pane_id"], target_pane);
        assert_eq!(moved["value"]["index"], 1);
        assert_eq!(moved["replayed"], false);
        assert_eq!(replay["value"], moved["value"]);
        assert_eq!(replay["revision"], moved["revision"]);
        assert_eq!(replay["replayed"], true);

        let snapshot = public_session_snapshot(&mux).unwrap();
        assert_eq!(snapshot["panes"].as_array().unwrap().len(), 1);
        assert!(snapshot["panes"].as_array().unwrap().iter().all(|pane| pane["id"] != source_pane));
        assert_eq!(snapshot["tabs"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn layout_apply_round_trips_and_rejects_dropped_tabs_before_receipt() {
        let mux = mux();
        let created = terminal_workspace(&mux, "layout-round-trip");
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
        let pane = created["value"]["pane_id"].as_str().unwrap().to_string();
        dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneSplit,
                selectors(None, None, Some(&pane), None),
                json!({"direction":"right","ratio":0.5}),
                Some("layout-split"),
            ),
        )
        .unwrap();
        let exported = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenLayoutExport,
                selectors(None, Some(&screen), None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(exported["version"], 1);
        assert_eq!(exported["root"]["kind"], "split");
        assert_eq!(exported["root"]["ratio"], 0.5);

        let mut missing_tab = exported.clone();
        missing_tab["root"]["first"]["tab_ids"] = json!([]);
        assert!(
            dispatch(
                &mux,
                parsed(
                    ResourceOperation::WorkspaceLayoutApply,
                    selectors(Some(&workspace), None, None, None),
                    json!({"layout":missing_tab}),
                    Some("layout-validation-before-receipt"),
                ),
            )
            .is_err()
        );

        let mut changed = exported;
        changed["root"]["ratio"] = json!(0.3);
        let apply_request = || {
            parsed(
                ResourceOperation::WorkspaceLayoutApply,
                selectors(Some(&workspace), None, None, None),
                json!({"layout":changed}),
                Some("layout-validation-before-receipt"),
            )
        };
        let applied = dispatch(&mux, apply_request()).unwrap();
        let replay = dispatch(&mux, apply_request()).unwrap();
        assert_eq!(applied["value"]["id"], workspace);
        assert_eq!(applied["replayed"], false);
        assert_eq!(replay["value"], applied["value"]);
        assert_eq!(replay["revision"], applied["revision"]);
        assert_eq!(replay["replayed"], true);

        let changed_export = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenLayoutExport,
                selectors(None, Some(&screen), None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert!(
            (changed_export["root"]["ratio"].as_f64().unwrap() - 0.3).abs() < f64::EPSILON * 1e9
        );

        let undone = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenLayoutUndo,
                selectors(None, Some(&screen), None, None),
                json!({"confirm_close":false}),
                Some("layout-undo"),
            ),
        )
        .unwrap();
        assert_eq!(undone["value"]["id"], screen);
        assert_eq!(undone["value"]["layout"]["root"]["ratio"], 0.5);
    }

    #[test]
    fn pure_topology_mutations_preserve_exact_public_snapshots() {
        let mux = mux();
        let created = terminal_workspace(&mux, "pure-topology");
        let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
        let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
        let first_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
        let first_tab = created["value"]["tab_id"].as_str().unwrap().to_string();

        let second_tab = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabCreateTerminal,
                selectors(None, None, Some(&first_pane), None),
                json!({"name":"second tab"}),
                Some("pure-second-tab"),
            ),
        )
        .unwrap();
        let second_tab_id = second_tab["value"]["tab_id"].as_str().unwrap().to_string();
        let renamed_tab = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabRename,
                selectors(None, None, None, Some(&first_tab)),
                json!({"name":"renamed tab"}),
                Some("pure-rename-tab"),
            ),
        )
        .unwrap();
        assert_eq!(renamed_tab["value"]["name"], "renamed tab");
        let focused_tab = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabFocus,
                selectors(None, None, None, Some(&first_tab)),
                json!({}),
                Some("pure-focus-tab"),
            ),
        )
        .unwrap();
        assert_eq!(focused_tab["value"]["focused"], true);
        assert_eq!(
            dispatch(
                &mux,
                parsed(
                    ResourceOperation::TabGet,
                    selectors(None, None, None, Some(&second_tab_id)),
                    json!({}),
                    None,
                ),
            )
            .unwrap()["focused"],
            false
        );

        let split = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneSplit,
                selectors(None, None, Some(&first_pane), None),
                json!({"direction":"right","ratio":0.4}),
                Some("pure-split"),
            ),
        )
        .unwrap();
        let second_pane = split["value"]["pane_id"].as_str().unwrap().to_string();
        let renamed_pane = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneRename,
                selectors(None, None, Some(&second_pane), None),
                json!({"name":"renamed pane"}),
                Some("pure-rename-pane"),
            ),
        )
        .unwrap();
        assert_eq!(renamed_pane["value"]["name"], "renamed pane");
        let neighbor = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneNeighborGet,
                selectors(None, None, Some(&first_pane), None),
                json!({"direction":"right"}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(neighbor["pane"]["id"], second_pane);
        let focused_pane = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneFocusDirection,
                selectors(None, None, Some(&first_pane), None),
                json!({"direction":"right"}),
                Some("pure-focus-direction"),
            ),
        )
        .unwrap();
        assert_eq!(focused_pane["value"]["id"], second_pane);
        assert_eq!(focused_pane["value"]["focused"], true);

        let zoomed = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneZoom,
                selectors(None, None, Some(&second_pane), None),
                json!({"enabled":true}),
                Some("pure-zoom"),
            ),
        )
        .unwrap();
        assert_eq!(zoomed["value"]["zoomed"], true);

        let layout = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenLayoutExport,
                selectors(None, Some(&screen), None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        let split_id = layout["root"]["split_id"].as_str().unwrap();
        let resized = dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneSplitRatioSet,
                selectors(None, None, Some(&second_pane), None),
                json!({"split_id":split_id,"ratio":0.25}),
                Some("pure-ratio"),
            ),
        )
        .unwrap();
        assert_eq!(resized["value"]["id"], second_pane);
        let resized_layout = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenLayoutExport,
                selectors(None, Some(&screen), None, None),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(resized_layout["root"]["ratio"], 0.25);

        let renamed_screen = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenRename,
                selectors(None, Some(&screen), None, None),
                json!({"name":"renamed screen"}),
                Some("pure-rename-screen"),
            ),
        )
        .unwrap();
        assert_eq!(renamed_screen["value"]["name"], "renamed screen");
        let focused_screen = dispatch(
            &mux,
            parsed(
                ResourceOperation::ScreenFocus,
                selectors(None, Some(&screen), None, None),
                json!({}),
                Some("pure-focus-screen"),
            ),
        )
        .unwrap();
        assert_eq!(focused_screen["value"]["focused"], true);
        let focused_workspace = dispatch(
            &mux,
            parsed(
                ResourceOperation::WorkspaceFocus,
                selectors(Some(&workspace), None, None, None),
                json!({}),
                Some("pure-focus-workspace"),
            ),
        )
        .unwrap();
        assert_eq!(focused_workspace["value"]["focused"], true);
    }
}
