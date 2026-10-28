//! BrowserSurface frame storage: attach streams, frame epochs, and
//! navigation capture reconciliation when a frame is stored.

use super::*;
use crate::panic_free::RecoverPoison;

impl BrowserSurface {
    pub fn attach_frames(&self) -> (BrowserAttachState, BrowserFrameStream) {
        let (tx, rx) = crate::stream_interrupt::signal();
        let slot = Arc::new(Mutex::new(BrowserAttachUpdate::default()));
        let mut state = self.state.lock().recover_poison();
        let pointer_frame_floor_seq = self.exported_pointer_frame_floor_seq_locked(&state);
        let pointer_frame_seq = self.exported_pointer_frame_seq_locked(&state);
        let snapshot = browser_attach_state_locked(
            &state,
            Instant::now(),
            self.is_dead(),
            true,
            pointer_frame_floor_seq,
            pointer_frame_seq,
        );
        if !self.is_dead() {
            state.taps.push(BrowserFrameTap { slot: slot.clone(), notify: tx });
        }
        drop(state);
        let viewer = FrameViewer {
            viewers: self.frame_viewers.clone(),
            command_tx: self.command_tx.clone(),
            command_order: self.command_order.clone(),
        };
        if self.frame_viewers.fetch_add(1, Ordering::AcqRel) == 0 {
            viewer.wake_worker();
        }
        (snapshot, BrowserFrameStream { slot, notify: rx, _viewer: viewer })
    }

    /// At least one frame viewer is attached.
    pub(super) fn has_frame_viewers(&self) -> bool {
        self.frame_viewers.load(Ordering::Acquire) > 0
    }

    pub(super) fn set_screencast_paused(&self, paused: bool) {
        let mut state = self.state.lock().recover_poison();
        state.screencast_paused = paused;
        if !paused {
            // Frames are due from now on, not since the page went live.
            state.live_since = state.live_since.map(|_| Instant::now());
            state.last_frame_at = None;
            state.stall_nudged = false;
        }
    }

    pub(super) fn screencast_paused(&self) -> bool {
        self.state.lock().recover_poison().screencast_paused
    }

    /// Worker side of frame demand for a natively hosted page: screencast
    /// while a frame viewer is attached, nothing otherwise. Daemon-hosted
    /// pages always screencast and are left alone. A failed start or stop is
    /// retried at [`Self::frame_demand_retry_at`], which the worker waits for.
    pub(super) fn reconcile_frame_demand(&self) {
        let now = Instant::now();
        let session = if self.is_dead() {
            None
        } else {
            match self.session.lock().recover_poison().as_ref() {
                Some(session) if session.runtime.native_hosted() => Some(session.clone()),
                _ => None,
            }
        };
        let wanted = self.has_frame_viewers();
        {
            let mut state = self.state.lock().recover_poison();
            if session.is_none() || wanted != state.screencast_paused {
                state.frame_demand_retry_at = None;
                return;
            }
            if state.frame_demand_retry_at.is_some_and(|retry_at| now < retry_at) {
                return;
            }
        }
        let Some(session) = session else { return };
        let (width, height) = self.pixel_size();
        let client = &session.runtime.client;
        let result = if wanted {
            client.start_screencast(&session.session_id, width, height)
        } else {
            client.stop_screencast(&session.session_id)
        };
        let current = self.session.lock().recover_poison();
        if current.as_ref().is_none_or(|live| live.session_id != session.session_id) {
            return;
        }
        let mut state = self.state.lock().recover_poison();
        if result.is_err() {
            state.frame_demand_retry_at = Some(Instant::now() + FRAME_DEMAND_RETRY_DELAY);
            return;
        }
        state.frame_demand_retry_at = None;
        drop(state);
        self.set_screencast_paused(!wanted);
        if !wanted {
            // Nobody views the page now: the next viewer must not get, or
            // aim guarded pointer input at, pixels from before the pause.
            let mut state = self.state.lock().recover_poison();
            state.latest_frame = None;
            Self::set_pointer_frame_locked(&mut state, None);
            self.set_pending_attach_frame_locked(&mut state, None);
            self.mark_state_dirty_locked(&mut state);
        }
    }

    /// When the worker retries a failed screencast start or stop.
    pub(super) fn frame_demand_retry_at(&self) -> Option<Instant> {
        self.state.lock().recover_poison().frame_demand_retry_at
    }

    #[cfg(test)]
    pub(crate) fn store_frame(&self, frame: BrowserFrame) {
        self.store_frame_for_epoch(frame, self.frame_epoch.current());
    }

    /// Tests: a state change, then a frame, for the attach taps.
    #[cfg(test)]
    pub(crate) fn store_state_and_frame_for_test(&self, frame: BrowserFrame) {
        let mut state = self.state.lock().unwrap();
        self.mark_state_dirty_locked(&mut state);
        drop(state);
        self.store_frame(frame);
    }

    pub(super) fn store_frame_for_epoch(&self, frame: BrowserFrame, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().recover_poison();
        if let Some(pending_epoch) = state.pending_frame_epoch {
            if frame_epoch >= pending_epoch
                && state
                    .pending_frame
                    .as_ref()
                    .is_none_or(|(retained_epoch, _)| frame_epoch >= *retained_epoch)
            {
                state.pending_frame = Some((frame_epoch, frame));
            }
            return false;
        }
        if frame_epoch > state.accepted_frame_epoch {
            if state
                .pending_frame
                .as_ref()
                .is_none_or(|(retained_epoch, _)| frame_epoch >= *retained_epoch)
            {
                state.pending_frame = Some((frame_epoch, frame));
            }
            return false;
        }
        if frame_epoch < state.accepted_frame_epoch {
            return false;
        }
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch == frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        if state.failed_screencast_capture_epoch == Some(frame_epoch) {
            state.failed_screencast_capture_epoch = None;
        }
        self.store_frame_locked(&mut state, frame);
        true
    }

    pub(super) fn store_frame_locked(&self, state: &mut BrowserState, mut frame: BrowserFrame) {
        // Screencast frames keep streaming the previous page after a
        // failed navigation; they must not mask that failure. A fresh
        // frame does prove Chrome recovered from the worker's
        // not-responding state, so clear only that class here.
        let clears_not_responding = state.failure_kind == Some(BrowserFailureKind::NotResponding);
        if !matches!(state.status, BrowserStatus::Failed(_)) || clears_not_responding {
            state.status = BrowserStatus::Live;
            if clears_not_responding {
                state.failure_kind = None;
                state.not_responding_reported = false;
                // `mark_failed` overwrote the title with "browser failed: ..."
                // and broadcast the failure to attach clients. Recovering only
                // in-memory would leave remote TUIs stuck on the failed
                // status/title even as fresh frames arrive. Restore a non-failed
                // title from the retained URL (the next CDP title event refines
                // it) and broadcast the recovered state to attach clients the
                // same way the failure was broadcast.
                //
                // Do NOT set `self.dirty` here: the caller that delivers this
                // frame emits `SurfaceOutput` via `if !dirty.swap(true)`, which
                // is what redraws the local TUI. Pre-setting `dirty` would
                // consume that transition and suppress the local recovery
                // redraw, leaving the local status line stuck on the failure.
                state.title = state.url.clone();
            }
        }
        frame.seq = state.next_frame_seq;
        state.next_frame_seq = state.next_frame_seq.saturating_add(1);
        state.last_frame_at = Some(Instant::now());
        state.stall_nudged = false;
        let page_viewport = (frame.css_width.max(1), frame.css_height.max(1));
        let pointer_geometry_changed =
            state.page_viewport.is_some_and(|previous| previous != page_viewport);
        if pointer_geometry_changed {
            state.pointer_motion_generation = state.pointer_motion_generation.wrapping_add(1);
        }
        state.page_viewport = Some(page_viewport);
        let can_authorize_pointer = matches!(state.status, BrowserStatus::Live)
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation;
        let pointer_frame_seq = can_authorize_pointer.then_some(frame.seq);
        if pointer_geometry_changed {
            Self::set_pointer_frame_locked(state, pointer_frame_seq);
        } else if state.pointer_frame_seq != pointer_frame_seq {
            Self::advance_pointer_frame_locked(state, pointer_frame_seq);
        }
        if clears_not_responding {
            self.mark_state_dirty_locked(state);
        }
        let frame = Arc::new(frame);
        state.latest_frame = Some(frame.clone());
        let update = BrowserFrameUpdate {
            frame: frame.as_ref().clone(),
            status: state.status.clone(),
            pointer_frame_floor_seq: self.exported_pointer_frame_floor_seq_locked(state),
            pointer_frame_seq: self.exported_pointer_frame_seq_locked(state),
        };
        let attach_state = browser_attach_state_locked(
            state,
            Instant::now(),
            false,
            false,
            update.pointer_frame_floor_seq,
            update.pointer_frame_seq,
        );
        state.taps.retain(|tap| {
            let mut slot = tap.slot.lock().recover_poison();
            slot.frame = Some(update.clone());
            if slot.state.is_some() {
                slot.state = Some(attach_state.clone());
            }
            drop(slot);
            match tap.notify.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => true,
                Err(TrySendError::Disconnected(())) => false,
            }
        });
    }

    pub(super) fn reconcile_navigation_capture_locked(
        state: &mut BrowserState,
        navigation_epoch: u64,
    ) {
        if navigation_epoch > state.accepted_navigation_epoch {
            state.accepted_navigation_epoch = navigation_epoch;
            state.pointer_capture_generation = state.pointer_capture_generation.wrapping_add(1);
        }
    }

    pub(super) fn accept_frame_epoch_locked(
        &self,
        state: &mut BrowserState,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) {
        if frame_epoch < state.accepted_frame_epoch {
            return;
        }
        Self::reconcile_navigation_capture_locked(state, navigation_epoch);
        state.accepted_frame_epoch = frame_epoch;
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch <= frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        if state.failed_screencast_capture_epoch == Some(frame_epoch) {
            state.failed_screencast_capture_epoch = None;
        }
        if state.pending_frame_epoch.is_some_and(|pending_epoch| frame_epoch >= pending_epoch) {
            state.pending_frame_epoch = None;
        }
        let pending = match state.pending_frame.take() {
            Some((pending_epoch, frame)) if pending_epoch == frame_epoch => Some(frame),
            newer @ Some((pending_epoch, _)) if pending_epoch > frame_epoch => {
                state.pending_frame = newer;
                None
            }
            _ => None,
        };
        if let Some(frame) = pending {
            self.store_frame_locked(state, frame);
        }
    }
}
