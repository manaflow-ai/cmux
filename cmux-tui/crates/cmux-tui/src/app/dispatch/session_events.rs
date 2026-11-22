//! Session result handlers: surface attach and mutation settlement, remote
//! tree updates and client list updates.

// The handler bodies came verbatim from app.rs and name its items and imports.
use crate::app::*;

impl App {
    pub(super) fn on_mux_subscription_recovered(
        &mut self,
        recovery_generation: u64,
        destination_generation: u64,
        result: Result<TreeView, String>,
    ) -> anyhow::Result<RenderAction> {
        if recovery_generation != self.mux_recovery_generation.load(Ordering::Acquire) {
            return Ok(RenderAction::None);
        }
        match result {
            Ok(tree) => {
                let empty = tree.workspaces().is_empty();
                self.replace_authoritative_tree(tree, destination_generation);
                self.session.refresh_clients_background();
                if empty {
                    if self.request_current_machine_session() {
                        return Ok(RenderAction::Draw);
                    }
                    self.quit = true;
                    return Ok(RenderAction::None);
                }
                self.status_message =
                    Some(localization::catalog().session.mux_subscription_recovered.to_string());
            }
            Err(error) => {
                if self
                    .mux_recovery_generation
                    .compare_exchange(recovery_generation, 0, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    return Ok(RenderAction::None);
                }
                self.deferred_input.clear();
                self.latest_semantic_destination_intent = None;
                self.semantic_destination_outcomes.clear();
                self.prefix_armed = false;
                self.session.invalidate_remote_tree();
                self.session.refresh_remote_tree_if_stale();
                self.status_message =
                    Some(localization::catalog().session.mux_subscription_recovery_failed(&error));
            }
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_surface_attach_settled(
        &mut self,
        outcome: SurfaceAttachOutcome,
    ) -> anyhow::Result<RenderAction> {
        match outcome {
            SurfaceAttachOutcome::Attached => {
                self.claim_active_terminal_geometry(false);
            }
            SurfaceAttachOutcome::Deferred => {}
            SurfaceAttachOutcome::Retired { surface } => {
                self.retire_surface_state(surface);
                self.remove_surface_from_cached_tree(surface);
                self.session.refresh_remote_tree_if_stale();
            }
            SurfaceAttachOutcome::Failed { surface, operation, error, reconnect_required } => {
                if reconnect_required {
                    self.deferred_input
                        .retain(|input| input.admission.destination != Some(surface));
                    self.status_message = Some(
                        localization::catalog()
                            .attach
                            .surface_sync_unknown(surface, operation, &error),
                    );
                } else {
                    self.status_message = Some(
                        localization::catalog()
                            .attach
                            .surface_sync_failed(surface, operation, &error),
                    );
                }
            }
        }
        if !self.session.has_pending_mutations()
            && !self.session.remote_tree_is_stale()
            && !self.deferred_input.is_empty()
        {
            self.pointer_route_phase = PointerRoutePhase::DrawPending;
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_clear_history_succeeded(
        &mut self,
        surface: SurfaceId,
        input_revision: u64,
        selection_at_invocation: Option<Selection>,
        selection_generation: u64,
    ) -> anyhow::Result<RenderAction> {
        let Some(handle) = self.session.surface(surface) else {
            return Ok(RenderAction::None);
        };
        if self.input_revision == input_revision {
            let _ = handle.scroll_to_bottom();
        }
        self.render_states.remove(&surface);
        if self.selection_generation == selection_generation
            && self.selection == selection_at_invocation
            && self.selection.is_some_and(|selection| selection.surface == surface)
        {
            self.replace_selection(None);
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_session_mutation_settled(
        &mut self,
        outcome: SessionMutationOutcome,
        impact: MutationImpact,
    ) -> anyhow::Result<RenderAction> {
        self.session.settle_pending_mutation(impact);
        let (semantic_intent, outcome) = match outcome {
            SessionMutationOutcome::SemanticIntent { intent, outcome } => (Some(intent), *outcome),
            outcome => (None, outcome),
        };
        match outcome {
            SessionMutationOutcome::SemanticIntent { .. } => {
                unreachable!("semantic mutation outcomes are unwrapped once")
            }
            SessionMutationOutcome::Success { tree } => {
                if let Some(tree) = tree {
                    self.replace_tree(tree);
                }
                // A visible remote surface can require a separate
                // resize after attach when the peer lacks atomic
                // initial sizing. Retry the deferred authority claim
                // after that resize settles.
                self.claim_active_terminal_geometry(false);
                self.layout_refresh_retries_remaining = 0;
            }
            SessionMutationOutcome::AuthoritativeMutationSucceeded {
                tree,
                authoritative_generation,
                destination_generation,
                completion,
            } => {
                self.session.clear_surface_sync_failures();
                self.replace_authoritative_tree(tree, destination_generation);
                self.layout_refresh_retries_remaining = 0;
                if let Some(completion) = completion {
                    self.pending_session_completions.push_back(completion);
                }
                self.apply_session_completions_through(authoritative_generation);
            }
            SessionMutationOutcome::IdentityRefreshSucceeded {
                tree,
                authoritative_generation,
                destination_generation,
                refresh_sequence,
            } => {
                if !self.accept_refresh_sequence(refresh_sequence) {
                    let applied_completion =
                        self.apply_session_completions_through(authoritative_generation);
                    return Ok(if applied_completion {
                        RenderAction::Draw
                    } else {
                        RenderAction::None
                    });
                }
                self.session.clear_surface_sync_failures();
                self.session.reconcile_retired_surfaces(&tree);
                self.replace_authoritative_tree(tree, destination_generation);
                self.layout_refresh_retries_remaining = 0;
                self.background_refresh_attempts = 0;
                self.background_refresh_retry_at = None;
                self.apply_session_completions_through(authoritative_generation);
                self.complete_remote_tree_refresh(true);
                self.session.reconcile_ambiguous_creations();
            }
            SessionMutationOutcome::CommittedTreeStale { error, completion } => {
                if let Some(completion) = completion {
                    self.pending_session_completions.push_back(completion);
                }
                self.layout_refresh_retries_remaining = LAYOUT_REFRESH_RETRIES;
                if let Some(error) = error {
                    self.status_message = Some(
                        localization::catalog()
                            .sidebar
                            .layout_refresh_failed
                            .replace("{error}", error.as_str()),
                    );
                }
                self.session.invalidate_remote_tree();
                self.session.refresh_remote_tree_if_stale();
            }
            SessionMutationOutcome::IdentityRefreshFailed { error, refresh_sequence } => {
                if !self.accept_refresh_sequence(refresh_sequence) {
                    return Ok(RenderAction::None);
                }
                self.status_message = Some(
                    localization::catalog().sidebar.layout_stale.replace("{error}", error.as_str()),
                );
                let refresh_stale = self.layout_refresh_retries_remaining > 0;
                if refresh_stale {
                    self.layout_refresh_retries_remaining -= 1;
                    self.session.invalidate_remote_tree();
                }
                self.complete_remote_tree_refresh(refresh_stale);
                return Ok(RenderAction::Draw);
            }
            SessionMutationOutcome::SurfaceSyncFailed {
                surface,
                operation,
                error,
                reconnect_required,
            } => {
                if self
                    .pending_pointer_motion
                    .is_some_and(|pointer| pointer.destination == Some(surface))
                {
                    self.pending_pointer_motion = None;
                }
                if reconnect_required {
                    self.deferred_input
                        .retain(|input| input.admission.destination != Some(surface));
                    self.status_message = Some(
                        localization::catalog()
                            .attach
                            .surface_sync_unknown(surface, operation, &error),
                    );
                } else {
                    self.status_message = Some(
                        localization::catalog()
                            .attach
                            .surface_sync_failed(surface, operation, &error),
                    );
                }
            }
            SessionMutationOutcome::SurfaceSizeReleased { surface } => {
                let expected = self.pending_size_releases.remove(&surface);
                if expected {
                    self.visible_size_surfaces.remove(&surface);
                } else if self.visible_size_surfaces.remove(&surface) {
                    // A release already in flight can settle after the
                    // pane becomes visible. Force the next draw to
                    // reclaim its lease even if geometry is unchanged.
                    self.session.invalidate_surface_size_report(surface);
                }
            }
            SessionMutationOutcome::SurfaceSizeReleaseFailed { surface, error } => {
                if self.pending_size_releases.remove(&surface) {
                    self.session.invalidate_surface_size_report(surface);
                    if self.pane_areas.iter().any(|area| area.surface == surface) {
                        self.visible_size_surfaces.remove(&surface);
                    }
                    self.status_message = Some(
                        localization::catalog().layout.surface_size_release_failed(surface, &error),
                    );
                }
            }
            SessionMutationOutcome::SurfaceSizeReleaseCanceled { surface } => {
                self.pending_size_releases.remove(&surface);
            }
            SessionMutationOutcome::ClientSizingChanged => {
                self.session.refresh_clients_background();
            }
            SessionMutationOutcome::CreationResponseAmbiguous(error) => {
                crate::client_log::stderr_log!(
                    "session",
                    "{BIN}: session creation response was ambiguous: {error}"
                );
                self.status_message =
                    Some(localization::catalog().session.creation_reconciling.to_string());
                self.layout_refresh_retries_remaining = LAYOUT_REFRESH_RETRIES;
                self.session.invalidate_remote_tree();
                self.session.refresh_remote_tree_if_stale();
                return Ok(RenderAction::Draw);
            }
            SessionMutationOutcome::MutationTimedOut(error) => {
                crate::client_log::stderr_log!(
                    "session",
                    "{BIN}: session operation timed out: {error}"
                );
                if let Some(intent) = semantic_intent {
                    // A peer without creation receipts cannot identify
                    // which surface, if any, a timed-out creation made.
                    // Fail only that route so dependent input is never
                    // guessed onto whichever surface became active.
                    self.mark_semantic_destination_failed(intent);
                }
                self.status_message =
                    Some(localization::catalog().session.operation_reconciling.to_string());
                self.layout_refresh_retries_remaining = LAYOUT_REFRESH_RETRIES;
                self.session.invalidate_remote_tree();
                self.session.refresh_remote_tree_if_stale();
                return Ok(RenderAction::Draw);
            }
            SessionMutationOutcome::Failed(error) => {
                crate::client_log::stderr_log!(
                    "session",
                    "{BIN}: session operation failed: {error}"
                );
                if let Some(intent) = semantic_intent {
                    self.mark_semantic_destination_failed(intent);
                    self.status_message =
                        Some(localization::catalog().session.operation_failed.to_string());
                    return Ok(RenderAction::Draw);
                }
                self.deferred_input.clear();
                self.prefix_armed = false;
                self.pending_session_completions.clear();
                self.status_message =
                    Some(localization::catalog().session.operation_failed.to_string());
                return Ok(RenderAction::Draw);
            }
            SessionMutationOutcome::Canceled => {
                if let Some(intent) = semantic_intent {
                    self.mark_semantic_destination_failed(intent);
                    self.status_message =
                        Some(localization::catalog().session.operation_canceled.to_string());
                    return Ok(RenderAction::Draw);
                }
                if self.session.has_pending_mutations() {
                    self.session.defer_cancellation();
                    return Ok(RenderAction::None);
                }
                self.apply_session_cancellation();
                return Ok(RenderAction::Draw);
            }
        }
        self.session.refresh_remote_tree_if_stale();
        if self.session.has_pending_mutations() || self.session.remote_tree_is_stale() {
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_remote_tree_updated(
        &mut self,
        refresh_sequence: u64,
        destination_generation: u64,
        result: Result<TreeView, String>,
    ) -> anyhow::Result<RenderAction> {
        if !self.accept_refresh_sequence(refresh_sequence) {
            return Ok(RenderAction::None);
        }
        let refreshed = match result {
            Ok(tree) => {
                self.session.reconcile_retired_surfaces(&tree);
                self.replace_authoritative_tree(tree, destination_generation);
                self.layout_refresh_retries_remaining = 0;
                self.background_refresh_attempts = 0;
                self.background_refresh_retry_at = None;
                true
            }
            Err(error) => {
                let retrying = self.schedule_background_refresh_retry();
                let template = if retrying {
                    localization::catalog().sidebar.refresh_remote_tree_retrying
                } else {
                    localization::catalog().sidebar.refresh_remote_tree_stopped
                };
                self.status_message = Some(
                    template
                        .replace("{attempts}", &BACKGROUND_REFRESH_RETRIES.to_string())
                        .replace("{error}", error.as_str()),
                );
                let _ = self.session.take_background_refresh_dirty();
                false
            }
        };
        if refreshed {
            self.complete_remote_tree_refresh(true);
            self.session.reconcile_ambiguous_creations();
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn on_clients_updated(
        &mut self,
        generation: u64,
        result: Result<Vec<ClientInfo>, String>,
    ) -> anyhow::Result<RenderAction> {
        if generation != self.session.client_refresh_generation() {
            return Ok(RenderAction::None);
        }
        match result {
            Ok(clients) => self.replace_clients(clients),
            Err(error) => {
                self.status_message = Some(
                    localization::catalog()
                        .sidebar
                        .clients_list_failed
                        .replace("{error}", error.as_str()),
                );
            }
        }
        Ok(RenderAction::Draw)
    }
}
