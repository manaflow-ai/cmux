//! BrowserSurface frame transitions: navigation and reconfigure barriers,
//! navigation epoch observation, authority expiry, and rollback after a
//! failed command.

use super::*;

impl BrowserSurface {
    #[cfg(test)]
    pub(super) fn begin_navigation_frame_transition(
        &self,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        self.begin_navigation_frame_transition_to(false)
    }

    #[cfg(test)]
    pub(super) fn begin_targeted_navigation_frame_transition(
        &self,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        self.begin_navigation_frame_transition_to(true)
    }

    pub(super) fn begin_navigation_frame_transition_to(
        &self,
        may_be_same_document: bool,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        let mut state = self.state.lock().unwrap();
        if state.pending_frame_epoch.is_some()
            || state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
        {
            anyhow::bail!("browser navigation is still committing");
        }
        Ok(self.reserve_navigation_frame_transition_locked(&mut state, may_be_same_document))
    }

    pub(super) fn reserve_navigation_frame_transition_locked(
        &self,
        state: &mut BrowserState,
        may_be_same_document: bool,
    ) -> PointerFrameInvalidation {
        // A targeted navigation can resolve within the current document. Keep
        // an accepted press alive until ingress proves a document replacement.
        let invalidation = self.invalidate_pointer_frame_locked(state, !may_be_same_document);
        self.install_navigation_frame_transition_locked(state, may_be_same_document, invalidation)
    }

    pub(super) fn install_navigation_frame_transition_locked(
        &self,
        state: &mut BrowserState,
        may_be_same_document: bool,
        mut invalidation: PointerFrameInvalidation,
    ) -> PointerFrameInvalidation {
        let pending_frame_epoch = self.frame_epoch.current().wrapping_add(1);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_navigation_epoch = Some(pending_frame_epoch);
        state.pending_authority_deadline = Some(Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
        state.pending_same_document_navigation = may_be_same_document;
        state.pending_failure_recovery =
            state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery);
        state.pending_frame = None;
        invalidation.expected_frame_epoch = Some(pending_frame_epoch);
        state.pending_navigation_rollback = Some(invalidation.clone());
        self.mark_state_dirty_locked(state);
        invalidation
    }

    pub(super) fn navigation_transition_pending(&self) -> bool {
        let state = self.state.lock().unwrap();
        state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation
    }

    pub(super) fn begin_superseding_navigation_frame_transition(
        &self,
        may_be_same_document: bool,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        let mut state = self.state.lock().unwrap();
        let navigation_pending = state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation;
        if !navigation_pending && state.pending_frame_epoch.is_some() {
            anyhow::bail!("browser frame reconfiguration is still committing");
        }
        let current_frame_epoch = self.frame_epoch.current();
        let preserved_rollback = may_be_same_document
            .then(|| {
                state.pending_navigation_rollback.as_ref().filter(|rollback| {
                    state.pending_document_epoch.is_none()
                        && rollback.revision == state.pointer_frame_revision
                        && rollback
                            .expected_frame_epoch
                            .is_some_and(|expected_epoch| current_frame_epoch < expected_epoch)
                        && state.latest_frame.as_ref().map(|frame| frame.seq)
                            == rollback.previous_latest_frame_seq
                })
            })
            .flatten()
            .cloned();
        let verified_committed_frame_seq = (state.pending_document_epoch.is_none()
            && matches!(state.status, BrowserStatus::Live)
            && state.accepted_navigation_epoch == self.frame_epoch.latest_navigation()
            && state.accepted_frame_epoch == current_frame_epoch)
            .then(|| state.latest_frame.as_ref().map(|frame| frame.seq))
            .flatten();
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        if preserved_rollback.is_none()
            && let Some(frame_seq) = verified_committed_frame_seq
        {
            // stopLoading settled the command that kept this verified document
            // behind its barrier. Reinstall its pointer token before the
            // replacement invalidates it, so a rejected replacement can roll
            // back to the pixels that are actually displayed.
            Self::set_pointer_frame_locked(&mut state, Some(frame_seq));
            let retained_frame = state.latest_frame.clone();
            self.set_pending_attach_frame_locked(&mut state, retained_frame);
        }
        Ok(match preserved_rollback {
            Some(rollback) => {
                // Page.stopLoading is ordered after old lifecycle events on
                // this CDP session. An ingress epoch still below the old
                // reservation proves that navigation never committed, so the
                // replacement may retain the original rollback authority.
                self.install_navigation_frame_transition_locked(
                    &mut state,
                    may_be_same_document,
                    rollback,
                )
            }
            None => {
                self.reserve_navigation_frame_transition_locked(&mut state, may_be_same_document)
            }
        })
    }

    #[cfg(test)]
    pub(super) fn begin_frame_transition(&self, revoke_capture: bool) -> PointerFrameInvalidation {
        let mut state = self.state.lock().unwrap();
        let pending_frame_epoch =
            state.pending_frame_epoch.unwrap_or_else(|| self.frame_epoch.current()).wrapping_add(1);
        let mut invalidation = self.invalidate_pointer_frame_locked(&mut state, revoke_capture);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_frame = None;
        invalidation.expected_frame_epoch = Some(pending_frame_epoch);
        self.mark_state_dirty_locked(&mut state);
        invalidation
    }

    pub(super) fn begin_reconfigure_frame_transition(&self) -> PointerFrameInvalidation {
        let mut state = self.state.lock().unwrap();
        // A capture restart advances the shared ingress epoch exactly once on
        // success. A failed attempt advances it zero times, so every retry,
        // including one for replacement geometry, waits on current + 1.
        let pending_frame_epoch = self.frame_epoch.current().wrapping_add(1);
        let mut invalidation = self.invalidate_pointer_frame_locked(&mut state, false);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_frame = None;
        invalidation.expected_frame_epoch = Some(pending_frame_epoch);
        self.mark_state_dirty_locked(&mut state);
        invalidation
    }

    pub(super) fn abandon_frame_transition(&self) {
        let mut state = self.state.lock().unwrap();
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
    }

    pub(super) fn observe_navigation_frame_epoch(&self, frame_epoch: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        if frame_epoch <= state.handled_navigation_epoch {
            return false;
        }
        let latest_same_document_navigation = self.frame_epoch.latest_same_document_navigation();
        if latest_same_document_navigation < frame_epoch {
            // A later cross-document navigation supersedes any same-document
            // event that entered CDP first, even if the surface thread has not
            // consumed that older event yet.
            state.handled_same_document_navigation_epoch = latest_same_document_navigation;
        }
        let precedes_pending_command =
            state.pending_navigation_epoch.is_some_and(|pending_epoch| frame_epoch < pending_epoch);
        if precedes_pending_command && frame_epoch != self.frame_epoch.latest_navigation() {
            return false;
        }
        if precedes_pending_command {
            // CDP ingress already committed this document before the newer
            // command reserved its epoch. Retain that command's rollback and
            // barrier, but expose the committed document for loader-verified
            // paint. If the newer command fails, its rollback reconciles to
            // this document instead of restoring the older page.
            state.handled_navigation_epoch = frame_epoch;
            state.pending_document_epoch = Some(frame_epoch);
            state
                .pending_authority_deadline
                .get_or_insert_with(|| Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
            self.mark_state_dirty_locked(&mut state);
            drop(state);
            self.wake_lifecycle_worker();
            return true;
        }
        if state.pending_navigation_epoch.is_none() {
            state.pending_failure_recovery = false;
        }
        let capture_revoked_at_command =
            state.pending_navigation_epoch.is_some() && !state.pending_same_document_navigation;
        state.handled_navigation_epoch = frame_epoch;
        if state.pending_navigation_epoch.is_some_and(|pending_epoch| frame_epoch >= pending_epoch)
        {
            state.pending_navigation_epoch = None;
        }
        state.pending_same_document_navigation = false;
        state.pending_navigation_rollback = None;
        self.invalidate_pointer_frame_locked(&mut state, !capture_revoked_at_command);
        state.pending_document_epoch = Some(frame_epoch);
        state.pending_authority_deadline = Some(Instant::now() + NAVIGATION_AUTHORITY_TIMEOUT);
        let pending_frame_epoch = state
            .pending_frame_epoch
            .unwrap_or(frame_epoch)
            .max(frame_epoch)
            .max(state.accepted_frame_epoch);
        state.pending_frame_epoch = Some(pending_frame_epoch);
        state.pending_frame = None;
        self.mark_state_dirty_locked(&mut state);
        drop(state);
        self.wake_lifecycle_worker();
        true
    }

    pub(super) fn needs_document_paint(&self, navigation_epoch: u64) -> bool {
        self.state.lock().unwrap().pending_document_epoch == Some(navigation_epoch)
    }

    pub(super) fn pending_authority_deadline(&self) -> Option<Instant> {
        self.state.lock().unwrap().pending_authority_deadline
    }

    pub(super) fn expire_navigation_authority(&self, now: Instant) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        if state.pending_authority_deadline.is_none_or(|deadline| deadline > now) {
            return None;
        }
        let has_pending_authority = state.pending_navigation_epoch.is_some()
            || state.pending_document_epoch.is_some()
            || state.pending_same_document_navigation;
        if !has_pending_authority {
            state.pending_authority_deadline = None;
            return None;
        }
        let same_document =
            state.pending_document_epoch.is_none() && state.pending_same_document_navigation;
        let detail = "navigation did not produce verifiable pixels before its safety deadline";
        let (kind, message) = if same_document {
            (
                BrowserFailureKind::UpdatedPageVerification,
                format!(
                    "{BROWSER_UPDATED_PAGE_VERIFICATION_FAILED_PREFIX}{detail}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
                ),
            )
        } else {
            (
                BrowserFailureKind::NewPageVerification,
                format!(
                    "{BROWSER_NEW_PAGE_VERIFICATION_FAILED_PREFIX}{detail}{BROWSER_VERIFICATION_FAILED_SUFFIX}"
                ),
            )
        };
        self.mark_pending_authority_failed_locked(&mut state, kind, &message);
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
        Some(message)
    }
}

impl BrowserSurface {
    pub(super) fn restore_pointer_frame_after_failed_command(
        &self,
        invalidation: PointerFrameInvalidation,
    ) {
        let mut state = self.state.lock().unwrap();
        let owns_navigation_rollback =
            state.pending_navigation_rollback.as_ref().is_some_and(|rollback| {
                rollback.revision == invalidation.revision
                    && rollback.expected_frame_epoch == invalidation.expected_frame_epoch
            });
        let committed_navigation_epoch = self.frame_epoch.latest_navigation();
        let committed_navigation_precedes_failed_command = owns_navigation_rollback
            && invalidation.expected_frame_epoch.is_some_and(|expected_epoch| {
                committed_navigation_epoch > invalidation.previous_accepted_navigation_epoch
                    && committed_navigation_epoch < expected_epoch
                    && state.handled_navigation_epoch >= committed_navigation_epoch
            });
        if committed_navigation_precedes_failed_command {
            state.pending_navigation_epoch = invalidation.previous_pending_navigation_epoch;
            if invalidation.previous_pending_navigation_epoch.is_some() {
                state.pending_authority_deadline = invalidation.previous_pending_authority_deadline;
            }
            state.pending_same_document_navigation =
                invalidation.previous_pending_same_document_navigation;
            state.pending_failure_recovery = false;
            state.pending_navigation_rollback = None;
            state.pointer_capture_generation = invalidation.previous_capture_generation;
            state.pointer_motion_generation = invalidation.previous_motion_generation;
            state.pending_frame = None;
            if state.accepted_navigation_epoch == committed_navigation_epoch {
                state.pointer_capture_generation =
                    invalidation.previous_capture_generation.wrapping_add(1);
                state.pointer_motion_generation =
                    invalidation.previous_motion_generation.wrapping_add(1);
                state.pending_frame_epoch = invalidation.previous_pending_frame_epoch;
                let pointer_frame_seq = matches!(state.status, BrowserStatus::Live)
                    .then(|| state.latest_frame.as_ref().map(|frame| frame.seq))
                    .flatten();
                Self::set_pointer_frame_locked(&mut state, pointer_frame_seq);
                let retained_frame = state.latest_frame.clone();
                self.set_pending_attach_frame_locked(&mut state, retained_frame);
            } else {
                state.pointer_motion_generation =
                    invalidation.previous_motion_generation.wrapping_add(1);
                state.pending_frame_epoch = state.pending_document_epoch.map(|navigation_epoch| {
                    self.frame_epoch.current().max(navigation_epoch).max(state.accepted_frame_epoch)
                });
                Self::set_pointer_frame_locked(&mut state, None);
                self.set_pending_attach_frame_locked(&mut state, None);
            }
            self.mark_state_dirty_locked(&mut state);
            return;
        }
        let restoring_failed_recovery = state.pending_failure_recovery
            && state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery);
        if state.pointer_frame_revision != invalidation.revision
            || !(matches!(state.status, BrowserStatus::Live) || restoring_failed_recovery)
            || state.latest_frame.as_ref().map(|frame| frame.seq)
                != invalidation.previous_latest_frame_seq
        {
            if owns_navigation_rollback {
                state.pending_navigation_rollback = None;
                state.pending_failure_recovery = false;
            }
            return;
        }
        if owns_navigation_rollback {
            state.pending_navigation_rollback = None;
        }
        state.pointer_capture_generation = invalidation.previous_capture_generation;
        state.pointer_motion_generation = invalidation.previous_motion_generation;
        state.pending_frame_epoch = invalidation.previous_pending_frame_epoch;
        state.pending_navigation_epoch = invalidation.previous_pending_navigation_epoch;
        state.pending_authority_deadline = invalidation.previous_pending_authority_deadline;
        state.pending_same_document_navigation =
            invalidation.previous_pending_same_document_navigation;
        state.pending_failure_recovery = false;
        state.pending_frame = invalidation.previous_pending_frame;
        Self::set_pointer_frame_range_locked(
            &mut state,
            invalidation.previous_floor,
            invalidation.previous,
        );
        state.presented_pointer_frames = invalidation.previous_presented_pointer_frames;
        let retained_frame = state.latest_frame.clone();
        self.set_pending_attach_frame_locked(&mut state, retained_frame);
        self.mark_state_dirty_locked(&mut state);
    }

    #[cfg(test)]
    pub(super) fn restore_pointer_frame_on_command_error<T>(
        &self,
        invalidation: PointerFrameInvalidation,
        result: anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        if let Err(error) = &result
            && !is_cdp_timeout_error(&error.to_string())
        {
            self.restore_pointer_frame_after_failed_command(invalidation);
        }
        result
    }

    pub(super) fn settle_navigation_transition(&self, invalidation: PointerFrameInvalidation) {
        let Some(expected_frame_epoch) = invalidation.expected_frame_epoch else {
            return;
        };
        // Command acknowledgment does not mean the document committed. The
        // ingress navigation event owns this barrier and may arrive after the
        // short synchronous wait on a slow page.
        let committed =
            self.frame_epoch.wait_until_at_least(expected_frame_epoch, NAVIGATION_COMMIT_WAIT);
        #[cfg(test)]
        if !committed {
            self.navigation_commit_wait_timeouts.fetch_add(1, Ordering::AcqRel);
        }
        let _ = committed;
    }

    pub(super) fn finish_navigation_command<T>(
        &self,
        invalidation: PointerFrameInvalidation,
        result: anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        match &result {
            Ok(_) => self.settle_navigation_transition(invalidation),
            // The command may already have reached Chrome. Only a later
            // main-frame event can safely settle this ambiguous transition.
            Err(error) if is_cdp_timeout_error(&error.to_string()) => {}
            Err(_) => self.restore_pointer_frame_after_failed_command(invalidation),
        }
        result
    }
}
