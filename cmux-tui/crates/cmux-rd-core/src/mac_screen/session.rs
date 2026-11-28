//! One Mac Screen tab's stream to another of the person's Macs (the Mac's `MacScreenSession`):
//! its phase, why it failed, where its connect is, the offer it holds until the session socket
//! opens, the host's candidates it holds until the link process has its answer, and its live
//! stats. Events in, effects out: the app does the platform work an effect names (start the
//! deadline, send the offer, attach the transport, tear down) and reports what happened back as
//! the next event. Words the person reads come back as a [`Message`] (a localization key and
//! its English, or the text a side said), and the app localizes them.

use super::offer::{OfferInputs, lacks_display, make_offer};
use super::stage::{CONNECT_TIMEOUT_MS, Stage};
use cmux_rd_proto::app_line::AppLine;
use cmux_rd_proto::rd_doc::{RdDocument, is_relayed};
use serde::{Deserialize, Serialize};

/// Text for the person: a localization key with its English (`key` set), or what a side said.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Message {
    /// The app's localization key (`L.t(key, text)`); None for a side's own words.
    pub key: Option<String>,
    /// The English text (with `%@` for the host's name when `names_host`), or the side's words.
    pub text: String,
    /// The text takes the host's name (`%@`).
    #[serde(default)]
    pub names_host: bool,
}

impl Message {
    fn localized(key: &str, text: &str) -> Self {
        Message { key: Some(key.to_owned()), text: text.to_owned(), names_host: false }
    }

    fn said(text: impl Into<String>) -> Self {
        Message { key: None, text: text.into(), names_host: false }
    }

    pub fn no_ticket() -> Self {
        Self::localized("macScreen.rd.noTicket", "The other Mac did not approve a session yet.")
    }
    pub fn no_binary() -> Self {
        Self::localized("macScreen.rd.noBinary", "cmux could not start its screen viewer.")
    }
    pub fn host_ended() -> Self {
        Self::localized("macScreen.rd.hostEnded", "The other Mac ended the session.")
    }
    pub fn signaling_failed() -> Self {
        Self::localized(
            "macScreen.rd.signalingFailed",
            "The session could not reach the other Mac.",
        )
    }
    pub fn viewer_stopped() -> Self {
        Self::localized("macScreen.rd.viewerStopped", "The screen viewer stopped.")
    }
    pub fn lost() -> Self {
        Self::localized("macScreen.rd.lost", "The connection to the other Mac was lost.")
    }

    /// The failed card's text for a connect that timed out in `stage`; None once shown.
    pub fn timed_out(stage: Stage) -> Option<Self> {
        let text = match stage {
            Stage::Answer => "No answer from %@ within 15 seconds.",
            Stage::Link => "%@ answered, but no link came up within 15 seconds.",
            Stage::Frame => "Connected to %@, but no picture arrived within 15 seconds.",
            Stage::Shown => return None,
        };
        Some(Message { names_host: true, ..Self::localized(stage.timeout_key()?, text) })
    }
}

/// Where the session is.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case", tag = "phase")]
pub enum Phase {
    Connecting,
    Connected,
    Failed {
        message: Message,
        needs_sign_in: bool,
    },
    #[default]
    Ended,
}

impl Phase {
    fn failed(message: Message) -> Self {
        Phase::Failed { message, needs_sign_in: false }
    }

    fn runs(&self) -> bool {
        matches!(self, Phase::Connecting | Phase::Connected)
    }
}

/// Why the last session failed, in the words of the side that knew.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FailureCause {
    /// The host could not serve the session (its `failed: <reason>`); `reason` may be empty.
    Host(String),
    /// This Mac's link to the host failed (`cmux rd connect`'s words).
    Link(String),
}

/// How a host's cmux.rd/1 `ended` reason reads (the Mac's `RemoteRdHandshake.hostEnd`):
/// `failed` or `failed: <reason>` is a failure with its reason, anything else a stop.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HostEnd {
    HostFailed(String),
    HostStoppedSharing,
}

pub fn host_end(reason: &str) -> HostEnd {
    let text = reason.trim();
    if text != "failed" && !text.starts_with("failed:") {
        return HostEnd::HostStoppedSharing;
    }
    HostEnd::HostFailed(text["failed".len()..].trim_start_matches([':', ' ']).to_owned())
}

/// What `cmux rd connect`'s `ended` line says about who failed (cmux-rd-host `connect.rs`):
/// `host: failed: <reason>` is the host's own failure, `link failed: <why>` this Mac's link,
/// `failed: <error>` the link bridge's own error. None for every other end (the host stopped,
/// the viewer stopped, the pane closed), which needs no explanation.
pub fn failure_cause_of_ended(reason: &str) -> Option<FailureCause> {
    if let Some(rest) = reason.strip_prefix("host: ") {
        return match host_end(rest) {
            HostEnd::HostFailed(why) => Some(FailureCause::Host(why)),
            HostEnd::HostStoppedSharing => None,
        };
    }
    ["link failed: ", "failed: "]
        .iter()
        .find_map(|prefix| reason.strip_prefix(prefix))
        .map(|why| FailureCause::Link(why.to_owned()))
}

/// The label of a link path kind (`Direct (local network)`, `Direct`, `Relayed`); None for
/// an unknown or absent kind, which reads `-`.
pub fn path_label(kind: Option<&str>) -> Option<Message> {
    match kind? {
        "direct_lan" => Some(Message::localized("macScreen.rd.pathLan", "Direct (local network)")),
        "direct_wan" => Some(Message::localized("macScreen.rd.pathDirect", "Direct")),
        kind if is_relayed(kind) => Some(Message::localized("macScreen.rd.pathRelayed", "Relayed")),
        _ => None,
    }
}

/// The stream's numbers for the toolbar's readout (the Mac's `LiveStats`).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(default)]
pub struct LiveStats {
    pub fps: f64,
    pub kilobytes_per_second: f64,
    pub latency_ms: Option<f64>,
    pub encoding: String,
    pub target_fps: Option<u32>,
    pub frames_received: f64,
    pub frames_decoded: f64,
    pub frames_dropped: f64,
    /// The host's own once-a-second counters (cmux.rd/1 `stats`), None until the first one.
    pub host_kbps: Option<f64>,
    pub loss_percent: Option<f64>,
    pub encode_ms_p50: Option<f64>,
    /// The profile the host says it encodes with; the view labels Ultra only from this.
    pub encode_profile: Option<String>,
}

impl Default for LiveStats {
    fn default() -> Self {
        LiveStats {
            fps: 0.0,
            kilobytes_per_second: 0.0,
            latency_ms: None,
            encoding: "H.264".to_owned(),
            target_fps: None,
            frames_received: 0.0,
            frames_decoded: 0.0,
            frames_dropped: 0.0,
            host_kbps: None,
            loss_percent: None,
            encode_ms_p50: None,
            encode_profile: None,
        }
    }
}

/// Pixel sizes (zero until known).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Default)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// What the app does for the session.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "effect")]
pub enum Effect {
    /// End this session's platform work: the deadline, tasks, transport, process, socket dir.
    Teardown,
    /// Start the connect deadline; when it passes, send [`Event::DeadlinePassed`].
    ScheduleDeadline {
        ms: u64,
    },
    CancelDeadline,
    /// The connect got past a stage at this moment (its timings).
    Reached {
        stage: Stage,
    },
    /// Send this offer over the session's signaling.
    SendOffer {
        text: String,
    },
    /// Give the link process the host's answer (with the session id, servers and a socket);
    /// then send [`Event::AnswerHanded`].
    SendAnswer {
        peer_key: String,
        candidates: Vec<String>,
    },
    /// A host candidate for the link process.
    ProcessCandidate {
        candidate: String,
    },
    /// A link candidate for the host, over signaling (`sdpMid` `cmux-rd`).
    SignalCandidate {
        candidate: String,
    },
    /// Tell the hub whether the path is relayed.
    SignalPath {
        relay: bool,
    },
    /// The link listens for the pane: attach a transport to its socket.
    AttachTransport,
    RequestKeyframe,
    /// The host's displays (pixel sizes) and the one streamed, from its answer.
    StreamDisplays {
        displays: Vec<(u32, u32)>,
        current: usize,
    },
    /// A round trip for the timings.
    SampleRtt {
        ms: Option<f64>,
    },
    /// A quality or display change needs a new hub session.
    Restart,
    /// An answer that is not a cmux.rd/1 document came (log it).
    BadAnswer,
}

/// The transport's state (the Mac's `RemoteRdStreamTransport` status).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "state")]
pub enum TransportState {
    Connecting,
    WaitingForConsent,
    Streaming,
    Ended {
        #[serde(flatten)]
        why: TransportEnd,
    },
}

/// Why a transport ended.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "why")]
pub enum TransportEnd {
    ConnectionLost,
    HostFailed {
        reason: String,
    },
    HostStoppedSharing,
    /// Any other end, in the app's words.
    Other {
        reason: String,
    },
}

/// What happened to the session.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "event")]
pub enum Event {
    /// A connect: whether the hub's ticket has signaling and whether the link process started.
    Connect {
        signaling: bool,
        process_started: bool,
    },
    Disconnect,
    /// The session socket is open (signaling `hello`).
    Hello,
    Answer {
        text: String,
    },
    Candidate {
        candidate: String,
        sdp_mid: Option<String>,
    },
    Bye,
    /// Signaling ended with an error.
    SignalingFailed,
    /// Sending the offer failed.
    OfferFailed,
    /// One line of the link process, and what the offer is made of if this line has the key.
    ProcessLine {
        line: Box<AppLine>,
        #[serde(default)]
        inputs: OfferInputs,
    },
    /// The link process's lines ended (it exited) with this stderr tail.
    ProcessExited {
        stderr_tail: String,
    },
    /// The link process has its answer.
    AnswerHanded,
    /// The socket directory or the transport could not be made.
    ViewerFailed,
    Transport {
        #[serde(flatten)]
        state: TransportState,
        rtt_ms: Option<f64>,
        stream_size: Option<Size>,
    },
    HostStats {
        kbps: f64,
        loss_percent: Option<f64>,
        encode_ms_p50: Option<f64>,
        encode_profile: Option<String>,
    },
    /// The connect deadline passed.
    DeadlinePassed,
    /// A frame reached the screen at `now_ms` (a monotonic clock).
    FramePresented {
        size: Size,
        now_ms: f64,
    },
    /// The frame counter's dropped frames.
    FramesDropped {
        dropped: f64,
    },
    StreamFrameSize {
        size: Size,
    },
    ApplyQuality,
    SelectDisplay {
        index: i64,
    },
    /// A run's screen link names this display (a CGDirectDisplayID).
    LinkDisplay {
        id: Option<u32>,
    },
    /// The viewer gallery's fixture: the session reads as this, with no process or network.
    Preview {
        phase: Phase,
        failure_cause: Option<FailureCause>,
        #[serde(default)]
        link_connected: bool,
        #[serde(default)]
        frame_size: Size,
        #[serde(default)]
        stalled: bool,
        stats: Option<Box<LiveStats>>,
        path: Option<String>,
    },
}

/// One session's state.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(default)]
pub struct Session {
    #[serde(flatten)]
    pub phase: Phase,
    /// Set with a failed phase when a side said why; cleared by the next connect.
    pub failure_cause: Option<FailureCause>,
    /// The secure link came up in this session.
    pub link_connected: bool,
    pub stats: LiveStats,
    pub frame_size: Size,
    pub stream_size: Size,
    /// The measured path's kind (`direct_lan`, ...); its label is [`path_label`].
    pub path_kind: Option<String>,
    /// A label the gallery set in place of the path's.
    pub path_text: Option<String>,
    pub is_stalled: bool,
    /// The stage a connect whose deadline passed was in.
    pub timed_out_stage: Option<Stage>,
    pub connect_stage: Stage,
    /// The display picked for the next session (an index; None: the host's main display).
    pub wanted_display: Option<i64>,
    /// The display a run's screen link names, asked for until the person picks one.
    pub linked_display: Option<u32>,
    /// The host's answer lists its display ids and the linked display is not one.
    pub linked_display_gone: bool,
    signaling_open: bool,
    pending_offer: Option<String>,
    offered: bool,
    awaiting_answer: bool,
    /// The link process has the host's answer: host candidates go to it at once.
    answer_handed: bool,
    /// The host's candidates that came before the link process had its answer.
    held_candidates: Vec<String>,
    asked_keyframe: bool,
    frame_window_start_ms: Option<f64>,
    frame_window_frames: u32,
}

impl Session {
    pub fn new() -> Self {
        Session::default()
    }

    /// The path's label as the toolbar shows it (None: `-`).
    pub fn path_label(&self) -> Option<Message> {
        if let Some(text) = &self.path_text {
            return Some(Message::said(text.clone()));
        }
        path_label(self.path_kind.as_deref())
    }

    pub fn apply(&mut self, event: Event) -> Vec<Effect> {
        let mut fx = Vec::new();
        match event {
            Event::Connect { signaling, process_started } => {
                self.connect(signaling, process_started, &mut fx);
            }
            Event::Disconnect => self.disconnect(&mut fx),
            Event::Hello => {
                self.signaling_open = true;
                if let Some(text) = self.pending_offer.take() {
                    fx.push(Effect::SendOffer { text });
                }
            }
            Event::Answer { text } => self.answer(&text, &mut fx),
            Event::Candidate { candidate, sdp_mid } => {
                if sdp_mid.as_deref() == Some("cmux-rd") {
                    // A candidate the host trickled right behind its answer waits until the
                    // answer has gone to the process.
                    if self.answer_handed {
                        fx.push(Effect::ProcessCandidate { candidate });
                    } else {
                        self.held_candidates.push(candidate);
                    }
                }
            }
            Event::Bye => self.end(Message::host_ended(), &mut fx),
            Event::SignalingFailed => {
                if self.phase == Phase::Connecting {
                    self.fail(Message::signaling_failed(), &mut fx);
                }
            }
            Event::OfferFailed => self.fail(Message::signaling_failed(), &mut fx),
            Event::ProcessLine { line, inputs } => self.process_line(*line, &inputs, &mut fx),
            Event::ProcessExited { stderr_tail } => {
                if self.phase == Phase::Connecting {
                    let message = if stderr_tail.is_empty() {
                        Message::viewer_stopped()
                    } else {
                        Message::said(stderr_tail)
                    };
                    self.fail(message, &mut fx);
                }
            }
            Event::AnswerHanded => {
                self.answer_handed = true;
                for candidate in std::mem::take(&mut self.held_candidates) {
                    fx.push(Effect::ProcessCandidate { candidate });
                }
            }
            Event::ViewerFailed => self.fail(Message::viewer_stopped(), &mut fx),
            Event::Transport { state, rtt_ms, stream_size } => {
                self.transport(state, rtt_ms, stream_size, &mut fx);
            }
            Event::HostStats { kbps, loss_percent, encode_ms_p50, encode_profile } => {
                self.stats.host_kbps = Some(kbps);
                self.stats.kilobytes_per_second = kbps / 8.0;
                self.stats.loss_percent = loss_percent;
                self.stats.encode_ms_p50 = encode_ms_p50;
                self.stats.encode_profile = encode_profile;
            }
            Event::DeadlinePassed => self.connect_timed_out(&mut fx),
            Event::FramePresented { size, now_ms } => self.frame_presented(size, now_ms, &mut fx),
            Event::FramesDropped { dropped } => self.stats.frames_dropped = dropped,
            Event::StreamFrameSize { size } => {
                if size.width >= 1.0 && size != self.frame_size {
                    self.frame_size = size;
                }
            }
            Event::ApplyQuality => {
                if self.phase.runs() {
                    fx.push(Effect::Restart);
                }
            }
            Event::SelectDisplay { index } => {
                self.wanted_display = Some(index);
                self.linked_display = None;
                self.linked_display_gone = false;
                if self.phase.runs() {
                    fx.push(Effect::Restart);
                }
            }
            Event::LinkDisplay { id } => self.linked_display = id,
            Event::Preview {
                phase,
                failure_cause,
                link_connected,
                frame_size,
                stalled,
                stats,
                path,
            } => {
                self.phase = phase;
                if let Some(stats) = stats {
                    self.stats = *stats;
                }
                if path.is_some() {
                    self.path_text = path;
                }
                self.failure_cause = failure_cause;
                self.link_connected = link_connected;
                self.frame_size = frame_size;
                self.is_stalled = stalled;
            }
        }
        fx
    }

    fn connect(&mut self, signaling: bool, process_started: bool, fx: &mut Vec<Effect>) {
        self.disconnect(fx);
        if !signaling {
            self.phase = Phase::failed(Message::no_ticket());
            return;
        }
        self.phase = Phase::Connecting;
        self.failure_cause = None;
        self.link_connected = false;
        self.timed_out_stage = None;
        self.connect_stage = Stage::Answer;
        self.is_stalled = false;
        self.frame_size = Size::default();
        self.stream_size = Size::default();
        self.stats = LiveStats::default();
        if !process_started {
            self.phase = Phase::failed(Message::no_binary());
            return;
        }
        // One deadline per connect: a picture cancels it, a disconnect or the next connect
        // replaces it.
        fx.push(Effect::ScheduleDeadline { ms: CONNECT_TIMEOUT_MS });
        self.signaling_open = false;
        self.pending_offer = None;
        self.offered = false;
        self.awaiting_answer = false;
        self.answer_handed = false;
        self.held_candidates.clear();
        self.asked_keyframe = false;
    }

    fn disconnect(&mut self, fx: &mut Vec<Effect>) {
        fx.push(Effect::Teardown);
        if self.phase.runs() {
            self.phase = Phase::Ended;
        }
    }

    fn end(&mut self, reason: Message, fx: &mut Vec<Effect>) {
        let was_connected = self.phase == Phase::Connected;
        self.disconnect(fx);
        self.phase = if was_connected { Phase::Ended } else { Phase::failed(reason) };
    }

    fn fail(&mut self, message: Message, fx: &mut Vec<Effect>) {
        self.disconnect(fx);
        self.phase = Phase::failed(message);
    }

    /// The host could not serve the session: a failure even after the picture started.
    fn host_failed(&mut self, reason: String, fx: &mut Vec<Effect>) {
        self.fail(Message::said(reason.clone()), fx);
        self.failure_cause = Some(FailureCause::Host(reason));
    }

    /// `cmux rd connect`'s `ended` line: the session ends, a failure naming who failed.
    fn link_ended(&mut self, reason: String, fx: &mut Vec<Effect>) {
        match failure_cause_of_ended(&reason) {
            Some(FailureCause::Host(why)) => self.host_failed(why, fx),
            Some(cause) => {
                self.end(Message::said(reason), fx);
                if matches!(self.phase, Phase::Failed { .. }) {
                    self.failure_cause = Some(cause);
                }
            }
            None => self.end(Message::said(reason), fx),
        }
    }

    /// The connect got past a stage (never back: a late answer does not undo a link).
    fn reach(&mut self, stage: Stage, fx: &mut Vec<Effect>) {
        if stage <= self.connect_stage {
            return;
        }
        self.connect_stage = stage;
        fx.push(Effect::Reached { stage });
        if stage == Stage::Shown {
            fx.push(Effect::CancelDeadline);
        }
    }

    fn connect_timed_out(&mut self, fx: &mut Vec<Effect>) {
        let stage = self.connect_stage;
        let Some(message) = Message::timed_out(stage) else { return };
        self.disconnect(fx);
        self.timed_out_stage = Some(stage);
        self.phase = Phase::failed(message);
    }

    fn answer(&mut self, text: &str, fx: &mut Vec<Effect>) {
        let Some(answer) = RdDocument::parse(text) else {
            fx.push(Effect::BadAnswer);
            return;
        };
        self.reach(Stage::Link, fx);
        if !answer.displays.is_empty() {
            fx.push(Effect::StreamDisplays {
                displays: answer.displays.clone(),
                current: answer.current_display.unwrap_or(0),
            });
        }
        if let Some(linked) = self.linked_display {
            self.linked_display_gone = lacks_display(&answer, linked);
        }
        if self.awaiting_answer {
            self.awaiting_answer = false;
            fx.push(Effect::SendAnswer { peer_key: answer.key, candidates: answer.candidates });
        }
    }

    fn process_line(&mut self, line: AppLine, inputs: &OfferInputs, fx: &mut Vec<Effect>) {
        if line.connected {
            self.reach(Stage::Frame, fx);
        }
        if let Some(key) = line.key.as_deref().filter(|_| !self.offered) {
            self.offered = true;
            let (offer, wish) = make_offer(key, inputs, self.wanted_display, self.linked_display);
            self.stats.target_fps = Some(wish.max_fps);
            self.awaiting_answer = true;
            // The signaling socket opens on its own: the offer waits for its `hello`.
            if self.signaling_open {
                fx.push(Effect::SendOffer { text: offer.text() });
            } else {
                self.pending_offer = Some(offer.text());
            }
        }
        if let Some(candidate) = line.candidate {
            fx.push(Effect::SignalCandidate { candidate });
        }
        if line.connected {
            self.link_connected = true;
        }
        if line.listening {
            fx.push(Effect::AttachTransport);
        }
        if let Some(path) = line.path {
            self.path_kind.clone_from(&path.kind);
            self.stats.latency_ms = path.rtt_ms;
            fx.push(Effect::SampleRtt { ms: path.rtt_ms });
            if let Some(kind) = &path.kind {
                fx.push(Effect::SignalPath { relay: is_relayed(kind) });
            }
        }
        if let Some(reason) = line.ended {
            self.link_ended(reason, fx);
        }
    }

    fn transport(
        &mut self,
        state: TransportState,
        rtt_ms: Option<f64>,
        stream_size: Option<Size>,
        fx: &mut Vec<Effect>,
    ) {
        if let Some(size) = stream_size.filter(|s| s.width >= 1.0 && s.height >= 1.0) {
            self.stream_size = size;
        }
        match state {
            TransportState::Streaming => {
                if !self.asked_keyframe {
                    self.asked_keyframe = true;
                    fx.push(Effect::RequestKeyframe);
                }
                self.reach(Stage::Frame, fx);
                self.phase = Phase::Connected;
                if let Some(rtt) = rtt_ms {
                    self.stats.latency_ms = Some(rtt);
                    fx.push(Effect::SampleRtt { ms: Some(rtt) });
                }
            }
            TransportState::Ended { why } => match why {
                TransportEnd::ConnectionLost => self.fail(Message::lost(), fx),
                TransportEnd::HostFailed { reason } => self.host_failed(reason, fx),
                TransportEnd::HostStoppedSharing => self.end(Message::host_ended(), fx),
                TransportEnd::Other { reason } => self.end(Message::said(reason), fx),
            },
            TransportState::Connecting | TransportState::WaitingForConsent => {}
        }
    }

    /// A frame reached the screen: counts it for the stats (once a second, no timer).
    fn frame_presented(&mut self, size: Size, now_ms: f64, fx: &mut Vec<Effect>) {
        if size != self.frame_size && size.width >= 1.0 {
            self.frame_size = size;
        }
        self.reach(Stage::Shown, fx);
        let start = *self.frame_window_start_ms.get_or_insert(now_ms);
        self.frame_window_frames += 1;
        self.stats.frames_decoded += 1.0;
        let elapsed = now_ms - start;
        if elapsed >= 1000.0 {
            self.stats.fps = f64::from(self.frame_window_frames) / (elapsed / 1000.0);
            self.frame_window_start_ms = Some(now_ms);
            self.frame_window_frames = 0;
        }
    }
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
