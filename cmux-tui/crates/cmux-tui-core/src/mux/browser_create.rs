//! Browser surface creation in a workspace: target adoption and attaching the surface to a pane (or killing it).

use super::*;

impl Mux {
    pub(super) fn create_browser_surface_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        url: String,
        size: Option<(u16, u16)>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let lifecycle = self.workspace_lifecycle(workspace);
        let workspace_lifecycle = lifecycle.lock().unwrap();
        if self.state.lock().unwrap().workspace_by_id(workspace).is_none() {
            anyhow::bail!("unknown workspace {workspace}");
        }
        let surface = self.spawn_browser_surface_with_resource_identity(
            url,
            size,
            Some(workspace),
            resource_identity,
        )?;
        let pending_surface = self.pending_workspace_surface(surface.id);
        let notifications = self.tree_decorations();
        let active_at = self.next_active_at();
        let (delta, selection_resync) = {
            let mut state = self.state.lock().unwrap();
            let Some(wi) = state.workspace_index(workspace) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("workspace disappeared while creating browser tab");
            };
            let target = state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
            if let Some(target) = target {
                let Some((_, si)) = state.screen_of(target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating browser tab");
                };
                let Some(pane) = state.panes.get_mut(&target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating browser tab");
                };
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = active_at;
                let index = pane.tabs.len() - 1;
                fence_layout_undo_for_tab_membership(&mut state, &[target]);
                let screen = state.workspaces[wi].screens[si].id;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabAdded,
                    surface.id,
                )
                .expect("new browser tab is present in tree snapshot");
                (
                    TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    },
                    true,
                )
            } else {
                let (pane_id, pane) = self.make_pane(surface.id)?;
                let screen_id = self.next_id();
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.workspaces[wi].screens.push(Screen {
                    id: screen_id,
                    public_id: ScreenPublicId::random()?,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                    creation_order_auto_layout: Some(vec![pane_id]),
                    viewport_splits: Default::default(),
                    viewport_base_width: None,
                    layout_columns: Vec::new(),
                    layout_revision: 0,
                    layout_undo: Default::default(),
                });
                state.workspaces[wi].active_screen = 0;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::ScreenAdded,
                    screen_id,
                )
                .expect("first browser screen is present in tree snapshot");
                (
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    },
                    false,
                )
            }
        };
        drop(pending_surface);
        self.emit_tree_delta(delta, selection_resync);
        drop(workspace_lifecycle);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    pub fn adopt_browser_target(
        self: &Arc<Self>,
        opener_surface: SurfaceId,
        target_id: String,
        url: String,
        runtime: Arc<BrowserRuntime>,
    ) -> anyhow::Result<bool> {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let (pane_id, size) = {
            let state = self.state.lock().unwrap();
            let Some(pane_id) = state.pane_of(opener_surface) else {
                return Ok(false);
            };
            let size = state.surfaces.get(&opener_surface).map(|surface| surface.size());
            (pane_id, size)
        };
        let id = self.next_id();
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = self.cell_pixel_creation_size();
        let surface =
            browser::new_surface(id, url.clone(), size, cell_pixels, &opts, Arc::downgrade(self))?;
        let active_at = self.next_active_at();
        let attached =
            match self.attach_browser_surface_to_pane_or_kill(pane_id, &surface, active_at) {
                BrowserSurfaceAttach::MissingPane => return Ok(false),
                BrowserSurfaceAttach::Attached(delta) => delta,
            };
        let identity = surface
            .resource_identity()
            .context("adopted browser surface omitted its public identity")?;
        let result = serde_json::json!({
            "tab_id":identity.tab_id,
            "browser_id":identity.content_id,
        });
        if let Err(error) = self.commit_ordinary_full_resource_projection(
            &Actor::Daemon,
            "browser.target.adopt",
            result,
        ) {
            let rollback = self.close_surface_for_resource_effect(surface.id);
            return match rollback {
                Ok(true) => Err(error.context("could not persist adopted browser target")),
                Ok(false) => Err(error.context(
                    "could not persist adopted browser target and its tab disappeared during rollback",
                )),
                Err(rollback) => Err(error.context(format!(
                    "could not persist adopted browser target; rollback also failed: {rollback:#}"
                ))),
            };
        }
        if let Some(delta) = attached {
            self.emit_tree_delta(delta, true);
        } else {
            self.emit(MuxEvent::TreeChanged);
        }
        self.start_browser_bootstrap(
            surface,
            BrowserBootstrap::ExistingTarget { target_id, url },
            Some(runtime),
        );
        Ok(true)
    }

    pub(super) fn attach_browser_surface_to_pane_or_kill(
        &self,
        pane_id: PaneId,
        surface: &Arc<Surface>,
        active_at: u64,
    ) -> BrowserSurfaceAttach {
        let notifications = self.tree_decorations();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&pane_id) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    fence_layout_undo_for_tab_membership(&mut state, &[pane_id]);
                    if let Some(identity) = surface.resource_identity().cloned() {
                        state.register_tab_identity(surface.id, &identity);
                    }
                    state.surfaces.insert(surface.id, surface.clone());
                    let delta = (|| {
                        let (wi, si) = state.screen_of(pane_id)?;
                        let pane = state.panes.get(&pane_id)?;
                        let index = pane.tabs.iter().position(|id| *id == surface.id)?;
                        let entity = crate::server::tree_entity_json(
                            &state,
                            &notifications,
                            TreeDeltaKind::TabAdded,
                            surface.id,
                        )?;
                        Some(TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace: state.workspaces[wi].id,
                            screen: Some(state.workspaces[wi].screens[si].id),
                            pane: Some(pane_id),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                            workspace_revision: None,
                            transaction: None,
                        })
                    })();
                    BrowserSurfaceAttach::Attached(delta)
                }
                None => BrowserSurfaceAttach::MissingPane,
            }
        };
        if matches!(attached, BrowserSurfaceAttach::MissingPane) {
            surface.kill();
        }
        attached
    }
}
