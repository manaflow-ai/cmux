//! Browser tab creation under a reserved identity (the resource effect of
//! `tab.create_browser`), moved out of mux.rs. `activate` false adds the tab
//! to an existing pane without making it the active tab
//! (`frontend-browser-activate-v1`).

use super::*;
use crate::resource::BrowserPublicId;

/// Advertised by `identify` once `new-frontend-browser-tab` takes `activate`.
pub(crate) const FRONTEND_BROWSER_ACTIVATE_CAPABILITY: &str = "frontend-browser-activate-v1";

/// Internal `tab.create_browser` field (never accepted from a v2 client):
/// `false` when the tab must not become its pane's active tab.
pub(crate) const ACTIVATE_FIELD: &str = "frontend_browser_activate";

/// The internal fields of a frontend browser tab's `tab.create_browser`:
/// its registered browser id, and [`ACTIVATE_FIELD`] when it stays in the
/// background.
pub(crate) fn frontend_fields(browser_id: &BrowserPublicId, activate: bool) -> Map<String, Value> {
    let mut fields = Map::from_iter([(
        "frontend_browser_id".to_string(),
        Value::String(browser_id.as_str().to_string()),
    )]);
    if !activate {
        fields.insert(ACTIVATE_FIELD.to_string(), Value::Bool(false));
    }
    fields
}

impl Mux {
    /// The `tab.create_browser` effect in an existing pane: the URL and
    /// [`ACTIVATE_FIELD`] come from the operation's fields.
    pub(super) fn new_browser_tab_for_effect(
        self: &Arc<Self>,
        fields: &Map<String, Value>,
        pane: PaneId,
        size: Option<(u16, u16)>,
        identity: TabResourceIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        let url = fields
            .get("url")
            .and_then(Value::as_str)
            .context("bad request: tab.create_browser needs a url")?
            .to_string();
        let activate = fields.get(ACTIVATE_FIELD).and_then(Value::as_bool).unwrap_or(true);
        self.new_browser_tab_reserved(url, Some(pane), size, identity, None, activate)
    }

    /// A browser tab under a reserved identity. With `activate` false
    /// (`frontend-browser-activate-v1`) a tab added to an existing pane does
    /// not become its active tab and does not bump the pane's focus order.
    pub(crate) fn new_browser_tab_reserved(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        resource_identity: TabResourceIdentity,
        workspace_key: Option<String>,
        activate: bool,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_with_resource_identity(
            url,
            pane,
            size,
            Some(resource_identity),
            workspace_key,
            activate,
        )
    }

    fn new_browser_tab_with_resource_identity(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        resource_identity: Option<TabResourceIdentity>,
        workspace_key: Option<String>,
        activate: bool,
    ) -> anyhow::Result<Arc<Surface>> {
        let (target, empty_workspace) = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            let empty_workspace = target
                .is_none()
                .then(|| state.workspaces.get(state.active_workspace))
                .flatten()
                .filter(|workspace| workspace.screens.is_empty())
                .map(|workspace| workspace.id);
            (target, empty_workspace)
        };
        let Some(target) = target else {
            if let Some(workspace) = empty_workspace {
                return self.create_browser_surface_in_workspace(
                    workspace,
                    url,
                    size,
                    resource_identity,
                );
            }
            let workspace_key = match workspace_key {
                Some(workspace_key) => workspace_key,
                None => Self::new_workspace_key()?,
            };
            let surface = self.spawn_browser_surface_with_resource_identity(
                url,
                size,
                None,
                resource_identity,
            )?;
            let (pane_id, pane) = self.make_pane(surface.id)?;
            let screen_id = self.next_id();
            let ws_id = self.next_id();
            let notifications = self.tree_decorations();
            if let Some(workspace_id) = empty_workspace {
                let delta = {
                    let mut state = self.state.lock().unwrap();
                    let Some(workspace_index) =
                        state.workspaces.iter().position(|workspace| workspace.id == workspace_id)
                    else {
                        state.surfaces.remove(&surface.id);
                        surface.kill();
                        anyhow::bail!("workspace disappeared while creating browser tab");
                    };
                    state.insert_pane(pane);
                    stamp_pane_focus(self, &mut state, pane_id);
                    state.workspaces[workspace_index].screens.push(Screen {
                        id: screen_id,
                        public_id: ScreenPublicId::random()?,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                        viewport_splits: Default::default(),
                        viewport_base_width: None,
                        layout_columns: Vec::new(),
                        layout_revision: 0,
                        layout_undo: Default::default(),
                    });
                    state.workspaces[workspace_index].active_screen = 0;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::ScreenAdded,
                        screen_id,
                    )
                    .expect("first workspace screen is present in tree snapshot");
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace: workspace_id,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    }
                };
                self.emit(MuxEvent::TreeDelta(delta));
                self.reap_if_dead(&surface);
                return Ok(surface);
            }
            let mutation = WorkspaceMutation::local("cmux-tui");
            let workspace_public_id = WorkspacePublicId::random()?;
            let mut registry = self.workspace_registry.lock().unwrap();
            let delta = {
                let mut state = self.state.lock().unwrap();
                let name = Self::default_workspace_name(&state);
                let index = state.workspaces.len();
                let mut desired = self.registry_projection(&state);
                desired.push(RegistryWorkspace {
                    id: ws_id,
                    public_id: workspace_public_id.clone(),
                    key: workspace_key.clone(),
                    name: name.clone(),
                    group_key: self.session.clone(),
                });
                let commit = match registry.commit(
                    &mutation,
                    &serde_json::json!({
                        "op": "new-browser-workspace",
                        "workspace": ws_id,
                        "key": workspace_key.clone(),
                        "name": name,
                    }),
                    None,
                    None,
                    "workspace-added",
                    &workspace_key,
                    &desired,
                    &serde_json::json!({
                        "workspace": ws_id,
                        "workspace_id": workspace_public_id.as_str(),
                        "key": workspace_key.clone(),
                        "index": index,
                    }),
                ) {
                    Ok(commit) => commit,
                    Err(error) => {
                        drop(state);
                        drop(registry);
                        self.discard_spawned(vec![surface]);
                        return Err(error);
                    }
                };
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.push_workspace(Workspace {
                    id: ws_id,
                    public_id: workspace_public_id,
                    key: workspace_key,
                    name,
                    screens: vec![Screen {
                        id: screen_id,
                        public_id: ScreenPublicId::random()?,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                        viewport_splits: Default::default(),
                        viewport_base_width: None,
                        layout_columns: Vec::new(),
                        layout_revision: 0,
                        layout_undo: Default::default(),
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                state.workspace_revision = commit.revision;
                let workspace_revision = commit.revision;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::WorkspaceAdded,
                    ws_id,
                )
                .expect("new workspace is present in tree snapshot");
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                    workspace_revision: Some(workspace_revision),
                    transaction: None,
                }
            };
            let selection_resync = delta.index.is_some_and(|index| index > 0);
            self.emit_committed_workspace_delta(&registry, delta, selection_resync);
            drop(registry);
            self.reap_if_dead(&surface);
            return Ok(surface);
        };

        let surface =
            self.spawn_browser_surface_with_resource_identity(url, size, None, resource_identity)?;
        let active_at = self.next_active_at();
        let notifications = self.tree_decorations();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    if activate {
                        pane.active_tab = pane.tabs.len() - 1;
                        pane.active_at = active_at;
                    }
                    let index = pane.tabs.len() - 1;
                    fence_layout_undo_for_tab_membership(&mut state, &[target]);
                    let (wi, si) = state.screen_of(target).expect("live pane belongs to a screen");
                    let workspace = state.workspaces[wi].id;
                    let screen = state.workspaces[wi].screens[si].id;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new browser tab is present in tree snapshot");
                    Some(TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    })
                }
                None => {
                    state.surfaces.remove(&surface.id);
                    None
                }
            }
        };
        let Some(delta) = attached else {
            surface.kill();
            anyhow::bail!("pane disappeared while creating browser tab");
        };
        // A background tab changes no pane's selection.
        self.emit_tree_delta(delta, activate);
        self.reap_if_dead(&surface);
        Ok(surface)
    }
}
