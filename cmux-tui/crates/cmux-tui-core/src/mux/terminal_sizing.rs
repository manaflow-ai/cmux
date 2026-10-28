//! Shared terminal sizing: geometry claims, view participants and sub-views, size policies, the sizing engine entries, size state publication, and client size participation.

use super::*;
use std::sync::PoisonError;

mod grid_hold;
mod handheld_ceiling;
pub(super) use grid_hold::AppliedSeat;
pub(crate) mod host_policy;
mod thread_qos;

impl Mux {
    /// Activity by one client view: attach, explicit focus-click, or keyboard,
    /// paste or mouse input. Under the default `latest` policy the view takes
    /// the grid when it has reported a viewport. Returns whether the
    /// published size state changed.
    pub fn claim_terminal_geometry(&self, surface: SurfaceId, client: u64) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        if client != 0 && !self.control_clients.contains(client) {
            return None;
        }
        Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
            if sizing.detached_views.contains(&(client, surface)) {
                return false;
            }
            sizing.terminal_runtime_by_placement.insert(surface, runtime);
            let id = sizing.view_participant_id(runtime, surface, client);
            let participant = mux.view_participant(sizing, runtime, surface, client);
            let mut member = sizing.own_view_member(runtime, surface, client);
            let geometry_before = member.placement;
            // As an attach: a view with no report yet takes the geometry on
            // its first report, so the participant keeps its viewport.
            member.join_view(surface, |view| sizing.has_report(view, client));
            let moved = member.placement != geometry_before;
            let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
            entry.members.insert(id.clone(), member);
            let changed = if entry.engine.contains(&id) {
                // A claim on another view of the participant makes it the
                // geometry view, with its report.
                let reported =
                    moved && Self::report_view_viewport(entry, &id, participant.viewport);
                reported | entry.engine.note_activity(&id)
            } else {
                entry.engine.attach(participant)
            };
            sizing.note_size_state(runtime, changed);
            changed
        }))
    }

    /// Sets participant `id`'s viewport to its geometry view's report.
    pub(super) fn report_view_viewport(
        entry: &mut TerminalSizingEntry,
        id: &str,
        viewport: Option<TerminalGridSize>,
    ) -> bool {
        let viewport = viewport.map(TerminalGridSize::clamped);
        match entry.engine.participant(id).map(|current| current.viewport) {
            None => false,
            Some(current) if current == viewport => false,
            Some(_) => match viewport {
                Some(viewport) => entry.engine.report(id, viewport),
                None => entry.engine.clear_viewport(id),
            },
        }
    }

    /// Keyboard, paste or mouse input from an attached client. Unlike
    /// [`Self::claim_terminal_geometry`] it never adds a participant, so a
    /// one-shot `send` from an unattached connection cannot take the grid.
    pub(crate) fn note_terminal_input(&self, surface: SurfaceId, client: u64) {
        if self.note_terminal_activity(surface, client, None).is_some() {
            self.activity.note_user_input();
        }
    }

    /// Activity of the caller's own view (`view:None`) or of one of its relay
    /// sub-views, for example a phone whose input a Mac mirror forwards.
    /// `None` means the terminal or participant does not exist; otherwise
    /// whether the published size state changed.
    pub(crate) fn note_terminal_activity(
        &self,
        surface: SurfaceId,
        client: u64,
        view: Option<&str>,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let id = match view {
                Some(view) => sub_view_participant_id(client, view),
                None => sizing.view_participant_id(runtime, surface, client),
            };
            if view.is_none() && sizing.detached_views.contains(&(client, surface)) {
                // A detached view's input is not its participant's activity.
                return None;
            }
            let viewport = sizing.view_report(surface, client);
            let mut member = sizing
                .terminal_sizing
                .get(&runtime)?
                .members
                .get(&id)
                .filter(|member| member.client == client)?
                .clone();
            let geometry_before = member.placement;
            if view.is_none() && member.views.contains(&surface) && member.placement != surface {
                // Input on another view of the same participant makes it the
                // geometry view, once it has a report (as an attach).
                member.join_view(surface, |view| sizing.has_report(view, client));
            }
            let moved = member.placement != geometry_before;
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            entry.members.insert(id.clone(), member);
            let mut changed = moved && Self::report_view_viewport(entry, &id, viewport);
            changed |= entry.engine.note_activity(&id);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Restore the automatic counts rule for every view of this terminal.
    /// This is the terminal meaning of the legacy "use all client sizes".
    pub fn release_terminal_geometry(&self, surface: SurfaceId) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        Some(self.mutate_terminal_sizing(runtime, |_, sizing| {
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { return false };
            let ids = entry.engine.participant_ids().map(str::to_owned).collect::<Vec<_>>();
            let mut changed = false;
            for id in ids {
                if entry.engine.participant(&id).is_some_and(|p| p.counts_override.is_some()) {
                    changed |= entry.engine.set_counts_override(&id, None);
                }
            }
            sizing.note_size_state(runtime, changed);
            changed
        }))
    }

    /// Mirror a client view's attachment and latest report into the sizing
    /// engine after an attach commits. Idempotent.
    pub(crate) fn sync_terminal_client_view(&self, surface: SurfaceId, client: u64) {
        let Some(runtime) = self.surface(surface).and_then(|surface| surface.terminal_runtime_id())
        else {
            return;
        };
        self.mutate_terminal_sizing(runtime, |mux, sizing| {
            mux.sync_terminal_view_locked(sizing, runtime, surface, client);
        });
    }

    /// Push a client's changed identity into every engine it participates in.
    pub(crate) fn refresh_terminal_client_identity(&self, client: u64) {
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let identity = self.client_sizing_identity(client);
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        for runtime in runtimes {
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            let views = entry
                .members
                .iter()
                .filter(|(_, member)| member.client == client && member.view.is_none())
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let mut changed = false;
            for id in views {
                let mut participant = TerminalSizingParticipant::new(id, identity.device_kind);
                participant.user_id = identity.user_id.clone();
                participant.display_name = identity.display_name.clone();
                participant.device_name = identity.device_name.clone();
                participant.device_id = identity.device_id.clone();
                changed |= entry.engine.update_identity(&participant);
            }
            sizing.note_size_state(runtime, changed);
            // A changed identity may change which views are this Mac's.
            self.refresh_host_policy_locked(&mut sizing, runtime);
            // The same-user handheld rule may change who counts.
            self.apply_terminal_grid(&sizing, runtime);
        }
        drop(sizing);
        self.publish_size_states();
    }

    /// Create or update one relay sub-view (for example a phone behind a Mac
    /// mirror) and record its viewport. Returns the host participant id and
    /// whether the view now sets a dimension of the grid.
    pub(crate) fn report_terminal_sub_view(
        &self,
        surface: SurfaceId,
        client: u64,
        view: &str,
        identity: Option<ClientSizingIdentity>,
        viewport: Option<(u16, u16)>,
    ) -> anyhow::Result<(String, bool)> {
        let runtime = self
            .surface(surface)
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?
            .terminal_runtime_id()
            .ok_or_else(|| anyhow::anyhow!("relay views are supported only for terminals"))?;
        anyhow::ensure!(
            self.control_clients.attached_client_ids_for_surface(surface).contains(&client),
            "relay views require an attached relay connection for surface {surface}"
        );
        let id = sub_view_participant_id(client, view);
        let owns = self.mutate_terminal_sizing(runtime, |mux, sizing| {
            let via = sizing.view_participant_id(runtime, surface, client);
            let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
            entry.members.insert(id.clone(), SizingMember::sub_view(client, surface, view));
            let has_identity = identity.is_some();
            let identity = identity.unwrap_or_default();
            let participant = TerminalSizingParticipant {
                id: id.clone(),
                user_id: identity.user_id,
                display_name: identity.display_name,
                device_kind: identity.device_kind,
                device_name: identity.device_name,
                device_id: identity.device_id,
                via: Some(via),
                viewport: viewport.map(|(cols, rows)| TerminalGridSize::new(cols, rows)),
                counts_override: None,
            };
            let changed = if entry.engine.contains(&id) {
                let mut changed = has_identity && entry.engine.update_identity(&participant);
                changed |= match participant.viewport {
                    Some(viewport) => entry.engine.report(&id, viewport),
                    None => false,
                };
                changed
            } else {
                entry.engine.attach(participant)
            };
            sizing.note_size_state(runtime, changed);
            entry_owns(sizing, runtime, &id)
        });
        Ok((id, owns))
    }

    /// Forget one relay sub-view's viewport and keep it attached.
    pub(crate) fn release_terminal_sub_view(
        &self,
        surface: SurfaceId,
        client: u64,
        view: &str,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let id = sub_view_participant_id(client, view);
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if entry.members.get(&id).is_none_or(|member| member.client != client) {
                return None;
            }
            let changed = entry.engine.clear_viewport(&id);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Remove one relay sub-view. The next owner takes the grid.
    pub(crate) fn detach_terminal_sub_view(
        &self,
        surface: SurfaceId,
        client: u64,
        view: &str,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let id = sub_view_participant_id(client, view);
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if entry.members.get(&id).is_none_or(|member| member.client != client) {
                return None;
            }
            entry.members.remove(&id);
            let changed = entry.engine.detach(&id);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Resolve a host participant id on any terminal to its connection,
    /// placement and relay sub-view name.
    pub(crate) fn terminal_participant_member(
        &self,
        participant: &str,
    ) -> Option<(u64, SurfaceId, Option<String>)> {
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        sizing.terminal_sizing.values().find_map(|entry| {
            entry
                .members
                .get(participant)
                .map(|member| (member.client, member.placement, member.view.clone()))
        })
    }

    /// Resolve a host participant id on one terminal (participant ids are
    /// per terminal, so the same `c<client>` can name views of several).
    pub(crate) fn terminal_participant_member_on(
        &self,
        surface: SurfaceId,
        participant: &str,
    ) -> Option<(u64, SurfaceId, Option<String>)> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        sizing
            .terminal_sizing
            .get(&runtime)?
            .members
            .get(participant)
            .map(|member| (member.client, member.placement, member.view.clone()))
    }

    /// The connection and every placement of an own-view participant on the
    /// terminal shown at `surface`; `None` for a relay sub-view or an unknown id.
    pub(crate) fn terminal_participant_views_on(
        &self,
        surface: SurfaceId,
        participant: &str,
    ) -> Option<(u64, Vec<SurfaceId>)> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let member = sizing.terminal_sizing.get(&runtime)?.members.get(participant)?;
        member.view.is_none().then(|| (member.client, member.views.iter().copied().collect()))
    }

    /// Detach one connection's own view participant of the terminal shown at
    /// `placement`: every view of that participant (under
    /// [`ParticipantScheme::PerApp`] all of the connection's views of the
    /// terminal), keeping the connection, its streams and its relay
    /// sub-views. Each view stays out of the engine until
    /// [`Self::reattach_terminal_own_view`]. Returns the detached placements.
    pub(crate) fn detach_terminal_own_view(
        &self,
        placement: SurfaceId,
        client: u64,
    ) -> Option<Vec<SurfaceId>> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self.surface(placement)?.terminal_runtime_id()?;
        Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
            let mut views = sizing.own_view_member(runtime, placement, client).views;
            views.insert(placement);
            for view in &views {
                sizing.detached_views.insert((client, *view));
                mux.sync_terminal_view_locked(sizing, runtime, *view, client);
            }
            views.into_iter().collect()
        }))
    }

    /// Forgets the detach marks [`Self::detach_terminal_own_view`] set on
    /// `client`'s views at `placements` (one terminal) once their streams
    /// ended, so a later attach of that connection joins again.
    pub(crate) fn forget_terminal_own_view_detaches(&self, client: u64, placements: &[SurfaceId]) {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let Some(runtime) = placements
            .first()
            .and_then(|placement| self.surface(*placement))
            .and_then(|surface| surface.terminal_runtime_id())
        else {
            return;
        };
        self.mutate_terminal_sizing(runtime, |mux, sizing| {
            for &view in placements {
                if sizing.detached_views.remove(&(client, view)) {
                    mux.sync_terminal_view_locked(sizing, runtime, view, client);
                }
            }
        });
    }

    /// Restore one view detached by [`Self::detach_terminal_own_view`], with
    /// its latest report. Each detached view of a participant got its own
    /// notice and returns with its own reattach; the others stay detached.
    /// `counts` sets the participant's counts override (a viewer reattaches
    /// with `Some(false)`). Returns the view's participant id.
    pub(crate) fn reattach_terminal_own_view(
        &self,
        placement: SurfaceId,
        client: u64,
        counts: Option<bool>,
    ) -> anyhow::Result<String> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self
            .surface(placement)
            .and_then(|surface| surface.terminal_runtime_id())
            .ok_or_else(|| anyhow::anyhow!("surface {placement} is not a terminal"))?;
        self.mutate_terminal_sizing(runtime, |mux, sizing| {
            let id = sizing.view_participant_id(runtime, placement, client);
            anyhow::ensure!(
                sizing.detached_views.remove(&(client, placement)),
                "view of surface {placement} is not detached"
            );
            mux.sync_terminal_view_locked(sizing, runtime, placement, client);
            if let Some(entry) = sizing.terminal_sizing.get_mut(&runtime)
                && entry.engine.contains(&id)
                && counts.is_some()
            {
                let changed = entry.engine.set_counts_override(&id, counts);
                sizing.note_size_state(runtime, changed);
            }
            Ok(id)
        })
    }

    /// Set or clear one participant's explicit counts choice.
    pub fn set_terminal_size_counts(
        &self,
        surface: SurfaceId,
        participant: &str,
        counts: Option<bool>,
    ) -> Option<bool> {
        self.set_terminal_size_counts_hiding(surface, participant, counts, None)
    }

    /// Set (`Some`) or clear (`None`) a terminal's policy override.
    pub fn set_terminal_size_policy(
        &self,
        surface: SurfaceId,
        policy: Option<TerminalSizingPolicy>,
    ) -> Option<TerminalSizingState> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
            match policy {
                Some(policy) => sizing.terminal_size_policies.insert(runtime, policy),
                None => sizing.terminal_size_policies.remove(&runtime),
            };
            let resolved = mux.resolved_size_policy(sizing, runtime, surface);
            let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
            let changed = entry.engine.set_policy(resolved);
            let state = entry.engine.state().clone();
            sizing.note_size_state(runtime, changed);
            state
        }))
    }

    /// Sets how own views map to participants, as `terminalSizingPerApp`
    /// does at daemon start. Call before any view joins.
    #[cfg(test)]
    pub(crate) fn set_participant_scheme_for_test(&self, scheme: ParticipantScheme) {
        self.client_sizing.lock().unwrap().participant_scheme = scheme;
    }

    /// The participant scheme fixed at daemon start.
    pub(crate) fn participant_scheme(&self) -> ParticipantScheme {
        self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner).participant_scheme
    }

    /// Pins the `latest` policy on the workspace that shows `surface`, for
    /// tests about latest-activity semantics (`latest` is also the default; the pin keeps
    /// such a test independent of the default).
    #[cfg(test)]
    pub(crate) fn pin_latest_size_policy_for_test(&self, surface: SurfaceId) {
        let workspace = self.surface_workspace(surface).expect("surface has a workspace");
        self.set_workspace_size_policy(
            workspace,
            Some(TerminalSizingPolicy::new(
                crate::sizing_policy::TerminalSizingMode::Latest,
                Vec::new(),
                None,
            )),
        )
        .expect("pin latest size policy");
    }

    /// Set (`Some`) or clear (`None`) a workspace's default policy and apply
    /// it to every live terminal in that workspace without an override.
    pub(crate) fn set_workspace_size_policy(
        &self,
        workspace: WorkspaceId,
        policy: Option<TerminalSizingPolicy>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.with_state(|state| state.workspaces.iter().any(|w| w.id == workspace)),
            "unknown workspace {workspace}"
        );
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        match policy {
            Some(policy) => sizing.workspace_size_policies.insert(workspace, policy),
            None => sizing.workspace_size_policies.remove(&workspace),
        };
        let affected = sizing
            .terminal_sizing
            .iter()
            .filter(|(runtime, _)| !sizing.terminal_size_policies.contains_key(runtime))
            .filter_map(|(runtime, entry)| {
                // Any placement in the workspace: a terminal shown there and
                // elsewhere follows this default too (workspace_default_of).
                let placement = entry
                    .placements
                    .iter()
                    .copied()
                    .chain(self.runtime_placements(*runtime))
                    .find(|placement| self.surface_workspace(*placement) == Some(workspace))?;
                Some((*runtime, placement))
            })
            .collect::<Vec<_>>();
        let mut owner_changes = HashSet::new();
        for (runtime, placement) in affected {
            let owners_before = sizing.terminal_owner_clients(runtime);
            let resolved = self.resolved_size_policy(&sizing, runtime, placement);
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            let changed = entry.engine.set_policy(resolved);
            sizing.note_size_state(runtime, changed);
            self.apply_terminal_grid(&sizing, runtime);
            owner_changes.extend(
                owners_before
                    .symmetric_difference(&sizing.terminal_owner_clients(runtime))
                    .copied(),
            );
        }
        drop(sizing);
        self.publish_size_states();
        self.emit_client_sizing_changes(owner_changes);
        Ok(())
    }

    /// The terminal's published size state, creating its engine on demand.
    pub fn terminal_size_state(&self, surface: SurfaceId) -> Option<TerminalSizingState> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        Some(self.terminal_sizing_entry(&mut sizing, runtime, surface).engine.state().clone())
    }

    /// The host participant id of `client`'s own view of `surface`.
    pub fn terminal_view_participant_id(&self, surface: SurfaceId, client: u64) -> Option<String> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        Some(self.participant_scheme().view_participant_id(runtime, surface, client))
    }

    pub(crate) fn client_sizing_identity(&self, client: u64) -> ClientSizingIdentity {
        if client == 0 {
            // The in-process frontend, named after its host like a remote TUI.
            static DEVICE_NAME: OnceLock<String> = OnceLock::new();
            let device_name = DEVICE_NAME.get_or_init(|| {
                crate::platform::local_hostname().unwrap_or_else(|| "cmux-tui".to_string())
            });
            return ClientSizingIdentity {
                device_kind: TerminalDeviceKind::Tui,
                device_name: Some(device_name.clone()),
                ..ClientSizingIdentity::default()
            };
        }
        self.control_clients.sizing_identity(client).unwrap_or_default()
    }

    pub(super) fn view_participant(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) -> TerminalSizingParticipant {
        let identity = self.client_sizing_identity(client);
        TerminalSizingParticipant {
            id: sizing.view_participant_id(runtime, placement, client),
            user_id: identity.user_id,
            display_name: identity.display_name,
            device_kind: identity.device_kind,
            device_name: identity.device_name,
            device_id: identity.device_id,
            via: None,
            viewport: sizing.view_report(placement, client),
            counts_override: None,
        }
    }

    pub(super) fn resolved_size_policy(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
    ) -> TerminalSizingPolicy {
        if let Some(policy) = sizing.terminal_size_policies.get(&runtime) {
            return policy.clone();
        }
        self.workspace_default_of(sizing, runtime, placement)
            .or_else(|| self.host_policy_for(sizing, runtime))
            .or_else(|| sizing.host_policy.as_ref().map(|host| host.expand(&[])))
            .unwrap_or_default()
    }

    pub(super) fn terminal_sizing_entry<'a>(
        &self,
        sizing: &'a mut ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
    ) -> &'a mut TerminalSizingEntry {
        let policy = (!sizing.terminal_sizing.contains_key(&runtime))
            .then(|| self.resolved_size_policy(sizing, runtime, placement));
        let entry = sizing.terminal_sizing.entry(runtime).or_insert_with(|| {
            let (cols, rows) = self
                .surface(placement)
                .or_else(|| self.surface(runtime))
                .map_or((80, 24), |surface| surface.size());
            TerminalSizingEntry {
                engine: TerminalSizingEngine::new(
                    TerminalGridSize::new(cols, rows),
                    policy.unwrap_or_default(),
                ),
                placements: BTreeSet::new(),
                members: HashMap::new(),
                applied: std::cell::Cell::new(None),
                applied_participants: std::cell::RefCell::new(std::collections::BTreeMap::new()),
                hold: std::cell::Cell::new(None),
            }
        });
        entry.placements.insert(placement);
        entry
    }

    /// Mirror one client view's attachment and latest report into the
    /// engine. A view is present while its connection is attached to the
    /// placement or while it has a retained report. The view's participant
    /// stays while any of its views is present; its viewport is its geometry
    /// view's report, and a view that joins becomes the geometry view
    /// (attaching is activity).
    pub(super) fn sync_terminal_view_locked(
        &self,
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) {
        let id = sizing.view_participant_id(runtime, placement, client);
        let attached = client != 0
            && self.control_clients.attached_client_ids_for_surface(placement).contains(&client);
        let present = (attached || sizing.has_report(placement, client))
            && !sizing.detached_views.contains(&(client, placement));
        let known =
            sizing.terminal_sizing.get(&runtime).is_some_and(|entry| entry.engine.contains(&id));
        if !present && !known {
            return;
        }
        let mut member = sizing.own_view_member(runtime, placement, client);
        let geometry_before = member.placement;
        let reports = |view| sizing.has_report(view, client);
        let alive = if !present {
            member.leave_view(placement, reports)
        } else {
            if !known || !member.views.contains(&placement) {
                member.join_view(placement, reports);
            } else if reports(placement) {
                member.note_report(placement);
            } else {
                member.yield_geometry(placement, reports);
            }
            true
        };
        // A view that just took the participant's geometry is its activity
        // (attaching is activity).
        let joined = present && member.placement == placement && geometry_before != placement;
        let participant =
            alive.then(|| self.view_participant(sizing, runtime, member.placement, client));
        let entry = self.terminal_sizing_entry(sizing, runtime, placement);
        let changed = match participant {
            None => {
                entry.members.remove(&id);
                entry.engine.detach(&id)
            }
            Some(participant) => {
                entry.members.insert(id.clone(), member);
                if known {
                    let reported = Self::report_view_viewport(entry, &id, participant.viewport);
                    reported | (joined && entry.engine.note_activity(&id))
                } else {
                    entry.engine.attach(participant)
                }
            }
        };
        sizing.note_size_state(runtime, changed);
        self.refresh_host_policy_locked(sizing, runtime);
    }

    /// Resize the PTY to the engine's decision when that decision changed.
    /// A held grid is left alone.
    pub(super) fn apply_terminal_grid(&self, sizing: &ClientSizingState, runtime: SurfaceId) {
        let Some(entry) = sizing.terminal_sizing.get(&runtime) else { return };
        let state = entry.engine.state();
        if state.reason == TerminalSizingReason::Held {
            return;
        }
        let target = self.terminal_grid_target(entry, runtime, (state.cols, state.rows));
        if entry.applied.get() == Some(target) {
            return;
        }
        let Some(surface) = entry
            .placements
            .iter()
            .find_map(|placement| self.surface(*placement))
            .or_else(|| self.surface(runtime))
        else {
            return;
        };
        // Compare with the size last requested (a hosted mirror lags the
        // host by a round trip), and record the decision only once it is in
        // effect so that a failed resize is retried on the next decision.
        if surface.requested_size() == target
            || self.resize_surface(surface.id, target.0, target.1).is_ok()
        {
            entry.applied.set(Some(target));
        }
    }

    /// Run one engine mutation, apply the resulting grid, then publish size
    /// state and client ownership changes after the sizing lock is released.
    pub(super) fn mutate_terminal_sizing<R>(
        &self,
        runtime: SurfaceId,
        mutate: impl FnOnce(&Self, &mut ClientSizingState) -> R,
    ) -> R {
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let owners_before = sizing.terminal_owner_clients(runtime);
        let result = mutate(self, &mut sizing);
        // Participants may have come, gone or changed identity.
        self.refresh_host_policy_locked(&mut sizing, runtime);
        self.apply_terminal_grid(&sizing, runtime);
        let owners_after = sizing.terminal_owner_clients(runtime);
        drop(sizing);
        self.publish_size_states();
        self.emit_client_sizing_changes(owners_before.symmetric_difference(&owners_after).copied());
        result
    }

    /// Deliver pending size states to subscribers and attach streams. Call
    /// only without the sizing lock held.
    pub(super) fn publish_size_states(&self) {
        let follows_visibility = self.kitty_share_follows_visibility();
        let (publications, visible, thread_qos_changed) = {
            let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
            let visible = follows_visibility.then(|| sizing.visible_terminals());
            let thread_qos_changed = self.request_terminal_threads_shown(&mut sizing);
            (sizing.take_size_state_publications(), visible, thread_qos_changed)
        };
        for surface in thread_qos_changed {
            surface.send_thread_qos_to_host();
        }
        // Size leases are what the person sees: the Kitty share follows them
        // (claimed, released, expired), never a bare attach.
        if let Some((order, visible)) = visible {
            self.set_kitty_visible_terminals(order, visible);
        }
        for publication in publications {
            for placement in publication.placements {
                if self.surface(placement).is_none() {
                    continue;
                }
                self.control_clients.send_size_state(
                    placement,
                    publication.runtime,
                    &publication.state,
                    publication.scheme,
                );
                self.emit(MuxEvent::SizeStateChanged {
                    surface: placement,
                    runtime: publication.runtime,
                    state: publication.state.clone(),
                });
            }
        }
    }

    pub(super) fn emit_client_sizing_changes(&self, clients: impl IntoIterator<Item = u64>) {
        for client in clients {
            let (name, kind) = self.control_clients.client_info(client).unwrap_or((None, None));
            self.emit(MuxEvent::ClientChanged { client, name, kind });
        }
    }

    /// Claim or release a terminal's canonical geometry for one live client,
    /// or update the legacy shared-size policy for a non-terminal surface.
    pub fn set_client_size_participation(
        &self,
        surface: SurfaceId,
        client: u64,
        participating: bool,
    ) -> Option<bool> {
        if let Some(runtime) = self.surface(surface)?.terminal_runtime_id() {
            // Terminals map the legacy participation switch onto the shared
            // engine: disabling sets `counts_override:false`; enabling clears
            // that choice and counts as activity.
            let id = self.participant_scheme().view_participant_id(runtime, surface, client);
            if participating {
                {
                    let _lifecycle = self.lock_client_sizing_lifecycle();
                    if client != 0 && !self.control_clients.contains(client) {
                        return None;
                    }
                }
                let cleared = self
                    .client_sizing
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .terminal_sizing
                    .get(&runtime)
                    .and_then(|entry| entry.engine.participant(&id))
                    .is_some_and(|participant| participant.counts_override == Some(false));
                if cleared {
                    self.set_terminal_size_counts(surface, &id, None);
                }
                return self
                    .claim_terminal_geometry(surface, client)
                    .map(|changed| changed || cleared);
            }
            let _lifecycle = self.lock_client_sizing_lifecycle();
            // Revalidate after acquiring the sizing lifecycle fence. A
            // disconnect may have removed the client while this action was
            // waiting for the fence, and a stale release must not report a
            // successful no-op against a dead client.
            if client != 0 && !self.control_clients.contains(client) {
                return None;
            }
            return Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
                sizing.terminal_runtime_by_placement.insert(surface, runtime);
                let participant = mux.view_participant(sizing, runtime, surface, client);
                let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
                let mut attached = false;
                if !entry.engine.contains(&id) {
                    entry.members.insert(id.clone(), SizingMember::own_view(client, surface));
                    attached = entry.engine.attach(participant);
                }
                let changed = entry.engine.set_counts_override(&id, Some(false));
                sizing.note_size_state(runtime, attached || changed);
                changed
            }));
        }
        let _lifecycle = self.lock_client_sizing_lifecycle();
        self.surface(surface)?;
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let attached_clients = self.control_clients.attached_client_ids_for_surface(surface);
        let mut known_clients = attached_clients.clone();
        if let Some(reporters) = sizing.surfaces.get(&surface) {
            known_clients.extend(reporters.keys().copied());
        }
        if !known_clients.contains(&client) {
            return None;
        }
        if sizing.client_participates(surface, client) == participating {
            return Some(false);
        }
        let policy = sizing.policies.entry(surface).or_default();
        if let Some(exclusive) = policy.exclusive_client.take() {
            policy
                .excluded_clients
                .extend(known_clients.iter().copied().filter(|candidate| *candidate != exclusive));
            policy.excluded_clients.remove(&exclusive);
        }
        if participating {
            policy.excluded_clients.remove(&client);
        } else {
            policy.excluded_clients.insert(client);
        }
        if policy.excluded_clients.is_empty() {
            sizing.policies.remove(&surface);
        }
        self.apply_effective_client_size(&sizing, surface, Some(&attached_clients));
        drop(sizing);
        self.emit_client_sizing_changes([client]);
        Some(true)
    }

    /// Atomically grant one client/placement canonical terminal geometry.
    pub fn use_only_client_size(&self, surface: SurfaceId, target: u64) -> Option<bool> {
        if self.surface(surface)?.terminal_runtime_id().is_some() {
            if target != 0
                && !self.control_clients.attached_client_ids_for_surface(surface).contains(&target)
            {
                return None;
            }
            self.client_surface_size(surface, target)?;
            return self.set_client_size_participation(surface, target, true);
        }
        let _lifecycle = self.lock_client_sizing_lifecycle();
        self.surface(surface)?;
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let attached_clients = self.control_clients.attached_client_ids_for_surface(surface);
        let reporters = sizing.surfaces.get(&surface);
        let target_is_reporting = reporters.is_some_and(|viewers| viewers.contains_key(&target));
        if !target_is_reporting {
            return None;
        }
        let mut known_clients = attached_clients.clone();
        if let Some(reporters) = reporters {
            known_clients.extend(reporters.keys().copied());
        }
        let excluded = known_clients
            .iter()
            .copied()
            .filter(|client| *client != target)
            .collect::<HashSet<_>>();
        let policy = sizing.policies.entry(surface).or_default();
        if policy.excluded_clients == excluded && policy.exclusive_client == Some(target) {
            return Some(false);
        }
        policy.excluded_clients = excluded;
        policy.exclusive_client = Some(target);
        self.apply_effective_client_size(&sizing, surface, Some(&attached_clients));
        drop(sizing);
        self.emit_client_sizing_changes(known_clients);
        Some(true)
    }

    /// Restore automatic sizing: terminals clear every counts override,
    /// browsers drop their include/exclude policy.
    pub fn use_all_client_sizes(&self, surface: SurfaceId) -> Option<bool> {
        if self.surface(surface)?.terminal_runtime_id().is_some() {
            return self.release_terminal_geometry(surface);
        }
        let _lifecycle = self.lock_client_sizing_lifecycle();
        self.surface(surface)?;
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let attached_clients = self.control_clients.attached_client_ids_for_surface(surface);
        let Some(_) = sizing.policies.remove(&surface) else {
            return Some(false);
        };
        let mut known_clients = attached_clients.clone();
        if let Some(reporters) = sizing.surfaces.get(&surface) {
            known_clients.extend(reporters.keys().copied());
        }
        self.apply_effective_client_size(&sizing, surface, Some(&attached_clients));
        drop(sizing);
        self.emit_client_sizing_changes(known_clients);
        Some(true)
    }

    pub fn client_size_participates(&self, surface: SurfaceId, client: u64) -> bool {
        if let Some(runtime) =
            self.surface(surface).and_then(|surface| surface.terminal_runtime_id())
        {
            return self
                .client_sizing
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .owns_terminal_geometry(runtime, surface, client);
        }
        self.client_sizing
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .client_participates(surface, client)
    }

    pub fn control_clients_json(&self, requesting_client: u64) -> Value {
        let mut clients = self.control_clients.list_json(requesting_client);
        if let Some(clients) = clients.as_array_mut() {
            for info in clients {
                let id = info.get("client").and_then(Value::as_u64).unwrap_or_default();
                if let Some(sizes) = info.get_mut("sizes").and_then(Value::as_array_mut) {
                    for size in sizes {
                        let surface =
                            size.get("surface").and_then(Value::as_u64).unwrap_or_default();
                        size["size_participating"] =
                            serde_json::json!(self.client_size_participates(surface, id));
                    }
                }
            }
        }
        let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let local_sizes = sizing
            .surfaces
            .iter()
            .filter_map(|(surface, viewers)| {
                viewers.get(&0).map(|(cols, rows)| {
                    serde_json::json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "size_participating": sizing.report_participates(*surface, 0),
                    })
                })
            })
            .collect::<Vec<_>>();
        if !local_sizes.is_empty()
            && let Some(clients) = clients.as_array_mut()
        {
            clients.insert(
                0,
                serde_json::json!({
                    "client": 0,
                    "transport": "local",
                    "name": "This TUI",
                    "kind": "tui",
                    "connected_seconds": 0,
                    "attached": local_sizes.iter().filter_map(|size| size.get("surface")).cloned().collect::<Vec<_>>(),
                    "sizes": local_sizes,
                    "self": requesting_client == 0,
                }),
            );
        }
        clients
    }
}
