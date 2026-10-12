//! BrowserSurface input dispatch: mouse, wheel, key and text events, with
//! frame admission, confirmed variants, and abandoned press release.

use super::*;

impl BrowserSurface {
    pub fn mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        self.mouse_event_for_frame(event_type, x, y, button, click_count, None)
    }

    /// Queue a mouse event admitted by the opaque `frame_seq` authority token.
    /// Uncaptured events with stale authority are ignored. An accepted press
    /// retains motion across ordinary repaints while its document and geometry
    /// remain valid, plus ownership of its balancing release after either is
    /// invalidated.
    pub fn mouse_event_for_frame(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        self.mouse_event_for_frame_from(BrowserMouseDispatch {
            input_owner: BrowserPointerOwner::Local,
            event_type,
            x,
            y,
            button,
            click_count,
            frame_seq,
        })
    }

    /// Queue guarded mouse input under one capture owner. Local in-process
    /// input has a reserved stable owner. Legacy remote sockets use a bounded
    /// compatibility lease; negotiated sockets use their connection registry id.
    pub(crate) fn mouse_event_for_frame_from(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
    ) -> anyhow::Result<()> {
        let pointer_admission = self.admit_pointer_frame(dispatch.input_owner, dispatch.frame_seq);
        let command = BrowserCommand::Mouse {
            input_owner: dispatch.input_owner,
            event_type: dispatch.event_type.to_string(),
            x: dispatch.x,
            y: dispatch.y,
            button: dispatch.button.map(ToOwned::to_owned),
            click_count: dispatch.click_count,
            frame_seq: dispatch.frame_seq,
            pointer_admission,
        };
        if dispatch.event_type == "mouseReleased" {
            self.enqueue_pointer_release(command)
        } else {
            self.enqueue_bounded(command)
        }
    }

    pub(super) fn mouse_event_blocking_with_admission(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
        pointer_admission: Option<BrowserPointerAdmission>,
        active_pointer_presses: &mut HashMap<String, ActivePointerPress>,
    ) -> BrowserWorkerResult {
        let button = dispatch.button.unwrap_or("none");
        if let Some(press) = active_pointer_presses.get(button).copied()
            && press.input_owner != dispatch.input_owner
        {
            if self.pointer_capture_is_current(press.capture_generation) {
                return Ok(BrowserWorkerSuccess::LocallySettled);
            }
            active_pointer_presses.remove(button);
        }
        let session = if dispatch.event_type == "mouseReleased"
            && active_pointer_presses.contains_key(button)
        {
            self.require_attached_session()?
        } else {
            self.require_live_session()?
        };
        if dispatch.event_type == "mousePressed" {
            self.maybe_nudge_stalled_external(&session);
        }
        let mut captured_press = None;
        let mut captured_release = false;
        let point = match (dispatch.event_type, dispatch.frame_seq) {
            ("mousePressed", Some(frame_seq)) => {
                let Some((point, capture_generation, motion_generation, ingress_motion_generation)) =
                    self.capture_guarded_input_point_from(
                        dispatch.input_owner,
                        frame_seq,
                        pointer_admission,
                        dispatch.x,
                        dispatch.y,
                    )
                else {
                    return Ok(BrowserWorkerSuccess::LocallySettled);
                };
                captured_press = Some(ActivePointerPress::new(
                    dispatch.input_owner,
                    capture_generation,
                    motion_generation,
                    ingress_motion_generation,
                    frame_seq,
                    point,
                    dispatch.click_count,
                ));
                Some(point)
            }
            ("mouseReleased", Some(dispatch_frame_seq)) => {
                let Some(press) = active_pointer_presses.get(button).copied() else {
                    return Ok(BrowserWorkerSuccess::LocallySettled);
                };
                let point = match self.captured_pointer_route(
                    press.capture_generation,
                    press.motion_generation,
                    press.ingress_motion_generation,
                    press.frame_seq,
                    dispatch_frame_seq,
                    (dispatch.x, dispatch.y),
                ) {
                    CapturedPointerRoute::Current(point) => Some(point),
                    CapturedPointerRoute::MotionInvalidated => {
                        Some((press.last_target_x, press.last_target_y))
                    }
                    CapturedPointerRoute::InvalidCapture => {
                        active_pointer_presses.remove(button);
                        None
                    }
                };
                if point.is_some() {
                    captured_release = true;
                }
                point
            }
            ("mouseMoved", Some(dispatch_frame_seq)) => {
                if let Some(press) = active_pointer_presses.get(button).copied() {
                    match self.captured_pointer_route(
                        press.capture_generation,
                        press.motion_generation,
                        press.ingress_motion_generation,
                        press.frame_seq,
                        dispatch_frame_seq,
                        (dispatch.x, dispatch.y),
                    ) {
                        CapturedPointerRoute::Current(point) => {
                            if press.input_owner == dispatch.input_owner
                                && let Some(press) = active_pointer_presses.get_mut(button)
                            {
                                press.refresh_pointer_position(point.0, point.1);
                            }
                            Some(point)
                        }
                        CapturedPointerRoute::MotionInvalidated => None,
                        CapturedPointerRoute::InvalidCapture => {
                            active_pointer_presses.remove(button);
                            None
                        }
                    }
                } else {
                    self.scale_guarded_input_point_from(
                        dispatch.input_owner,
                        dispatch.frame_seq,
                        pointer_admission,
                        dispatch.x,
                        dispatch.y,
                    )
                }
            }
            ("mouseReleased", None) => self.scale_guarded_input_point_from(
                dispatch.input_owner,
                None,
                pointer_admission,
                dispatch.x,
                dispatch.y,
            ),
            _ => self.scale_guarded_input_point_from(
                dispatch.input_owner,
                dispatch.frame_seq,
                pointer_admission,
                dispatch.x,
                dispatch.y,
            ),
        };
        let Some((x, y)) = point else {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        };
        let replaced_press = captured_press
            .map(|generation| active_pointer_presses.insert(button.to_string(), generation));
        let result = session.runtime.client.dispatch_mouse_event(
            &session.session_id,
            dispatch.event_type,
            x,
            y,
            dispatch.button,
            dispatch.click_count,
        );
        if let Err(error) = result {
            if is_cdp_timeout_error(&error.to_string()) {
                if captured_release && let Some(press) = active_pointer_presses.get_mut(button) {
                    press.last_target_x = x;
                    press.last_target_y = y;
                    if dispatch.click_count.is_some() {
                        press.click_count = dispatch.click_count;
                    }
                    // The first call may have reached Chrome. Retain its exact
                    // capture and schedule one balancing retry before any later
                    // pointer command can replace that ownership.
                    press.release_retry_at = Some(Instant::now() + POINTER_RELEASE_RETRY_DELAY);
                }
            } else {
                match replaced_press {
                    Some(Some(previous)) => {
                        active_pointer_presses.insert(button.to_string(), previous);
                    }
                    Some(None) => {
                        active_pointer_presses.remove(button);
                    }
                    None => {}
                }
            }
            return Err(error);
        }
        if captured_release {
            active_pointer_presses.remove(button);
        }
        Ok(BrowserWorkerSuccess::BrowserResponded)
    }

    #[cfg(test)]
    pub(super) fn mouse_event_blocking(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
        active_pointer_presses: &mut HashMap<String, ActivePointerPress>,
    ) -> BrowserWorkerResult {
        let pointer_admission = self.admit_pointer_frame(dispatch.input_owner, dispatch.frame_seq);
        self.mouse_event_blocking_with_admission(
            dispatch,
            pointer_admission,
            active_pointer_presses,
        )
    }

    pub(crate) fn mouse_event_confirmed(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let input_owner = BrowserPointerOwner::Legacy;
        let frame_seq = Some(frame_seq);
        let pointer_admission = self.admit_pointer_frame(input_owner, frame_seq);
        self.execute_confirmed(BrowserCommand::Mouse {
            input_owner,
            event_type: event_type.to_string(),
            x,
            y,
            button: button.map(ToOwned::to_owned),
            click_count,
            frame_seq,
            pointer_admission,
        })
    }

    pub(super) fn release_abandoned_pointer_press_blocking(
        &self,
        button: &str,
        press: ActivePointerPress,
    ) -> BrowserWorkerResult {
        if !self.pointer_capture_is_current(press.capture_generation) {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        }
        let session = self.require_attached_session()?;
        session
            .runtime
            .client
            .dispatch_mouse_event(
                &session.session_id,
                "mouseReleased",
                press.last_target_x,
                press.last_target_y,
                Some(button),
                press.click_count,
            )
            .map(|_| BrowserWorkerSuccess::BrowserResponded)
    }

    pub fn wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        self.wheel_for_frame(x, y, delta_y, None)
    }

    pub fn wheel_2d(&self, x: f64, y: f64, delta_x: f64, delta_y: f64) -> anyhow::Result<()> {
        self.wheel_2d_for_frame_from(BrowserPointerOwner::Local, x, y, delta_x, delta_y, None)
    }

    /// Queue a wheel event only if `frame_seq` is still the live pointer-authority token.
    pub fn wheel_for_frame(
        &self,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        self.wheel_for_frame_from(BrowserPointerOwner::Local, x, y, delta_y, frame_seq)
    }

    pub(crate) fn wheel_for_frame_from(
        &self,
        input_owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        self.wheel_2d_for_frame_from(input_owner, x, y, 0.0, delta_y, frame_seq)
    }

    pub(super) fn wheel_2d_for_frame_from(
        &self,
        input_owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let pointer_admission = self.admit_pointer_frame(input_owner, frame_seq);
        self.enqueue_bounded(BrowserCommand::Wheel {
            input_owner,
            x,
            y,
            delta_x,
            delta_y,
            frame_seq,
            pointer_admission,
        })
    }

    pub(super) fn wheel_blocking(
        &self,
        dispatch: BrowserWheelDispatch,
        pointer_admission: Option<BrowserPointerAdmission>,
    ) -> BrowserWorkerResult {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        let Some((x, y, delta_x, delta_y)) =
            self.scale_guarded_wheel_2d_from(dispatch, pointer_admission)
        else {
            return Ok(BrowserWorkerSuccess::LocallySettled);
        };
        session
            .runtime
            .client
            .dispatch_wheel(&session.session_id, x, y, delta_x, delta_y)
            .map(|_| BrowserWorkerSuccess::BrowserResponded)
    }

    pub(crate) fn wheel_confirmed(
        &self,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let input_owner = BrowserPointerOwner::Legacy;
        let frame_seq = Some(frame_seq);
        let pointer_admission = self.admit_pointer_frame(input_owner, frame_seq);
        self.execute_confirmed(BrowserCommand::Wheel {
            input_owner,
            x,
            y,
            delta_x,
            delta_y,
            frame_seq,
            pointer_admission,
        })
    }

    pub fn key_event(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::Key {
            event_type: event_type.to_string(),
            key: key.to_string(),
            code: code.to_string(),
            windows_virtual_key_code,
            modifiers,
            text: text.map(ToOwned::to_owned),
        })
    }

    pub fn key_press(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::KeyPress {
            key: key.to_string(),
            code: code.to_string(),
            windows_virtual_key_code,
            modifiers,
            text: text.map(ToOwned::to_owned),
        })
    }

    pub(super) fn key_event_blocking(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent { event_type, key, code, windows_virtual_key_code, modifiers, text },
        )
    }

    pub(super) fn key_press_blocking(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        let key_down = session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent {
                event_type: "keyDown",
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            },
        );
        let key_up = session.runtime.client.dispatch_key_event(
            &session.session_id,
            CdpKeyEvent {
                event_type: "keyUp",
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text: None,
            },
        );
        key_down.and(key_up)
    }

    pub(crate) fn key_event_confirmed(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Key {
            event_type: event_type.to_string(),
            key: key.to_string(),
            code: code.to_string(),
            windows_virtual_key_code,
            modifiers,
            text: text.map(ToOwned::to_owned),
        })
    }

    pub fn insert_text(&self, text: &str) -> anyhow::Result<()> {
        self.enqueue_bounded(BrowserCommand::InsertText(text.to_string()))
    }

    pub(super) fn insert_text_blocking(&self, text: &str) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        self.maybe_nudge_stalled_external(&session);
        session.runtime.client.insert_text(&session.session_id, text)
    }

    pub(crate) fn insert_text_confirmed(&self, text: &str) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::InsertText(text.to_string()))
    }
}
