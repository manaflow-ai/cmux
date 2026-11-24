//! Subscriptions and event emission: mux event, config reload, attached surface and session subscriptions, and the emit_* helpers that publish terminal and tree events.

use super::*;
use crate::mux::resource_content::collect_screen_split_ids;

impl Mux {
    /// The revision of what `list-workspaces` shows (`list-workspaces-known-v1`,
    /// mux/tree_revision.rs). Read it before reading the tree.
    pub(crate) fn tree_revision(&self) -> String {
        self.tree_revision.current()
    }

    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribers.subscribe()
    }

    pub fn subscribe_config_reload(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_config_reload()
    }

    /// The events that can change which terminals are live (topology,
    /// terminal registry, surface exits): the terminal reaper's filter, for
    /// the owner's keepers watch (server/owner_keepers.rs).
    pub(crate) fn subscribe_terminal_lifecycle(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_terminal_topology()
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
        // A selection may show a workspace whose respawns wait in line: they
        // check again (terminal_respawn.rs). Free when none waits.
        if matches!(
            event,
            MuxEvent::TreeChanged
                | MuxEvent::TreeSelectionChanged(_)
                | MuxEvent::WorkspacePresentationChanged(_)
                | MuxEvent::TreeDelta(_)
        ) {
            self.respawn_gate.wake_waiters();
        }
        if tree_revision::changes_tree(&event) {
            self.tree_revision.bump();
        }
        self.activity.observe(&event);
        if let MuxEvent::Conversation(conversation) = &event {
            self.chiefs().brains.observe(conversation);
        }
        self.subscribers.emit(event);
    }

    pub(crate) fn emit_terminal_output(&self, runtime_id: SurfaceId) {
        self.activity.note_output(runtime_id);
        for placement in self.terminal_event_placements(runtime_id) {
            self.emit(MuxEvent::SurfaceOutput(placement));
        }
    }

    #[track_caller]
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
            self.emit(MuxEvent::terminal_title(placement, title.clone()));
        }
    }

    pub(crate) fn emit_terminal_program_status(
        &self,
        surface: SurfaceId,
        status: Option<crate::program_status::ShownProgramStatus>,
    ) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::ProgramStatusChanged { surface: placement, status });
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
            self.emit(MuxEvent::SurfaceExited(placement, None));
        }
    }

    pub(super) fn emit_tree_delta(&self, delta: TreeDelta, selection_resync: bool) {
        #[cfg(test)]
        if let Some(revision) = delta.workspace_revision
            && let Some(hook) = self.workspace_delta_before_emit.lock().unwrap().clone()
        {
            hook(revision);
        }
        let workspace = delta.workspace;
        self.emit(MuxEvent::TreeDelta(delta));
        if selection_resync {
            // The selection a delta moves (the focused workspace, the pane's active tab) is in its
            // workspace: a client that reads `selection-changed` applies it without a snapshot (#32408).
            self.emit(MuxEvent::TreeSelectionChanged(Some(workspace)));
        }
    }

    pub(super) fn emit_committed_workspace_delta(
        &self,
        registry: &WorkspaceRegistry,
        mut delta: TreeDelta,
        selection_resync: bool,
    ) {
        debug_assert!(delta.workspace_revision.is_some());
        // One read per delta, here, instead of one per subscriber in
        // `tree_delta_json`. A failed read leaves the fields out, as before.
        delta.mutation = delta
            .workspace_revision
            .and_then(|revision| registry.event_mutation(revision).ok().flatten())
            .map(|(origin, mutation_id)| Arc::new(DeltaMutation { origin, mutation_id }));
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

    /// [`Self::rebuild_split_screen_index`] for one screen whose layout just changed by gaining
    /// panes and splits (a split, a new pane): the indexes of that screen only, so the work
    /// follows the screen and not the session. `old_splits` is
    /// `collect_screen_split_ids` of the screen as it was before the change. Splits that left
    /// the screen drop out of both indexes; panes it holds are (re)recorded. A change that
    /// removes panes from the screen needs the full rebuild.
    pub(crate) fn reindex_screen_after_growth(
        state: &mut State,
        workspace_index: usize,
        screen_index: usize,
        old_splits: &HashSet<SplitId>,
    ) {
        #[cfg(test)]
        crate::walk_counters::index_rebuild_visited(1);
        let Some(screen) =
            state.workspaces.get(workspace_index).and_then(|ws| ws.screens.get(screen_index))
        else {
            return Self::rebuild_split_screen_index(state);
        };
        debug_assert!(
            screen.layout_column_projection_is_consistent(),
            "screen {} has a stale layout column projection",
            screen.id
        );
        let screen_id = screen.id;
        let mut new_splits = HashSet::new();
        collect_screen_split_ids(screen, &mut new_splits);
        let mut located = HashMap::new();
        index_node(&screen.root, workspace_index, screen_index, screen_id, &mut located);
        let panes = screen.root.pane_ids_vec();
        for split in old_splits {
            state.split_screens.remove(split);
            if !new_splits.contains(split)
                && let Some(public_id) = state.resource_indexes.split_ids.remove(split)
            {
                state.resource_indexes.splits.remove(&public_id);
            }
        }
        state.split_screens.extend(located);
        for pane_id in panes {
            let Some(tabs) = state.panes.get(&pane_id).map(|pane| pane.tabs.clone()) else {
                continue;
            };
            state.resource_indexes.pane_screen.insert(pane_id, screen_id);
            for slot in tabs {
                state.register_placed_tab_identity(slot);
                if state.resource_indexes.tab_ids.contains_key(&slot) {
                    state.resource_indexes.tab_pane.insert(slot, pane_id);
                }
            }
        }
    }

    /// After the workspaces `low..=high` changed positions (a move), record their new positions
    /// in `split_screens`: the splits of those workspaces only, not a walk of the session.
    pub(crate) fn reindex_workspace_positions(state: &mut State, low: usize, high: usize) {
        let high = high.min(state.workspaces.len().saturating_sub(1));
        for workspace_index in low..=high {
            #[cfg(test)]
            crate::walk_counters::index_rebuild_visited(1);
            let Some(workspace) = state.workspaces.get(workspace_index) else { continue };
            let mut located = HashMap::new();
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                index_node(&screen.root, workspace_index, screen_index, screen.id, &mut located);
            }
            state.split_screens.extend(located);
        }
    }

    pub(crate) fn rebuild_split_screen_index(state: &mut State) {
        #[cfg(test)]
        crate::walk_counters::index_rebuild_visited(state.workspaces.len());
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
