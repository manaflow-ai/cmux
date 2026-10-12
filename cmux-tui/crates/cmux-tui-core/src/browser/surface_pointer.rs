//! BrowserSurface pointer authority: input point and wheel delta scaling,
//! pointer frame admission, guarded and captured pointer routes.

use super::*;

impl BrowserSurface {
    pub(super) fn frames_stalled_at(&self, now: Instant) -> bool {
        let state = self.state.lock().unwrap();
        frames_stalled_locked(&state, now, self.is_dead())
    }

    pub(super) fn scale_input_point_locked(state: &BrowserState, x: f64, y: f64) -> (f64, f64) {
        let (pane_width, pane_height) = state.pane_pixels;
        let (page_width, page_height) = state.page_viewport.unwrap_or(state.capture_pixels);
        let page_width = page_width.max(1);
        let page_height = page_height.max(1);
        let x = x / f64::from(pane_width.max(1)) * f64::from(page_width);
        let y = y / f64::from(pane_height.max(1)) * f64::from(page_height);
        (x.clamp(0.0, f64::from(page_width)), y.clamp(0.0, f64::from(page_height)))
    }

    #[cfg(test)]
    pub(super) fn scale_input_point(&self, x: f64, y: f64) -> (f64, f64) {
        Self::scale_input_point_locked(&self.state.lock().unwrap(), x, y)
    }

    pub(super) fn pointer_epoch_is_current_locked(&self, state: &BrowserState) -> bool {
        state.pending_frame_epoch.is_none()
            && state.pending_navigation_epoch.is_none()
            && state.pending_document_epoch.is_none()
            && !state.pending_same_document_navigation
            && state.accepted_frame_epoch == self.frame_epoch.current()
            && state.accepted_navigation_epoch == self.frame_epoch.latest_navigation()
            && state.handled_same_document_navigation_epoch
                == self.frame_epoch.latest_same_document_navigation()
    }

    pub(super) fn exported_pointer_frame_seq_locked(&self, state: &BrowserState) -> Option<u64> {
        self.pointer_epoch_is_current_locked(state).then_some(state.pointer_frame_seq).flatten()
    }

    pub(super) fn exported_pointer_frame_floor_seq_locked(
        &self,
        state: &BrowserState,
    ) -> Option<u64> {
        self.pointer_epoch_is_current_locked(state)
            .then_some(state.pointer_frame_floor_seq)
            .flatten()
    }

    pub(super) fn pointer_frame_is_in_current_route_locked(
        &self,
        state: &BrowserState,
        frame_seq: u64,
    ) -> bool {
        let Some((floor, latest)) = state.pointer_frame_floor_seq.zip(state.pointer_frame_seq)
        else {
            return false;
        };
        self.pointer_epoch_is_current_locked(state) && (floor..=latest).contains(&frame_seq)
    }

    pub(super) fn presented_pointer_frame_is_current_locked(
        &self,
        state: &BrowserState,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        state.presented_pointer_frames.get(&owner) == Some(&frame_seq)
            && self.pointer_frame_is_in_current_route_locked(state, frame_seq)
    }

    pub(super) fn acknowledge_pointer_frame_locked(
        &self,
        state: &mut BrowserState,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        if !self.pointer_frame_is_in_current_route_locked(state, frame_seq)
            || state
                .presented_pointer_frames
                .get(&owner)
                .is_some_and(|presented| *presented > frame_seq)
        {
            return false;
        }
        state.presented_pointer_frames.insert(owner, frame_seq);
        true
    }

    pub(super) fn admit_pointer_frame(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
    ) -> Option<BrowserPointerAdmission> {
        let mut state = self.state.lock().unwrap();
        let admitted = match frame_seq {
            Some(frame_seq) => self.acknowledge_pointer_frame_locked(&mut state, owner, frame_seq),
            None => {
                state.pointer_frame_seq.is_some() && self.pointer_epoch_is_current_locked(&state)
            }
        };
        admitted.then_some(BrowserPointerAdmission { owner, frame_seq })
    }

    pub(super) fn pointer_guard_is_current_locked(
        &self,
        state: &BrowserState,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
    ) -> bool {
        if pointer_admission != Some(BrowserPointerAdmission { owner, frame_seq }) {
            return false;
        }
        match frame_seq {
            Some(frame_seq) => self.pointer_frame_is_in_current_route_locked(state, frame_seq),
            None => {
                state.pointer_frame_seq.is_some() && self.pointer_epoch_is_current_locked(state)
            }
        }
    }

    pub(super) fn scale_guarded_input_point_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
        x: f64,
        y: f64,
    ) -> Option<(f64, f64)> {
        let state = self.state.lock().unwrap();
        if !self.pointer_guard_is_current_locked(&state, owner, frame_seq, pointer_admission) {
            return None;
        }
        Some(Self::scale_input_point_locked(&state, x, y))
    }

    #[cfg(test)]
    pub(super) fn scale_guarded_input_point(
        &self,
        frame_seq: Option<u64>,
        x: f64,
        y: f64,
    ) -> Option<(f64, f64)> {
        let admitted = frame_seq.is_none_or(|frame_seq| {
            let state = self.state.lock().unwrap();
            self.presented_pointer_frame_is_current_locked(
                &state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
        });
        let pointer_admission = admitted
            .then_some(BrowserPointerAdmission { owner: BrowserPointerOwner::Local, frame_seq });
        self.scale_guarded_input_point_from(
            BrowserPointerOwner::Local,
            frame_seq,
            pointer_admission,
            x,
            y,
        )
    }

    pub(super) fn capture_guarded_input_point_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: u64,
        pointer_admission: Option<BrowserPointerAdmission>,
        x: f64,
        y: f64,
    ) -> Option<((f64, f64), u64, u64, u64)> {
        let ingress_motion_generation = self.frame_epoch.pointer_motion_generation();
        let state = self.state.lock().unwrap();
        if !ingress_motion_generation.is_multiple_of(2)
            || !self.pointer_guard_is_current_locked(
                &state,
                owner,
                Some(frame_seq),
                pointer_admission,
            )
            || ingress_motion_generation != self.frame_epoch.pointer_motion_generation()
        {
            return None;
        }
        Some((
            Self::scale_input_point_locked(&state, x, y),
            state.pointer_capture_generation,
            state.pointer_motion_generation,
            ingress_motion_generation,
        ))
    }

    #[cfg(test)]
    pub(super) fn capture_guarded_input_point(
        &self,
        frame_seq: u64,
        x: f64,
        y: f64,
    ) -> Option<((f64, f64), u64, u64, u64)> {
        let admitted = {
            let state = self.state.lock().unwrap();
            self.presented_pointer_frame_is_current_locked(
                &state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
        };
        let pointer_admission = admitted.then_some(BrowserPointerAdmission {
            owner: BrowserPointerOwner::Local,
            frame_seq: Some(frame_seq),
        });
        self.capture_guarded_input_point_from(
            BrowserPointerOwner::Local,
            frame_seq,
            pointer_admission,
            x,
            y,
        )
    }

    #[cfg(test)]
    pub(super) fn scale_captured_input_point(
        &self,
        capture_generation: u64,
        x: f64,
        y: f64,
    ) -> Option<(f64, f64)> {
        let state = self.state.lock().unwrap();
        if state.pointer_capture_generation != capture_generation
            || state.accepted_navigation_epoch != self.frame_epoch.latest_navigation()
        {
            return None;
        }
        Some(Self::scale_input_point_locked(&state, x, y))
    }

    pub(super) fn captured_pointer_route(
        &self,
        capture_generation: u64,
        motion_generation: u64,
        ingress_motion_generation: u64,
        frame_seq: u64,
        dispatch_frame_seq: u64,
        point: (f64, f64),
    ) -> CapturedPointerRoute {
        let state = self.state.lock().unwrap();
        if state.pointer_capture_generation != capture_generation
            || state.accepted_navigation_epoch != self.frame_epoch.latest_navigation()
        {
            return CapturedPointerRoute::InvalidCapture;
        }
        if state.pointer_motion_generation != motion_generation
            || self.frame_epoch.pointer_motion_generation() != ingress_motion_generation
            || dispatch_frame_seq != frame_seq
        {
            return CapturedPointerRoute::MotionInvalidated;
        }
        CapturedPointerRoute::Current(Self::scale_input_point_locked(&state, point.0, point.1))
    }

    pub(super) fn pointer_capture_is_current(&self, capture_generation: u64) -> bool {
        let state = self.state.lock().unwrap();
        state.pointer_capture_generation == capture_generation
            && state.accepted_navigation_epoch == self.frame_epoch.latest_navigation()
    }

    pub(super) fn set_pointer_frame_range_locked(
        state: &mut BrowserState,
        floor: Option<u64>,
        latest: Option<u64>,
    ) {
        debug_assert_eq!(floor.is_some(), latest.is_some());
        debug_assert!(floor.zip(latest).is_none_or(|(floor, latest)| floor <= latest));
        state.pointer_frame_floor_seq = floor;
        state.pointer_frame_seq = latest;
        state.pointer_frame_revision = state.pointer_frame_revision.wrapping_add(1);
    }

    pub(super) fn set_pointer_frame_locked(state: &mut BrowserState, frame_seq: Option<u64>) {
        Self::set_pointer_frame_range_locked(state, frame_seq, frame_seq);
        state.presented_pointer_frames.clear();
    }

    pub(super) fn advance_pointer_frame_locked(state: &mut BrowserState, frame_seq: Option<u64>) {
        let floor = frame_seq.and(state.pointer_frame_floor_seq.or(frame_seq));
        Self::set_pointer_frame_range_locked(state, floor, frame_seq);
    }

    pub(super) fn set_pending_attach_frame_locked(
        &self,
        state: &mut BrowserState,
        frame: Option<Arc<BrowserFrame>>,
    ) {
        let update = frame.map(|frame| BrowserFrameUpdate {
            frame: frame.as_ref().clone(),
            status: state.status.clone(),
            pointer_frame_floor_seq: self.exported_pointer_frame_floor_seq_locked(state),
            pointer_frame_seq: self.exported_pointer_frame_seq_locked(state),
        });
        for tap in &state.taps {
            tap.slot.lock().unwrap().frame = update.clone();
        }
    }

    pub(super) fn invalidate_pointer_frame_locked(
        &self,
        state: &mut BrowserState,
        revoke_capture: bool,
    ) -> PointerFrameInvalidation {
        let previous = state.pointer_frame_seq;
        let previous_floor = state.pointer_frame_floor_seq;
        let previous_presented_pointer_frames = state.presented_pointer_frames.clone();
        let previous_latest_frame_seq = state.latest_frame.as_ref().map(|frame| frame.seq);
        let previous_capture_generation = state.pointer_capture_generation;
        let previous_motion_generation = state.pointer_motion_generation;
        let previous_pending_frame_epoch = state.pending_frame_epoch;
        let previous_pending_navigation_epoch = state.pending_navigation_epoch;
        let previous_pending_authority_deadline = state.pending_authority_deadline;
        let previous_pending_same_document_navigation = state.pending_same_document_navigation;
        let previous_accepted_navigation_epoch = state.accepted_navigation_epoch;
        let previous_pending_frame = state.pending_frame.clone();
        Self::set_pointer_frame_locked(state, None);
        self.set_pending_attach_frame_locked(state, None);
        state.pending_screencast_capture = None;
        state.pointer_motion_generation = state.pointer_motion_generation.wrapping_add(1);
        if revoke_capture {
            state.pointer_capture_generation = state.pointer_capture_generation.wrapping_add(1);
        }
        PointerFrameInvalidation {
            previous,
            previous_floor,
            previous_presented_pointer_frames,
            previous_latest_frame_seq,
            previous_capture_generation,
            previous_motion_generation,
            previous_pending_frame_epoch,
            previous_pending_navigation_epoch,
            previous_pending_authority_deadline,
            previous_pending_same_document_navigation,
            previous_accepted_navigation_epoch,
            previous_pending_frame,
            revision: state.pointer_frame_revision,
            expected_frame_epoch: None,
        }
    }

    #[cfg(test)]
    pub(super) fn invalidate_pointer_frame(&self) -> PointerFrameInvalidation {
        self.begin_frame_transition(true)
    }
}

impl BrowserSurface {
    pub(super) fn scale_delta_locked(state: &BrowserState, delta: f64) -> f64 {
        if let Some((_, page_height)) = state.page_viewport {
            delta * f64::from(page_height.max(1)) / f64::from(state.pane_pixels.1.max(1))
        } else {
            delta * state.capture_scale
        }
    }

    #[cfg(test)]
    pub(super) fn scale_delta(&self, delta: f64) -> f64 {
        Self::scale_delta_locked(&self.state.lock().unwrap(), delta)
    }

    #[cfg(test)]
    pub(super) fn scale_guarded_wheel_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: Option<u64>,
        pointer_admission: Option<BrowserPointerAdmission>,
        x: f64,
        y: f64,
        delta_y: f64,
    ) -> Option<(f64, f64, f64)> {
        self.scale_guarded_wheel_2d_from(
            BrowserWheelDispatch { input_owner: owner, x, y, delta_x: 0.0, delta_y, frame_seq },
            pointer_admission,
        )
        .map(|(x, y, _, delta_y)| (x, y, delta_y))
    }

    pub(super) fn scale_guarded_wheel_2d_from(
        &self,
        dispatch: BrowserWheelDispatch,
        pointer_admission: Option<BrowserPointerAdmission>,
    ) -> Option<(f64, f64, f64, f64)> {
        let state = self.state.lock().unwrap();
        if !self.pointer_guard_is_current_locked(
            &state,
            dispatch.input_owner,
            dispatch.frame_seq,
            pointer_admission,
        ) {
            return None;
        }
        let (x, y) = Self::scale_input_point_locked(&state, dispatch.x, dispatch.y);
        Some((
            x,
            y,
            Self::scale_delta_locked(&state, dispatch.delta_x),
            Self::scale_delta_locked(&state, dispatch.delta_y),
        ))
    }

    #[cfg(test)]
    pub(super) fn scale_guarded_wheel(
        &self,
        frame_seq: Option<u64>,
        x: f64,
        y: f64,
        delta_y: f64,
    ) -> Option<(f64, f64, f64)> {
        let admitted = frame_seq.is_none_or(|frame_seq| {
            let state = self.state.lock().unwrap();
            self.presented_pointer_frame_is_current_locked(
                &state,
                BrowserPointerOwner::Local,
                frame_seq,
            )
        });
        let pointer_admission = admitted
            .then_some(BrowserPointerAdmission { owner: BrowserPointerOwner::Local, frame_seq });
        self.scale_guarded_wheel_from(
            BrowserPointerOwner::Local,
            frame_seq,
            pointer_admission,
            x,
            y,
            delta_y,
        )
    }
}
