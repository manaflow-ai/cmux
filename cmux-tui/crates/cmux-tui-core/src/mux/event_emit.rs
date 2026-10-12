//! Subscriptions and event emission: mux event, config reload, attached surface and session subscriptions, and the emit_* helpers that publish terminal and tree events.

use super::*;

impl Mux {
    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribers.subscribe()
    }

    pub fn subscribe_config_reload(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_config_reload()
    }

    /// Request one owner config reload and wait until the owner applies it.
    pub fn request_config_reload(&self) -> Result<(), ConfigReloadError> {
        const APPLY_TIMEOUT: Duration = Duration::from_secs(5);

        let request = {
            let mut state = self.config_reload.lock().unwrap();
            state.requested = state.requested.saturating_add(1);
            state.requested
        };
        self.emit(MuxEvent::ConfigReloadRequested);

        let deadline = Instant::now() + APPLY_TIMEOUT;
        let mut state = self.config_reload.lock().unwrap();
        while state.applied < request {
            if self.shutting_down.load(Ordering::Acquire) {
                return Err(ConfigReloadError::OwnerStopped);
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(ConfigReloadError::TimedOut);
            };
            let (next, timeout) =
                self.config_reload_changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.applied < request {
                return Err(ConfigReloadError::TimedOut);
            }
        }
        Ok(())
    }

    /// Capture the newest request that the owner is about to apply.
    pub fn begin_config_reload_application(&self) -> u64 {
        self.config_reload.lock().unwrap().requested
    }

    /// Publish completion after the owner applies the captured request.
    pub fn complete_config_reload_application(&self, request: u64) {
        let mut state = self.config_reload.lock().unwrap();
        state.applied = state.applied.max(request);
        drop(state);
        self.config_reload_changed.notify_all();
    }

    pub fn subscribe_attached_surface(&self, surface: SurfaceId) -> MuxEventReceiver {
        self.subscribers.subscribe_attached_surface(surface)
    }

    pub fn subscribe_surface_session(&self, surface: SurfaceId) -> Option<MuxEventReceiver> {
        let state = self.state.lock().unwrap();
        let pane = state.pane_of(surface)?;
        let (workspace_index, screen_index) = state.screen_of(pane)?;
        let workspace = state.workspaces.get(workspace_index)?;
        let screen = workspace.screens.get(screen_index)?;
        Some(self.subscribers.subscribe_surface_session(surface, workspace.id, screen.id, pane))
    }

    pub fn emit(&self, event: MuxEvent) {
        self.activity.observe(&event);
        self.subscribers.emit(event);
    }

    pub(crate) fn emit_terminal_output(&self, runtime_id: SurfaceId) {
        for placement in self.terminal_event_placements(runtime_id) {
            self.emit(MuxEvent::SurfaceOutput(placement));
        }
    }

    pub(super) fn terminal_event_placements(&self, surface_id: SurfaceId) -> Vec<SurfaceId> {
        let state = self.state.lock().unwrap();
        let Some(surface) =
            state.surfaces.get(&surface_id).or_else(|| state.terminal_runtime_by_id(surface_id))
        else {
            return vec![surface_id];
        };
        let Some(runtime_id) = surface.terminal_runtime_id() else { return vec![surface_id] };
        let Some(terminal_id) = surface.terminal_public_id() else { return vec![surface_id] };
        let placements = state
            .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
            .iter()
            .copied()
            .filter(|placement| {
                state
                    .surfaces
                    .get(placement)
                    .is_some_and(|surface| surface.terminal_runtime_id() == Some(runtime_id))
            })
            .collect::<Vec<_>>();
        if placements.is_empty() && state.surfaces.contains_key(&surface_id) {
            vec![surface_id]
        } else {
            placements
        }
    }

    pub(crate) fn emit_terminal_title(&self, surface: SurfaceId, title: Arc<str>) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::TitleChanged { surface: placement, title: title.clone() });
        }
    }

    pub(crate) fn emit_terminal_bell(&self, surface: SurfaceId) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::Bell(placement));
        }
    }

    pub(crate) fn emit_terminal_resized(
        &self,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        reservation_id: Option<u64>,
    ) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::SurfaceResized { surface: placement, cols, rows, reservation_id });
        }
    }

    pub(crate) fn emit_terminal_scroll(&self, surface: SurfaceId, offset: u64, at_bottom: bool) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::ScrollChanged { surface: placement, offset, at_bottom });
        }
    }

    #[cfg(test)]
    pub(super) fn emit_terminal_exited(&self, surface: SurfaceId) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::SurfaceExited(placement));
        }
    }

    pub(super) fn emit_tree_delta(&self, delta: TreeDelta, selection_resync: bool) {
        #[cfg(test)]
        if let Some(revision) = delta.workspace_revision
            && let Some(hook) = self.workspace_delta_before_emit.lock().unwrap().clone()
        {
            hook(revision);
        }
        self.emit(MuxEvent::TreeDelta(delta));
        if selection_resync {
            self.emit(MuxEvent::TreeSelectionChanged);
        }
    }

    pub(super) fn emit_committed_workspace_delta(
        &self,
        _registry: &WorkspaceRegistry,
        delta: TreeDelta,
        selection_resync: bool,
    ) {
        debug_assert!(delta.workspace_revision.is_some());
        self.emit_tree_delta(delta, selection_resync);
    }

    pub(super) fn emit_empty_if_current(&self, workspace_revision: Option<u64>) {
        let Some(workspace_revision) = workspace_revision else { return };
        #[cfg(test)]
        let before_empty_check = self.workspace_close_before_empty_check.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_empty_check {
            hook();
        }
        let state = self.state.lock().unwrap();
        if state.workspaces.is_empty() && state.workspace_revision == workspace_revision {
            self.emit(MuxEvent::Empty);
        }
    }

    pub(crate) fn rebuild_split_screen_index(state: &mut State) {
        fn index_node(
            node: &Node,
            workspace_index: usize,
            screen_index: usize,
            screen: ScreenId,
            index: &mut HashMap<SplitId, (usize, usize, ScreenId)>,
        ) {
            if let Node::Split { id, a, b, .. } = node {
                index.insert(*id, (workspace_index, screen_index, screen));
                index_node(a, workspace_index, screen_index, screen, index);
                index_node(b, workspace_index, screen_index, screen, index);
            }
        }

        let mut index = HashMap::new();
        for (workspace_index, workspace) in state.workspaces.iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                debug_assert!(
                    screen.layout_column_projection_is_consistent(),
                    "screen {} has a stale layout column projection",
                    screen.id
                );
                index_node(&screen.root, workspace_index, screen_index, screen.id, &mut index);
            }
        }
        state.split_screens = index;
        state.rebuild_resource_indexes();
    }

    pub(super) fn emit_terminal_registry_changed(
        &self,
        registry: &WorkspaceRegistry,
        terminal_revision: u64,
    ) {
        self.emit(MuxEvent::TerminalRegistryChanged {
            registry_id: registry.registry_id().to_string(),
            generation: registry.generation().to_string(),
            terminal_revision,
        });
    }
}
