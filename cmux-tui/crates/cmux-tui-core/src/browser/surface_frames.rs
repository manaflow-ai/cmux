//! BrowserSurface frame storage: attach streams, frame epochs, and
//! navigation capture reconciliation when a frame is stored.

use super::*;

impl BrowserSurface {
    pub fn attach_frames(&self) -> (BrowserAttachState, BrowserFrameStream) {
        let (tx, rx) = crate::stream_interrupt::signal();
        let slot = Arc::new(RankedMutex::new(BrowserAttachUpdate::default()));
        let mut state = self.state.lock().unwrap();
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
        (snapshot, BrowserFrameStream { slot, notify: rx })
    }

    #[cfg(test)]
    pub(super) fn store_frame(&self, frame: BrowserFrame) {
        self.store_frame_for_epoch(frame, self.frame_epoch.current());
    }

    pub(super) fn store_frame_for_epoch(&self, frame: BrowserFrame, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
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
            let mut slot = tap.slot.lock().unwrap();
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
