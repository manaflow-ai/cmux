//! This Mac serving one approved device hub session (the Mac's `MacScreenRdHost`): which
//! protocol the viewer's first offer picks (cmux.rd/1 starts `cmux rd serve`, anything else is
//! a WebRTC viewer whose signals all go to the WebRTC host), the setup line the serve process
//! gets, the answer built from the process's lines and sent once its host candidates are known,
//! candidates both ways, and how the session ends. Events in, effects out: the app runs the
//! process, the signaling, the deadline and the capture exclusions an effect names.

use cmux_rd_proto::app_line::AppLine;
use cmux_rd_proto::rd_doc::{RdDocument, Turn, is_relayed};
use serde::{Deserialize, Serialize};

/// How long the started host may take to answer (its key and candidates).
pub const ANSWER_TIMEOUT_MS: u64 = 15_000;
/// The most stderr a serve or connect process keeps for its exit's words.
pub const STDERR_TAIL_BYTES: usize = 4096;
/// The serve's frame rate is capped at this, whatever the viewer asks.
const MAX_FPS: u32 = 120;

/// The approved session this host serves.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(default)]
pub struct HostSession {
    pub id: String,
    pub viewer_id: String,
    pub view_only: bool,
    pub stun: Vec<String>,
    pub turn: Vec<Turn>,
}

/// The viewer of `cmux rd serve`'s setup line.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct SetupViewer {
    pub user: String,
    pub install: String,
}

/// `cmux rd serve`'s setup line (cmux-rd-host `serve.rs`).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Setup {
    pub session: String,
    pub peer_key: String,
    pub viewer: SetupViewer,
    pub scope: String,
    pub stun: Vec<String>,
    pub turn: Vec<Turn>,
    pub display: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_fps: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_width: Option<u32>,
    /// The viewer's Customize wishes (absent: the host's defaults).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_kbps: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<bool>,
    /// The viewer's `a=cmux-rd-encode-profile:` (`ultra`); absent for the standard profile.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encode_profile: Option<String>,
}

/// The setup line for a viewer's offer.
pub fn setup(session: &HostSession, offer: &RdDocument) -> Setup {
    Setup {
        session: session.id.clone(),
        peer_key: offer.key.clone(),
        viewer: SetupViewer { user: session.viewer_id.clone(), install: session.viewer_id.clone() },
        scope: if session.view_only { "view" } else { "control" }.to_owned(),
        stun: session.stun.clone(),
        turn: session.turn.clone(),
        display: offer.display.map_or_else(|| "main".to_owned(), |d| d.to_string()),
        max_fps: offer.max_fps.map(|fps| fps.min(MAX_FPS)),
        max_width: offer.max_width,
        max_kbps: offer.max_kbps,
        cursor: offer.cursor,
        encode_profile: offer.encode_profile.clone(),
    }
}

/// A line's kinds for the log, so a session's log shows the stage it reached.
pub fn line_kinds(line: &AppLine) -> String {
    let fields = [
        (line.displays.is_some(), "displays"),
        (line.current.is_some(), "current"),
        (line.key.is_some(), "key"),
        (line.candidate.is_some(), "candidate"),
        (line.candidates_done, "candidates_done"),
        (line.connected, "connected"),
        (line.listening, "listening"),
        (line.path.is_some(), "path"),
        (line.error.is_some(), "error"),
        (line.ended.is_some(), "ended"),
    ];
    let names: Vec<&str> = fields.iter().filter(|(on, _)| *on).map(|(_, name)| *name).collect();
    if names.is_empty() { "unknown".to_owned() } else { names.join(" ") }
}

/// Keeps the last [`STDERR_TAIL_BYTES`] of a process's stderr.
pub fn push_stderr_tail(tail: &mut Vec<u8>, data: &[u8]) {
    tail.extend_from_slice(data);
    if tail.len() > STDERR_TAIL_BYTES {
        tail.drain(..tail.len() - STDERR_TAIL_BYTES);
    }
}

/// What the host tells the hub host.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "kind", content = "reason")]
pub enum HostEvent {
    /// The viewer's link is up.
    ViewerConnected,
    /// The session ended (the viewer left, the link failed, or Stop).
    ViewerEnded(String),
    /// The host could not start or serve (no capture permission, no display, no answer).
    SourceFailed(String),
}

/// What the app does for the host.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "effect")]
pub enum HostEffect {
    /// A WebRTC viewer: start the WebRTC host and give it this signal and every later one.
    ServeWebRtc,
    /// Give the WebRTC host this signal.
    Forward,
    /// Start `cmux rd serve` (in the helper when there is one), then send
    /// [`HostInput::ServeStarted`].
    StartServe,
    /// One JSON line for the serve process's stdin.
    ProcessSend {
        line: serde_json::Value,
    },
    /// Start sending the process the windows its capture leaves out (`exclude_windows`).
    WatchExclusions,
    ScheduleAnswerDeadline {
        ms: u64,
    },
    CancelAnswerDeadline,
    /// Send the cmux.rd/1 answer over signaling.
    SendAnswer {
        text: String,
    },
    /// A host candidate for the viewer, over signaling (`sdpMid` `cmux-rd`).
    SendCandidate {
        candidate: String,
    },
    SendPath {
        relay: bool,
    },
    Emit {
        event: HostEvent,
    },
    /// Stop the serve process (and stop reading its lines).
    StopProcess,
    /// The session's signaling is done: serve returns.
    EndServe,
    /// An offer that starts nothing (logged with why).
    OfferIgnored {
        why: String,
    },
}

/// What happened to the host.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "snake_case", tag = "input")]
pub enum HostInput {
    Offer {
        text: String,
    },
    Candidate {
        candidate: String,
        sdp_mid: Option<String>,
    },
    Bye,
    /// Any other signal (a WebRTC viewer's gets forwarded).
    Other,
    /// Whether `cmux rd serve` started, with the error's words if not.
    ServeStarted {
        error: Option<String>,
    },
    ProcessLine {
        line: Box<AppLine>,
    },
    /// The serve process's lines ended; `cancelled` when this session's reader was cancelled.
    ProcessExited {
        #[serde(default)]
        stderr_tail: String,
        #[serde(default)]
        cancelled: bool,
    },
    AnswerTimedOut,
    /// Stop: the viewer sees the link close.
    Disconnect,
}

/// One served session.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(default)]
pub struct Host {
    pub session: HostSession,
    /// An offer started a host (rd or WebRTC).
    pub started: bool,
    /// A WebRTC viewer: every signal goes to the WebRTC host.
    pub web_rtc: bool,
    /// The serve process started.
    pub process_started: bool,
    pub connected: bool,
    answered: bool,
    answer: Option<RdDocument>,
    pending_offer: Option<RdDocument>,
    /// The process's lines are done with (an `ended`, a timeout, a stop).
    lines_done: bool,
}

impl Host {
    pub fn new(session: HostSession) -> Self {
        Host { session, ..Host::default() }
    }

    pub fn apply(&mut self, input: HostInput) -> Vec<HostEffect> {
        let mut fx = Vec::new();
        if self.web_rtc
            && matches!(
                input,
                HostInput::Offer { .. }
                    | HostInput::Candidate { .. }
                    | HostInput::Bye
                    | HostInput::Other
            )
        {
            fx.push(HostEffect::Forward);
            return fx;
        }
        match input {
            HostInput::Offer { text } => self.offer(&text, &mut fx),
            HostInput::Candidate { candidate, sdp_mid } => {
                if sdp_mid.as_deref() == Some("cmux-rd") {
                    fx.push(HostEffect::ProcessSend {
                        line: serde_json::json!({ "candidate": candidate }),
                    });
                }
            }
            HostInput::Bye => {
                fx.push(HostEffect::StopProcess);
                fx.push(HostEffect::EndServe);
            }
            HostInput::Other => {}
            HostInput::ServeStarted { error } => self.serve_started(error, &mut fx),
            HostInput::ProcessLine { line } => {
                if !self.lines_done {
                    self.line(*line, &mut fx);
                }
            }
            HostInput::ProcessExited { stderr_tail, cancelled } => {
                if !self.lines_done && !cancelled {
                    self.lines_done = true;
                    // Its own words, never a grant's: the process (the helper) just ended.
                    let stopped = "the screen host exited without saying why";
                    let words = if stderr_tail.is_empty() {
                        stopped.to_owned()
                    } else {
                        format!("{stopped}: {stderr_tail}")
                    };
                    fx.push(HostEffect::Emit { event: HostEvent::SourceFailed(words) });
                }
            }
            HostInput::AnswerTimedOut => {
                if !self.answered && !self.lines_done {
                    self.lines_done = true;
                    fx.push(HostEffect::StopProcess);
                    fx.push(HostEffect::Emit {
                        event: HostEvent::SourceFailed("the screen host did not answer".into()),
                    });
                }
            }
            HostInput::Disconnect => {
                self.lines_done = true;
                fx.push(HostEffect::CancelAnswerDeadline);
                fx.push(HostEffect::StopProcess);
            }
        }
        fx
    }

    fn offer(&mut self, text: &str, fx: &mut Vec<HostEffect>) {
        let parsed = RdDocument::parse(text);
        if self.started {
            fx.push(HostEffect::OfferIgnored { why: "already serving".into() });
            return;
        }
        self.started = true;
        match parsed {
            None => {
                self.web_rtc = true;
                fx.push(HostEffect::ServeWebRtc);
            }
            Some(offer) => {
                self.pending_offer = Some(offer);
                fx.push(HostEffect::StartServe);
            }
        }
    }

    fn serve_started(&mut self, error: Option<String>, fx: &mut Vec<HostEffect>) {
        let Some(offer) = self.pending_offer.take() else { return };
        if let Some(error) = error {
            self.lines_done = true;
            fx.push(HostEffect::Emit {
                event: HostEvent::SourceFailed(format!("the screen host could not start: {error}")),
            });
            fx.push(HostEffect::EndServe);
            return;
        }
        self.process_started = true;
        // The helper answers in under a second; one that has not by the deadline never will.
        fx.push(HostEffect::ScheduleAnswerDeadline { ms: ANSWER_TIMEOUT_MS });
        let setup = serde_json::to_value(setup(&self.session, &offer)).unwrap_or_default();
        fx.push(HostEffect::ProcessSend { line: setup });
        fx.push(HostEffect::WatchExclusions);
        for candidate in offer.candidates {
            fx.push(HostEffect::ProcessSend {
                line: serde_json::json!({ "candidate": candidate }),
            });
        }
    }

    fn line(&mut self, line: AppLine, fx: &mut Vec<HostEffect>) {
        if let Some(displays) = line.displays {
            let doc = self.answer.get_or_insert_with(RdDocument::default);
            doc.displays = displays;
            doc.current_display = line.current;
        }
        if let Some(key) = line.key {
            self.answer.get_or_insert_with(RdDocument::default).key = key;
        }
        if let Some(candidate) = line.candidate {
            if self.answered {
                fx.push(HostEffect::SendCandidate { candidate });
            } else if let Some(doc) = &mut self.answer {
                doc.candidates.push(candidate);
            }
        }
        // The answer goes once this side's host candidates are known (serve says
        // candidates_done then); reflexive and relayed ones trickle after it.
        if line.candidates_done
            && !self.answered
            && let Some(doc) = &self.answer
        {
            self.answered = true;
            fx.push(HostEffect::CancelAnswerDeadline);
            fx.push(HostEffect::SendAnswer { text: doc.text() });
        }
        if line.connected && !self.connected {
            self.connected = true;
            fx.push(HostEffect::Emit { event: HostEvent::ViewerConnected });
        }
        if let Some(kind) = line.path.and_then(|p| p.kind) {
            fx.push(HostEffect::SendPath { relay: is_relayed(&kind) });
        }
        if let Some(reason) = line.ended {
            self.lines_done = true;
            let event = if self.connected {
                HostEvent::ViewerEnded(reason)
            } else {
                HostEvent::SourceFailed(reason)
            };
            fx.push(HostEffect::Emit { event });
        }
    }
}

#[cfg(test)]
#[path = "rd_host_tests.rs"]
mod tests;
