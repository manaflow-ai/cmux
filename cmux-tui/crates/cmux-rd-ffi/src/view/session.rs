//! The remote view tab's session rules (was the decisions inside
//! `RemoteVNCSession.swift`, `RemoteVNCSource.swift`,
//! `RemoteVNCCredentialStore.swift` and `RemoteViewPageSession.swift`):
//! which session a record opens, when a VNC session connects, retries, asks
//! for a sign-in or stops, the generation fence between RFB sessions, the
//! scroll-to-wheel-click remainder, the Keychain item's name, and the page
//! session's show / hide / Take over state machine.
//!
//! Every reducer is pure: state and one event in, the next state and the
//! effects to run out. The Swift shell owns the tasks, the RFB client, the
//! Keychain calls and the views, and runs the effects in order.

use serde::{Deserialize, Serialize};

use super::pane::{ControlMode, ModeControl, SessionEnd, SessionState};
use super::tab::{self, TabRecord};

// MARK: - VNC endpoint

/// The port of a Cloud machine's VNC server (behind its websockify 6901).
pub const CLOUD_VNC_PORT: u16 = 5901;
/// Where a loopback name connects.
pub const LOOPBACK_ADDRESS: &str = "127.0.0.1";

/// A VNC address (`VNCEndpoint`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

impl Endpoint {
    /// `VNCEndpoint.label`: `host:port`, `[v6]:port`. The Keychain account.
    pub fn label(&self) -> String {
        if self.host.contains(':') {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }
}

/// A record's VNC address: the reserved names are never resolved (`local`
/// and `localhost` are this Mac); `demo` when the host is the reserved name
/// served by the loopback demo desktop.
pub fn vnc_endpoint(host: &str, port: u16, demo_host: &str) -> (Endpoint, bool) {
    let lower = host.to_lowercase();
    let host = if lower == "local" || lower == "localhost" { LOOPBACK_ADDRESS } else { host };
    (Endpoint { host: host.to_owned(), port }, lower == demo_host)
}

/// A Cloud machine's desktop: its VNC server, over the app's Cloud tunnel.
pub fn cloud_endpoint(host: &str) -> Endpoint {
    Endpoint { host: host.to_owned(), port: CLOUD_VNC_PORT }
}

// MARK: - RFB failures

/// `RFBError`'s cases (their payloads are not needed for the decision).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RfbError {
    Transport,
    ConnectionClosed,
    UnsupportedProtocolVersion,
    NoSupportedSecurityType,
    PasswordRequired,
    CredentialsRequired,
    AuthenticationFailed,
    ProtocolViolation,
}

/// How an RFB failure reads in the pane (`RemoteVNCSource.end(for:)`): none
/// is the viewer's own stop; a missing secret asks to sign in; a refused one
/// asks again, marked rejected only when credentials were sent.
pub fn end_for(error: Option<RfbError>, had_credentials: bool) -> SessionEnd {
    match error {
        None => SessionEnd::StoppedByViewer,
        Some(RfbError::PasswordRequired | RfbError::CredentialsRequired) => {
            SessionEnd::SignInRequired { rejected: false }
        }
        Some(RfbError::AuthenticationFailed) => {
            SessionEnd::SignInRequired { rejected: had_credentials }
        }
        Some(_) => SessionEnd::ConnectionLost,
    }
}

/// The wait before the automatic reconnect after `tries` lost paths since
/// the last session that streamed: 1, 2, 4, then 8 s.
pub fn retry_wait_seconds(tries: u32) -> u64 {
    (1u64 << tries.min(3)).min(10)
}

// MARK: - The source's generation fence

/// `RemoteVNCSource`'s session counter: a late frame, handshake or status of
/// an older session (or of a stopped one) is dropped.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SourceFence {
    pub generation: u64,
    pub has_client: bool,
}

impl SourceFence {
    /// A new session: the next generation; it publishes `connecting`.
    pub fn connect(&mut self) -> u64 {
        self.generation += 1;
        self.has_client = true;
        self.generation
    }

    /// Stop: ends the current generation at once. None when no session ran
    /// (nothing to publish); else the generation `stoppedByViewer` is
    /// published in.
    pub fn stop(&mut self) -> Option<u64> {
        if !self.has_client {
            return None;
        }
        self.has_client = false;
        self.generation += 1;
        Some(self.generation)
    }

    pub fn accepts(&self, generation: u64) -> bool {
        self.generation == generation
    }
}

// MARK: - Scroll

/// Hundredths per wheel click: one line, or about ten points of a swipe.
pub const LINE_PER_CLICK: f64 = 100.0;
pub const POINTS_PER_CLICK: f64 = 1000.0;

/// `RemoteVNCScroll`: scroll deltas (hundredths of a line, or of a point when
/// precise) into whole wheel clicks, keeping the remainder.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WheelScroll {
    pub x: f64,
    pub y: f64,
}

impl WheelScroll {
    pub fn add(&mut self, dx: i32, dy: i32, precise: bool) -> (i64, i64) {
        let unit = if precise { POINTS_PER_CLICK } else { LINE_PER_CLICK };
        let x = self.x + f64::from(dx);
        let y = self.y + f64::from(dy);
        let clicks_x = (x / unit).trunc();
        let clicks_y = (y / unit).trunc();
        self.x = x - clicks_x * unit;
        self.y = y - clicks_y * unit;
        (clicks_x as i64, clicks_y as i64)
    }
}

/// The pane's pointer buttons as RFB buttons (`RemoteVNCInput`): RFB has no
/// back and forward.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneButton {
    Left,
    Middle,
    Right,
    Back,
    Forward,
}

pub fn rfb_button(button: PaneButton) -> Option<PaneButton> {
    match button {
        PaneButton::Back | PaneButton::Forward => None,
        other => Some(other),
    }
}

// MARK: - Saved sign-ins

/// The Keychain service of every VNC sign-in.
pub const CREDENTIAL_SERVICE: &str = "cmux-next VNC";
/// Unattended live checks: a `{username, password}` JSON file named here.
pub const DEBUG_CREDENTIALS_ENV: &str = "CMUX_NEXT_VNC_DEBUG_CREDENTIALS_FILE";

/// The Keychain account of `endpoint`'s sign-in (one per `host:port`).
pub fn credential_account(endpoint: &Endpoint) -> String {
    endpoint.label()
}

/// The debug credentials file is read only when this user alone can read it.
pub fn debug_file_readable(posix_mode: u32) -> bool {
    posix_mode & 0o077 == 0
}

/// The stored item: `{username?, password?}`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredCredentials {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
}

/// The sign-in sheet's ids.
pub const SIGN_IN_USER_FIELD: &str = "user";
pub const SIGN_IN_PASSWORD_FIELD: &str = "password";
pub const SIGN_IN_CONNECT_BUTTON: &str = "connect";
pub const SIGN_IN_IDENTIFIER: &str = "remote.vnc.signIn";

// MARK: - The VNC session

/// `RemoteVNCSession`'s state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct VncSession {
    /// A Cloud desktop: a fresh transport over the Cloud tunnel per session.
    pub cloud: bool,
    /// The host is the loopback demo desktop (the server is still there).
    pub demo: bool,
    pub demo_port: Option<u16>,
    pub demo_starting: bool,
    pub prompting: bool,
    pub closed: bool,
    /// Stop (a hidden tab) until the next connect.
    pub stopped: bool,
    pub retry_pending: bool,
    /// Lost paths since the last session that streamed.
    pub lost_tries: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum VncEvent {
    Connect,
    /// Stop, a hidden tab.
    Stop,
    /// The tab closed: the demo server goes too.
    Close,
    /// Reconnect or Sign In pressed; `source` is the source's state now.
    Reconnect {
        source: SessionState,
    },
    /// A lost path, queued onto the main actor: `source` is the source's
    /// state when it lands.
    Loss {
        source: SessionState,
    },
    /// The backoff wait ended (a cancelled wait sends nothing).
    RetryFired,
    /// A Cloud session streamed.
    Connected,
    /// The demo server started (`port` None: it failed).
    DemoStarted {
        port: Option<u16>,
    },
    /// The sign-in sheet closed.
    SignInAnswer {
        button: Option<String>,
        dismissal: bool,
        has_password: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum VncEffect {
    /// Connect over a fresh Cloud transport, no credentials; tell
    /// `Connected` once it streams.
    ConnectCloud,
    /// Connect to the endpoint with the saved sign-in (or none).
    ConnectSaved,
    /// Connect to the running demo desktop on loopback, no credentials.
    ConnectDemo {
        port: u16,
    },
    /// Start the demo server; tell `DemoStarted`.
    StartDemo,
    /// Stop the demo server (closed while it started, or the tab closed).
    StopDemo,
    CancelDemoStart,
    StopSource,
    CancelRetry,
    ScheduleRetry {
        seconds: u64,
    },
    /// Show the sign-in sheet (the saved user name prefilled).
    PromptSignIn,
    /// Connect with the typed credentials; save them once the host accepts.
    ConnectTyped,
    /// Cancel keeps the sign-in card: publish the status again.
    RepublishStatus,
}

impl VncSession {
    pub fn new(cloud: bool, demo: bool) -> Self {
        Self { cloud, demo, ..Self::default() }
    }

    fn cancel_retry(&mut self, out: &mut Vec<VncEffect>) {
        if self.retry_pending {
            self.retry_pending = false;
            out.push(VncEffect::CancelRetry);
        }
    }

    fn connect(&mut self, out: &mut Vec<VncEffect>) {
        if self.closed {
            return;
        }
        self.stopped = false;
        if self.cloud {
            out.push(VncEffect::ConnectCloud);
        } else if !self.demo {
            out.push(VncEffect::ConnectSaved);
        } else if let Some(port) = self.demo_port {
            out.push(VncEffect::ConnectDemo { port });
        } else if !self.demo_starting {
            self.demo_starting = true;
            out.push(VncEffect::StartDemo);
        }
    }

    pub fn reduce(&mut self, event: VncEvent) -> Vec<VncEffect> {
        let mut out = Vec::new();
        match event {
            VncEvent::Connect => self.connect(&mut out),
            VncEvent::Stop => {
                self.stopped = true;
                self.cancel_retry(&mut out);
                out.push(VncEffect::StopSource);
            }
            VncEvent::Close => {
                self.closed = true;
                self.cancel_retry(&mut out);
                out.push(VncEffect::StopSource);
                if self.demo_starting {
                    out.push(VncEffect::CancelDemoStart);
                }
                if self.demo {
                    out.push(VncEffect::StopDemo);
                }
                self.demo = false;
                self.demo_starting = false;
            }
            VncEvent::Reconnect { source } => {
                // A manual reconnect supersedes any delayed automatic retry.
                self.cancel_retry(&mut out);
                // A Cloud desktop only ever goes over the Cloud tunnel: no sheet.
                let sign_in = matches!(
                    source,
                    SessionState::Ended { reason: SessionEnd::SignInRequired { .. } }
                );
                if !self.cloud && sign_in {
                    if !self.prompting {
                        self.prompting = true;
                        out.push(VncEffect::PromptSignIn);
                    }
                } else {
                    self.connect(&mut out);
                }
            }
            VncEvent::Loss { source } => {
                // A manual reconnect that ran first started a new session: this
                // loss is no longer the source's status, so it schedules nothing.
                let lost =
                    matches!(source, SessionState::Ended { reason: SessionEnd::ConnectionLost });
                if self.cloud && !self.closed && !self.stopped && !self.retry_pending && lost {
                    let seconds = retry_wait_seconds(self.lost_tries);
                    self.lost_tries += 1;
                    self.retry_pending = true;
                    out.push(VncEffect::ScheduleRetry { seconds });
                }
            }
            VncEvent::RetryFired => {
                if self.retry_pending && !self.closed {
                    self.retry_pending = false;
                    self.connect(&mut out);
                }
            }
            VncEvent::Connected => self.lost_tries = 0,
            VncEvent::DemoStarted { port } => {
                if self.closed || !self.demo_starting {
                    out.push(VncEffect::StopDemo);
                } else {
                    self.demo_starting = false;
                    if let Some(port) = port {
                        self.demo_port = Some(port);
                        self.connect(&mut out);
                    }
                }
            }
            VncEvent::SignInAnswer { button, dismissal, has_password } => {
                self.prompting = false;
                if button.as_deref() == Some(SIGN_IN_CONNECT_BUTTON) && !dismissal && has_password {
                    out.push(VncEffect::ConnectTyped);
                } else {
                    out.push(VncEffect::RepublishStatus);
                }
            }
        }
        out
    }
}

// MARK: - The page session

/// How long a hidden Cloud desktop keeps its session.
pub const CLOUD_HIDE_GRACE_SECONDS: u64 = 120;

/// The reserved host of the test desktop.
pub const MOCK_HOST: &str = "mock";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SessionKind {
    /// A `cmux.rd/1` host (a Cloud machine's, or the debug loopback host).
    #[default]
    Rd,
    /// An RFB compatibility host (a `via=vnc` record or a Cloud VNC desktop).
    Vnc,
    /// The test desktop.
    Mock,
}

impl SessionKind {
    /// `debug.remote_view`'s `source`.
    pub fn name(self) -> &'static str {
        match self {
            Self::Rd => "rd",
            Self::Vnc => "vnc",
            Self::Mock => "mock",
        }
    }
}

/// Whether `record`'s first session is in control: a Cloud desktop always
/// opens watching, whatever `mode=` its URL carries.
pub fn starts_in_control(record: &TabRecord) -> bool {
    !record.cloud_desktop && record.mode == ControlMode::Control
}

/// What the app can reach when it opens a record.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MakeContext {
    /// A development build.
    pub debug_build: bool,
    /// `RemoteViewAvailability().isAvailable`.
    pub available: bool,
    /// `RemoteViewAvailability().isCloudRdAvailable`.
    pub cloud_rd_available: bool,
    /// The app has a `cmux-rd` route to this Cloud machine.
    pub cloud_rd_route: bool,
    /// The app can open this Cloud machine's desktop stream (VNC).
    pub cloud_transport: bool,
    /// `RemoteViewDebugRdHost` is opted in and made a transport.
    pub debug_rd_host: bool,
}

/// The pane a page session builds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneConfig {
    pub host_name: String,
    pub initial_mode: ControlMode,
    pub via_cloud_tunnel: bool,
    pub mode_control: ModeControl,
    /// A Cloud rd desktop whose path closed comes back by itself.
    pub auto_reconnects_lost: bool,
    /// The layer-contents presenter, fitted (decoded RFB frames).
    pub layer_contents_fit: bool,
}

/// The session `make` opens, or none (this build cannot show it).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPlan {
    pub kind: SessionKind,
    /// The rd source: a Cloud machine's (`cloudRd`) or the debug host.
    pub cloud_rd: bool,
    /// The VNC session goes over the Cloud tunnel.
    pub vnc_cloud: bool,
    /// The VNC record's port.
    pub vnc_port: Option<u16>,
    /// The mode the first rd transport is made in.
    pub first_control: bool,
    pub pane: PaneConfig,
    pub state: PageSession,
}

/// `RemoteViewPageSession.make`'s choice.
pub fn make(
    record: &TabRecord,
    context: MakeContext,
    display_name: Option<&str>,
) -> Option<SessionPlan> {
    let named = || display_name.unwrap_or(&record.host).to_owned();
    let rd = |cloud_rd: bool| {
        let control = starts_in_control(record);
        SessionPlan {
            kind: SessionKind::Rd,
            cloud_rd,
            vnc_cloud: false,
            vnc_port: None,
            first_control: control,
            pane: PaneConfig {
                host_name: named(),
                initial_mode: if control { ControlMode::Control } else { ControlMode::View },
                via_cloud_tunnel: record.cloud_desktop,
                mode_control: if record.cloud_desktop {
                    ModeControl::TakeOver
                } else {
                    ModeControl::Toggle
                },
                auto_reconnects_lost: record.cloud_desktop,
                layer_contents_fit: false,
            },
            state: PageSession::new(SessionKind::Rd, record.cloud_desktop, control),
        }
    };
    let vnc = |cloud: bool, port: Option<u16>| SessionPlan {
        kind: SessionKind::Vnc,
        cloud_rd: false,
        vnc_cloud: cloud,
        vnc_port: port,
        first_control: false,
        pane: PaneConfig {
            host_name: named(),
            initial_mode: record.mode,
            via_cloud_tunnel: record.cloud_desktop,
            mode_control: ModeControl::Toggle,
            auto_reconnects_lost: false,
            layer_contents_fit: true,
        },
        state: PageSession::new(SessionKind::Vnc, record.cloud_desktop, false),
    };
    if record.cloud_rd {
        return (context.cloud_rd_available && context.cloud_rd_route).then(|| rd(true));
    }
    if !context.debug_build || !context.available {
        return None;
    }
    if record.cloud_desktop {
        return context.cloud_transport.then(|| vnc(true, None));
    }
    if let Some(port) = record.vnc_port {
        return Some(vnc(false, Some(port)));
    }
    if record.host.to_lowercase() == MOCK_HOST {
        return Some(SessionPlan {
            kind: SessionKind::Mock,
            cloud_rd: false,
            vnc_cloud: false,
            vnc_port: None,
            first_control: false,
            pane: PaneConfig {
                host_name: record.host.clone(),
                initial_mode: record.mode,
                via_cloud_tunnel: false,
                mode_control: ModeControl::Toggle,
                auto_reconnects_lost: false,
                layer_contents_fit: false,
            },
            state: PageSession::new(SessionKind::Mock, false, false),
        });
    }
    (tab::is_loopback(&record.host) && context.debug_rd_host).then(|| rd(false))
}

/// `RemoteViewPageSession`'s state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PageSession {
    pub kind: SessionKind,
    /// A Cloud desktop keeps its session through a short hide.
    pub keeps_session_when_hidden: bool,
    /// The mode the next rd session starts in.
    pub rd_control: bool,
    /// The current rd transport already connected once.
    pub rd_used: bool,
    /// The person pressed Stop: only Reconnect starts a new session.
    pub stopped: bool,
    pub visible: bool,
    /// The session still runs from before the last hide.
    pub live_while_hidden: bool,
    /// The hide grace's deadline is pending.
    pub hide_grace_pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PageEvent {
    /// The tab is shown.
    Resume,
    /// The tab is hidden.
    Pause,
    /// The tab closed.
    End,
    /// The hide grace's deadline passed (a cancelled one sends nothing).
    HideGraceElapsed,
    /// The pane's Stop.
    StopPressed,
    /// The pane's Reconnect.
    ReconnectPressed,
    /// Take over (`control`) or Hand back.
    SwitchMode { control: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum PageEffect {
    PaneStart,
    PaneStop,
    /// `pane.apply(.restartForMode)`.
    PaneRestartForMode,
    /// Make a new rd transport in that mode and put it in the source.
    ReplaceRdTransport {
        control: bool,
    },
    RdConnect,
    RdStop,
    VncConnect,
    VncStop,
    /// The VNC session's Reconnect (in the pane's window).
    VncReconnect,
    /// The test desktop: ask for a keyframe.
    MockKeyframe,
    /// The test desktop: end as stopped by the viewer.
    MockStop,
    /// The test desktop: streaming again, and a keyframe.
    MockReconnect,
    ScheduleHideGrace {
        seconds: u64,
    },
    CancelHideGrace,
}

impl PageSession {
    pub fn new(kind: SessionKind, cloud_desktop: bool, rd_control: bool) -> Self {
        Self { kind, keeps_session_when_hidden: cloud_desktop, rd_control, ..Self::default() }
    }

    /// The pane's mode control: only a Cloud rd desktop has Take over.
    pub fn mode_control(&self) -> ModeControl {
        if self.kind == SessionKind::Rd && self.keeps_session_when_hidden {
            ModeControl::TakeOver
        } else {
            ModeControl::Toggle
        }
    }

    /// `remote_view.mode` and the toolbar: only a session with Take over
    /// switches (None: refused, the answer's `changed: false`).
    pub fn select_mode(&mut self, control: bool) -> Option<Vec<PageEffect>> {
        (self.mode_control() == ModeControl::TakeOver)
            .then(|| self.reduce(PageEvent::SwitchMode { control }))
    }

    fn cancel_grace(&mut self, out: &mut Vec<PageEffect>) {
        if self.hide_grace_pending {
            self.hide_grace_pending = false;
            out.push(PageEffect::CancelHideGrace);
        }
    }

    fn start_rd(&mut self, out: &mut Vec<PageEffect>) {
        if self.kind != SessionKind::Rd {
            return;
        }
        if self.rd_used {
            out.push(PageEffect::ReplaceRdTransport { control: self.rd_control });
        }
        self.rd_used = true;
        out.push(PageEffect::PaneStart);
        out.push(PageEffect::RdConnect);
    }

    fn end_hidden_session(&mut self, out: &mut Vec<PageEffect>) {
        self.hide_grace_pending = false;
        self.live_while_hidden = false;
        match self.kind {
            SessionKind::Vnc => out.push(PageEffect::VncStop),
            SessionKind::Rd => out.push(PageEffect::RdStop),
            SessionKind::Mock => {}
        }
    }

    fn pause(&mut self, out: &mut Vec<PageEffect>) {
        if !self.visible {
            return;
        }
        self.visible = false;
        out.push(PageEffect::PaneStop);
        if self.keeps_session_when_hidden && !self.stopped {
            self.live_while_hidden = true;
            self.hide_grace_pending = true;
            out.push(PageEffect::ScheduleHideGrace { seconds: CLOUD_HIDE_GRACE_SECONDS });
            return;
        }
        self.end_hidden_session(out);
    }

    pub fn reduce(&mut self, event: PageEvent) -> Vec<PageEffect> {
        let mut out = Vec::new();
        match event {
            PageEvent::Resume => {
                if self.visible {
                    return out;
                }
                self.visible = true;
                self.cancel_grace(&mut out);
                if self.live_while_hidden {
                    self.live_while_hidden = false;
                    out.push(PageEffect::PaneStart);
                    return out;
                }
                match self.kind {
                    SessionKind::Vnc => {
                        out.push(PageEffect::PaneStart);
                        if !self.stopped {
                            out.push(PageEffect::VncConnect);
                        }
                    }
                    SessionKind::Mock => {
                        out.push(PageEffect::PaneStart);
                        out.push(PageEffect::MockKeyframe);
                    }
                    // After the person's Stop the last frame and the ended card stay.
                    SessionKind::Rd => {
                        if !self.stopped {
                            self.start_rd(&mut out);
                        }
                    }
                }
            }
            PageEvent::Pause => self.pause(&mut out),
            PageEvent::End => {
                self.pause(&mut out);
                self.cancel_grace(&mut out);
                self.end_hidden_session(&mut out);
            }
            PageEvent::HideGraceElapsed => {
                if self.hide_grace_pending {
                    self.end_hidden_session(&mut out);
                }
            }
            PageEvent::StopPressed => match self.kind {
                SessionKind::Rd => {
                    self.stopped = true;
                    out.push(PageEffect::RdStop);
                }
                SessionKind::Vnc => {
                    self.stopped = true;
                    out.push(PageEffect::VncStop);
                }
                SessionKind::Mock => out.push(PageEffect::MockStop),
            },
            PageEvent::ReconnectPressed => match self.kind {
                SessionKind::Rd => {
                    self.stopped = false;
                    out.push(PageEffect::PaneStop);
                    if self.visible {
                        self.start_rd(&mut out);
                    }
                }
                SessionKind::Vnc => {
                    self.stopped = false;
                    out.push(PageEffect::VncReconnect);
                }
                SessionKind::Mock => out.push(PageEffect::MockReconnect),
            },
            PageEvent::SwitchMode { control } => {
                if self.kind != SessionKind::Rd || control == self.rd_control {
                    return out;
                }
                self.rd_control = control;
                // The transport made for the first (or the live) session is in the old mode.
                self.rd_used = true;
                if !self.visible || self.stopped {
                    // A hidden one still live in its grace ends now: shown again, it
                    // starts fresh in the new mode.
                    if self.live_while_hidden {
                        self.cancel_grace(&mut out);
                        self.end_hidden_session(&mut out);
                    }
                    return out;
                }
                out.push(PageEffect::PaneStop);
                out.push(PageEffect::PaneRestartForMode);
                self.start_rd(&mut out);
            }
        }
        out
    }
}
