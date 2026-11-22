//! BrowserSurface blocking paint verification: document, same-document and
//! screencast capture authorization, screencast restart, loaderless navigation.

use super::*;

impl BrowserSurface {
    pub(super) fn authorize_document_paint_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        navigation_epoch: u64,
    ) -> BrowserWorkerResult {
        self.authorize_document_paint_with_attempt_budget_blocking(
            session_id,
            frame_id,
            loader_id,
            navigation_epoch,
            AUTHORITY_CAPTURE_ATTEMPT_BUDGET,
        )
    }

    pub(super) fn authorize_document_paint_with_attempt_budget_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        navigation_epoch: u64,
        attempt_budget: Duration,
    ) -> BrowserWorkerResult {
        if !self.needs_document_paint(navigation_epoch)
            || self.frame_epoch.latest_navigation() != navigation_epoch
        {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = self.require_verification_session()?;
        if session.session_id != session_id {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let mut last_error = None;
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            if !self.needs_document_paint(navigation_epoch)
                || self.frame_epoch.latest_navigation() != navigation_epoch
            {
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let deadline = Instant::now() + attempt_budget;
            match self.capture_main_frame_after_restart(&session, frame_id, loader_id, deadline) {
                Ok((frame_epoch, captured)) => {
                    let accepted = self.accept_document_paint(
                        navigation_epoch,
                        frame_epoch,
                        browser_frame_from_capture(session_id, captured),
                    );
                    if accepted {
                        self.dirty.store(true, Ordering::Release);
                    }
                    return Ok(BrowserWorkerSuccess::BrowserResponded);
                }
                Err(_) if self.frame_epoch.latest_navigation() != navigation_epoch => {
                    return Ok(BrowserWorkerSuccess::LocallySettled);
                }
                Err(error) => {
                    let timed_out = is_cdp_timeout_error(&error.to_string());
                    last_error = Some(error);
                    if timed_out {
                        break;
                    }
                }
            }
        }
        let error = last_error.expect("authority capture attempts must record an error");
        self.fail_document_authority(navigation_epoch, &error);
        Err(error)
    }

    pub(super) fn authorize_same_document_paint_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
    ) -> BrowserWorkerResult {
        if !self.needs_same_document_paint() {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = self.require_verification_session()?;
        if session.session_id != session_id {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let mut last_error = None;
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            if !self.needs_same_document_paint() {
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let deadline = Instant::now() + AUTHORITY_CAPTURE_ATTEMPT_BUDGET;
            match self.capture_main_frame_after_restart(&session, frame_id, loader_id, deadline) {
                Ok((frame_epoch, captured)) => {
                    let accepted = self.accept_same_document_paint(
                        frame_epoch,
                        browser_frame_from_capture(session_id, captured),
                    );
                    if accepted {
                        self.dirty.store(true, Ordering::Release);
                    }
                    return Ok(BrowserWorkerSuccess::BrowserResponded);
                }
                Err(error) => {
                    let timed_out = is_cdp_timeout_error(&error.to_string());
                    last_error = Some(error);
                    if timed_out {
                        break;
                    }
                }
            }
        }
        let error = last_error.expect("authority capture attempts must record an error");
        self.fail_same_document_authority(&error);
        Err(error)
    }

    pub(super) fn authorize_screencast_capture_blocking(
        &self,
        session_id: &str,
        frame_id: &str,
        loader_id: &str,
        reservation_id: u64,
        frame_epoch: u64,
        navigation_epoch: u64,
    ) -> BrowserWorkerResult {
        if !self.may_need_screencast_capture(reservation_id, frame_epoch, navigation_epoch) {
            self.cancel_screencast_capture(reservation_id);
            if let Some(session) = self.session.lock().unwrap().clone() {
                let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                    session_id,
                    reservation_id,
                    frame_epoch,
                    navigation_epoch,
                );
            }
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = match self.require_live_session() {
            Ok(session) => session,
            Err(error) => {
                self.cancel_screencast_capture(reservation_id);
                if let Some(session) = self.session.lock().unwrap().clone() {
                    let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                        session_id,
                        reservation_id,
                        frame_epoch,
                        navigation_epoch,
                    );
                }
                return Err(error);
            }
        };
        if session.session_id != session_id {
            self.cancel_screencast_capture(reservation_id);
            let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                session_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            );
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let mut last_error = None;
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            if !self.may_need_screencast_capture(reservation_id, frame_epoch, navigation_epoch) {
                self.cancel_screencast_capture(reservation_id);
                let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                    session_id,
                    reservation_id,
                    frame_epoch,
                    navigation_epoch,
                );
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            let deadline = Instant::now() + AUTHORITY_CAPTURE_ATTEMPT_BUDGET;
            match session
                .runtime
                .client
                .capture_main_frame_for_loader_before(session_id, frame_id, loader_id, deadline)
            {
                Ok(captured) => {
                    let accepted = self.accept_screencast_capture(
                        reservation_id,
                        frame_epoch,
                        navigation_epoch,
                        browser_frame_from_capture(session_id, captured),
                    );
                    if accepted {
                        self.dirty.store(true, Ordering::Release);
                        let _ = session.runtime.client.settle_timestampless_screencast_capture(
                            session_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        );
                    } else {
                        let _ = session.runtime.client.cancel_timestampless_screencast_capture(
                            session_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        );
                    }
                    return Ok(BrowserWorkerSuccess::BrowserResponded);
                }
                Err(error) => {
                    let timed_out = is_cdp_timeout_error(&error.to_string());
                    last_error = Some(error);
                    if timed_out {
                        break;
                    }
                }
            }
        }
        let error = last_error.expect("authority capture attempts must record an error");
        let suppressed = session.runtime.client.suppress_timestampless_screencast_capture(
            session_id,
            reservation_id,
            frame_epoch,
            navigation_epoch,
        );
        if suppressed {
            self.suppress_failed_screencast_capture(
                reservation_id,
                frame_epoch,
                navigation_epoch,
                &error,
            );
        } else {
            self.cancel_screencast_capture(reservation_id);
        }
        Err(error)
    }

    pub(super) fn capture_main_frame_after_restart(
        &self,
        session: &BrowserSession,
        frame_id: &str,
        loader_id: &str,
        deadline: Instant,
    ) -> anyhow::Result<(u64, CapturedFrame)> {
        let frame_epoch = self.restart_screencast_for_authority(session, deadline)?;
        let captured = session.runtime.client.capture_main_frame_for_loader_before(
            &session.session_id,
            frame_id,
            loader_id,
            deadline,
        )?;
        Ok((frame_epoch, captured))
    }

    pub(super) fn restart_screencast_for_authority(
        &self,
        session: &BrowserSession,
        deadline: Instant,
    ) -> anyhow::Result<u64> {
        let (width, height) = self.pixel_size();
        session.runtime.client.stop_screencast_before(&session.session_id, deadline)?;
        session.runtime.client.start_screencast_with_frame_barrier_before(
            &session.session_id,
            width,
            height,
            deadline,
        )
    }

    pub(super) fn begin_latest_navigation_frame_transition(
        &self,
        session: &BrowserSession,
        may_be_same_document: bool,
    ) -> anyhow::Result<PointerFrameInvalidation> {
        match self.begin_navigation_frame_transition_to(may_be_same_document) {
            Ok(invalidation) => Ok(invalidation),
            Err(_) if self.navigation_transition_pending() => {
                // Page.stopLoading is ordered on the same CDP session. By the
                // time it responds, ingress has assigned epochs to every old
                // navigation event Chrome emitted, so a fresh current + 1
                // reservation rejects any old event still queued to the
                // surface while allowing the latest-wins URL to proceed.
                session.runtime.client.stop_loading(&session.session_id)?;
                self.begin_superseding_navigation_frame_transition(may_be_same_document)
            }
            Err(first_error) => {
                // The previous transition may have settled between the first
                // reservation attempt and the state check.
                self.begin_navigation_frame_transition_to(may_be_same_document)
                    .map_err(|_| first_error)
            }
        }
    }

    pub(super) fn reconcile_loaderless_navigation(
        &self,
        session: &BrowserSession,
    ) -> anyhow::Result<()> {
        if !self.needs_same_document_paint() {
            return Ok(());
        }
        // CDP omits loaderId for same-document Page.navigate results. If the
        // corresponding event was delayed or absent, snapshot the subscribed
        // session and authorize freshly captured pixels for that loader.
        for _ in 0..AUTHORITY_CAPTURE_ATTEMPTS {
            let snapshot =
                match session.runtime.client.snapshot_main_frame_with_retry(&session.session_id) {
                    Ok(snapshot) => snapshot,
                    Err(error) => {
                        self.fail_same_document_authority(&error);
                        return Err(error);
                    }
                };
            if self.reconcile_same_document_snapshot(snapshot.same_document_navigation_epoch) {
                return self
                    .authorize_same_document_paint_blocking(
                        &session.session_id,
                        &snapshot.frame_id,
                        &snapshot.loader_id,
                    )
                    .map(|_| ());
            }
            if !self.needs_same_document_paint() {
                return Ok(());
            }
        }
        let error =
            anyhow::anyhow!("main-frame snapshot was invalidated by repeated page navigation");
        self.fail_same_document_authority(&error);
        Err(error)
    }
}
