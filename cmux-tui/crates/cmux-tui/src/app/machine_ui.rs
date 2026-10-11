//! Machine UI updates: managed workspace session mutations, machine UI state
//! updates, installing a prepared machine session, and presenting a machine
//! as asleep or waking it.

use std::path::PathBuf;

use crate::app::machine_worker::{PreparedMachineSession, uses_provider_managed_workspaces};
use crate::app::menu::context_menu::ContextMenu;
use crate::app::overlays::PromptTarget;
use crate::app::pointer::deferred::PointerRoutePhase;
use crate::app::pointer::route::RenderedPointerFrame;
use crate::app::{
    App, PaneFocusHistory, RenderAction, WorkspaceRailSelection, publishes_global_cell_metrics,
};
use crate::localization;
use crate::machine::{
    MachineConnectionPhase, MachineKey, MachineRailTarget, MachineRequest, MachineUiState,
    ManagedMachineStatus, ManagedWorkspaceSessionMutation,
};
use crate::session::TreeView;
use crate::sidebar_files::FileBrowser;

impl App {
    pub(super) fn apply_managed_workspace_session_mutation(
        &mut self,
        mutation: ManagedWorkspaceSessionMutation,
    ) {
        if !self.session.workspaces_are_provider_managed()
            && let Err(error) = self.session.mark_workspaces_provider_managed()
        {
            self.status_message = Some(
                localization::catalog()
                    .sidebar
                    .workspace_state_failed
                    .replace("{error}", &error.to_string()),
            );
            return;
        }
        let (workspace_key, rename) = match mutation {
            ManagedWorkspaceSessionMutation::Rename { workspace_key, name } => {
                (workspace_key, Some(name))
            }
            ManagedWorkspaceSessionMutation::Close { workspace_key } => (workspace_key, None),
        };
        let Some(workspace_id) = self
            .tree
            .workspaces()
            .iter()
            .find(|workspace| workspace.key == workspace_key)
            .map(|workspace| workspace.id)
        else {
            self.status_message =
                Some(localization::catalog().sidebar.managed_workspace_unavailable.to_string());
            return;
        };
        // Queued mirror failures settle through SessionMutationOutcome::Failed.
        // Missing mirrors must be surfaced here because no operation is queued.
        if let Some(name) = rename {
            self.session.rename_provider_managed_workspace(workspace_id, workspace_key, name);
        } else {
            self.session.close_provider_managed_workspace(workspace_id, workspace_key);
        }
    }

    pub(super) fn apply_machine_ui_update(&mut self, mut update: MachineUiState) -> RenderAction {
        if self.machine_ui.is_none()
            && self.machine_selection_intent.is_none()
            && self.machine_presented.is_none()
        {
            self.machine_selection_intent = update.snapshot.active;
            self.machine_presented = update.snapshot.active;
        }
        // A machine is "usable" while it is in the catalog and not soft
        // deleted: providers with recovery keep deleted machines listed as
        // Recoverable rows, which can be restored or purged but never
        // presented.
        let machine_usable = |update: &MachineUiState, key: MachineKey| {
            update.snapshot.machines.iter().any(|machine| machine.key == key)
                && update
                    .managed_machine(key)
                    .is_none_or(|managed| managed.status != ManagedMachineStatus::Recoverable)
        };
        update.snapshot.active =
            self.machine_presented.filter(|presented| machine_usable(&update, *presented));
        // A queued switch aimed at a machine that just became unusable (the
        // wake that raced its own deletion) must not survive: it would both
        // fail pointlessly and block the failover below.
        let doomed_request = match &update.request {
            // The wake that raced its own deletion.
            Some(MachineRequest::Switch(target)) => !machine_usable(&update, *target),
            // The stream-loss recovery for the machine being deleted: the
            // provider link is demonstrably alive (this update just arrived
            // over it), and reconnecting would only reopen the deleted
            // machine. Let the failover below aim somewhere usable instead.
            Some(MachineRequest::ReconnectProvider) => {
                self.machine_presented.is_some_and(|presented| !machine_usable(&update, presented))
            }
            _ => false,
        };
        if doomed_request {
            crate::client_log::info(
                "machine",
                "dropped a queued request aimed at a deleted machine",
            );
            update.request = None;
            // An intent left aiming at the deleted machine would fail the
            // input-routing gate forever (intent != presented with nothing
            // queued to repair it): fall back to the still-usable presented
            // machine, or clear it so the failover below takes over.
            if self.machine_selection_intent.is_some_and(|intent| !machine_usable(&update, intent))
            {
                self.machine_selection_intent =
                    self.machine_presented.filter(|presented| machine_usable(&update, *presented));
            }
        }
        // The presented machine was deleted (gone from the catalog, or left
        // behind as a Recoverable row): its session is dead, so input must
        // never route into it, whatever else is queued or in flight.
        let presented_deleted =
            self.machine_presented.is_some_and(|presented| !machine_usable(&update, presented));
        if !presented_deleted {
            // A deferred deletion can recover before failover runs. Do not
            // carry its old slot into a later, unrelated deletion.
            self.machine_deleted_rail_index = None;
        }
        if presented_deleted {
            if self.machine_deleted_rail_index.is_none()
                && let Some(presented) = self.machine_presented
            {
                self.machine_deleted_rail_index = self.machine_ui.as_ref().and_then(|previous| {
                    previous.snapshot.machines.iter().position(|machine| machine.key == presented)
                });
            }
            update.session_available = false;
        }
        // Switch to the next available machine instead of leaving the dead
        // session on screen. "Next" is the usable machine at or after its
        // old list slot, else the last usable one. Deferred (input stays
        // gated above) while another request occupies the queue slot or the
        // user is already aiming somewhere else usable; the next update
        // with a free slot re-enters this path.
        let mut failover_rail_target = None;
        let failed_intent_is_stale = self
            .machine_selection_intent
            .filter(|intent| Some(*intent) != self.machine_presented)
            .is_some_and(|intent| {
                !self.machine_action_in_flight
                    && (update.connection_phase(intent) == MachineConnectionPhase::Failed
                        || self.machine_ui.as_ref().is_some_and(|previous| {
                            previous.connection_phase(intent) == MachineConnectionPhase::Failed
                        }))
            });
        if presented_deleted
            && let Some(presented) = self.machine_presented
            && update.request.is_none()
            && !self.machine_action_in_flight
            && self.machine_selection_intent.is_none_or(|intent| {
                intent == presented || !machine_usable(&update, intent) || failed_intent_is_stale
            })
        {
            let previous_index = self
                .machine_deleted_rail_index
                .or_else(|| {
                    self.machine_ui
                        .as_ref()
                        .and_then(|previous| {
                            previous
                                .snapshot
                                .machines
                                .iter()
                                .position(|machine| machine.key == presented)
                        })
                        .or_else(|| {
                            update
                                .snapshot
                                .machines
                                .iter()
                                .position(|machine| machine.key == presented)
                        })
                })
                .unwrap_or(0);
            let next_key = update
                .snapshot
                .machines
                .iter()
                .enumerate()
                .filter(|(_, machine)| machine_usable(&update, machine.key))
                .map(|(index, machine)| (index, machine.key))
                .fold(None, |best: Option<(usize, MachineKey)>, (index, key)| match best {
                    // Prefer the first usable machine at or after the old
                    // slot; otherwise keep the last usable one before it.
                    Some((chosen, _)) if chosen >= previous_index => best,
                    _ if index >= previous_index => Some((index, key)),
                    _ => Some((index, key)),
                })
                .map(|(_, key)| key);
            match next_key {
                Some(next_key) => {
                    crate::client_log::info(
                        "machine",
                        &format!(
                            "presented machine {} was deleted; switching to {}",
                            presented.0, next_key.0
                        ),
                    );
                    update.request = Some(MachineRequest::Switch(next_key));
                    failover_rail_target = Some(next_key);
                    self.machine_deleted_rail_index = None;
                    // The presented session belongs to a deleted machine:
                    // gate input away from it while the failover switch runs
                    // (a failed switch leaves the rail on the replacement,
                    // where Enter retries).
                    update.session_available = false;
                }
                None => {
                    crate::client_log::info(
                        "machine",
                        &format!(
                            "presented machine {} was deleted; no usable machine remains",
                            presented.0
                        ),
                    );
                    // Nothing usable remains: drop the presentation instead
                    // of routing input into the deleted machine's dead
                    // session. The rail keeps its create and connect rows.
                    self.machine_presented = None;
                    self.machine_selection_intent = None;
                    self.machine_deleted_rail_index = None;
                    update.session_available = false;
                }
            }
        }
        let guard_error = (uses_provider_managed_workspaces(Some(&update))
            && !self.session.workspaces_are_provider_managed())
        .then(|| self.session.mark_workspaces_provider_managed().err())
        .flatten()
        .map(|error| error.to_string());
        if guard_error.is_some() {
            update.session_available = false;
        }
        let provider_changed = self
            .machine_ui
            .as_ref()
            .and_then(|machine| machine.provider.as_ref())
            != update.provider.as_ref()
            || self.machine_ui.as_ref().map(MachineUiState::managed_workspaces).unwrap_or_default()
                != update.managed_workspaces()
            || self.machine_ui.as_ref().map(MachineUiState::managed_machines).unwrap_or_default()
                != update.managed_machines();
        if provider_changed {
            if self.menu.as_ref().is_some_and(ContextMenu::targets_provider_state) {
                self.menu = None;
            }
            if self.prompt.as_ref().is_some_and(|prompt| {
                matches!(
                    prompt.target,
                    PromptTarget::ProviderAction(_)
                        | PromptTarget::ConfirmProviderAction
                        | PromptTarget::ManagedWorkspace(_)
                        | PromptTarget::ConfirmPurgeManagedWorkspace(_)
                        | PromptTarget::ManagedMachine(_)
                        | PromptTarget::ConfirmDeleteManagedMachine(_)
                        | PromptTarget::ConfirmPurgeManagedMachine(_)
                )
            }) {
                self.prompt = None;
                self.pending_provider_action = None;
            }
        }
        if let Some(previous) = self.machine_ui.as_ref() {
            if let Some(MachineRequest::Switch(machine)) = previous.request.as_ref()
                && self.machine_selection_intent == Some(*machine)
                && machine_usable(&update, *machine)
                && update.request.is_none()
            {
                crate::client_log::info(
                    "machine",
                    &format!("preserving the pending switch to {}", machine.0),
                );
                update.request = Some(MachineRequest::Switch(*machine));
            }
            update.extend_connection_phases_from(previous);
            update.reconcile_navigation_from(previous);
        }
        if let Some(next_key) = failover_rail_target {
            // After reconciliation, which would otherwise keep the still
            // listed (recoverable) row selected.
            update.select_rail_target(MachineRailTarget::Machine(next_key));
        }
        let notice = update.notice.clone();
        self.machine_ui = Some(update);
        self.machine_pointer_context_cache = None;
        self.reconcile_workspace_rail_selection();
        if let Some(error) = guard_error {
            self.status_message = Some(error);
        } else if let Some(notice) = notice {
            self.status_notice_text = Some(notice.clone());
            self.status_message = Some(notice);
        }
        RenderAction::Draw
    }
}

impl App {
    pub(super) fn install_prepared_machine_session(
        &mut self,
        prepared: PreparedMachineSession,
        retire_previous: bool,
    ) {
        self.cancel_pointer_interaction();
        let PreparedMachineSession {
            session,
            event_worker,
            generation,
            mux_titles,
            mux_recovery_generation,
            tree,
            label,
            session_available,
            machine: _,
        } = prepared;
        self.pty_input.activate_session_generation(generation);
        self.session_generation = generation;
        self.last_frontend_presentation = None;
        let previous_session = std::mem::replace(&mut self.session, session);
        let previous_worker = self.session_event_worker.replace(event_worker);
        self.mux_titles = mux_titles;
        self.mux_recovery_generation = mux_recovery_generation;
        self.session_label = label;
        self.reset_session_presentation(tree);
        if let Some(worker) = self.session_event_worker.as_ref() {
            worker.activate();
        }
        if session_available {
            if publishes_global_cell_metrics(self.surface_only) {
                self.session.set_cell_pixel_size(self.cell_pixels.0, self.cell_pixels.1);
            }
            self.session.apply_config(self.config.clone());
            self.session.refresh_clients_background();
            self.session.refresh_machine_usage_background();
        }

        if let Some(mut previous_worker) = previous_worker {
            previous_worker.stop_and_join();
        }
        if retire_previous {
            previous_session.begin_shutdown();
        }
    }

    pub(super) fn reset_session_presentation(&mut self, tree: TreeView) {
        for surface in self.tab_locations.keys().copied().collect::<Vec<_>>() {
            self.browser_input.forget_surface(surface);
        }
        self.tree = tree;
        // The readout belongs to the previous daemon; the replacement's own
        // value arrives from its background refresh.
        self.machine_usage = None;
        self.tab_locations.clear();
        self.rebuild_tab_locations();
        self.render_states.clear();
        self.pane_areas.clear();
        self.viewport_projection.clear();
        self.viewport_layout.clear();
        self.viewport_stacked_headers.clear();
        self.viewport_states.clear();
        self.viewport_virtual_width = 0;
        self.viewport_offset = 0;
        self.pane_focus_history = PaneFocusHistory::default();
        self.pane_focus_history.sync_membership(&self.tree);
        // The adopted tree's focus is the server's own; report only what the
        // user changes afterwards.
        self.reported_focus = self.current_client_focus();
        self.restore_client_focus_from_session();
        self.rendered_terminal_sizes.clear();
        self.rendered_terminal_pointer_semantics.clear();
        self.rendered_pane_content_generations.clear();
        self.rendered_terminal_bounds.clear();
        self.rendered_kitty_graphics.clear();
        self.graphics_scene_cache.invalidate();
        self.graphics_dirty_surfaces.clear();
        self.visible_size_surfaces.clear();
        self.pending_size_releases.clear();
        self.geometry_authority_surface = None;
        self.prefix_armed = false;
        self.sidebar_focus_pending = false;
        self.sidebar_files =
            FileBrowser::new(std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        self.sidebar_workspace_selection =
            self.tree.active_workspace.min(self.tree.workspaces().len().saturating_sub(1));
        self.sidebar_recoverable_workspace_selection = 0;
        self.workspace_rail_selection = WorkspaceRailSelection::Workspace;
        self.tabs_rail_selection = 0;
        self.tabs_rail_scroll = 0;
        self.tabs_rail_follow_selection = true;
        self.sidebar_followed_surface = None;
        self.sidebar_plugin_surface = None;
        self.sidebar_plugin_error = None;
        self.sidebar_plugin_retry_after_ms = None;
        self.sidebar_plugin_retry_at = None;
        self.hits.clear();
        self.tab_scroll.clear();
        self.hover = None;
        self.menu = None;
        self.clients.clear();
        self.client_border_labels.clear();
        self.size_state_labels.clear();
        self.prompt = None;
        self.pairing_dialog = None;
        self.pairing_queue.clear();
        self.omnibar = None;
        self.toast = None;
        self.shake_frames = 0;
        self.replace_selection(None);
        self.reset_selection_click_sequence();
        self.last_browser_hover = None;
        self.deferred_input.clear();
        self.pending_pointer_motion = None;
        self.deferred_input_sequence = 0;
        self.rendered_pointer_frame = RenderedPointerFrame::default();
        // Retain processed and in-flight graphics state until the replacement
        // session presents its first snapshot. The writer may still present
        // an older accepted submission before the replacement is written.
        self.pointer_route_phase = PointerRoutePhase::DrawPending;
        self.layout_refresh_retries_remaining = 0;
        self.background_refresh_attempts = 0;
        self.background_refresh_retry_at = None;
        self.last_applied_refresh_sequence = 0;
        self.applied_destination_generation = 0;
        self.pending_session_completions.clear();
        self.drag = None;
        self.active_pointer_buttons.clear();
        self.ignored_pty_mouse_buttons.clear();
        self.encode_buf.clear();
    }

    /// A machine that is sleeping or stopped lost its stream BECAUSE it was
    /// paused; reconnecting would start it right back up and make pause
    /// impossible. Present it as asleep instead - the user's next input (or
    /// a rail click) wakes it through the normal switch path.
    pub(super) fn present_machine_as_asleep_after_stream_loss(&mut self) -> bool {
        let Some(machine) = self.machine_ui.as_mut() else { return false };
        let Some(active) = machine.snapshot.active else { return false };
        if !machine.snapshot.machines.iter().any(|descriptor| {
            descriptor.key == active
                && matches!(
                    descriptor.status,
                    crate::machine::MachineStatus::Sleeping
                        | crate::machine::MachineStatus::Stopped
                )
        }) {
            return false;
        }
        crate::client_log::info(
            "machine",
            &format!("stream lost for sleeping machine {}; presenting as asleep", active.0),
        );
        machine.session_available = false;
        machine.set_connection_phase(active, MachineConnectionPhase::Disconnected);
        // The previous open's narration is stale now; a later wake
        // reuses the same selection intent, so select_machine_intent
        // will not clear it.
        machine.clear_connection_progress(active);
        true
    }

    pub(super) fn request_current_machine_session(&mut self) -> bool {
        if self.present_machine_as_asleep_after_stream_loss() {
            return true;
        }
        let Some(machine) = self.machine_ui.as_mut() else { return false };
        if machine.request.is_none() {
            let request = machine
                .snapshot
                .active
                .map_or(MachineRequest::ReconnectProvider, MachineRequest::Switch);
            crate::client_log::info(
                "machine",
                &format!("stream lost; queueing {request:?} to reconnect"),
            );
            machine.request = Some(request);
        }
        true
    }

    /// The user typed at a machine whose session is gone (it paused or the
    /// stream died while they were away). Queue a switch back to it: the
    /// provider resumes the VM and the interstitial shows the live loading
    /// states. Returns false when there is nothing sensible to wake.
    pub(super) fn wake_presented_machine(&mut self) -> bool {
        let Some(presented) = self.machine_presented else { return false };
        // While a switch to a DIFFERENT machine is in flight the key must
        // not re-aim back at the old machine (that could resume a machine
        // the user deliberately left paused). Consume it; the transition
        // interstitial is visible and the switch will settle.
        if self.machine_selection_intent.is_some_and(|intent| intent != presented) {
            return true;
        }
        {
            let Some(machine) = self.machine_ui.as_mut() else { return false };
            if machine.request.is_some() {
                return true;
            }
            machine.request = Some(MachineRequest::Switch(presented));
        }
        self.select_machine_intent(presented);
        if let Some(ui) = self.machine_ui.as_mut() {
            // select_machine_intent keeps the presented machine's phase; the
            // wake is a real reconnect, so the interstitial must show it.
            ui.set_connection_phase(presented, MachineConnectionPhase::Connecting);
        }
        true
    }
}
