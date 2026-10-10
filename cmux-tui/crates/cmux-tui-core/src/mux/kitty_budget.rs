//! Kitty graphics budget: render attachment permits, kitty image surface reservations and commits, per-surface limits, and the budget worker that rebalances them.

use super::*;

impl Mux {
    pub(crate) fn claim_render_attachment(&self) -> Option<RenderAttachmentPermit> {
        self.active_render_attachments
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < RENDER_ATTACHMENT_LIMIT).then_some(active + 1)
            })
            .ok()?;
        Some(RenderAttachmentPermit { active: self.active_render_attachments.clone() })
    }

    /// Reserve a Kitty image budget entry that owns no quota yet, without
    /// waiting. For a host launched ahead of its creation
    /// (`terminal_work`): an uncommitted entry cannot shrink when later
    /// reservations do, so owning quota before the commit would make every
    /// concurrent launch wait on it. The committed surface is promoted to a
    /// quota owner and the budget worker applies its limits then.
    pub(crate) fn reserve_kitty_image_surface_without_quota(
        self: &Arc<Self>,
        surface: SurfaceId,
    ) -> anyhow::Result<KittyImageBudgetReservation> {
        let mut budget = self.kitty_image_budget.lock().unwrap();
        Self::prune_dead_kitty_image_surfaces(&mut budget);
        anyhow::ensure!(
            !budget.entries.contains_key(&surface),
            "Kitty image budget already reserved for surface {surface}"
        );
        budget.entries.insert(
            surface,
            KittyImageBudgetEntry {
                surface: None,
                applied: KittyGraphicsLimits::disabled(),
                owns_quota: false,
                removing: false,
            },
        );
        Ok(KittyImageBudgetReservation {
            mux: Arc::downgrade(self),
            surface,
            initial_limits: KittyGraphicsLimits::disabled(),
            committed: false,
        })
    }

    pub(super) fn commit_kitty_image_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        surface: &Arc<Surface>,
        applied: KittyGraphicsLimits,
    ) -> anyhow::Result<()> {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            let entry = budget
                .entries
                .get_mut(&id)
                .ok_or_else(|| anyhow::anyhow!("Kitty image budget reservation disappeared"))?;
            anyhow::ensure!(
                entry.surface.is_none() && !entry.removing,
                "Kitty image budget reservation is no longer pending"
            );
            entry.surface = Some(Arc::downgrade(surface));
            entry.applied = applied;
            Self::rebalance_kitty_image_budget_owners(&mut budget);
        }
        self.start_kitty_image_budget_worker();
        Ok(())
    }

    pub(super) fn cancel_kitty_image_surface_reservation(self: &Arc<Self>, id: SurfaceId) {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            if budget.entries.get(&id).is_some_and(|entry| entry.surface.is_none()) {
                budget.entries.remove(&id);
                Self::rebalance_kitty_image_budget_owners(&mut budget);
            }
        }
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
    }

    pub(crate) fn unregister_kitty_image_surface(
        self: &Arc<Self>,
        surface: &Surface,
    ) -> anyhow::Result<()> {
        let runtime_id = surface.terminal_runtime_id().unwrap_or(surface.id);
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            let removed_current_surface = budget
                .entries
                .get(&runtime_id)
                .and_then(|entry| entry.surface.as_ref())
                .and_then(Weak::upgrade)
                .is_some_and(|registered| std::ptr::eq(registered.as_ref(), surface));
            if removed_current_surface {
                budget.entries.remove(&runtime_id);
                budget.blocked_surfaces.remove(&runtime_id);
                Self::rebalance_kitty_image_budget_owners(&mut budget);
            }
        }
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
        Ok(())
    }

    pub(crate) fn resource_terminal_host_identity(
        &self,
        surface: &Surface,
    ) -> Option<TerminalHostIdentity> {
        surface.terminal_host_identity().or_else(|| {
            let runtime = surface.terminal_runtime_id()?;
            self.reserved_in_process_terminals.lock().unwrap().get(&runtime).cloned()
        })
    }

    pub(crate) fn kitty_image_limits_for_reconnect(
        &self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<KittyGraphicsLimits> {
        let mut budget = self.kitty_image_budget.lock().unwrap();
        Self::prune_dead_kitty_image_surfaces(&mut budget);
        let target = kitty_image_limits_for_capacity(budget.capacity);
        let entry = budget
            .entries
            .get(&surface.id)
            .ok_or_else(|| anyhow::anyhow!("Kitty image budget entry disappeared on reconnect"))?;
        anyhow::ensure!(
            entry
                .surface
                .as_ref()
                .and_then(Weak::upgrade)
                .is_some_and(|registered| Arc::ptr_eq(&registered, surface)),
            "Kitty image budget entry changed ownership on reconnect"
        );
        Ok(if entry.removing || !entry.owns_quota {
            KittyGraphicsLimits::disabled()
        } else {
            target
        })
    }

    /// Record the Kitty limits a reconnected host applied in its handshake.
    ///
    /// The limits are the host's authoritative state, whatever the budget
    /// wants now: the reconnect read its target before the handshake, and a
    /// terminal that joined or left since then moves the target. Limits
    /// above the current target are recorded as they are, so admission still
    /// counts them and the budget worker shrinks them on the live connection,
    /// like any other surface whose share shrank. Refusing them here did not
    /// undo them on the host; it tore down the healthy connection and left a
    /// dead writer installed through the reconnect backoff, so input failed
    /// with EPIPE (the terminal_host_recovery template-adoption flake).
    /// Kitty limits are advisory; only a surface that no longer owns the
    /// entry is refused.
    pub(super) fn reconcile_reconnected_kitty_image_surface(
        self: &Arc<Self>,
        surface: &Arc<Surface>,
        applied: KittyGraphicsLimits,
    ) -> bool {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            Self::prune_dead_kitty_image_surfaces(&mut budget);
            let Some(entry) = budget.entries.get_mut(&surface.id) else { return false };
            let owns_entry = entry
                .surface
                .as_ref()
                .and_then(Weak::upgrade)
                .is_some_and(|registered| Arc::ptr_eq(&registered, surface));
            if !owns_entry {
                return false;
            }
            entry.applied = applied;
            budget.blocked_surfaces.remove(&surface.id);
        }
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
        true
    }

    pub(super) fn prune_dead_kitty_image_surfaces(budget: &mut KittyImageBudgetState) {
        budget.entries.retain(|_, entry| {
            entry.surface.as_ref().is_none_or(|surface| surface.strong_count() > 0)
        });
        let live_ids = budget.entries.keys().copied().collect::<HashSet<_>>();
        budget.blocked_surfaces.retain(|id| live_ids.contains(id));
        Self::rebalance_kitty_image_budget_owners(budget);
    }

    pub(super) fn kitty_image_budget_owner_count(budget: &KittyImageBudgetState) -> usize {
        budget.entries.values().filter(|entry| entry.owns_quota).count()
    }

    pub(super) fn rebalance_kitty_image_budget_owners(budget: &mut KittyImageBudgetState) {
        let owner_count = Self::kitty_image_budget_owner_count(budget);
        debug_assert!(owner_count <= KITTY_IMAGE_BUDGET_OWNER_LIMIT);
        let available = KITTY_IMAGE_BUDGET_OWNER_LIMIT.saturating_sub(owner_count);
        if budget.blocked_surfaces.is_empty() && available > 0 && owner_count < budget.entries.len()
        {
            let mut candidates = budget
                .entries
                .iter()
                .filter_map(|(&id, entry)| {
                    (!entry.owns_quota
                        && !entry.removing
                        && entry.surface.as_ref().is_some_and(|surface| surface.strong_count() > 0))
                    .then_some(id)
                })
                .collect::<Vec<_>>();
            candidates.sort_unstable();
            for id in candidates.into_iter().take(available) {
                if let Some(entry) = budget.entries.get_mut(&id) {
                    entry.owns_quota = true;
                }
            }
        }
        budget.capacity = kitty_image_budget_capacity(
            Self::kitty_image_budget_owner_count(budget),
            budget.capacity,
        );
    }

    pub(super) fn start_kitty_image_budget_worker(self: &Arc<Self>) {
        let should_start = {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            Self::prune_dead_kitty_image_surfaces(&mut budget);
            let target = kitty_image_limits_for_capacity(budget.capacity);
            let has_work = budget.entries.values().any(|entry| {
                entry.surface.as_ref().is_some_and(|surface| surface.strong_count() > 0)
                    && entry.applied
                        != if entry.removing || !entry.owns_quota {
                            KittyGraphicsLimits::disabled()
                        } else {
                            target
                        }
            });
            if budget.worker_running || !budget.blocked_surfaces.is_empty() || !has_work {
                false
            } else {
                budget.worker_running = true;
                true
            }
        };
        if !should_start {
            return;
        }
        let mux = Arc::downgrade(self);
        if let Err(error) = std::thread::Builder::new()
            .name("kitty-image-budget".into())
            .spawn(move || Self::run_kitty_image_budget_worker(mux))
        {
            self.kitty_image_budget.lock().unwrap().worker_running = false;
            self.kitty_image_budget_changed.notify_all();
            self.emit(MuxEvent::GraphicsStatus(
                GraphicsStatus::KittyImageBudgetWorkerStartFailed {
                    error: Arc::<str>::from(error.to_string()),
                },
            ));
        }
    }

    pub(super) fn run_kitty_image_budget_worker(mux: Weak<Self>) {
        let mut failure_streak = 0_u32;
        let mut pending_operations = Vec::<PendingKittyImageBudgetOperation>::new();
        // The last wave's (surface, limits). An identical next wave with no
        // failure means an applied result did not stick (the surface was
        // replaced): treat it as a failure so the retry is spaced instead of
        // re-running the same wave in a hot loop.
        let mut previous_wave = Vec::<(SurfaceId, KittyGraphicsLimits)>::new();
        loop {
            let Some(mux) = mux.upgrade() else { return };
            if mux.shutting_down.load(Ordering::Acquire) {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                budget.expansion_in_flight = false;
                budget.worker_running = false;
                drop(budget);
                mux.kitty_image_budget_changed.notify_all();
                return;
            }

            let mut failures = Vec::new();
            let mut failed_operations = HashSet::new();
            let mut failed_surface_ids = HashSet::new();
            let mut retained_pending = Vec::new();
            let mut pending_completed = false;
            {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                for pending in pending_operations.drain(..) {
                    let Some(result) = pending.result.try_take() else {
                        retained_pending.push(pending);
                        continue;
                    };
                    pending_completed = true;
                    match result {
                        Ok(()) => {
                            if let Some(entry) = budget.entries.get_mut(&pending.surface_id)
                                && entry
                                    .surface
                                    .as_ref()
                                    .and_then(Weak::upgrade)
                                    .zip(pending.surface.upgrade())
                                    .is_some_and(|(registered, completed)| {
                                        Arc::ptr_eq(&registered, &completed)
                                    })
                            {
                                entry.applied = pending.limits;
                            }
                        }
                        Err(error) => {
                            failed_operations.insert(pending.surface_id);
                            failed_surface_ids.insert(pending.surface_id);
                            failures.push(format!("surface {}: {error:#}", pending.surface_id));
                        }
                    }
                }
                budget.expansion_in_flight =
                    retained_pending.iter().any(|pending| pending.expanding);
            }
            pending_operations = retained_pending;
            if pending_completed {
                mux.kitty_image_budget_changed.notify_all();
            }

            let pending_ids =
                pending_operations.iter().map(|pending| pending.surface_id).collect::<HashSet<_>>();
            let (tasks, deferred_expansion) = {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                Self::prune_dead_kitty_image_surfaces(&mut budget);
                let target = kitty_image_limits_for_capacity(budget.capacity);
                let mut tasks = Vec::new();
                for (&id, entry) in &budget.entries {
                    if pending_ids.contains(&id) || failed_operations.contains(&id) {
                        continue;
                    }
                    let Some(surface) = entry.surface.as_ref().and_then(Weak::upgrade) else {
                        continue;
                    };
                    let desired = if entry.removing || !entry.owns_quota {
                        KittyGraphicsLimits::disabled()
                    } else {
                        target
                    };
                    if entry.applied != desired
                        && (entry.removing
                            || !entry.owns_quota
                            || kitty_image_limits_exceed(entry.applied, desired))
                    {
                        tasks.push((id, surface, desired, false));
                    }
                }
                if tasks.is_empty() {
                    budget.entries.retain(|id, entry| {
                        pending_ids.contains(id)
                            || !(entry.removing
                                && (entry.surface.is_none()
                                    || entry.applied == KittyGraphicsLimits::disabled()))
                    });
                    let previous_capacity = budget.capacity;
                    Self::rebalance_kitty_image_budget_owners(&mut budget);
                    if budget.capacity != previous_capacity {
                        continue;
                    }
                    let target = kitty_image_limits_for_capacity(budget.capacity);
                    for (&id, entry) in &budget.entries {
                        if pending_ids.contains(&id) || failed_operations.contains(&id) {
                            continue;
                        }
                        let Some(surface) = entry.surface.as_ref().and_then(Weak::upgrade) else {
                            continue;
                        };
                        if entry.owns_quota && !entry.removing && entry.applied != target {
                            tasks.push((
                                id,
                                surface,
                                target,
                                kitty_image_limits_exceed(target, entry.applied),
                            ));
                        }
                    }
                }
                budget.expansion_in_flight =
                    pending_operations.iter().any(|pending| pending.expanding)
                        || tasks.iter().any(|task| task.3);
                if tasks.is_empty() && pending_operations.is_empty() && failed_operations.is_empty()
                {
                    budget.expansion_in_flight = false;
                    budget.worker_running = false;
                    drop(budget);
                    mux.kitty_image_budget_changed.notify_all();
                    return;
                }
                // The deadline pool deliberately bounds admitted operations.
                // Submit at most one pool-width wave, then recompute desired
                // limits before the next wave so large topology bursts cannot
                // turn ordinary queueing into false saturation failures.
                tasks.sort_unstable_by_key(|task| task.0);
                let deferred_expansion =
                    tasks.iter().skip(CELL_PIXEL_FANOUT_MAX_WORKERS).any(|task| task.3);
                tasks.truncate(CELL_PIXEL_FANOUT_MAX_WORKERS);
                (tasks, deferred_expansion)
            };

            if !tasks.is_empty() {
                let deadline =
                    Instant::now() + crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT;
                let operation_mux = Arc::downgrade(&mux);
                let results = bounded_deadline_map(
                    &mux.deadline_fanout_pool,
                    &tasks,
                    deadline,
                    move |(_, surface, limits, _), deadline| {
                        let Some(mux) = operation_mux.upgrade() else {
                            anyhow::bail!("multiplexer shut down before Kitty quota update");
                        };
                        mux.apply_kitty_image_limits(surface, *limits, deadline)
                    },
                );
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                let mut retry_expansion = false;
                for ((id, surface, limits, expanding), result) in tasks.iter().zip(results) {
                    match result {
                        DeadlineMapResult::Complete(Ok(())) => {
                            if let Some(entry) = budget.entries.get_mut(id)
                                && entry
                                    .surface
                                    .as_ref()
                                    .and_then(Weak::upgrade)
                                    .is_some_and(|registered| Arc::ptr_eq(&registered, surface))
                            {
                                entry.applied = *limits;
                            }
                        }
                        DeadlineMapResult::Complete(Err(error)) => {
                            retry_expansion |= *expanding;
                            failed_surface_ids.insert(*id);
                            failures.push(format!("surface {id}: {error:#}"));
                        }
                        DeadlineMapResult::Pending(result) => {
                            pending_operations.push(PendingKittyImageBudgetOperation {
                                surface_id: *id,
                                surface: Arc::downgrade(surface),
                                limits: *limits,
                                expanding: *expanding,
                                result,
                            });
                        }
                        DeadlineMapResult::Unscheduled => {
                            retry_expansion |= *expanding;
                            failed_surface_ids.insert(*id);
                            failures.push(format!(
                                "surface {id}: update was rejected because the deadline worker \
                                 pool is saturated"
                            ));
                        }
                    }
                }
                budget.expansion_in_flight = deferred_expansion
                    || retry_expansion
                    || pending_operations.iter().any(|pending| pending.expanding);
            }
            for pending in &pending_operations {
                if failed_surface_ids.insert(pending.surface_id) {
                    failures.push(format!(
                        "surface {}: update did not complete before its deadline",
                        pending.surface_id
                    ));
                }
            }
            mux.kitty_image_budget_changed.notify_all();
            let wave = tasks.iter().map(|(id, _, limits, _)| (*id, *limits)).collect::<Vec<_>>();
            if failures.is_empty() && !wave.is_empty() && wave == previous_wave {
                failures.push("Kitty quota update did not converge".to_string());
            }
            previous_wave = wave;
            if failures.is_empty() {
                failure_streak = 0;
                continue;
            }

            failure_streak = failure_streak.saturating_add(1);
            let retry_exhausted = failure_streak >= KITTY_IMAGE_BUDGET_RETRY_MAX_ATTEMPTS;
            // A transient retry is internal recovery. Publishing it as a
            // graphics status overwrites the user's status bar for a routine
            // topology change, even when the next attempt succeeds. Surface
            // only the terminal failure after the retry budget is exhausted.
            if retry_exhausted {
                let omitted = failures.len().saturating_sub(8);
                let mut summary = failures.into_iter().take(8).collect::<Vec<_>>().join("; ");
                if omitted > 0 {
                    summary.push_str(&format!("; {omitted} more"));
                }
                mux.emit(MuxEvent::GraphicsStatus(GraphicsStatus::KittyImageBudgetUpdateFailed {
                    retry_exhausted,
                    summary: Arc::<str>::from(summary),
                }));
            }
            if retry_exhausted {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                let blocked = failed_surface_ids
                    .into_iter()
                    .filter(|id| budget.entries.contains_key(id))
                    .collect::<Vec<_>>();
                budget.blocked_surfaces.extend(blocked);
                budget.expansion_in_flight = false;
                budget.worker_running = false;
                drop(budget);
                mux.kitty_image_budget_changed.notify_all();
                return;
            }
            let multiplier =
                1_u32.checked_shl(failure_streak.saturating_sub(1).min(16)).unwrap_or(u32::MAX);
            let delay = KITTY_IMAGE_BUDGET_RETRY_INITIAL
                .saturating_mul(multiplier)
                .min(KITTY_IMAGE_BUDGET_RETRY_MAX);
            drop(mux);
            std::thread::sleep(delay);
        }
    }

    pub(super) fn apply_kitty_image_limits(
        &self,
        surface: &Arc<Surface>,
        limits: KittyGraphicsLimits,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        #[cfg(test)]
        if let Some(operation) = self.kitty_image_budget_operation.lock().unwrap().clone() {
            return operation(surface, limits, deadline);
        }
        surface.set_kitty_graphics_limits_until(limits, deadline)
    }
}
