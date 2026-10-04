//! `app-screens-v1` on the raw wire (plans/cmux-next/app-screens.md):
//! `new-app-tab`, and the screen fields of the raw tree (`kind`, `app`). A
//! connection that did not negotiate the capability reads an app tab as a
//! frontend `browser` tab (conversation_tabs_wire.rs projection).

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::{Mux, PaneId, WorkspaceId, paired_surface_size};
use crate::model::{Screen, State};
use crate::state::app_screens::AppTabTarget;
use crate::state::app_screens_store::AppTabRecord;
use crate::workspace_registry::WorkspaceMutation;

/// `new-app-tab`: a tab showing `app` (at `route`), placed like
/// `new-frontend-browser-tab`. With `idempotency_key` a retry returns the
/// tab the first request created.
#[derive(Deserialize)]
pub(super) struct NewAppTabParams {
    app: String,
    #[serde(default)]
    route: Option<String>,
    #[serde(default)]
    pane: Option<PaneId>,
    /// A workspace to put the tab in (its first pane when it is empty).
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

const NEW_APP_TAB_ORIGIN: &str = "new-app-tab";

pub(super) fn new_app_tab(mux: &Arc<Mux>, params: NewAppTabParams) -> anyhow::Result<Value> {
    let NewAppTabParams { app, route, pane, workspace, idempotency_key, cols, rows } = params;
    let target = match (pane, workspace) {
        (_, None) => AppTabTarget::Pane(pane),
        (None, Some(workspace)) => AppTabTarget::Workspace(workspace),
        (Some(_), Some(_)) => anyhow::bail!("bad request: send pane or workspace, not both"),
    };
    let mutation =
        idempotency_key.map(|key| WorkspaceMutation::new(key, NEW_APP_TAB_ORIGIN)).transpose()?;
    let size = paired_surface_size("new-app-tab", cols, rows)?;
    let record = AppTabRecord { app, route };
    let outcome = mux.new_app_tab(target, record, mutation.as_ref(), size)?;
    let identity = outcome.surface.resource_identity();
    Ok(json!({
        "surface": outcome.surface.id,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
        "replayed": outcome.replayed,
    }))
}

/// `create-workspace {initial: {app, route?}}`: the new workspace starts
/// with one app tab instead of being empty, in one commit.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct InitialApp {
    app: String,
    #[serde(default)]
    route: Option<String>,
}

pub(super) fn create_workspace(
    mux: &Arc<Mux>,
    name: Option<String>,
    key: Option<String>,
    initial: InitialApp,
    request: &super::MutationRequest,
    mutation: &WorkspaceMutation,
) -> anyhow::Result<Value> {
    anyhow::ensure!(
        request.expected_generation.is_none(),
        "bad request: expected_generation is not supported with initial"
    );
    let record = AppTabRecord { app: initial.app, route: initial.route };
    let (surface, replayed) = mux.state_create_app_workspace(
        name,
        key,
        false,
        record,
        request.expected_revision,
        mutation,
    )?;
    let placed = mux.with_state(|state| {
        let pane = state.pane_of(surface)?;
        let (index, _) = state.screen_of(pane)?;
        let workspace = &state.workspaces[index];
        let identity = state.surfaces.get(&surface)?.resource_identity().cloned()?;
        Some((workspace.id, workspace.key.clone(), index, state.workspace_revision, identity))
    });
    let (workspace, key, index, revision, identity) =
        placed.ok_or_else(|| anyhow::anyhow!("the created app tab disappeared"))?;
    let (registry_id, generation) = mux.registry_identity();
    Ok(json!({
        "workspace": workspace,
        "key": key,
        "index": index,
        "workspace_revision": revision,
        "replayed": replayed,
        "registry_id": registry_id,
        "generation": generation,
        "surface": surface,
        "tab_resource_id": identity.tab_id.as_str(),
        "content_resource_id": identity.content_id.as_str(),
    }))
}

/// The app fields of one raw screen: `kind` and `app` on an app screen; an
/// ordinary screen gets nothing.
pub(super) fn merge_screen_fields(state: &State, screen: &Screen, value: &mut Value) {
    let Some(app) = state.resource_indexes.screen_apps.get(&screen.id) else { return };
    value["kind"] = json!(app.kind.as_str());
    value["app"] = json!(app.app);
}

#[cfg(test)]
#[path = "app_screens_tests.rs"]
mod tests;
