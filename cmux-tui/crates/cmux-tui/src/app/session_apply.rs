//! Applying session results to the App: mutation completions and
//! cancellations, PTY failures, mux titles, tree replacement and surface
//! retirement, and remote tree refresh retries.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_tui_core::{PaneId, SurfaceId, SurfaceKind};

use crate::app::overlays::{Prompt, PromptTarget};
use crate::app::pointer::Drag;
use crate::app::pointer::deferred::SemanticDestinationOutcome;
use crate::app::session_mutation::{SessionCompletion, SessionCompletionAction};
use crate::app::{
    App, BACKGROUND_REFRESH_RETRIES, RenderAction, adjust_active_tab_after_removal,
    localized_clear_history_failure, preserve_client_view,
};
use crate::localization;
use crate::pty_input::{
    PtyInputKind, PtyOperationDelivery, PtyOperationFailure, TERMINAL_EXITED_LABEL,
};
use crate::session::TreeView;

impl App {
    pub(super) fn apply_session_completion(&mut self, completion: SessionCompletion) {
        if self.surface_only.is_some() {
            return;
        }
        let semantic_intent = completion.semantic_intent;
        match completion.action {
            SessionCompletionAction::SurfaceCreated { surface }
            | SessionCompletionAction::SurfaceMoved { surface } => {
                self.resolve_semantic_destination(semantic_intent, surface);
                self.select_completed_surface(surface);
            }
            SessionCompletionAction::BrowserTabCreated { surface } => {
                self.resolve_semantic_destination(semantic_intent, surface);
                self.select_completed_surface(surface);
                let pane = self
                    .tab_locations
                    .get(&surface)
                    .and_then(|[workspace, screen, pane, _]| {
                        self.tree
                            .workspaces()
                            .get(*workspace)
                            .and_then(|workspace| workspace.screens.get(*screen))
                            .and_then(|screen| screen.panes.get(*pane))
                    })
                    .filter(|pane| {
                        pane.active_surface() == Some(surface)
                            && pane
                                .tabs
                                .get(pane.active_tab)
                                .is_some_and(|tab| tab.kind == SurfaceKind::Browser)
                    })
                    .map(|pane| pane.id);
                if let Some(pane) = pane {
                    self.focus_omnibar_with_buffer(pane, String::new(), false);
                }
            }
            SessionCompletionAction::LayoutUndoConfirmation { pane, revision, closes_panes } => {
                self.cancel_pty_mouse_drag();
                let label = self.layout_undo_confirmation_label(&closes_panes);
                self.prompt = Some(Prompt::new(
                    label,
                    String::new(),
                    PromptTarget::ConfirmLayoutUndo { pane, revision },
                ));
            }
            SessionCompletionAction::LayoutUndoUnavailable => {
                self.status_message =
                    Some(localization::catalog().sidebar.layout_nothing_to_undo.to_string());
            }
            SessionCompletionAction::LayoutUndoStale => {
                self.status_message =
                    Some(localization::catalog().sidebar.layout_undo_stale.to_string());
            }
        }
    }

    fn resolve_semantic_destination(&mut self, intent: Option<u64>, surface: SurfaceId) {
        let Some(intent) = intent else { return };
        let outcome = if self.tab_locations.contains_key(&surface) {
            SemanticDestinationOutcome::Resolved(surface)
        } else {
            SemanticDestinationOutcome::Failed
        };
        if let Some(current) = self.semantic_destination_outcomes.get_mut(&intent) {
            *current = outcome;
        }
    }

    fn layout_undo_confirmation_label(&self, closes_panes: &[PaneId]) -> String {
        let identities = closes_panes
            .iter()
            .map(|pane_id| {
                self.tree.pane(*pane_id).map_or_else(
                    || pane_id.to_string(),
                    |pane| {
                        let tabs = pane
                            .tabs
                            .iter()
                            .map(|tab| tab.short_id.as_str())
                            .collect::<Vec<_>>()
                            .join(", ");
                        if tabs.is_empty() {
                            pane.short_id.clone()
                        } else {
                            format!("{} [{}]", pane.short_id, tabs)
                        }
                    },
                )
            })
            .collect::<Vec<_>>()
            .join("; ");
        localization::catalog().sidebar.confirm_layout_undo.replace("{items}", &identities)
    }

    fn select_completed_surface(&mut self, surface: SurfaceId) {
        let Some([workspace_index, screen_index, pane_index, tab_index]) =
            self.tab_locations.get(&surface).copied()
        else {
            return;
        };
        let Some(pane_id) = self
            .tree
            .workspaces()
            .get(workspace_index)
            .and_then(|workspace| workspace.screens.get(screen_index))
            .and_then(|screen| screen.panes.get(pane_index))
            .map(|pane| pane.id)
        else {
            return;
        };
        self.tree.active_workspace = workspace_index;
        if !self.tree.set_active_screen(workspace_index, screen_index)
            || !self.tree.set_active_pane(workspace_index, screen_index, pane_id)
            || !self.tree.set_active_tab(workspace_index, screen_index, pane_id, tab_index)
        {
            return;
        }
        self.pane_focus_history.record(pane_id);
        self.claim_active_terminal_geometry(true);
    }

    pub(super) fn apply_session_cancellation(&mut self) {
        self.deferred_input.clear();
        self.latest_semantic_destination_intent = None;
        self.semantic_destination_outcomes.clear();
        self.prefix_armed = false;
        self.pending_session_completions.clear();
        self.pending_size_releases.clear();
        self.status_message = Some(localization::catalog().session.operation_canceled.to_string());
    }

    pub(super) fn apply_pty_failures(&mut self) -> RenderAction {
        let failures = self.pty_failures.take();
        let mut action = RenderAction::None;
        for failure in failures {
            action = action.merge(self.apply_pty_operation_failure(failure));
        }
        action
    }

    pub(super) fn apply_pty_operation_failure(
        &mut self,
        failure: PtyOperationFailure,
    ) -> RenderAction {
        if failure.session_generation != self.session_generation {
            return RenderAction::None;
        }
        if failure.label == "relaunch sidebar plugin" {
            self.sidebar_focus_pending = false;
        }
        if failure.kind == Some(PtyInputKind::Motion)
            && failure.delivery == PtyOperationDelivery::KnownNotDelivered
            && let Some(surface) = failure.surface_id.and_then(|id| self.session.surface(id))
        {
            surface.reset_mouse_motion_dedupe();
        }
        let matches_active_press =
            failure.surface_id.zip(failure.reservation_id).is_some_and(
                |(surface, reservation_id)| {
                    matches!(&self.drag, Some(Drag::PtyMouse { surface: active_surface, reservation_id: active_reservation, .. }) if *active_surface == surface && *active_reservation == reservation_id)
                },
            );
        let failed_active_press = failure.kind == Some(PtyInputKind::Press)
            && failure.delivery == PtyOperationDelivery::KnownNotDelivered
            && matches_active_press;
        let recovery_release_required = failure.kind == Some(PtyInputKind::Press)
            && failure.delivery == PtyOperationDelivery::Ambiguous
            && matches_active_press;
        if failed_active_press || (failure.lane_failed && !recovery_release_required) {
            self.drag = None;
        }
        self.status_message = Some(if failure.label == TERMINAL_EXITED_LABEL {
            localization::catalog().terminal.pty_input_exited.to_string()
        } else if failure.label == "attach surface"
            && failure.delivery == PtyOperationDelivery::Ambiguous
        {
            format!(
                "{}: {}",
                localization::catalog().terminal.attach_outcome_unknown,
                failure.error
            )
        } else if failure.label == "clear terminal history"
            && failure.delivery == PtyOperationDelivery::Ambiguous
        {
            localization::catalog().terminal.clear_history_outcome_unknown.to_string()
        } else if failure.label == "clear terminal history" {
            let detail = localized_clear_history_failure(&failure.error);
            format!("{}: {}", localization::catalog().terminal.clear_history_failed, detail)
        } else {
            format!("{}: {}", localization::catalog().terminal.operation_failed, failure.error)
        });
        RenderAction::Draw
    }

    pub(super) fn apply_mux_titles(&mut self) -> bool {
        let titles = self.mux_titles.take_dirty();
        self.apply_mux_title_snapshot(titles)
    }

    fn reapply_mux_titles(&mut self) -> bool {
        let titles = self.mux_titles.snapshot();
        self.apply_mux_title_snapshot(titles)
    }

    fn apply_mux_title_snapshot(&mut self, titles: HashMap<SurfaceId, Arc<str>>) -> bool {
        if titles.is_empty() {
            return false;
        }
        let mut changed = false;
        for (surface, title) in titles {
            let Some([workspace, screen, pane, tab]) = self.tab_locations.get(&surface).copied()
            else {
                continue;
            };
            if self
                .tree
                .update_surface_title_at(surface, [workspace, screen, pane, tab], title.as_ref())
                .is_some_and(|changed| changed)
            {
                changed = true;
            }
        }
        changed
    }

    pub(super) fn replace_tree(&mut self, mut tree: TreeView) {
        let previous_active = self.active_pane();
        let selected_workspace = self
            .tree
            .workspaces()
            .get(self.sidebar_workspace_selection)
            .map(|workspace| workspace.id);
        preserve_client_view(&self.tree, &mut tree);
        let first_adoption = self.reported_focus.is_none();
        if first_adoption {
            // First adopted tree: its focus is the server's own baseline.
            self.reported_focus = tree
                .active_screen()
                .and_then(|screen| screen.panes.iter().find(|pane| pane.id == screen.active_pane))
                .map(|pane| crate::session::ClientFocus { pane: pane.id, tab: pane.active_tab });
        }
        if let Some(surface) = self.surface_only
            && !tree.select_surface(surface)
        {
            tree = TreeView::default();
            self.quit = true;
        }
        let live_browsers = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .filter(|tab| tab.kind == SurfaceKind::Browser)
            .map(|tab| tab.surface)
            .collect::<HashSet<_>>();
        let removed_browsers = self
            .tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .filter(|tab| tab.kind == SurfaceKind::Browser)
            .map(|tab| tab.surface)
            .filter(|surface| !live_browsers.contains(surface))
            .collect::<Vec<_>>();
        for surface in removed_browsers {
            self.browser_input.forget_surface(surface);
        }
        let live_screens = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .map(|screen| screen.id)
            .collect::<HashSet<_>>();
        self.viewport_states.retain(|screen, _| live_screens.contains(screen));
        self.pane_focus_history.sync_membership(&tree);
        self.tree = tree;
        self.sidebar_workspace_selection = selected_workspace
            .and_then(|selected| {
                self.tree.workspaces().iter().position(|workspace| workspace.id == selected)
            })
            .unwrap_or_else(|| {
                self.sidebar_workspace_selection.min(self.tree.workspaces().len().saturating_sub(1))
            });
        if self.active_pane() != previous_active
            && let Some(active) = self.active_pane()
        {
            self.pane_focus_history.record(active);
        }
        if first_adoption {
            self.restore_client_focus_from_session();
        }
        self.rebuild_tab_locations();
        self.reapply_mux_titles();
    }

    pub(super) fn replace_authoritative_tree(
        &mut self,
        tree: TreeView,
        destination_generation: u64,
    ) {
        if tree.pane_revision.is_none() {
            self.pane_focus_history.reconcile_membership(&tree);
        } else {
            self.pane_focus_history.sync_membership(&tree);
        }
        let live_surfaces = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .map(|tab| tab.surface)
            .collect::<HashSet<_>>();
        let removed_surfaces = self
            .tab_locations
            .keys()
            .copied()
            .filter(|surface| !live_surfaces.contains(surface))
            .collect::<Vec<_>>();
        for surface in removed_surfaces {
            self.retire_surface_state(surface);
        }
        self.replace_tree(tree);
        self.session.reconcile_retired_surfaces(&self.tree);
        self.claim_active_terminal_geometry(false);
        self.applied_destination_generation =
            self.applied_destination_generation.max(destination_generation);
    }

    pub(super) fn retire_surface_state(&mut self, surface: SurfaceId) {
        if self
            .selection_click_sequence
            .as_ref()
            .is_some_and(|sequence| sequence.surface == surface)
        {
            self.reset_selection_click_sequence();
        }
        if matches!(&self.drag, Some(Drag::PtyMouse { surface: active, .. }) if *active == surface)
        {
            self.cancel_pty_release_reservation();
            self.drag = None;
        }
        self.render_states.remove(&surface);
        self.rendered_kitty_graphics.remove(&surface);
        self.graphics_scene_cache.invalidate();
        self.graphics_dirty_surfaces.remove(&surface);
        self.rendered_terminal_sizes.remove(&surface);
        self.rendered_terminal_pointer_semantics.remove(&surface);
        self.rendered_pane_content_generations.remove(&surface);
        self.rendered_terminal_bounds.remove(&surface);
        self.visible_size_surfaces.remove(&surface);
        self.pending_size_releases.remove(&surface);
        self.mux_titles.remove(surface);
        self.session.retire_surface_input(surface);
        self.session.forget_surface(surface);
        if self.sidebar_plugin_surface == Some(surface) {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error =
                Some(localization::catalog().sidebar.plugin_exited.to_string());
            if self.config.sidebar.plugin.is_some() {
                self.leave_workspace_sidebar();
            }
        }
        if self.selection.is_some_and(|selection| selection.surface == surface) {
            self.replace_selection(None);
        }
        if self.omnibar.as_ref().is_some_and(|state| state.surface == surface) {
            self.omnibar = None;
        }
        if self.last_browser_hover.is_some_and(|(hovered, _, _, _)| hovered == surface) {
            self.last_browser_hover = None;
        }
        self.browser_input.forget_surface(surface);
    }

    pub(super) fn rebuild_tab_locations(&mut self) {
        self.tab_locations.clear();
        for (workspace_index, workspace) in self.tree.workspaces().iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                for (pane_index, pane) in screen.panes.iter().enumerate() {
                    for (tab_index, tab) in pane.tabs.iter().enumerate() {
                        self.tab_locations.insert(
                            tab.surface,
                            [workspace_index, screen_index, pane_index, tab_index],
                        );
                    }
                }
            }
        }
    }

    /// Remove a retired view from the client cache before the authoritative
    /// topology refresh arrives. The backend projection still owns parent
    /// pane, screen, and workspace collapse.
    pub(super) fn remove_surface_from_cached_tree(&mut self, surface: SurfaceId) {
        self.tree.invalidate_location_index();
        let Some([workspace_index, screen_index, pane_index, tab_index]) =
            self.tab_locations.get(&surface).copied()
        else {
            self.remove_surface_from_cached_tree_scan_and_rebuild_locations(surface);
            return;
        };

        let location_is_current = self
            .tree
            .workspaces()
            .get(workspace_index)
            .and_then(|workspace| workspace.screens.get(screen_index))
            .and_then(|screen| screen.panes.get(pane_index))
            .and_then(|pane| pane.tabs.get(tab_index))
            .is_some_and(|tab| tab.surface == surface);
        if !location_is_current {
            self.remove_surface_from_cached_tree_scan_and_rebuild_locations(surface);
            return;
        }

        let shifted_tabs = {
            let pane = &mut self.tree.workspaces_mut()[workspace_index].screens[screen_index].panes
                [pane_index];
            pane.tabs.remove(tab_index);
            adjust_active_tab_after_removal(pane, tab_index);
            pane.tabs
                .iter()
                .enumerate()
                .skip(tab_index)
                .map(|(tab_index, tab)| (tab.surface, tab_index))
                .collect::<Vec<_>>()
        };

        self.tab_locations.remove(&surface);
        for (shifted_surface, shifted_index) in shifted_tabs {
            self.tab_locations.insert(
                shifted_surface,
                [workspace_index, screen_index, pane_index, shifted_index],
            );
        }
    }

    /// Repair the cache from the tree and rebuild `tab_locations` if the index was missing or stale.
    /// This path is defensive only. Normal surface exits use the indexed path
    /// above and touch one pane instead of scanning the entire topology.
    fn remove_surface_from_cached_tree_scan_and_rebuild_locations(&mut self, surface: SurfaceId) {
        for workspace in self.tree.workspaces_mut() {
            for screen in &mut workspace.screens {
                for pane in &mut screen.panes {
                    let Some(index) = pane.tabs.iter().position(|tab| tab.surface == surface)
                    else {
                        continue;
                    };
                    pane.tabs.remove(index);
                    adjust_active_tab_after_removal(pane, index);
                }
            }
        }
        self.rebuild_tab_locations();
    }

    pub(super) fn apply_session_completions_through(
        &mut self,
        authoritative_generation: u64,
    ) -> bool {
        let mut applied = false;
        while self
            .pending_session_completions
            .front()
            .is_some_and(|completion| completion.mutation_generation <= authoritative_generation)
        {
            let completion = self.pending_session_completions.pop_front().unwrap();
            self.apply_session_completion(completion);
            applied = true;
        }
        applied
    }

    pub(super) fn complete_remote_tree_refresh(&self, refresh_stale: bool) {
        let background_dirty = self.session.take_background_refresh_dirty();
        if self.session.remote_tree_is_stale() {
            if refresh_stale || background_dirty {
                self.session.refresh_remote_tree_if_stale();
            }
        } else if background_dirty {
            self.session.refresh_remote_tree_background();
        }
    }

    pub(super) fn accept_refresh_sequence(&mut self, refresh_sequence: u64) -> bool {
        if refresh_sequence <= self.last_applied_refresh_sequence {
            return false;
        }
        self.last_applied_refresh_sequence = refresh_sequence;
        true
    }

    pub(super) fn schedule_background_refresh_retry(&mut self) -> bool {
        if self.background_refresh_attempts >= BACKGROUND_REFRESH_RETRIES {
            self.background_refresh_retry_at = None;
            return false;
        }
        self.background_refresh_attempts += 1;
        let delay_seconds = 1_u64 << u32::from(self.background_refresh_attempts.saturating_sub(1));
        self.background_refresh_retry_at =
            Some(Instant::now() + Duration::from_secs(delay_seconds.min(30)));
        true
    }

    pub(super) fn retry_background_refresh_if_due(&mut self) {
        if self.background_refresh_retry_at.is_some_and(|retry_at| Instant::now() >= retry_at) {
            self.background_refresh_retry_at = None;
            self.session.refresh_remote_tree_background();
        }
    }
}
