//! The remote view pane's state and its single writer (was
//! `RemotePaneState.swift`, `RemotePaneReducer.swift`,
//! `RemoteLatencyHold.swift`): what the pane shows for a status, a frame and
//! the viewer's choices. Pure: instants are nanoseconds on the caller's
//! monotonic clock, passed in with each event.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

const SECOND_NS: i64 = 1_000_000_000;
/// `RemoteLatencyHold.sustain`.
pub const LATENCY_SUSTAIN_NS: i64 = 3 * SECOND_NS;
/// `RemotePaneState.reconnectNoticeDelay` (`QuietHold.connectionDelay`).
pub const RECONNECT_NOTICE_DELAY_NS: i64 = 10 * SECOND_NS;
/// `RemotePaneState.connectNoticeDelay` (`QuietHold.comingUpDelay`).
pub const CONNECT_NOTICE_DELAY_NS: i64 = SECOND_NS;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ControlMode {
    View,
    #[default]
    Control,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ModeControl {
    #[default]
    Toggle,
    TakeOver,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpstreamKind {
    Microphone,
    Camera,
    Screen,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Path {
    #[default]
    Direct,
    ViaCloudRegion,
    Relayed,
    Compatibility,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SessionEnd {
    DisconnectedBy { name: String },
    HostStoppedSharing,
    HostFailed { reason: String },
    StoppedByViewer,
    ConnectionLost,
    ConsentDenied,
    SignInRequired { rejected: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SessionState {
    #[default]
    Connecting,
    WaitingForConsent,
    Streaming,
    Ended {
        reason: SessionEnd,
    },
}

impl SessionState {
    pub fn is_ended(&self) -> bool {
        matches!(self, Self::Ended { .. })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UpstreamStatus {
    pub offered: bool,
    pub requested: BTreeSet<UpstreamKind>,
    pub active: BTreeSet<UpstreamKind>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ViewStatus {
    pub path: Path,
    pub rtt_ms: Option<i64>,
    pub loss_percent: f64,
    pub state: SessionState,
    pub upstream: UpstreamStatus,
    pub end_reason: Option<String>,
    pub connecting_reason: Option<String>,
    pub stream_width: Option<i64>,
    pub stream_height: Option<i64>,
}

/// High latency with hysteresis: the path has to stay on the other side of
/// the limit for [`LATENCY_SUSTAIN_NS`] before the held state flips.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LatencyHold {
    pub high: bool,
    pub crossed_at: Option<i64>,
}

impl LatencyHold {
    /// When a pending flip is due; None with none pending.
    pub fn due(&self) -> Option<i64> {
        self.crossed_at.map(|t| t.saturating_add(LATENCY_SUSTAIN_NS))
    }

    pub fn sample(&mut self, over: bool, now: i64) {
        if over == self.high {
            self.crossed_at = None;
            return;
        }
        let since = self.crossed_at.unwrap_or(now);
        if now.saturating_sub(since) >= LATENCY_SUSTAIN_NS {
            self.high = over;
            self.crossed_at = None;
        } else {
            self.crossed_at = Some(since);
        }
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PaneState {
    pub host_name: String,
    pub status: Option<ViewStatus>,
    pub requested_mode: ControlMode,
    pub control_despite_latency: bool,
    pub interactive_max_rtt_ms: i64,
    pub has_frame: bool,
    pub via_cloud_tunnel: bool,
    pub reconnecting: bool,
    pub reconnecting_since: Option<i64>,
    pub reconnect_notice_due: bool,
    pub connecting_since: Option<i64>,
    pub connect_notice_due: bool,
    pub mode_control: ModeControl,
    pub latency: LatencyHold,
}

impl Default for PaneState {
    fn default() -> Self {
        Self {
            host_name: String::new(),
            status: None,
            requested_mode: ControlMode::Control,
            control_despite_latency: false,
            interactive_max_rtt_ms: 80,
            has_frame: false,
            via_cloud_tunnel: false,
            reconnecting: false,
            reconnecting_since: None,
            reconnect_notice_due: false,
            connecting_since: None,
            connect_notice_due: false,
            mode_control: ModeControl::Toggle,
            latency: LatencyHold::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Overlay {
    Connecting,
    WaitingForConsent,
    Ended { reason: SessionEnd },
}

/// Everything the pane's view reads, derived from a state at once.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneView {
    pub session_state: SessionState,
    pub is_high_latency: bool,
    pub sample_over_limit: bool,
    pub effective_mode: ControlMode,
    pub overlay: Option<Overlay>,
    pub quiet_reconnect: bool,
    pub coming_up: bool,
    pub quiet_connect: bool,
    pub quiet_connecting: bool,
    pub shows_latency_banner: bool,
    pub shows_session_controls: bool,
    pub upstream: UpstreamStatus,
    pub shows_upstream_buttons: bool,
    pub upstream_indicator: Vec<UpstreamKind>,
    pub pins_toolbar: bool,
    pub is_ended: bool,
    /// When the latency hold's pending flip is due (send `latencyCheck` then).
    pub latency_due: Option<i64>,
}

impl PaneState {
    pub fn session_state(&self) -> SessionState {
        self.status.as_ref().map(|s| s.state.clone()).unwrap_or_default()
    }

    pub fn is_ended(&self) -> bool {
        self.session_state().is_ended()
    }

    pub fn is_streaming(&self) -> bool {
        self.session_state() == SessionState::Streaming
    }

    pub fn sample_over_limit(&self) -> bool {
        match self.status.as_ref().and_then(|s| s.rtt_ms) {
            Some(rtt) => rtt > self.interactive_max_rtt_ms,
            None => false,
        }
    }

    pub fn effective_mode(&self) -> ControlMode {
        if !self.is_streaming() || self.requested_mode != ControlMode::Control {
            return ControlMode::View;
        }
        if self.latency.high && !self.control_despite_latency {
            ControlMode::View
        } else {
            ControlMode::Control
        }
    }

    pub fn quiet_reconnect(&self) -> bool {
        self.reconnecting && !self.reconnect_notice_due
    }

    pub fn coming_up(&self) -> bool {
        if self.reconnecting || self.has_frame {
            return false;
        }
        matches!(self.session_state(), SessionState::Connecting | SessionState::Streaming)
    }

    pub fn quiet_connect(&self) -> bool {
        self.coming_up() && self.connecting_since.is_some() && !self.connect_notice_due
    }

    pub fn quiet_connecting(&self) -> bool {
        self.quiet_reconnect() || self.quiet_connect()
    }

    pub fn overlay(&self) -> Option<Overlay> {
        match self.session_state() {
            SessionState::Connecting => (!self.quiet_connecting()).then_some(Overlay::Connecting),
            SessionState::WaitingForConsent => Some(Overlay::WaitingForConsent),
            SessionState::Streaming => {
                (!(self.has_frame || self.quiet_connecting())).then_some(Overlay::Connecting)
            }
            SessionState::Ended { reason } => Some(Overlay::Ended { reason }),
        }
    }

    pub fn upstream(&self) -> UpstreamStatus {
        if self.is_ended() {
            return UpstreamStatus::default();
        }
        self.status.as_ref().map(|s| s.upstream.clone()).unwrap_or_default()
    }

    pub fn view(&self) -> PaneView {
        let state = self.session_state();
        let upstream = self.upstream();
        let streaming = state == SessionState::Streaming;
        let overlay = self.overlay();
        PaneView {
            is_high_latency: self.latency.high,
            sample_over_limit: self.sample_over_limit(),
            effective_mode: self.effective_mode(),
            quiet_reconnect: self.quiet_reconnect(),
            coming_up: self.coming_up(),
            quiet_connect: self.quiet_connect(),
            quiet_connecting: self.quiet_connecting(),
            shows_latency_banner: streaming
                && self.requested_mode == ControlMode::Control
                && self.latency.high
                && !self.control_despite_latency,
            shows_session_controls: matches!(
                state,
                SessionState::Streaming | SessionState::WaitingForConsent
            ),
            shows_upstream_buttons: streaming && upstream.offered,
            upstream_indicator: upstream.active.iter().copied().collect(),
            pins_toolbar: overlay.is_some(),
            is_ended: state.is_ended(),
            latency_due: self.latency.due(),
            overlay,
            upstream,
            session_state: state,
        }
    }
}

/// Inputs to the pane state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PaneEvent {
    Status { status: ViewStatus },
    FrameShown,
    SelectMode { mode: ControlMode },
    ControlAnyway,
    Stop,
    Reconnect,
    RestartForMode,
    SetInteractiveMaxRtt { limit: i64 },
    StopUpstream { upstream: UpstreamKind },
    StopAllUpstreams,
    LatencyCheck,
    ReconnectNoticeCheck,
    ConnectNoticeCheck,
}

/// The pane's single writer: the next state for `event` at `now`.
pub fn reduce(state: &PaneState, event: &PaneEvent, now: i64) -> PaneState {
    let mut next = reduce_event(state, event);
    if next.status.as_ref().and_then(|s| s.rtt_ms).is_none() {
        next.latency.reset();
    } else {
        let over = next.sample_over_limit();
        next.latency.sample(over, now);
    }
    if next.reconnecting {
        let since = next.reconnecting_since.unwrap_or(now);
        next.reconnecting_since = Some(since);
        next.reconnect_notice_due = now.saturating_sub(since) >= RECONNECT_NOTICE_DELAY_NS;
    } else {
        next.reconnecting_since = None;
        next.reconnect_notice_due = false;
    }
    if next.coming_up() {
        let since = next.connecting_since.unwrap_or(now);
        next.connecting_since = Some(since);
        next.connect_notice_due = now.saturating_sub(since) >= CONNECT_NOTICE_DELAY_NS;
    } else {
        next.connecting_since = None;
        next.connect_notice_due = false;
    }
    next
}

fn reduce_event(state: &PaneState, event: &PaneEvent) -> PaneState {
    let mut next = state.clone();
    let connecting_status = || ViewStatus::default();
    match event {
        PaneEvent::Status { status } => {
            let was_ended = state.is_ended();
            next.status = Some(status.clone());
            if status.state == SessionState::Connecting && was_ended {
                next.control_despite_latency = false;
                next.reconnecting = state.has_frame || state.reconnecting;
                next.has_frame = false;
            }
        }
        PaneEvent::FrameShown => {
            if state.is_streaming() {
                next.has_frame = true;
                next.reconnecting = false;
            }
        }
        PaneEvent::SelectMode { mode } => {
            next.requested_mode = *mode;
            if *mode == ControlMode::View {
                next.control_despite_latency = false;
            }
        }
        PaneEvent::ControlAnyway => {
            if state.is_streaming() && state.latency.high {
                next.requested_mode = ControlMode::Control;
                next.control_despite_latency = true;
            }
        }
        PaneEvent::Stop => {
            if !state.is_ended() {
                let mut status = state.status.clone().unwrap_or_else(connecting_status);
                status.state = SessionState::Ended { reason: SessionEnd::StoppedByViewer };
                next.status = Some(status);
            }
        }
        PaneEvent::Reconnect => {
            if state.is_ended() {
                let mut status = state.status.clone().unwrap_or_else(connecting_status);
                status.state = SessionState::Connecting;
                status.rtt_ms = None;
                status.end_reason = None;
                next.status = Some(status);
                next.control_despite_latency = false;
                next.reconnecting = state.has_frame || state.reconnecting;
                next.has_frame = false;
            }
        }
        PaneEvent::RestartForMode => {
            if !state.is_ended() {
                let mut status = state.status.clone().unwrap_or_else(connecting_status);
                status.state = SessionState::Connecting;
                status.rtt_ms = None;
                next.status = Some(status);
                next.reconnecting = state.has_frame || state.reconnecting;
                next.has_frame = false;
            }
        }
        PaneEvent::SetInteractiveMaxRtt { limit } => next.interactive_max_rtt_ms = (*limit).max(0),
        PaneEvent::StopUpstream { upstream } => {
            if let Some(status) = next.status.as_mut() {
                status.upstream.active.remove(upstream);
                status.upstream.requested.remove(upstream);
            }
        }
        PaneEvent::StopAllUpstreams => {
            if let Some(status) = next.status.as_mut() {
                status.upstream.active.clear();
                status.upstream.requested.clear();
            }
        }
        PaneEvent::LatencyCheck
        | PaneEvent::ReconnectNoticeCheck
        | PaneEvent::ConnectNoticeCheck => {}
    }
    next
}
