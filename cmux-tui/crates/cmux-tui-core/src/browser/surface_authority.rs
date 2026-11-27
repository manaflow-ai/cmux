//! BrowserSurface paint authority: screencast capture reservations and
//! acceptance or failure of document and same-document paints.

use super::*;

impl BrowserSurface {
    pub(super) fn screencast_capture_context_matches(
        &self,
        state: &BrowserState,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        matches!(state.status, BrowserStatus::Live)
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation
            && state.accepted_navigation_epoch == navigation_epoch
            && self.frame_epoch.latest_navigation() == navigation_epoch
            && self.frame_epoch.current() == frame_epoch
            && state.accepted_frame_epoch <= frame_epoch
    }

    pub(super) fn reserve_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        if !self.screencast_capture_context_matches(&state, frame_epoch, navigation_epoch)
            || state.pending_screencast_capture.is_some_and(|reservation| {
                reservation.frame_epoch == frame_epoch
                    && reservation.navigation_epoch == navigation_epoch
            })
            || state.failed_screencast_capture_epoch == Some(frame_epoch)
        {
            return false;
        }
        state.pending_screencast_capture = Some(ScreencastCaptureReservation {
            id: reservation_id,
            frame_epoch,
            navigation_epoch,
        });
        true
    }

    pub(super) fn may_need_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> bool {
        let state = self.state.lock().unwrap();
        self.screencast_capture_context_matches(&state, frame_epoch, navigation_epoch)
            && state.pending_screencast_capture
                == Some(ScreencastCaptureReservation {
                    id: reservation_id,
                    frame_epoch,
                    navigation_epoch,
                })
            && state.failed_screencast_capture_epoch != Some(frame_epoch)
    }

    pub(super) fn cancel_screencast_capture(&self, reservation_id: u64) {
        let mut state = self.state.lock().unwrap();
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.id == reservation_id)
        {
            state.pending_screencast_capture = None;
        }
    }

    pub(super) fn needs_same_document_paint(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.pending_document_epoch.is_none() && state.pending_same_document_navigation
    }

    pub(super) fn reconcile_same_document_snapshot(
        &self,
        same_document_navigation_epoch: u64,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        if same_document_navigation_epoch != self.frame_epoch.latest_same_document_navigation()
            || state.pending_document_epoch.is_some()
            || !state.pending_same_document_navigation
        {
            return false;
        }
        state.handled_same_document_navigation_epoch = same_document_navigation_epoch;
        true
    }

    pub(super) fn observe_same_document_frame_epoch(&self, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if frame_epoch <= state.handled_same_document_navigation_epoch
            || frame_epoch != self.frame_epoch.latest_same_document_navigation()
            || state.pending_document_epoch.is_some()
            || state.pending_navigation_epoch.is_some() && !state.pending_same_document_navigation
            || !(matches!(state.status, BrowserStatus::Live)
                || state.pending_failure_recovery
                    && state
                        .failure_kind
                        .is_some_and(BrowserFailureKind::allows_navigation_recovery))
        {
            return false;
        }
        state.handled_same_document_navigation_epoch = frame_epoch;
        let already_pending = state.pending_same_document_navigation;
        if already_pending {
            // The ingress event proves the targeted command committed, so a
            // later command error cannot roll pointer authority back. Motion
            // was already invalidated when that command reserved its barrier.
            Self::set_pointer_frame_locked(&mut state, None);
            self.set_pending_attach_frame_locked(&mut state, None);
            state.pending_screencast_capture = None;
        } else {
            // Page-initiated history/hash changes have no preceding cmux
            // command. Establish the same fail-closed pixel barrier here while
            // preserving only an accepted press's balancing release.
            self.invalidate_pointer_frame_locked(&mut state, false);
            state.pending_failure_recovery = false;
        }
        state.pending_frame_epoch =
            Some(state.pending_frame_epoch.map_or(frame_epoch, |pending| pending.max(frame_epoch)));
        state.pending_navigation_epoch = None;
        state.pending_authority_deadline = Some(Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
        state.pending_same_document_navigation = true;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        self.mark_state_dirty_locked(&mut state);
        drop(state);
        self.wake_lifecycle_worker();
        true
    }

    pub(super) fn accept_document_paint(
        &self,
        navigation_epoch: u64,
        frame_epoch: u64,
        frame: BrowserFrame,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch != Some(navigation_epoch)
            || state.handled_navigation_epoch != navigation_epoch
            || self.frame_epoch.latest_navigation() != navigation_epoch
            || frame_epoch < navigation_epoch
        {
            return false;
        }
        let precedes_pending_command = state
            .pending_navigation_epoch
            .is_some_and(|pending_epoch| navigation_epoch < pending_epoch);
        let recovers_failure = state.pending_failure_recovery && !precedes_pending_command;
        state.pending_document_epoch = None;
        if !precedes_pending_command {
            state.pending_navigation_epoch = None;
            state.pending_authority_deadline = None;
            state.pending_same_document_navigation = false;
            state.pending_failure_recovery = false;
            state.pending_frame_epoch = None;
            state.pending_frame = None;
            state.pending_navigation_rollback = None;
        }
        state.accepted_navigation_epoch = navigation_epoch;
        state.accepted_frame_epoch = frame_epoch;
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch == frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        state.failed_screencast_capture_epoch = None;
        if recovers_failure {
            self.clear_error_locked(&mut state);
        }
        self.store_frame_locked(&mut state, frame);
        self.mark_state_dirty_locked(&mut state);
        true
    }

    pub(super) fn accept_same_document_paint(&self, frame_epoch: u64, frame: BrowserFrame) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch.is_some()
            || !state.pending_same_document_navigation
            || state.handled_same_document_navigation_epoch
                != self.frame_epoch.latest_same_document_navigation()
            || state.accepted_navigation_epoch != self.frame_epoch.latest_navigation()
            || frame_epoch != self.frame_epoch.current()
        {
            return false;
        }
        let recovers_failure = state.pending_failure_recovery;
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        state.accepted_frame_epoch = frame_epoch;
        if state
            .pending_screencast_capture
            .is_some_and(|reservation| reservation.frame_epoch == frame_epoch)
        {
            state.pending_screencast_capture = None;
        }
        state.failed_screencast_capture_epoch = None;
        if recovers_failure {
            self.clear_error_locked(&mut state);
        }
        self.store_frame_locked(&mut state, frame);
        self.mark_state_dirty_locked(&mut state);
        true
    }

    pub(super) fn accept_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
        frame: BrowserFrame,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        let reservation =
            ScreencastCaptureReservation { id: reservation_id, frame_epoch, navigation_epoch };
        let reserved = state.pending_screencast_capture == Some(reservation);
        if !reserved
            || !matches!(state.status, BrowserStatus::Live)
            || state.pending_frame_epoch.is_some()
            || state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation
            || state.accepted_navigation_epoch != navigation_epoch
            || self.frame_epoch.latest_navigation() != navigation_epoch
            || self.frame_epoch.current() != frame_epoch
            || state.accepted_frame_epoch > frame_epoch
        {
            if reserved {
                state.pending_screencast_capture = None;
            }
            return false;
        }
        state.pending_frame = None;
        state.accepted_frame_epoch = frame_epoch;
        state.pending_screencast_capture = None;
        state.failed_screencast_capture_epoch = None;
        self.store_frame_locked(&mut state, frame);
        self.mark_state_dirty_locked(&mut state);
        true
    }

    pub(super) fn suppress_failed_screencast_capture(
        &self,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
        error: &anyhow::Error,
    ) {
        let mut state = self.state.lock().unwrap();
        let reserved = state.pending_screencast_capture
            == Some(ScreencastCaptureReservation {
                id: reservation_id,
                frame_epoch,
                navigation_epoch,
            });
        if reserved {
            state.pending_screencast_capture = None;
        }
        if reserved
            && matches!(state.status, BrowserStatus::Live)
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation
            && state.accepted_navigation_epoch == navigation_epoch
            && self.frame_epoch.latest_navigation() == navigation_epoch
            && self.frame_epoch.current() == frame_epoch
            && state.accepted_frame_epoch <= frame_epoch
        {
            state.failed_screencast_capture_epoch = Some(frame_epoch);
            self.mark_failed_locked(
                &mut state,
                BrowserFailureKind::UpdatedPageVerification,
                &format!(
                    "{BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX}{error}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
                ),
            );
            self.mark_state_dirty_locked(&mut state);
            self.dirty.store(true, Ordering::Release);
        }
    }

    pub(super) fn fail_document_authority(&self, navigation_epoch: u64, error: &anyhow::Error) {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch != Some(navigation_epoch) {
            return;
        }
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        self.mark_failed_locked(
            &mut state,
            BrowserFailureKind::NewPageVerification,
            &format!(
                "{BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX}{error}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
            ),
        );
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    pub(super) fn fail_same_document_authority(&self, error: &anyhow::Error) {
        let mut state = self.state.lock().unwrap();
        if state.pending_document_epoch.is_some() || !state.pending_same_document_navigation {
            return;
        }
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        self.mark_failed_locked(
            &mut state,
            BrowserFailureKind::UpdatedPageVerification,
            &format!(
                "{BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX}{error}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
            ),
        );
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }
}
