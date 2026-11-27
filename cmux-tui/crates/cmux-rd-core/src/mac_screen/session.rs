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
        line: AppLine,
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
        stats: Option<LiveStats>,
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
            Event::ProcessLine { line, inputs } => self.process_line(line, &inputs, &mut fx),
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
                    self.stats = stats;
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
mod tests {
    use super::*;
    use cmux_rd_proto::app_line::LinePath;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";

    fn connected() -> (Session, Vec<Effect>) {
        let mut s = Session::new();
        let fx = s.apply(Event::Connect { signaling: true, process_started: true });
        (s, fx)
    }

    fn line(f: impl FnOnce(&mut AppLine)) -> Event {
        let mut line = AppLine::default();
        f(&mut line);
        Event::ProcessLine { line, inputs: OfferInputs::default() }
    }

    fn answer_text(f: impl FnOnce(&mut RdDocument)) -> String {
        let mut doc = RdDocument { key: "cd".repeat(32), ..RdDocument::default() };
        f(&mut doc);
        doc.text()
    }

    fn streaming() -> Event {
        Event::Transport { state: TransportState::Streaming, rtt_ms: Some(4.0), stream_size: None }
    }

    /// MacScreenHostEndTests.theHostsFailedEndKeepsItsReason
    #[test]
    fn the_hosts_failed_end_keeps_its_reason() {
        assert_eq!(
            host_end("failed: capture: no frame"),
            HostEnd::HostFailed("capture: no frame".into())
        );
        assert_eq!(host_end("failed"), HostEnd::HostFailed(String::new()));
        assert_eq!(host_end("stopped by the host"), HostEnd::HostStoppedSharing);
        assert_eq!(host_end("failedness"), HostEnd::HostStoppedSharing);
    }

    /// MacScreenHostEndTests.theLinkBridgesEndNamesWhoFailed
    #[test]
    fn the_link_bridges_end_names_who_failed() {
        let cause = failure_cause_of_ended;
        assert_eq!(
            cause("host: failed: capture: denied"),
            Some(FailureCause::Host("capture: denied".into()))
        );
        assert_eq!(cause("host: stopped by the host"), None);
        assert_eq!(
            cause("link failed: no route (2 routes)"),
            Some(FailureCause::Link("no route (2 routes)".into()))
        );
        assert_eq!(cause("failed: pane socket"), Some(FailureCause::Link("pane socket".into())));
        assert_eq!(cause("the host ended the session"), None);
        assert_eq!(cause("stopped by the viewer"), None);
    }

    #[test]
    fn path_kinds_label_and_relay() {
        assert_eq!(path_label(Some("direct_lan")).unwrap().text, "Direct (local network)");
        assert_eq!(
            path_label(Some("direct_wan")).unwrap().key.as_deref(),
            Some("macScreen.rd.pathDirect")
        );
        for kind in ["turn_relay", "do_relay", "via_cloud_region"] {
            assert_eq!(path_label(Some(kind)).unwrap().text, "Relayed");
        }
        assert_eq!(path_label(Some("tailnet")), None);
        assert_eq!(path_label(None), None);
    }

    #[test]
    fn a_connect_without_a_ticket_or_a_viewer_fails_with_its_words() {
        let mut s = Session::new();
        s.apply(Event::Connect { signaling: false, process_started: false });
        assert_eq!(s.phase, Phase::failed(Message::no_ticket()));
        s.apply(Event::Connect { signaling: true, process_started: false });
        assert_eq!(s.phase, Phase::failed(Message::no_binary()));
        let (s, fx) = connected();
        assert_eq!(s.phase, Phase::Connecting);
        assert_eq!(fx, [Effect::Teardown, Effect::ScheduleDeadline { ms: 15_000 }]);
    }

    /// The offer waits for the socket's hello; the answer goes to the link process once, and a
    /// candidate trickled before it waits until the process has it.
    #[test]
    fn the_offer_waits_for_hello_and_candidates_wait_for_the_answer() {
        let (mut s, _) = connected();
        assert!(s.apply(line(|l| l.key = Some(KEY.into()))).is_empty());
        assert_eq!(s.stats.target_fps, Some(60));
        let fx = s.apply(Event::Hello);
        let [Effect::SendOffer { text }] = fx.as_slice() else { panic!("{fx:?}") };
        assert!(text.starts_with("cmux.rd/1\r\n") && text.contains(KEY));
        // A second key line makes no second offer.
        assert!(s.apply(line(|l| l.key = Some(KEY.into()))).is_empty());
        let early = Event::Candidate { candidate: "c1".into(), sdp_mid: Some("cmux-rd".into()) };
        assert!(s.apply(early).is_empty());
        assert!(
            s.apply(Event::Candidate { candidate: "x".into(), sdp_mid: Some("0".into()) })
                .is_empty()
        );
        let fx = s.apply(Event::Answer { text: answer_text(|d| d.candidates = vec!["h".into()]) });
        assert_eq!(
            fx,
            [
                Effect::Reached { stage: Stage::Link },
                Effect::SendAnswer { peer_key: "cd".repeat(32), candidates: vec!["h".into()] }
            ]
        );
        assert_eq!(
            s.apply(Event::AnswerHanded),
            [Effect::ProcessCandidate { candidate: "c1".into() }]
        );
        let late = Event::Candidate { candidate: "c2".into(), sdp_mid: Some("cmux-rd".into()) };
        assert_eq!(s.apply(late), [Effect::ProcessCandidate { candidate: "c2".into() }]);
        // A repeated answer is not handed again, and the stage never moves back.
        assert!(s.apply(Event::Answer { text: answer_text(|_| {}) }).is_empty());
        assert!(matches!(
            s.apply(Event::Answer { text: "v=0".into() }).as_slice(),
            [Effect::BadAnswer]
        ));
    }

    #[test]
    fn an_open_socket_sends_the_offer_at_once() {
        let (mut s, _) = connected();
        s.apply(Event::Hello);
        let fx = s.apply(line(|l| l.key = Some(KEY.into())));
        assert!(matches!(fx.as_slice(), [Effect::SendOffer { .. }]));
    }

    /// MacScreenConnectDeadlineTests: the deadline fails naming the stage; a picture cancels it.
    #[test]
    fn the_deadline_names_the_stage_and_a_picture_cancels_it() {
        let (mut s, _) = connected();
        s.apply(Event::DeadlinePassed);
        assert_eq!(s.timed_out_stage, Some(Stage::Answer));
        let Phase::Failed { message, .. } = &s.phase else { panic!() };
        assert_eq!(message.key.as_deref(), Some("macScreen.card.noAnswer"));
        assert!(message.names_host);

        let (mut s, _) = connected();
        s.apply(Event::Answer { text: answer_text(|_| {}) });
        s.apply(line(|l| l.connected = true));
        assert!(s.link_connected);
        s.apply(Event::DeadlinePassed);
        assert_eq!(s.timed_out_stage, Some(Stage::Frame));

        let (mut s, _) = connected();
        let fx =
            s.apply(Event::FramePresented { size: Size { width: 10.0, height: 5.0 }, now_ms: 0.0 });
        assert_eq!(fx, [Effect::Reached { stage: Stage::Shown }, Effect::CancelDeadline]);
        assert!(s.apply(Event::DeadlinePassed).is_empty());
        assert_eq!(s.phase, Phase::Connecting);
        // A new connect starts over.
        s.apply(Event::Connect { signaling: true, process_started: true });
        assert_eq!(
            (s.connect_stage, s.timed_out_stage, s.frame_size),
            (Stage::Answer, None, Size::default())
        );
    }

    #[test]
    fn streaming_asks_one_keyframe_and_connects() {
        let (mut s, _) = connected();
        let fx = s.apply(streaming());
        assert_eq!(
            fx,
            [
                Effect::RequestKeyframe,
                Effect::Reached { stage: Stage::Frame },
                Effect::SampleRtt { ms: Some(4.0) }
            ]
        );
        assert_eq!((s.phase.clone(), s.stats.latency_ms), (Phase::Connected, Some(4.0)));
        assert_eq!(s.apply(streaming()), [Effect::SampleRtt { ms: Some(4.0) }]);
        let size = Some(Size { width: 1920.0, height: 1080.0 });
        s.apply(Event::Transport {
            state: TransportState::Connecting,
            rtt_ms: None,
            stream_size: size,
        });
        assert_eq!(Some(s.stream_size), size);
    }

    /// An end after the picture is a plain end; before it, a failure; the host's failure is
    /// always a failure with its reason.
    #[test]
    fn transport_ends_read_like_the_mac() {
        let (mut s, _) = connected();
        s.apply(streaming());
        s.apply(Event::Transport {
            state: TransportState::Ended { why: TransportEnd::HostStoppedSharing },
            rtt_ms: None,
            stream_size: None,
        });
        assert_eq!(s.phase, Phase::Ended);

        let (mut s, _) = connected();
        s.apply(Event::Bye);
        assert_eq!(s.phase, Phase::failed(Message::host_ended()));

        let (mut s, _) = connected();
        s.apply(streaming());
        let host = TransportEnd::HostFailed { reason: "capture".into() };
        s.apply(Event::Transport {
            state: TransportState::Ended { why: host },
            rtt_ms: None,
            stream_size: None,
        });
        assert_eq!(s.phase, Phase::failed(Message::said("capture")));
        assert_eq!(s.failure_cause, Some(FailureCause::Host("capture".into())));

        let (mut s, _) = connected();
        s.apply(streaming());
        let lost = TransportState::Ended { why: TransportEnd::ConnectionLost };
        s.apply(Event::Transport { state: lost, rtt_ms: None, stream_size: None });
        assert_eq!(s.phase, Phase::failed(Message::lost()));
    }

    #[test]
    fn the_links_ended_line_names_who_failed() {
        let (mut s, _) = connected();
        s.apply(line(|l| l.ended = Some("link failed: no route".into())));
        assert_eq!(s.phase, Phase::failed(Message::said("link failed: no route")));
        assert_eq!(s.failure_cause, Some(FailureCause::Link("no route".into())));

        let (mut s, _) = connected();
        s.apply(streaming());
        s.apply(line(|l| l.ended = Some("failed: pane socket".into())));
        assert_eq!(
            (s.phase.clone(), s.failure_cause.clone()),
            (Phase::Ended, None),
            "after the picture"
        );

        let (mut s, _) = connected();
        s.apply(streaming());
        s.apply(line(|l| l.ended = Some("host: failed: capture: denied".into())));
        assert_eq!(s.failure_cause, Some(FailureCause::Host("capture: denied".into())));

        let (mut s, _) = connected();
        s.apply(line(|l| l.ended = Some("stopped by the viewer".into())));
        assert_eq!(
            (s.phase.clone(), s.failure_cause.clone()),
            (Phase::failed(Message::said("stopped by the viewer")), None)
        );
        // A new connect forgets the cause.
        s.apply(Event::Connect { signaling: true, process_started: true });
        assert_eq!(s.failure_cause, None);
    }

    #[test]
    fn process_and_signaling_ends_fail_only_while_connecting() {
        let (mut s, _) = connected();
        s.apply(Event::ProcessExited { stderr_tail: String::new() });
        assert_eq!(s.phase, Phase::failed(Message::viewer_stopped()));
        let (mut s, _) = connected();
        s.apply(Event::ProcessExited { stderr_tail: "boom".into() });
        assert_eq!(s.phase, Phase::failed(Message::said("boom")));
        let (mut s, _) = connected();
        s.apply(streaming());
        assert!(s.apply(Event::ProcessExited { stderr_tail: "boom".into() }).is_empty());
        assert!(s.apply(Event::SignalingFailed).is_empty());
        assert_eq!(s.phase, Phase::Connected);
        s.apply(Event::OfferFailed);
        assert_eq!(s.phase, Phase::failed(Message::signaling_failed()));
    }

    #[test]
    fn the_path_line_labels_signals_and_samples() {
        let (mut s, _) = connected();
        let fx = s.apply(line(|l| {
            l.path = Some(LinePath { kind: Some("turn_relay".into()), rtt_ms: Some(30.0) });
            l.candidate = Some("srflx".into());
            l.listening = true;
        }));
        assert_eq!(
            fx,
            [
                Effect::SignalCandidate { candidate: "srflx".into() },
                Effect::AttachTransport,
                Effect::SampleRtt { ms: Some(30.0) },
                Effect::SignalPath { relay: true }
            ]
        );
        assert_eq!(s.path_label().unwrap().text, "Relayed");
        assert_eq!(s.stats.latency_ms, Some(30.0));
    }

    /// The run's linked display: asked for by id until a pick; a host that lacks it says so.
    #[test]
    fn the_linked_display_is_asked_for_until_a_pick() {
        let (mut s, _) = connected();
        s.apply(Event::LinkDisplay { id: Some(77) });
        s.apply(Event::Hello);
        let fx = s.apply(line(|l| l.key = Some(KEY.into())));
        let [Effect::SendOffer { text }] = fx.as_slice() else { panic!() };
        assert!(text.contains("a=cmux-rd-display-id:77\r\n"));
        let fx = s.apply(Event::Answer {
            text: answer_text(|d| {
                d.displays = vec![(100, 50), (200, 100)];
                d.display_ids = vec![1, 2];
                d.current_display = Some(1);
            }),
        });
        assert!(fx.contains(&Effect::StreamDisplays {
            displays: vec![(100, 50), (200, 100)],
            current: 1
        }));
        assert!(s.linked_display_gone);
        assert_eq!(s.apply(Event::SelectDisplay { index: 1 }), [Effect::Restart]);
        assert_eq!(
            (s.wanted_display, s.linked_display, s.linked_display_gone),
            (Some(1), None, false)
        );
        s.apply(Event::Disconnect);
        assert_eq!(s.phase, Phase::Ended);
        assert!(s.apply(Event::ApplyQuality).is_empty(), "no session to restart");
    }

    #[test]
    fn frames_count_once_a_second() {
        let (mut s, _) = connected();
        let size = Size { width: 100.0, height: 50.0 };
        for i in 0..30 {
            s.apply(Event::FramePresented { size, now_ms: f64::from(i) * 30.0 });
        }
        assert_eq!(s.stats.fps, 0.0);
        s.apply(Event::FramePresented { size, now_ms: 1250.0 });
        assert!((s.stats.fps - 31.0 / 1.25).abs() < 1e-9);
        assert_eq!((s.stats.frames_decoded, s.frame_size), (31.0, size));
        s.apply(Event::HostStats {
            kbps: 8000.0,
            loss_percent: Some(1.5),
            encode_ms_p50: None,
            encode_profile: Some("ultra".into()),
        });
        assert_eq!((s.stats.host_kbps, s.stats.kilobytes_per_second), (Some(8000.0), 1000.0));
    }

    #[test]
    fn the_state_and_events_speak_json() {
        let (s, _) = connected();
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["phase"], "connecting");
        assert_eq!(json["connect_stage"], "answer");
        let event: Event = serde_json::from_value(serde_json::json!({
            "event": "transport", "state": "ended", "why": "host_failed", "reason": "x"
        }))
        .unwrap();
        assert_eq!(
            event,
            Event::Transport {
                state: TransportState::Ended {
                    why: TransportEnd::HostFailed { reason: "x".into() }
                },
                rtt_ms: None,
                stream_size: None
            }
        );
        let line: Event = serde_json::from_value(serde_json::json!({
            "event": "process_line", "line": {"key": KEY}, "inputs": {"quality": "high", "refresh": 120}
        }))
        .unwrap();
        let mut s = Session::new();
        s.apply(Event::Connect { signaling: true, process_started: true });
        s.apply(Event::Hello);
        let fx = s.apply(line);
        let [Effect::SendOffer { text }] = fx.as_slice() else { panic!() };
        assert!(text.contains("a=cmux-rd-max-fps:60\r\n") && !text.contains("max-width"));
        let failed = serde_json::to_value(Phase::failed(Message::lost())).unwrap();
        assert_eq!(failed["phase"], "failed");
        assert_eq!(failed["message"]["key"], "macScreen.rd.lost");
    }
}
