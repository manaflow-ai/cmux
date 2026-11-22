//! Client surface resizes: client size resolution and records, control client resizes with reservations and completions, rollback, and size client removal.

use super::*;

impl Mux {
    pub(super) fn resolve_client_size(
        &self,
        requested: Option<(u16, u16)>,
        default: (u16, u16),
    ) -> (u16, u16) {
        let mut sizing = self.client_sizing.lock().unwrap();
        if let Some((cols, rows)) = requested {
            let size = clamp_terminal_size(cols, rows);
            sizing.record_explicit_size(size);
            return size;
        }
        let attached_clients = self.control_clients.attached_client_ids_by_surface();
        sizing
            .creation_size(&attached_clients)
            .unwrap_or_else(|| clamp_terminal_size(default.0, default.1))
    }

    /// Record a genuine client-chosen size (protocol resize-surface, sized
    /// creation, or the local TUI sizing a pane) as the default for future
    /// unsized surface creation.
    pub fn record_client_size(&self, cols: u16, rows: u16) -> (u16, u16) {
        let size = clamp_terminal_size(cols, rows);
        self.client_sizing.lock().unwrap().record_explicit_size(size);
        size
    }

    /// Record one viewer's available grid. A terminal report feeds the shared
    /// sizing engine and changes the PTY only when the engine's policy lets
    /// it; browser surfaces retain their existing shared-size reducer.
    pub fn resize_surface_for_client(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<bool> {
        self.resize_surface_for_client_with_reservation(id, client, cols, rows)
            .map(|(accepted, _)| accepted)
    }

    pub fn resize_surface_for_client_with_reservation(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        let requested = clamp_terminal_size(cols, rows);
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        // Serialize the report and its application. Otherwise an older
        // effective size can reach the PTY after a newer shared minimum.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let result = self.resize_surface_for_client_locked(
            &mut sizing,
            Some(&attached_clients),
            ClientResizeRequest {
                surface: id,
                client,
                requested,
                completion: None,
                terminal_runtime,
            },
        )?;
        sizing.note_applied_report(
            id,
            client,
            &attached_clients,
            result.1,
            result.2.applied_report_order,
        );
        drop(sizing);
        self.publish_size_states();
        Ok(result.0)
    }

    pub(crate) fn resize_surface_for_control_client_with_reservation(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<ControlClientResize> {
        self.resize_surface_for_control_client_with_completion(id, client, cols, rows, None)
    }

    pub(crate) fn resize_surface_for_control_client_with_completion(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<ControlClientResize> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        anyhow::ensure!(
            !self.control_clients.surface_attachment_is_retired_without_current(client, id),
            "surface {id} attachment was superseded"
        );
        let requested = clamp_terminal_size(cols, rows);
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        // Keep registration, report insertion, and reducer insertion in one
        // critical section. Disconnect and final stream detach remove their
        // leases through this same sizing lock after dropping the registry lock.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached = self.control_clients.record_size(client, id, requested.0, requested.1)?;
        let result = self.resize_surface_for_prepared_control_client_locked(
            &mut sizing,
            PreparedControlClientResize {
                request: ClientResizeRequest {
                    surface: id,
                    client,
                    requested,
                    completion,
                    terminal_runtime,
                },
                attached: attached.clone(),
            },
        );
        if result.is_err()
            && let Some((_, _, _, previous)) = attached.as_ref()
        {
            self.control_clients.restore_size(client, id, *previous);
        }
        drop(sizing);
        self.publish_size_states();
        result
    }

    pub(crate) fn resize_surface_for_prepared_control_client_with_completion(
        &self,
        id: SurfaceId,
        client: u64,
        requested: (u16, u16),
        completion: Option<SurfaceResizeCompletion>,
        attached: Option<crate::server::ClientSizeUpdate>,
    ) -> anyhow::Result<ControlClientResize> {
        let requested = clamp_terminal_size(requested.0, requested.1);
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        let mut sizing = self.client_sizing.lock().unwrap();
        let result = self.resize_surface_for_prepared_control_client_locked(
            &mut sizing,
            PreparedControlClientResize {
                request: ClientResizeRequest {
                    surface: id,
                    client,
                    requested,
                    completion,
                    terminal_runtime,
                },
                attached,
            },
        );
        drop(sizing);
        self.publish_size_states();
        result
    }

    pub(super) fn resize_surface_for_prepared_control_client_locked(
        &self,
        sizing: &mut ClientSizingState,
        prepared: PreparedControlClientResize,
    ) -> anyhow::Result<ControlClientResize> {
        let PreparedControlClientResize { request, attached } = prepared;
        let id = request.surface;
        let client = request.client;
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let result =
            self.resize_surface_for_client_locked(sizing, Some(&attached_clients), request);
        let result = result?;
        self.control_clients.set_report_order(client, id, result.2.applied_report_order);
        sizing.note_applied_report(
            id,
            client,
            &attached_clients,
            result.1,
            result.2.applied_report_order,
        );
        Ok(ControlClientResize {
            accepted: result.0.0,
            reservation_id: result.0.1,
            effective_size: result.1,
            attached,
            rollback: result.2,
        })
    }

    pub(super) fn resize_surface_for_client_locked(
        &self,
        sizing: &mut ClientSizingState,
        attached_clients: Option<&HashSet<u64>>,
        request: ClientResizeRequest,
    ) -> anyhow::Result<AppliedClientSize> {
        let ClientResizeRequest { surface: id, client, requested, completion, terminal_runtime } =
            request;
        let previous_geometry = self.surface(id).map(|surface| surface.size());
        if terminal_runtime.is_none()
            && sizing
                .policies
                .get(&id)
                .and_then(|policy| policy.exclusive_client)
                .is_some_and(|exclusive| exclusive != client)
        {
            sizing.policies.entry(id).or_default().excluded_clients.insert(client);
        }
        let report_order = sizing.next_size_order();
        let previous_order = sizing.report_order.insert((id, client), report_order);
        let previous = {
            let viewers = sizing.surfaces.entry(id).or_default();
            viewers.insert(client, requested)
        };
        if let Some(runtime) = terminal_runtime {
            sizing.terminal_runtime_by_placement.insert(id, runtime);
            self.sync_terminal_view_locked(sizing, runtime, id, client);
            let authoritative = sizing.owns_terminal_geometry(runtime, id, client);
            if !authoritative {
                // The report may still move the grid through another owner,
                // for example when it stops being the smallest viewport.
                self.apply_terminal_grid(sizing, runtime);
                return Ok((
                    (false, None),
                    previous_geometry,
                    ClientSizeRollback {
                        previous_size: previous,
                        previous_report_order: previous_order,
                        previous_geometry,
                        applied_report_order: report_order,
                    },
                ));
            }
            let (target, applied) =
                sizing.terminal_sizing.get(&runtime).map_or((requested, None), |entry| {
                    ((entry.engine.state().cols, entry.engine.state().rows), Some(&entry.applied))
                });
            if applied.is_some_and(|applied| applied.get() == Some(target))
                || previous_geometry == Some(target)
            {
                // The owner's decision is already in effect. Re-applying it
                // would override a resize this engine did not make.
                if let Some(applied) = applied {
                    applied.set(Some(target));
                }
                return Ok((
                    (false, None),
                    Some(target),
                    ClientSizeRollback {
                        previous_size: previous,
                        previous_report_order: previous_order,
                        previous_geometry,
                        applied_report_order: report_order,
                    },
                ));
            }
            if let Some(applied) = applied {
                applied.set(Some(target));
            }
            return match self.resize_surface_with_completion(id, target.0, target.1, completion) {
                Ok(changed) => Ok((
                    changed,
                    Some(target),
                    ClientSizeRollback {
                        previous_size: previous,
                        previous_report_order: previous_order,
                        previous_geometry,
                        applied_report_order: report_order,
                    },
                )),
                Err(error) => {
                    if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                        if let Some(previous) = previous {
                            viewers.insert(client, previous);
                        } else {
                            viewers.remove(&client);
                        }
                    }
                    if sizing.surfaces.get(&id).is_some_and(HashMap::is_empty) {
                        sizing.surfaces.remove(&id);
                        sizing.terminal_runtime_by_placement.remove(&id);
                    }
                    match previous_order {
                        Some(order) => {
                            sizing.report_order.insert((id, client), order);
                        }
                        None => {
                            sizing.report_order.remove(&(id, client));
                        }
                    }
                    if let Some(entry) = sizing.terminal_sizing.get(&runtime) {
                        entry.applied.set(previous_geometry);
                    }
                    self.sync_terminal_view_locked(sizing, runtime, id, client);
                    Err(error)
                }
            };
        }
        let use_excluded = sizing.uses_excluded_fallback(id, attached_clients);
        let effective = sizing.effective_size(id, use_excluded);
        let Some(effective) = effective else {
            return Ok((
                (false, None),
                None,
                ClientSizeRollback {
                    previous_size: previous,
                    previous_report_order: previous_order,
                    previous_geometry,
                    applied_report_order: report_order,
                },
            ));
        };
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        match self.resize_surface_with_completion(id, effective.0, effective.1, completion) {
            Ok(changed) => Ok((
                changed,
                Some(effective),
                ClientSizeRollback {
                    previous_size: previous,
                    previous_report_order: previous_order,
                    previous_geometry,
                    applied_report_order: report_order,
                },
            )),
            Err(error) => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    if let Some(previous) = previous {
                        viewers.insert(client, previous);
                    } else {
                        viewers.remove(&client);
                    }
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
                if let Some(previous_order) = previous_order {
                    sizing.report_order.insert((id, client), previous_order);
                } else {
                    sizing.report_order.remove(&(id, client));
                }
                Err(error)
            }
        }
    }

    pub(crate) fn rollback_surface_size_client(
        &self,
        id: SurfaceId,
        client: u64,
        rollback: ClientSizeRollback,
    ) {
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        let lifecycle = self.lock_client_sizing_lifecycle();
        if !self.control_clients.contains(client) {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap();
        let current_size =
            sizing.surfaces.get(&id).and_then(|viewers| viewers.get(&client).copied());
        let current_report_order = sizing.report_order.get(&(id, client)).copied();
        if current_report_order != Some(rollback.applied_report_order) {
            return;
        }
        self.control_clients.restore_size_and_report_order(
            client,
            id,
            rollback.previous_size,
            rollback.previous_report_order,
        );
        match rollback.previous_size {
            Some(size) => {
                sizing.surfaces.entry(id).or_default().insert(client, size);
            }
            None => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    viewers.remove(&client);
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
            }
        }
        match rollback.previous_report_order {
            Some(order) => {
                sizing.report_order.insert((id, client), order);
            }
            None => {
                sizing.report_order.remove(&(id, client));
            }
        }
        if let Some(runtime) = terminal_runtime {
            let owned_geometry = sizing.owns_terminal_geometry(runtime, id, client);
            self.sync_terminal_view_locked(&mut sizing, runtime, id, client);
            self.apply_terminal_grid(&sizing, runtime);
            // A failed first attach whose provisional report owned the grid
            // restores the preceding geometry when nobody else can take over.
            let held = sizing
                .terminal_sizing
                .get(&runtime)
                .is_some_and(|entry| entry.engine.state().reason == TerminalSizingReason::Held);
            let desired_geometry = (owned_geometry && held)
                .then_some(rollback.previous_size.or(rollback.previous_geometry))
                .flatten();
            drop(sizing);
            drop(lifecycle);
            if let Some((cols, rows)) = desired_geometry {
                let _ = self.resize_surface(id, cols, rows);
            }
            self.publish_size_states();
            return;
        }
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let use_excluded = sizing.uses_excluded_fallback(id, Some(&attached_clients));
        let desired_geometry =
            sizing.effective_size(id, use_excluded).or(rollback.previous_geometry);
        let restore =
            desired_geometry.map_or(SurfaceResizeRestore::Complete(true), |(cols, rows)| {
                let (completion, completed) = std::sync::mpsc::sync_channel(1);
                match self.resize_surface_with_completion(id, cols, rows, Some(completion)) {
                    Ok((true, Some(_))) => SurfaceResizeRestore::Pending(completed),
                    Ok((_, _)) => match self.surface(id) {
                        Some(surface) if surface.size() == (cols, rows) => {
                            SurfaceResizeRestore::Complete(true)
                        }
                        Some(surface) => match surface.pending_resize_completion(cols, rows) {
                            Ok(Some(pending)) => SurfaceResizeRestore::Pending(pending.completion),
                            Ok(None) | Err(_) => SurfaceResizeRestore::Complete(false),
                        },
                        None => SurfaceResizeRestore::Complete(false),
                    },
                    Err(_) => SurfaceResizeRestore::Complete(false),
                }
            });
        let rollback_token = sizing.rollback_token(id, Some(&attached_clients));
        drop(sizing);
        drop(lifecycle);

        #[cfg(test)]
        if let Some(hook) = self.client_rollback_before_wait.lock().unwrap().clone() {
            hook();
        }

        let restoration_failed = match restore {
            SurfaceResizeRestore::Complete(restored) => !restored,
            SurfaceResizeRestore::Pending(completion) => {
                match completion.recv_timeout(Duration::from_secs(10)) {
                    Ok(Ok(())) => false,
                    Ok(Err(_)) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => true,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        // The rolled-back registry remains authoritative while
                        // the compensating browser reservation stays queued.
                        // Do not reinstall the failed attach's claim before the
                        // browser worker reaches a terminal outcome, and do not
                        // retain the connection or another blocking waiter.
                        return;
                    }
                }
            }
        };
        if restoration_failed {
            self.reconcile_failed_surface_size_rollback(
                id,
                client,
                current_size,
                current_report_order,
                rollback_token,
            );
        }
    }

    pub(super) fn reconcile_failed_surface_size_rollback(
        &self,
        id: SurfaceId,
        client: u64,
        current_size: Option<(u16, u16)>,
        current_report_order: Option<u64>,
        rollback_token: ClientSizingRollbackToken,
    ) {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        if !self.control_clients.contains(client) {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        if sizing.rollback_token(id, Some(&attached_clients)) != rollback_token {
            return;
        }
        // The failed attach already changed the real surface geometry. If
        // restoration fails, retain the pre-rollback report only when no
        // newer sizing mutation superseded this rollback while it was pending.
        self.control_clients.restore_size_and_report_order(
            client,
            id,
            current_size,
            current_report_order,
        );
        match current_size {
            Some(size) => {
                sizing.surfaces.entry(id).or_default().insert(client, size);
            }
            None => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    viewers.remove(&client);
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
            }
        }
        match current_report_order {
            Some(order) => {
                sizing.report_order.insert((id, client), order);
            }
            None => {
                sizing.report_order.remove(&(id, client));
            }
        }
    }

    pub(super) fn apply_effective_client_size(
        &self,
        sizing: &ClientSizingState,
        surface_id: SurfaceId,
        attached_clients: Option<&HashSet<u64>>,
    ) {
        if let Some(runtime) =
            self.surface(surface_id).and_then(|surface| surface.terminal_runtime_id())
        {
            self.apply_terminal_grid(sizing, runtime);
            return;
        }
        let use_excluded = sizing.uses_excluded_fallback(surface_id, attached_clients);
        if let Some((cols, rows)) = sizing.effective_size(surface_id, use_excluded) {
            let _ = self.resize_surface(surface_id, cols, rows);
        } else if let Some(surface) = self.surface(surface_id) {
            let _ = surface.release_viewer_size();
        }
    }

    pub(super) fn apply_effective_client_sizes(
        &self,
        sizing: &ClientSizingState,
        affected: impl IntoIterator<Item = SurfaceId>,
        attached_clients: &HashMap<SurfaceId, HashSet<u64>>,
    ) {
        let mut affected = affected.into_iter().collect::<Vec<_>>();
        affected.sort_unstable();
        affected.dedup();
        for surface_id in affected {
            self.apply_effective_client_size(sizing, surface_id, attached_clients.get(&surface_id));
        }
    }

    pub fn remove_surface_size_client(&self, id: SurfaceId, client: u64) {
        // Removal participates in the same ordering as size reports.
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        // Final-stream cleanup runs after the registry removes this
        // attachment. Reconstruct the preceding attachment set so an
        // unreported client only triggers geometry when its removal actually
        // changes excluded-report fallback.
        let mut attached_clients_before = attached_clients.clone();
        attached_clients_before.insert(client);
        let fallback_before = sizing.uses_excluded_fallback(id, Some(&attached_clients_before));
        let removed = {
            let removed = sizing
                .surfaces
                .get_mut(&id)
                .is_some_and(|viewers| viewers.remove(&client).is_some());
            if sizing.surfaces.get(&id).is_some_and(HashMap::is_empty) {
                sizing.surfaces.remove(&id);
                sizing.terminal_runtime_by_placement.remove(&id);
            }
            removed
        };
        sizing.report_order.remove(&(id, client));
        if let Some(runtime) = terminal_runtime {
            let owners_before = sizing.terminal_owner_clients(runtime);
            // A released view keeps its participant while its stream stays
            // attached; a final detach removes it and elects the next owner.
            self.sync_terminal_view_locked(&mut sizing, runtime, id, client);
            self.apply_terminal_grid(&sizing, runtime);
            let owners_after = sizing.terminal_owner_clients(runtime);
            drop(sizing);
            self.publish_size_states();
            self.emit_client_sizing_changes(
                owners_before.symmetric_difference(&owners_after).copied(),
            );
            return;
        }
        let fallback_after = sizing.uses_excluded_fallback(id, Some(&attached_clients));
        // A final unreported attachment can be the only thing suppressing
        // this terminal's excluded-report fallback even though it had no
        // visibility lease of its own to remove.
        if !removed && fallback_before == fallback_after {
            return;
        }
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        self.apply_effective_client_size(&sizing, id, Some(&attached_clients));
        drop(sizing);
    }

    #[cfg(test)]
    pub fn remove_size_client(&self, client: u64) {
        self.remove_size_client_from_attached_surfaces(client, []);
    }

    pub(crate) fn remove_size_client_from_attached_surfaces(
        &self,
        client: u64,
        attached_surfaces: impl IntoIterator<Item = SurfaceId>,
    ) {
        let mut sizing = self.client_sizing.lock().unwrap();
        sizing.detached_views.retain(|(viewer, _)| *viewer != client);
        let attached_clients = self.control_clients.attached_client_ids_by_surface();
        // The registry snapshot no longer contains this client. Reconstruct
        // whether each old attachment suppressed excluded-report fallback so
        // an unsized disconnect only reapplies geometry when that changed.
        let detached_fallbacks = attached_surfaces
            .into_iter()
            .map(|surface| {
                let used_fallback = if sizing.client_participates(surface, client) {
                    false
                } else {
                    sizing.uses_excluded_fallback(surface, attached_clients.get(&surface))
                };
                (surface, used_fallback)
            })
            .collect::<HashMap<_, _>>();
        let mut affected = HashSet::new();
        for (surface, viewers) in &mut sizing.surfaces {
            if viewers.remove(&client).is_some() {
                affected.insert(*surface);
            }
        }
        sizing.surfaces.retain(|_, viewers| !viewers.is_empty());
        let reported_placements = sizing.surfaces.keys().copied().collect::<HashSet<_>>();
        sizing
            .terminal_runtime_by_placement
            .retain(|surface, _| reported_placements.contains(surface));
        sizing.report_order.retain(|(surface, reporter), _| {
            if *reporter != client {
                return true;
            }
            affected.insert(*surface);
            false
        });
        // Drop every view and relay sub-view of the departed client. Each
        // engine elects its next owner in the same step, so the grid follows
        // the remaining viewers instead of freezing.
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        let mut owner_changes = HashSet::new();
        for runtime in runtimes {
            let owners_before = sizing.terminal_owner_clients(runtime);
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            let departed = entry
                .members
                .iter()
                .filter(|(_, member)| member.client == client)
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            if departed.is_empty() {
                continue;
            }
            let mut changed = false;
            for id in departed {
                entry.members.remove(&id);
                changed |= entry.engine.detach(&id);
            }
            sizing.note_size_state(runtime, changed);
            self.apply_terminal_grid(&sizing, runtime);
            let owners_after = sizing.terminal_owner_clients(runtime);
            owner_changes.extend(owners_before.symmetric_difference(&owners_after).copied());
        }
        let mut restored_surfaces = HashSet::new();
        for (surface, policy) in &mut sizing.policies {
            let changed = if policy.exclusive_client == Some(client) {
                policy.exclusive_client = None;
                policy.excluded_clients.clear();
                restored_surfaces.insert(*surface);
                true
            } else {
                policy.excluded_clients.remove(&client)
            };
            if changed {
                affected.insert(*surface);
            }
        }
        sizing.policies.retain(|_, policy| {
            policy.exclusive_client.is_some() || !policy.excluded_clients.is_empty()
        });
        for (surface, fallback_before) in detached_fallbacks {
            let fallback_after =
                sizing.uses_excluded_fallback(surface, attached_clients.get(&surface));
            if fallback_before != fallback_after {
                affected.insert(surface);
            }
        }
        let mut changed_clients = HashSet::new();
        for surface in restored_surfaces {
            if let Some(clients) = attached_clients.get(&surface) {
                changed_clients.extend(clients.iter().copied());
            }
            if let Some(reporters) = sizing.surfaces.get(&surface) {
                changed_clients.extend(reporters.keys().copied());
            }
        }
        changed_clients.extend(owner_changes);
        changed_clients.remove(&client);
        self.apply_effective_client_sizes(&sizing, affected, &attached_clients);
        drop(sizing);
        self.publish_size_states();
        self.emit_client_sizing_changes(changed_clients);
    }

    pub fn client_surface_size(&self, id: SurfaceId, client: u64) -> Option<(u16, u16)> {
        self.client_sizing
            .lock()
            .unwrap()
            .surfaces
            .get(&id)
            .and_then(|viewers| viewers.get(&client).copied())
    }
}
