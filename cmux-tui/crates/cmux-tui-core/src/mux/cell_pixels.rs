//! Cell pixel size: the creation size, deferred and completed acks, the retry worker, and fanout of cell pixel size reports to surfaces.

use super::*;

impl Mux {
    pub fn set_cell_pixel_size(self: &Arc<Self>, width_px: u16, height_px: u16) -> CellPixelUpdate {
        self.set_cell_pixel_size_reporting(width_px, height_px, Arc::new(|_, _, _| {}))
    }

    pub fn cell_pixel_size(&self) -> (u16, u16) {
        *self.cell_pixels.lock().unwrap()
    }

    pub(crate) fn cell_pixel_creation_size(&self) -> (u16, u16) {
        if let Some(target) = self
            .pending_cell_pixels
            .lock()
            .unwrap()
            .as_ref()
            .filter(|pending| pending.use_for_creation)
            .map(|pending| pending.target)
        {
            return target;
        }
        self.cell_pixel_size()
    }

    pub(super) fn reconcile_surface_cell_pixels_for_publish<'a>(
        &'a self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<MutexGuard<'a, ()>> {
        loop {
            let lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let target = self.cell_pixel_creation_size();
            if surface.cell_pixel_size() == target {
                return Ok(lifecycle);
            }
            drop(lifecycle);
            validate_cell_pixel_convergence(
                surface,
                target,
                surface.set_cell_pixel_size_reporting_until(
                    target.0,
                    target.1,
                    Instant::now() + crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT,
                    Box::new(|_| {}),
                ),
            )?;
        }
    }

    pub(crate) fn reconcile_deferred_cell_pixel_ack(&self, surface: SurfaceId, target: (u16, u16)) {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        self.reconcile_cell_pixel_ack_locked(surface, target);
    }

    pub(crate) fn submit_deferred_cell_pixel_ack(
        &self,
        task: impl FnOnce() + Send + 'static,
    ) -> bool {
        self.deadline_fanout_pool.submit(Box::new(task))
    }

    pub(super) fn reconcile_cell_pixel_ack_locked(&self, surface: SurfaceId, target: (u16, u16)) {
        let mut pending = self.pending_cell_pixels.lock().unwrap();
        let Some(update) = pending.as_mut().filter(|update| update.target == target) else {
            return;
        };
        update.failures.remove(&surface);
        if !update.failures.is_empty() {
            return;
        }
        *self.cell_pixels.lock().unwrap() = target;
        *pending = None;
    }

    pub(super) fn reconcile_cell_pixel_completion_locked(
        &self,
        surface: SurfaceId,
        generation: u64,
        target: (u16, u16),
    ) {
        let mut pending = self.pending_cell_pixels.lock().unwrap();
        let Some(update) = pending
            .as_mut()
            .filter(|update| update.generation == generation && update.target == target)
        else {
            return;
        };
        update.failures.remove(&surface);
        if !update.failures.is_empty() {
            return;
        }
        *self.cell_pixels.lock().unwrap() = target;
        *pending = None;
    }

    pub(super) fn record_cell_pixel_completion(
        self: &Arc<Self>,
        completion: &Arc<CellPixelCompletionTracker>,
        surface: SurfaceId,
    ) {
        completion.completed.lock().unwrap().insert(surface);
        if completion.publishing.load(Ordering::Acquire) {
            return;
        }
        let _lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        if completion.completed.lock().unwrap().remove(&surface) {
            self.reconcile_cell_pixel_completion_locked(
                surface,
                completion.generation,
                completion.target,
            );
        }
    }

    pub(super) fn enqueue_cell_pixel_retries(
        self: &Arc<Self>,
        task: CellPixelRetryTask,
    ) -> std::io::Result<()> {
        let mut retries = self.cell_pixel_retries.lock().unwrap();
        if retries.pending.as_ref().is_some_and(|pending| pending.generation > task.generation) {
            return Ok(());
        }
        retries.pending = Some(task);
        if retries.worker_running {
            return Ok(());
        }
        retries.worker_running = true;
        let mux = Arc::downgrade(self);
        match std::thread::Builder::new()
            .name("cell-pixel-retry".to_string())
            .spawn(move || Self::run_cell_pixel_retry_worker(mux))
        {
            Ok(_) => Ok(()),
            Err(error) => {
                retries.worker_running = false;
                retries.pending = None;
                Err(error)
            }
        }
    }

    pub(super) fn run_cell_pixel_retry_worker(mux: Weak<Self>) {
        loop {
            let task = {
                let Some(mux) = mux.upgrade() else { return };
                let mut retries = mux.cell_pixel_retries.lock().unwrap();
                if mux.shutting_down.load(Ordering::Acquire) {
                    retries.pending = None;
                    retries.worker_running = false;
                    return;
                }
                match retries.pending.take() {
                    Some(task) => task,
                    None => {
                        retries.worker_running = false;
                        return;
                    }
                }
            };
            if let Some(mut task) = Self::run_cell_pixel_retry_task(&mux, task) {
                task.attempts = task.attempts.saturating_add(1);
                if task.attempts >= CELL_PIXEL_RETRY_MAX_ATTEMPTS {
                    if let Some(mux) = mux.upgrade() {
                        mux.finish_cell_pixel_retries(&task);
                    }
                    continue;
                }
                std::thread::sleep(cell_pixel_retry_delay(task.attempts));
                let Some(mux) = mux.upgrade() else { return };
                let mut retries = mux.cell_pixel_retries.lock().unwrap();
                if retries.pending.is_none() {
                    retries.pending = Some(task);
                }
            }
        }
    }

    pub(super) fn finish_cell_pixel_retries(&self, task: &CellPixelRetryTask) {
        let remaining = {
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let mut pending = self.pending_cell_pixels.lock().unwrap();
            let Some(pending) = pending.as_mut().filter(|pending| {
                pending.generation == task.generation && pending.target == task.target
            }) else {
                return;
            };
            pending.use_for_creation = false;
            pending.failures.len()
        };
        self.emit(MuxEvent::GraphicsStatus(GraphicsStatus::CellPixelUpdateRetriesExhausted {
            attempts: task.attempts,
            remaining,
            cell_pixels: task.target,
        }));
    }

    pub(super) fn run_cell_pixel_retry_task(
        mux: &Weak<Self>,
        task: CellPixelRetryTask,
    ) -> Option<CellPixelRetryTask> {
        let mut retry_candidates = task.surfaces;
        let mut pending_operations = Vec::new();
        for pending in task.pending {
            let Some(result) = pending.result.try_take() else {
                pending_operations.push(pending);
                continue;
            };
            let mux = mux.upgrade()?;
            let _cell_pixel_lifecycle = mux.cell_pixel_lifecycle.lock().unwrap();
            if !mux.pending_cell_pixels.lock().unwrap().as_ref().is_some_and(|update| {
                update.generation == task.generation && update.target == task.target
            }) {
                return None;
            }
            let (surface_id, _, result, deferred) = result;
            match result {
                Ok(_) => mux.reconcile_cell_pixel_completion_locked(
                    surface_id,
                    task.generation,
                    task.target,
                ),
                Err(_) if deferred => {}
                Err(_) => retry_candidates.push(pending.surface),
            }
        }
        let mut unique = HashSet::new();
        retry_candidates
            .retain(|surface| surface.upgrade().is_some_and(|surface| unique.insert(surface.id)));
        let mut remaining = Vec::new();
        for retry_wave in retry_candidates.chunks(CELL_PIXEL_FANOUT_MAX_WORKERS) {
            let mux = mux.upgrade()?;
            let active = {
                let _cell_pixel_lifecycle = mux.cell_pixel_lifecycle.lock().unwrap();
                let pending = mux.pending_cell_pixels.lock().unwrap();
                let pending = pending.as_ref().filter(|pending| {
                    pending.generation == task.generation
                        && pending.target == task.target
                        && !pending.failures.is_empty()
                })?;
                retry_wave
                    .iter()
                    .filter_map(Weak::upgrade)
                    .filter(|surface| pending.failures.contains(&surface.id))
                    .collect::<Vec<_>>()
            };
            let deadline = Instant::now() + task.timeout;
            let report = task.report.clone();
            #[cfg(test)]
            let operation_hook = task.operation_hook.clone();
            let target = task.target;
            let completion = task.completion.clone();
            let completion_mux = Arc::downgrade(&mux);
            let results = bounded_deadline_map(
                &mux.deadline_fanout_pool,
                &active,
                deadline,
                move |surface, deadline| {
                    let result = apply_cell_pixel_size_until(
                        surface,
                        target,
                        deadline,
                        &report,
                        #[cfg(test)]
                        operation_hook.as_ref(),
                    );
                    let completed_at = Instant::now();
                    if completed_at <= deadline
                        && result.2.is_ok()
                        && let Some(mux) = completion_mux.upgrade()
                    {
                        mux.record_cell_pixel_completion(&completion, surface.id);
                    }
                    result
                },
            );
            let _cell_pixel_lifecycle = mux.cell_pixel_lifecycle.lock().unwrap();
            if !mux.pending_cell_pixels.lock().unwrap().as_ref().is_some_and(|pending| {
                pending.generation == task.generation && pending.target == task.target
            }) {
                return None;
            }
            for (surface, result) in active.iter().zip(results) {
                let (surface_id, result, deferred) = match result {
                    DeadlineMapResult::Complete((surface_id, _, result, deferred)) => {
                        (surface_id, Some(result), deferred)
                    }
                    DeadlineMapResult::Pending(result) => {
                        pending_operations.push(PendingCellPixelOperation {
                            surface: Arc::downgrade(surface),
                            result,
                        });
                        continue;
                    }
                    DeadlineMapResult::Unscheduled => {
                        remaining.push(Arc::downgrade(surface));
                        continue;
                    }
                };
                match result.expect("complete deadline result has an operation result") {
                    Ok(_) => mux.reconcile_cell_pixel_completion_locked(
                        surface_id,
                        task.generation,
                        task.target,
                    ),
                    Err(_) if deferred => {}
                    Err(error)
                        if error
                            .downcast_ref::<
                                crate::terminal_host_runtime::CellPixelRequestDeadlineElapsed,
                            >()
                            .is_some() =>
                    {
                        remaining.push(Arc::downgrade(surface));
                    }
                    Err(_) => {
                        if let Some(pending) = mux
                            .pending_cell_pixels
                            .lock()
                            .unwrap()
                            .as_mut()
                            .filter(|pending| {
                                pending.generation == task.generation
                                    && pending.target == task.target
                            })
                        {
                            pending.use_for_creation = false;
                        }
                    }
                }
            }
        }
        let pending_ids = pending_operations
            .iter()
            .filter_map(|pending| pending.surface.upgrade())
            .map(|surface| surface.id)
            .collect::<HashSet<_>>();
        let mut unique = HashSet::new();
        remaining.retain(|surface| {
            surface.upgrade().is_some_and(|surface| {
                !pending_ids.contains(&surface.id) && unique.insert(surface.id)
            })
        });
        (!remaining.is_empty() || !pending_operations.is_empty()).then_some(CellPixelRetryTask {
            surfaces: remaining,
            pending: pending_operations,
            attempts: task.attempts,
            generation: task.generation,
            target: task.target,
            completion: task.completion,
            report: task.report,
            timeout: task.timeout,
            #[cfg(test)]
            operation_hook: task.operation_hook,
        })
    }

    pub fn set_cell_pixel_size_reporting(
        self: &Arc<Self>,
        width_px: u16,
        height_px: u16,
        report: SurfaceResizeReporter,
    ) -> CellPixelUpdate {
        let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let generation = self.next_cell_pixel_generation.fetch_add(1, Ordering::Relaxed);
        let next = (width_px.max(1), height_px.max(1));
        let completion = Arc::new(CellPixelCompletionTracker {
            generation,
            target: next,
            publishing: AtomicBool::new(true),
            completed: RankedMutex::new(HashSet::new()),
        });
        let mut surfaces = unique_surface_runtimes(&self.state.lock().unwrap());
        surfaces.sort_unstable_by_key(|surface| surface.id);
        #[cfg(test)]
        let timeout = self
            .cell_pixel_fanout_timeout
            .lock()
            .unwrap()
            .unwrap_or(crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT);
        #[cfg(not(test))]
        let timeout = crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT;
        let deadline = Instant::now() + timeout;
        #[cfg(test)]
        let operation_hook = self.cell_pixel_operation.lock().unwrap().clone();
        #[cfg(test)]
        let fanout_operation_hook = operation_hook.clone();
        let operation_report = report.clone();
        let operation_completion = completion.clone();
        let operation_mux = Arc::downgrade(self);
        let results = bounded_deadline_map(
            &self.deadline_fanout_pool,
            &surfaces,
            deadline,
            move |surface, deadline| {
                let result = apply_cell_pixel_size_until(
                    surface,
                    next,
                    deadline,
                    &operation_report,
                    #[cfg(test)]
                    fanout_operation_hook.as_ref(),
                );
                let completed_at = Instant::now();
                if completed_at <= deadline
                    && result.2.is_ok()
                    && let Some(mux) = operation_mux.upgrade()
                {
                    mux.record_cell_pixel_completion(&operation_completion, surface.id);
                }
                result
            },
        );
        let mut update = CellPixelUpdate::default();
        let mut retry_surfaces = Vec::new();
        let mut pending_operations = Vec::new();
        for (surface, result) in surfaces.iter().zip(results) {
            let (id, size, result, deferred) = match result {
                DeadlineMapResult::Complete(result) => result,
                DeadlineMapResult::Pending(result) => {
                    pending_operations.push(PendingCellPixelOperation {
                        surface: Arc::downgrade(surface),
                        result,
                    });
                    update.failures.push(CellPixelUpdateFailure {
                        surface: surface.id,
                        error: "cell pixel update is still running after the shared deadline"
                            .to_string(),
                        deferred: true,
                    });
                    continue;
                }
                DeadlineMapResult::Unscheduled => {
                    retry_surfaces.push(Arc::downgrade(surface));
                    update.failures.push(CellPixelUpdateFailure {
                        surface: surface.id,
                        error: "cell pixel update was deferred because the deadline worker pool \
                                is saturated"
                            .to_string(),
                        deferred: true,
                    });
                    continue;
                }
            };
            match result {
                Ok(Some(reservation_id)) => update.resizes.push((id, size, reservation_id)),
                Ok(None) => {}
                Err(error) => {
                    let retry = error
                        .downcast_ref::<
                            crate::terminal_host_runtime::CellPixelRequestDeadlineElapsed,
                        >()
                        .is_some();
                    if retry {
                        retry_surfaces.push(Arc::downgrade(surface));
                    }
                    update.failures.push(CellPixelUpdateFailure {
                        surface: id,
                        error: error.to_string(),
                        deferred: deferred || retry,
                    });
                }
            }
        }
        let completed = std::mem::take(&mut *completion.completed.lock().unwrap());
        if !completed.is_empty() {
            update.failures.retain(|failure| !completed.contains(&failure.surface));
            retry_surfaces.retain(|surface| {
                surface.upgrade().is_some_and(|surface| !completed.contains(&surface.id))
            });
            pending_operations.retain(|pending| {
                pending.surface.upgrade().is_some_and(|surface| !completed.contains(&surface.id))
            });
        }
        #[cfg(test)]
        if let Some(hook) = self.cell_pixel_before_publish.lock().unwrap().clone() {
            hook(self.cell_pixel_size());
        }
        // Keep the published value at the last fully converged metric. New
        // surfaces use the pending target, and late hosted acknowledgements
        // remove their exact failure before publishing it globally.
        if update.failures.is_empty() {
            *self.cell_pixels.lock().unwrap() = next;
            *self.pending_cell_pixels.lock().unwrap() = None;
        } else {
            *self.pending_cell_pixels.lock().unwrap() = Some(PendingCellPixelUpdate {
                generation,
                target: next,
                failures: update.failures.iter().map(|failure| failure.surface).collect(),
                use_for_creation: update.failures.iter().all(|failure| failure.deferred),
            });
        }
        completion.publishing.store(false, Ordering::Release);
        let raced_completions = std::mem::take(&mut *completion.completed.lock().unwrap());
        for surface in &raced_completions {
            self.reconcile_cell_pixel_completion_locked(*surface, generation, next);
        }
        if !raced_completions.is_empty() {
            update.failures.retain(|failure| !raced_completions.contains(&failure.surface));
            retry_surfaces.retain(|surface| {
                surface.upgrade().is_some_and(|surface| !raced_completions.contains(&surface.id))
            });
            pending_operations.retain(|pending| {
                pending
                    .surface
                    .upgrade()
                    .is_some_and(|surface| !raced_completions.contains(&surface.id))
            });
        }
        let retry_ids = retry_surfaces
            .iter()
            .filter_map(Weak::upgrade)
            .map(|surface| surface.id)
            .chain(
                pending_operations
                    .iter()
                    .filter_map(|pending| pending.surface.upgrade())
                    .map(|surface| surface.id),
            )
            .collect::<HashSet<_>>();
        let retry_spawn = if retry_surfaces.is_empty() && pending_operations.is_empty() {
            Ok(())
        } else {
            self.enqueue_cell_pixel_retries(CellPixelRetryTask {
                surfaces: retry_surfaces,
                pending: pending_operations,
                attempts: 0,
                generation,
                target: next,
                completion,
                report,
                timeout,
                #[cfg(test)]
                operation_hook,
            })
        };
        if let Err(error) = retry_spawn {
            for failure in &mut update.failures {
                if retry_ids.contains(&failure.surface) {
                    failure.deferred = false;
                    failure.error = format!("{}; could not schedule retry: {error}", failure.error);
                }
            }
            if let Some(pending) = self.pending_cell_pixels.lock().unwrap().as_mut() {
                pending.use_for_creation = update.failures.iter().all(|failure| failure.deferred);
            }
        }
        drop(cell_pixel_lifecycle);
        update
    }
}
