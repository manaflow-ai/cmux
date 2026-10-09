//! Thin ordered wrappers for session commands: config, sidebar plugin sync,
//! tabs, panes, screens, workspaces, layout undo and clear history.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use cmux_tui_core::{
    LayoutUndoResult, PaneId, ScreenId, SplitDir, SplitId, SurfaceId, WorkspaceId, ZoomMode,
};
use ghostty_vt::KeyInput;

use crate::app::ordered_session::{CreationCompletionKind, OrderedSession};
use crate::app::{
    AppEvent, MutationImpact, Selection, SessionCompletionAction, SessionMutationOutcome,
    SidebarPluginSyncClaim, classify_clear_history_failure, layout_undo_error_completion,
    record_surface_resize_dispatch_result, sidebar_plugin_status_settles_passive_claim,
};
use crate::config::Config;
use crate::localization;
use crate::session::CreationReceipt;

impl OrderedSession {
    pub(in crate::app) fn apply_config(&self, config: Config) {
        let session = self.inner.clone();
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let config_generation = self.config_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        self.operations.enqueue_coalescing_mutation_with_settlement(
            "apply config",
            ("apply config", 0, 0),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                session.apply_config(&config);
                config_generation.fetch_add(1, Ordering::AcqRel);
                committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                pending.defer(SessionMutationOutcome::Success { tree: None });
                Ok(())
            },
        );
    }

    pub(in crate::app) fn sidebar_plugin(&self, size: (u16, u16), relaunch: bool) {
        let config_generation = self.config_generation.load(Ordering::Acquire);
        let claim = if relaunch {
            None
        } else {
            let mut state = self.sidebar_plugin_sync.lock().unwrap();
            let desired = (size, config_generation, state.epoch);
            if state.claimed == Some(desired) || state.applied == Some(desired) {
                return;
            }
            state.claimed = Some(desired);
            Some(SidebarPluginSyncClaim {
                state: self.sidebar_plugin_sync.clone(),
                desired,
                applied: false,
            })
        };
        let session = self.inner.clone();
        let events = self.events.clone();
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        let superseded = pending.clone();
        let settlement = pending.clone();
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let operation = move || {
            let mut claim = claim;
            let status = session.sidebar_plugin(size, relaunch);
            let settles_passive_claim = sidebar_plugin_status_settles_passive_claim(&status);
            let _ = events.send(AppEvent::SidebarPluginUpdated { status, relaunch });
            committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
            if settles_passive_claim && let Some(claim) = &mut claim {
                claim.mark_applied();
            }
            pending.defer(SessionMutationOutcome::Success { tree: None });
            Ok(())
        };
        if relaunch {
            self.operations.enqueue_session_mutation_with_settlement(
                "relaunch sidebar plugin",
                self.remote,
                move || settlement.publish_deferred(),
                operation,
            );
        } else {
            self.operations.enqueue_coalescing_mutation_with_settlement(
                "sync sidebar plugin",
                ("sidebar plugin", 0, 0),
                self.remote,
                move || superseded.supersede(),
                move || settlement.publish_deferred(),
                operation,
            );
        }
    }

    pub(in crate::app) fn invalidate_sidebar_plugin_sync(&self) {
        let mut state = self.sidebar_plugin_sync.lock().unwrap();
        if state.claimed.is_none() && state.applied.is_none() {
            return;
        }
        state.epoch = state.epoch.wrapping_add(1);
        state.claimed = None;
        state.applied = None;
    }

    pub fn new_tab(&self, pane: Option<PaneId>, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        self.new_tab_for_semantic_intent(pane, size, Vec::new(), None)
    }

    pub(in crate::app) fn new_tab_for_semantic_intent(
        &self,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<cmux_tui_core::ResourceSelectors>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "create tab",
            semantic_intent,
            CreationCompletionKind::Surface,
            move |session| session.new_tab_receipted(pane, size, selector_candidates, &receipt),
        );
        Ok(())
    }

    pub fn run_command(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        let selector_candidates =
            self.inner.tree().resource_selectors_for_pane(pane).into_iter().collect();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "run command",
            None,
            CreationCompletionKind::Surface,
            move |session| {
                session.run_command_receipted(argv, pane, cwd, size, selector_candidates, &receipt)
            },
        );
        Ok(())
    }

    pub fn surface_cwd(&self, surface: SurfaceId) -> Option<String> {
        self.inner.surface_cwd(surface)
    }

    pub fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        self.new_browser_tab_for_semantic_intent(url, pane, size, Vec::new(), None)
    }

    pub(in crate::app) fn new_browser_tab_for_semantic_intent(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<cmux_tui_core::ResourceSelectors>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "create browser tab",
            semantic_intent,
            CreationCompletionKind::Browser,
            move |session| {
                session.new_browser_tab_receipted(url, pane, size, selector_candidates, &receipt)
            },
        );
        Ok(())
    }

    pub fn set_cell_pixel_size(&self, width: u16, height: u16) {
        let ownership = self.surface_resize_ownership.clone();
        self.enqueue_coalescing_pointer_mutation(
            "set cell pixel size",
            ("cell pixel size", 0),
            move |session| {
                session.set_cell_pixel_size(
                    width,
                    height,
                    Arc::new(move |surface, desired, accepted| {
                        record_surface_resize_dispatch_result(
                            &ownership, surface, desired, accepted,
                        );
                    }),
                )
            },
        );
    }

    pub(in crate::app) fn new_workspace_for_semantic_intent(
        &self,
        size: Option<(u16, u16)>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "create workspace",
            semantic_intent,
            CreationCompletionKind::Surface,
            move |session| session.new_workspace_receipted(size, &receipt),
        );
        Ok(())
    }

    pub(in crate::app) fn new_screen_for_semantic_intent(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "create screen",
            semantic_intent,
            CreationCompletionKind::Surface,
            move |session| session.new_screen_receipted(workspace, size, &receipt),
        );
        Ok(())
    }

    pub fn close_screen(&self, screen: ScreenId) {
        self.enqueue_destination_mutation("close screen", move |session| {
            session.close_screen(screen)
        });
    }

    pub fn rename_screen(&self, screen: ScreenId, name: String) {
        self.enqueue("rename screen", move |session| session.rename_screen(screen, name));
    }

    pub fn zoom_pane(&self, pane: Option<PaneId>) {
        self.enqueue_pointer_mutation("zoom pane", move |session| {
            session.zoom_pane(pane, ZoomMode::Toggle)
        });
    }

    pub fn set_pane_zoom(&self, pane: PaneId, zoomed: bool) {
        let mode = if zoomed { ZoomMode::On } else { ZoomMode::Off };
        self.enqueue_pointer_mutation("set pane zoom", move |session| {
            session.zoom_pane(Some(pane), mode)
        });
    }

    pub(in crate::app) fn split_for_semantic_intent(
        &self,
        pane: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<cmux_tui_core::ResourceSelectors>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "split pane",
            semantic_intent,
            CreationCompletionKind::Surface,
            move |session| session.split_receipted(pane, dir, size, selector_candidates, &receipt),
        );
        Ok(())
    }

    pub(in crate::app) fn new_pane_for_semantic_intent(
        &self,
        pane: PaneId,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<cmux_tui_core::ResourceSelectors>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            "create pane",
            semantic_intent,
            CreationCompletionKind::Surface,
            move |session| session.new_pane_receipted(pane, size, selector_candidates, &receipt),
        );
        Ok(())
    }

    pub(in crate::app) fn new_pane_right_for_semantic_intent(
        &self,
        pane: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
        selector_candidates: Vec<cmux_tui_core::ResourceSelectors>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let receipt = CreationReceipt::new();
        self.enqueue_creation_with_completion_for_semantic_intent(
            localization::catalog().layout.create_viewport_pane_operation,
            semantic_intent,
            CreationCompletionKind::Surface,
            move |session| {
                session.new_pane_right_receipted(pane, width, size, selector_candidates, &receipt)
            },
        );
        Ok(())
    }

    pub fn undo_layout(
        &self,
        pane: PaneId,
        revision: Option<u64>,
        confirm_close: bool,
    ) -> anyhow::Result<()> {
        self.enqueue_with_completion(
            localization::catalog().layout.undo_layout_operation,
            MutationImpact::Destination,
            move |session| {
                let result = match session.undo_layout(pane, revision, confirm_close) {
                    Ok(result) => result,
                    Err(error) => {
                        if let Some(action) = layout_undo_error_completion(&error) {
                            return Ok(Some(action));
                        }
                        return Err(error);
                    }
                };
                match result {
                    LayoutUndoResult::Undone { .. } => Ok(None),
                    LayoutUndoResult::ConfirmationRequired { revision, closes_panes, .. } => {
                        Ok(Some(SessionCompletionAction::LayoutUndoConfirmation {
                            pane,
                            revision,
                            closes_panes,
                        }))
                    }
                }
            },
        );
        Ok(())
    }

    pub fn set_split_ratio(&self, split: SplitId, ratio: f32) {
        self.set_split_ratio_deferred(split, ratio);
        self.settle_split_ratio();
    }

    pub fn set_viewport_pane_width(&self, pane: PaneId, width: f32) {
        self.set_viewport_pane_width_deferred(pane, width);
        self.settle_split_ratio();
    }

    pub(in crate::app) fn set_split_ratio_deferred(&self, split: SplitId, ratio: f32) {
        self.enqueue_coalescing_pointer_mutation(
            localization::catalog().layout.resize_exact_split_operation,
            (localization::catalog().layout.split_id_subject, split),
            {
                let owner = self.layout_resize_owner;
                let transaction = self.layout_resize_transaction.load(Ordering::Acquire);
                move |session| {
                    session.set_split_ratio_in_transaction(split, ratio, owner, transaction)
                }
            },
        );
    }

    pub(in crate::app) fn set_viewport_pane_width_deferred(&self, pane: PaneId, width: f32) {
        let owner = self.layout_resize_owner;
        let transaction = self.layout_resize_transaction.load(Ordering::Acquire);
        self.enqueue_coalescing_pointer_mutation(
            localization::catalog().layout.resize_viewport_pane_operation,
            (localization::catalog().layout.viewport_pane_subject, pane),
            move |session| {
                session.set_viewport_pane_width_in_transaction(pane, width, owner, transaction)
            },
        );
    }

    pub(in crate::app) fn settle_split_ratio(&self) {
        let _ = self.layout_resize_transaction.fetch_update(
            Ordering::AcqRel,
            Ordering::Acquire,
            |transaction| Some(transaction.wrapping_add(1).max(1)),
        );
        self.enqueue_pointer_mutation("settle split resize", |_| Ok(()));
    }

    pub fn close_surface(&self, surface: SurfaceId) {
        self.enqueue_destination_mutation("close tab", move |session| {
            session.close_surface(surface)
        });
    }

    pub fn clear_history(
        &self,
        surface: SurfaceId,
        input_revision: u64,
        selection_at_invocation: Option<Selection>,
        selection_generation: u64,
    ) {
        let events = self.events.clone();
        self.enqueue_coalescing_surface_operation(
            "clear terminal history",
            surface,
            move |session| {
                session
                    .clear_history_classified(surface)
                    .map_err(classify_clear_history_failure)?;
                let _ = events.send(AppEvent::ClearHistorySucceeded {
                    surface,
                    input_revision,
                    selection_at_invocation,
                    selection_generation,
                });
                Ok(())
            },
        );
    }

    pub fn clear_history_or_send_key(
        &self,
        surface: SurfaceId,
        fallback_key: KeyInput,
        input_revision: u64,
        selection_at_invocation: Option<Selection>,
        selection_generation: u64,
    ) {
        let session = self.inner.clone();
        let events = self.events.clone();
        let retained_bytes = fallback_key.utf8.capacity();
        self.operations.enqueue_surface_operation_with_retained_bytes(
            "clear terminal history",
            surface,
            self.remote,
            retained_bytes,
            move || {
                session
                    .clear_history_or_send_key_classified(surface, &fallback_key)
                    .map_err(classify_clear_history_failure)?;
                let _ = events.send(AppEvent::ClearHistorySucceeded {
                    surface,
                    input_revision,
                    selection_at_invocation,
                    selection_generation,
                });
                Ok(())
            },
        );
    }

    pub fn close_pane(&self, pane: PaneId) {
        self.enqueue_destination_mutation("close pane", move |session| session.close_pane(pane));
    }

    pub fn swap_pane(&self, pane: PaneId, target: PaneId) {
        self.enqueue_pointer_mutation("swap panes", move |session| session.swap_pane(pane, target));
    }

    pub fn close_workspace(&self, workspace: WorkspaceId) {
        self.enqueue_destination_mutation("close workspace", move |session| {
            session.close_workspace(workspace)
        });
    }

    pub fn mark_workspaces_provider_managed(&self) -> anyhow::Result<()> {
        self.inner.mark_workspaces_provider_managed()
    }

    pub fn workspaces_are_provider_managed(&self) -> bool {
        self.inner.workspaces_are_provider_managed()
    }

    pub fn close_provider_managed_workspace(&self, workspace: WorkspaceId, key: String) {
        self.enqueue_destination_mutation("close managed workspace", move |session| {
            session.close_provider_managed_workspace(workspace, key)
        });
    }

    pub fn rename_surface(&self, surface: SurfaceId, name: String) {
        self.enqueue("rename tab", move |session| session.rename_surface(surface, name));
    }

    pub fn rename_workspace(&self, workspace: WorkspaceId, name: String) {
        self.enqueue("rename workspace", move |session| session.rename_workspace(workspace, name));
    }

    pub fn rename_provider_managed_workspace(
        &self,
        workspace: WorkspaceId,
        key: String,
        name: String,
    ) {
        self.enqueue("rename managed workspace", move |session| {
            session.rename_provider_managed_workspace(workspace, key, name)
        });
    }

    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) {
        self.enqueue_destination_mutation("move tab", move |session| {
            session.move_tab(surface, pane, index)
        });
    }

    pub fn move_tab_to_workspace(&self, surface: SurfaceId, workspace: Option<WorkspaceId>) {
        self.enqueue_with_completion(
            localization::catalog().menu.move_tab_workspace,
            MutationImpact::Destination,
            move |session| {
                session.move_tab_to_workspace(surface, workspace)?;
                Ok(Some(SessionCompletionAction::SurfaceMoved { surface }))
            },
        );
    }

    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) {
        self.enqueue_pointer_mutation("move workspace", move |session| {
            session.move_workspace(workspace, index)
        });
    }
}
