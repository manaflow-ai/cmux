//! BrowserSurface state accessors, provider session replacement, liveness,
//! status/error/title/url updates, and attached-session lookup.

use super::*;

impl BrowserSurface {
    pub fn latest_frame(&self) -> Option<Arc<BrowserFrame>> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            None
        } else {
            state.latest_frame.clone()
        }
    }

    pub fn latest_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            None
        } else {
            let pointer_frame_seq = self.exported_pointer_frame_seq_locked(&state);
            state
                .latest_frame
                .as_ref()
                .map(|frame| (frame.seq, frame.css_width, frame.css_height, pointer_frame_seq))
        }
    }

    /// Return the opaque authority token for guarded pointer input. The token
    /// identifies the latest admitted bitmap and rotates on every later bitmap.
    pub fn latest_frame_seq(&self) -> Option<u64> {
        let state = self.state.lock().unwrap();
        self.exported_pointer_frame_seq_locked(&state)
    }

    /// Return whether the local input owner has acknowledged this exact
    /// bitmap as its current presentation.
    pub fn accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        let state = self.state.lock().unwrap();
        self.presented_pointer_frame_is_current_locked(
            &state,
            BrowserPointerOwner::Local,
            frame_seq,
        )
    }

    /// Return whether a bitmap belongs to the current document and coordinate
    /// mapping. Route membership does not authorize pointer input.
    pub fn pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        let state = self.state.lock().unwrap();
        self.pointer_frame_is_in_current_route_locked(&state, frame_seq)
    }

    /// Record that the local renderer presented this exact bitmap. Returns
    /// whether the renderer's acknowledged token changed.
    pub fn acknowledge_pointer_frame(&self, frame_seq: u64) -> bool {
        let mut state = self.state.lock().unwrap();
        let changed =
            state.presented_pointer_frames.get(&BrowserPointerOwner::Local) != Some(&frame_seq);
        changed
            && self.acknowledge_pointer_frame_locked(
                &mut state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
    }

    pub(crate) fn acknowledge_pointer_frame_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        let mut state = self.state.lock().unwrap();
        self.acknowledge_pointer_frame_locked(&mut state, owner, frame_seq)
    }

    pub(crate) fn forget_pointer_owner(&self, owner: BrowserPointerOwner) {
        self.state.lock().unwrap().presented_pointer_frames.remove(&owner);
    }

    pub fn latest_frame_update(&self) -> Option<BrowserFrameUpdate> {
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Failed(_)) {
            return None;
        }
        state.latest_frame.as_ref().map(|frame| BrowserFrameUpdate {
            frame: frame.as_ref().clone(),
            status: state.status.clone(),
            pointer_frame_floor_seq: self.exported_pointer_frame_floor_seq_locked(&state),
            pointer_frame_seq: self.exported_pointer_frame_seq_locked(&state),
        })
    }

    pub fn has_latest_frame(&self) -> bool {
        let state = self.state.lock().unwrap();
        !matches!(state.status, BrowserStatus::Failed(_)) && state.latest_frame.is_some()
    }

    pub fn title(&self) -> String {
        self.state.lock().unwrap().title.clone()
    }

    pub fn url(&self) -> String {
        self.state.lock().unwrap().url.clone()
    }

    pub fn status(&self) -> BrowserStatus {
        self.state.lock().unwrap().status.clone()
    }

    pub fn frames_stalled(&self) -> bool {
        self.frames_stalled_at(Instant::now())
    }

    pub fn source(&self) -> Option<BrowserSource> {
        self.session.lock().unwrap().as_ref().map(|session| session.runtime.source())
    }

    pub(crate) fn prepare_provider_bootstrap_attempt(&self) -> bool {
        if self.is_dead() || self.session.lock().unwrap().is_some() {
            return false;
        }
        self.expect_attach();
        let mut state = self.state.lock().unwrap();
        state.status = BrowserStatus::Starting;
        state.failure_kind = None;
        state.source = None;
        state.title = state.url.clone();
        state.live_since = None;
        state.last_frame_at = None;
        state.stall_nudged = false;
        state.not_responding_reported = false;
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
        true
    }

    pub(super) fn prepare_provider_reconnect(
        &self,
        runtime: &Arc<BrowserRuntime>,
        session_id: &str,
    ) -> bool {
        self.prepare_provider_session_replacement(|session| {
            session.session_id == session_id && Arc::ptr_eq(&session.runtime, runtime)
        })
    }

    pub(crate) fn prepare_provider_lease_replacement(
        &self,
        lease: Option<&BrowserProviderTargetLease>,
    ) -> bool {
        self.prepare_provider_session_replacement(|session| {
            !lease.is_some_and(|lease| {
                session.target_id == lease.target_id
                    && session.runtime.matches_provider(&lease.endpoint, &lease.authentication)
            })
        })
    }

    pub(super) fn prepare_provider_session_replacement(
        &self,
        should_replace: impl FnOnce(&BrowserSession) -> bool,
    ) -> bool {
        if self.is_dead() {
            return false;
        }
        let Some(session) = ({
            let mut current = self.session.lock().unwrap();
            let matches = current.as_ref().is_some_and(|session| {
                session.runtime.source() == BrowserSource::Provider && should_replace(session)
            });
            matches.then(|| current.take()).flatten()
        }) else {
            return false;
        };
        session.runtime.close_surface_detached(&session.target_id, &session.session_id);

        let frame_epoch = self.frame_epoch.advance();
        let mut state = self.state.lock().unwrap();
        self.invalidate_pointer_frame_locked(&mut state, true);
        state.latest_frame = None;
        state.pending_frame = None;
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_navigation_rollback = None;
        state.pending_screencast_capture = None;
        state.failed_screencast_capture_epoch = None;
        state.accepted_frame_epoch = frame_epoch;
        state.page_viewport = None;
        state.status = BrowserStatus::Starting;
        state.failure_kind = None;
        state.source = None;
        state.title = state.url.clone();
        state.live_since = None;
        state.last_frame_at = None;
        state.stall_nudged = false;
        state.not_responding_reported = false;
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
        true
    }

    pub fn size(&self) -> (u16, u16) {
        self.state.lock().unwrap().size
    }

    pub(super) fn pixel_size(&self) -> (u32, u32) {
        self.state.lock().unwrap().capture_pixels
    }

    pub fn is_dead(&self) -> bool {
        self.dead.load(Ordering::Acquire)
    }

    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    #[cfg(test)]
    pub(crate) fn take_worker_done_for_test(&self) -> Receiver<()> {
        self.worker_done.lock().unwrap().take().expect("worker done receiver already taken")
    }

    pub fn kill(&self) {
        if self.dead.swap(true, Ordering::AcqRel) {
            return;
        }
        self.close_taps();
        if let Some(session) = self.session.lock().unwrap().take() {
            session.runtime.close_surface_detached(&session.target_id, &session.session_id);
        }
        self.close_command_sender();
    }
}

impl BrowserSurface {
    pub(super) fn close_taps(&self) {
        self.state.lock().unwrap().taps.clear();
    }

    pub(super) fn mark_live(&self, session: BrowserSession) -> anyhow::Result<()> {
        let mut current_session = self.session.lock().unwrap();
        if self.is_dead() {
            anyhow::bail!("browser surface was closed before it started");
        }
        *current_session = Some(session);
        let mut state = self.state.lock().unwrap();
        state.source = current_session.as_ref().map(|session| session.runtime.source());
        if !matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
            state.failure_kind = None;
        }
        let now = Instant::now();
        state.live_since = Some(now);
        state.last_frame_at = None;
        state.stall_nudged = false;
        self.mark_state_dirty_locked(&mut state);
        Ok(())
    }

    pub(super) fn mark_failed_locked(
        &self,
        state: &mut BrowserState,
        kind: BrowserFailureKind,
        message: &str,
    ) {
        state.status = BrowserStatus::Failed(message.to_string());
        state.failure_kind = Some(kind);
        // Failure revokes admission for new input, but does not always prove
        // that the document or its coordinate mapping changed. Preserve an
        // accepted press long enough to deliver its balancing release.
        self.invalidate_pointer_frame_locked(state, false);
        state.pending_frame_epoch = None;
        state.pending_navigation_epoch = None;
        state.pending_document_epoch = None;
        state.pending_authority_deadline = None;
        state.pending_same_document_navigation = false;
        state.pending_failure_recovery = false;
        state.pending_frame = None;
        state.pending_navigation_rollback = None;
        state.pending_screencast_capture = None;
        state.title = format!("browser failed: {message}");
        state.stall_nudged = false;
    }

    pub(super) fn mark_pending_authority_failed_locked(
        &self,
        state: &mut BrowserState,
        kind: BrowserFailureKind,
        message: &str,
    ) {
        state.status = BrowserStatus::Failed(message.to_string());
        state.failure_kind = Some(kind);
        // Keep the current navigation generation pending so a late
        // loader-verified paint can recover it without a manual reload.
        self.invalidate_pointer_frame_locked(state, false);
        state.pending_authority_deadline = None;
        state.pending_failure_recovery = true;
        state.title = format!("browser failed: {message}");
        state.stall_nudged = false;
    }

    pub fn mark_failed(&self, message: String) {
        let mut state = self.state.lock().unwrap();
        self.mark_failed_locked(&mut state, BrowserFailureKind::Other, &message);
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    pub(super) fn mark_not_responding(&self) {
        let mut state = self.state.lock().unwrap();
        self.mark_failed_locked(
            &mut state,
            BrowserFailureKind::NotResponding,
            BROWSER_NOT_RESPONDING_MESSAGE,
        );
        self.mark_state_dirty_locked(&mut state);
        self.dirty.store(true, Ordering::Release);
    }

    pub(super) fn clear_error_locked(&self, state: &mut BrowserState) -> bool {
        if matches!(state.status, BrowserStatus::Failed(_)) {
            state.status = BrowserStatus::Live;
            state.failure_kind = None;
            // A verified paint from an explicit navigation or reload is the
            // recovery action for an exhausted resize. Let the desired
            // geometry enter a new bounded retry cycle only after that proof.
            state.reconfigure_failure = None;
            state.title = state.url.clone();
            return true;
        }
        false
    }

    #[cfg(test)]
    pub(super) fn clear_error(&self) {
        let mut state = self.state.lock().unwrap();
        if self.clear_error_locked(&mut state) {
            self.mark_state_dirty_locked(&mut state);
        }
    }

    /// Apply the location a frontend-rendered browser reports. Such a
    /// browser has no CDP target, so this is its only source of URL and
    /// title. Returns whether either changed.
    pub(crate) fn set_frontend_location(&self, url: Option<String>, title: Option<String>) -> bool {
        let mut changed = false;
        if let Some(url) = url {
            changed |= self.set_url(url);
        }
        if let Some(title) = title {
            changed |= self.set_title(title);
        }
        changed
    }

    pub(super) fn set_title(&self, title: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.title == title {
            return false;
        }
        state.title = title;
        self.mark_state_dirty_locked(&mut state);
        true
    }

    pub(super) fn set_url(&self, url: String) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.url != url {
            state.url = url;
            self.mark_state_dirty_locked(&mut state);
            return true;
        }
        false
    }

    pub(super) fn set_url_title(&self, url: String, title: String) {
        let mut state = self.state.lock().unwrap();
        state.url = url;
        state.title = title;
        state.stall_nudged = false;
        self.mark_state_dirty_locked(&mut state);
    }

    pub(super) fn mark_state_dirty_locked(&self, state: &mut BrowserState) {
        let pointer_frame_floor_seq = self.exported_pointer_frame_floor_seq_locked(state);
        let pointer_frame_seq = self.exported_pointer_frame_seq_locked(state);
        let snapshot = browser_attach_state_locked(
            state,
            Instant::now(),
            false,
            false,
            pointer_frame_floor_seq,
            pointer_frame_seq,
        );
        state.taps.retain(|tap| {
            let mut slot = tap.slot.lock().unwrap();
            if let Some(frame) = slot.frame.as_mut() {
                frame.status = snapshot.status.clone();
                frame.pointer_frame_floor_seq = snapshot.pointer_frame_floor_seq;
                frame.pointer_frame_seq = snapshot.pointer_frame_seq;
            }
            slot.state = Some(snapshot.clone());
            drop(slot);
            match tap.notify.try_send(()) {
                Ok(()) | Err(TrySendError::Full(())) => true,
                Err(TrySendError::Disconnected(())) => false,
            }
        });
    }

    pub(super) fn attached_session(&self) -> anyhow::Result<Option<BrowserSession>> {
        if self.is_dead() {
            anyhow::bail!("browser surface is closed");
        }
        Ok(self.session.lock().unwrap().clone())
    }

    pub(super) fn require_attached_session(&self) -> anyhow::Result<BrowserSession> {
        self.attached_session()?.ok_or_else(|| anyhow::anyhow!("browser is still starting"))
    }

    pub(super) fn require_live_session(&self) -> anyhow::Result<BrowserSession> {
        let session = self.require_attached_session()?;
        match self.status() {
            BrowserStatus::Live => Ok(session),
            BrowserStatus::Starting => anyhow::bail!("browser is still starting"),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
        }
    }

    pub(super) fn require_navigation_session(&self) -> anyhow::Result<BrowserSession> {
        let session = self.require_attached_session()?;
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Live)
            || state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery)
        {
            return Ok(session);
        }
        match &state.status {
            BrowserStatus::Starting => anyhow::bail!("browser is still starting"),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
            BrowserStatus::Live => unreachable!(),
        }
    }

    pub(super) fn require_verification_session(&self) -> anyhow::Result<BrowserSession> {
        let session = self.require_attached_session()?;
        let state = self.state.lock().unwrap();
        if matches!(state.status, BrowserStatus::Live)
            || state.pending_failure_recovery
                && state.failure_kind.is_some_and(BrowserFailureKind::allows_navigation_recovery)
        {
            return Ok(session);
        }
        match &state.status {
            BrowserStatus::Starting => anyhow::bail!("browser is still starting"),
            BrowserStatus::Failed(error) => anyhow::bail!("browser failed: {error}"),
            BrowserStatus::Live => unreachable!(),
        }
    }
}
