//! BrowserSurface resize and cell-metric changes: reconfigure reservations,
//! waiters, confirmation, failure retries, and release.

use super::*;

impl BrowserSurface {
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_reporting_acceptance(cols, rows, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
    }

    pub fn resize_reporting_acceptance(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        self.resize_reporting_completion(cols, rows, report, None)
    }

    pub(crate) fn resize_reporting_completion(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
        completion: Option<BrowserResizeWaiter>,
    ) -> anyhow::Result<Option<u64>> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let Some(queued) = self.reserve_reconfigure(cols, rows) else {
            report(None);
            if let Some(completion) = completion {
                let _ = completion.send(Ok(()));
            }
            return Ok(None);
        };
        self.enqueue_reconfigure(BrowserCommand::Reconfigure {
            queued,
            report: Some(report),
            completion,
        })?;
        Ok(Some(queued.id))
    }

    pub(super) fn reconfigure_reserved_blocking(
        &self,
        queued: QueuedBrowserGeometry,
    ) -> BrowserWorkerResult {
        let invalidation = self.begin_reconfigure_frame_transition();
        let result = self.reconfigure_blocking(
            queued.geometry.capture_pixels.0,
            queued.geometry.capture_pixels.1,
        );
        match result {
            Ok((frame_epoch, success)) => {
                self.confirm_reconfigure(queued, frame_epoch);
                Ok(success)
            }
            Err(failure) => {
                if failure.definitely_unchanged {
                    self.restore_pointer_frame_after_failed_command(invalidation);
                }
                Err(failure.error)
            }
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_reporting(width_px, height_px, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
    }

    pub(crate) fn cell_pixel_size(&self) -> (u16, u16) {
        *self.cell_pixels.lock().unwrap()
    }

    pub fn set_cell_pixel_size_reporting(
        &self,
        width_px: u16,
        height_px: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        // Store desired metrics before calculating the candidate geometry.
        // Settled geometry remains in BrowserState, so an enqueue rejection
        // leaves a visible mismatch that the same request can retry.
        *self.cell_pixels.lock().unwrap() = (width_px.max(1), height_px.max(1));
        let (cols, rows) = self.size();
        self.resize_reporting_acceptance(cols, rows, report)
    }

    pub(super) fn reserve_reconfigure(
        &self,
        cols: u16,
        rows: u16,
    ) -> Option<QueuedBrowserGeometry> {
        let geometry = self.resize_geometry(cols, rows);
        let mut state = self.state.lock().unwrap();
        if state.pending_reconfigures.back().is_some_and(|queued| queued.geometry == geometry)
            || state.pending_reconfigures.is_empty() && browser_geometry_locked(&state) == geometry
        {
            return None;
        }
        if let Some(failure) = state.reconfigure_failure {
            if failure.geometry == geometry {
                if failure.retry_at.is_none_or(|retry_at| Instant::now() < retry_at) {
                    return None;
                }
            } else {
                state.reconfigure_failure = None;
            }
        }
        let queued = QueuedBrowserGeometry { id: state.next_reconfigure_id, geometry };
        state.next_reconfigure_id = state.next_reconfigure_id.wrapping_add(1).max(1);
        state.pending_reconfigures.push_back(queued);
        Some(queued)
    }

    pub(crate) fn pending_resize_completion(
        &self,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<PendingBrowserResize>> {
        let geometry = self.resize_geometry(cols, rows);
        let mut state = self.state.lock().unwrap();
        if let Some(pending) =
            state.pending_reconfigures.iter().rev().find(|pending| pending.geometry == geometry)
        {
            let reservation = pending.id;
            if state
                .reconfigure_waiters
                .get(&reservation)
                .is_some_and(|waiters| waiters.len() >= MAX_RECONFIGURE_WAITERS_PER_RESERVATION)
            {
                anyhow::bail!("browser resize reservation {reservation} has too many waiters");
            }
            let (completion, completed) = sync_channel(1);
            state.reconfigure_waiters.entry(reservation).or_default().push(completion);
            return Ok(Some(PendingBrowserResize { reservation, completion: completed }));
        }
        if browser_geometry_locked(&state) == geometry {
            return Ok(None);
        }
        if state.reconfigure_failure.is_some_and(|failure| failure.geometry == geometry) {
            anyhow::bail!("browser resize is waiting to retry after a previous failure");
        }
        anyhow::bail!("browser resize was not accepted");
    }

    pub(super) fn complete_reconfigure_waiters(
        &self,
        reservation: u64,
        outcome: BrowserResizeOutcome,
    ) {
        let waiters =
            self.state.lock().unwrap().reconfigure_waiters.remove(&reservation).unwrap_or_default();
        for waiter in waiters {
            let _ = waiter.send(outcome.clone());
        }
    }

    pub(super) fn confirm_reconfigure(&self, queued: QueuedBrowserGeometry, frame_epoch: u64) {
        let mut state = self.state.lock().unwrap();
        let Some(index) =
            state.pending_reconfigures.iter().position(|pending| pending.id == queued.id)
        else {
            return;
        };
        state.pending_reconfigures.remove(index);
        let geometry = queued.geometry;
        let changed = browser_geometry_locked(&state) != geometry;
        state.reconfigure_failure = None;
        state.size = geometry.size;
        state.pane_pixels = geometry.pane_pixels;
        state.capture_pixels = geometry.capture_pixels;
        state.capture_scale = geometry.capture_scale;
        if changed {
            state.latest_frame = None;
            Self::set_pointer_frame_locked(&mut state, None);
            self.set_pending_attach_frame_locked(&mut state, None);
            state.page_viewport = None;
            state.live_since = Some(Instant::now());
            state.last_frame_at = None;
            state.stall_nudged = false;
        }
        if frame_epoch >= state.accepted_frame_epoch
            && state.pending_frame_epoch.is_none_or(|pending_epoch| frame_epoch >= pending_epoch)
        {
            let accepted_navigation_epoch = state.accepted_navigation_epoch;
            self.accept_frame_epoch_locked(&mut state, frame_epoch, accepted_navigation_epoch);
        }
        self.mark_state_dirty_locked(&mut state);
    }

    pub(super) fn fail_reconfigure(
        &self,
        queued: QueuedBrowserGeometry,
    ) -> Option<(u8, Option<Duration>)> {
        let mut state = self.state.lock().unwrap();
        let index =
            state.pending_reconfigures.iter().position(|pending| pending.id == queued.id)?;
        state.pending_reconfigures.remove(index);
        let geometry = queued.geometry;
        let attempts = state
            .reconfigure_failure
            .filter(|failure| failure.geometry == geometry)
            .map_or(1, |failure| failure.attempts.saturating_add(1));
        let retry_delay = BROWSER_RECONFIGURE_RETRY_DELAYS.get(usize::from(attempts - 1)).copied();
        state.reconfigure_failure = Some(BrowserReconfigureFailure {
            geometry,
            attempts,
            retry_at: retry_delay.map(|delay| Instant::now() + delay),
        });
        if retry_delay.is_none() && state.pending_reconfigures.is_empty() {
            state.pending_frame_epoch = None;
            state.pending_navigation_epoch = None;
            state.pending_document_epoch = None;
            state.pending_same_document_navigation = false;
            state.pending_failure_recovery = false;
            state.pending_frame = None;
            state.pending_navigation_rollback = None;
            self.mark_failed_locked(
                &mut state,
                BrowserFailureKind::ResizeRecovery,
                BROWSER_RESIZE_RECOVERY_FAILED_MESSAGE,
            );
            self.mark_state_dirty_locked(&mut state);
            self.dirty.store(true, Ordering::Release);
        }
        Some((attempts, retry_delay))
    }

    pub(super) fn release_reconfigure(&self, queued: QueuedBrowserGeometry) {
        let waiters = {
            let mut state = self.state.lock().unwrap();
            if let Some(index) =
                state.pending_reconfigures.iter().position(|pending| pending.id == queued.id)
            {
                state.pending_reconfigures.remove(index);
            }
            state.reconfigure_waiters.remove(&queued.id).unwrap_or_default()
        };
        for waiter in waiters {
            let _ = waiter.send(Err(Arc::from("browser resize was rejected before execution")));
        }
    }

    pub(super) fn reconfigure_blocking(
        &self,
        width: u32,
        height: u32,
    ) -> Result<(u64, BrowserWorkerSuccess), BrowserReconfigureCommandError> {
        let Some(session) = self.attached_session().map_err(|error| {
            BrowserReconfigureCommandError { error, definitely_unchanged: true }
        })?
        else {
            return Ok((self.frame_epoch.advance(), BrowserWorkerSuccess::LocallySettled));
        };
        if let Err(error) =
            session.runtime.client.set_device_metrics(&session.session_id, width, height)
        {
            let definitely_unchanged = !is_cdp_timeout_error(&error.to_string());
            return Err(BrowserReconfigureCommandError { error, definitely_unchanged });
        }
        let _ = session.runtime.client.stop_screencast(&session.session_id);
        session
            .runtime
            .client
            .start_screencast_with_frame_barrier(&session.session_id, width, height)
            .map(|frame_epoch| (frame_epoch, BrowserWorkerSuccess::BrowserResponded))
            .map_err(|error| BrowserReconfigureCommandError { error, definitely_unchanged: false })
    }

    pub(crate) fn resize_needed(&self, cols: u16, rows: u16) -> bool {
        let geometry = self.resize_geometry(cols, rows);
        let mut state = self.state.lock().unwrap();
        if state.reconfigure_failure.is_some_and(|failure| failure.geometry != geometry) {
            state.reconfigure_failure = None;
        }
        if state.pending_reconfigures.back().is_some_and(|queued| queued.geometry == geometry) {
            return false;
        }
        if let Some(failure) = state.reconfigure_failure
            && failure.geometry == geometry
            && failure.retry_at.is_none_or(|retry_at| Instant::now() < retry_at)
        {
            return false;
        }
        browser_geometry_locked(&state) != geometry || !state.pending_reconfigures.is_empty()
    }

    pub(super) fn resize_geometry(&self, cols: u16, rows: u16) -> BrowserGeometry {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let cell = *self.cell_pixels.lock().unwrap();
        let pixel_w = cols as u32 * cell.0.max(1) as u32;
        let pixel_h = rows as u32 * cell.1.max(1) as u32;
        let capture_scale = capture_scale_for(pixel_w, pixel_h, self.capture_options);
        let capture_pixels = scaled_pixels(pixel_w, pixel_h, capture_scale);
        BrowserGeometry {
            size: (cols, rows),
            pane_pixels: (pixel_w, pixel_h),
            capture_pixels,
            capture_scale,
        }
    }
}
