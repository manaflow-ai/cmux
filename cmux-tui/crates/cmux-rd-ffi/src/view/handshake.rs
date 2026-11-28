//! The viewer's side of the `cmux.rd/1` session setup as a pure reducer (was
//! `RemoteRdHandshake.swift`): hello and start go out, then the host answers
//! welcome and started (or refused); ended closes the session. Every other
//! order is a protocol error and ends the session.

use cmux_rd_proto::control::Control;
use serde::{Deserialize, Serialize};

use super::control::{Incoming, Welcome};
use super::pane::{SessionEnd, SessionState};

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Phase {
    #[default]
    AwaitingWelcome,
    AwaitingStarted,
    Streaming {
        session: u64,
    },
    Ended {
        end: SessionEnd,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Handshake {
    #[serde(default)]
    pub phase: Phase,
    #[serde(default)]
    pub welcome: Option<Welcome>,
    /// The service the hello asked for; welcome must name the same one.
    pub service: String,
    /// True after the viewer sent stop: the host's ended then means "stopped by viewer".
    #[serde(default)]
    pub stop_sent: bool,
}

impl Handshake {
    pub fn new(service: &str) -> Self {
        Self {
            phase: Phase::AwaitingWelcome,
            welcome: None,
            service: service.to_owned(),
            stop_sent: false,
        }
    }

    /// The pane-facing state of the current phase.
    pub fn session_state(&self) -> SessionState {
        match &self.phase {
            Phase::AwaitingWelcome | Phase::AwaitingStarted => SessionState::Connecting,
            Phase::Streaming { .. } => SessionState::Streaming,
            Phase::Ended { end } => SessionState::Ended { reason: end.clone() },
        }
    }

    pub fn is_ended(&self) -> bool {
        matches!(self.phase, Phase::Ended { .. })
    }

    pub fn is_streaming(&self) -> bool {
        matches!(self.phase, Phase::Streaming { .. })
    }

    fn end(&mut self, end: SessionEnd) {
        self.phase = Phase::Ended { end };
    }

    /// Applies one control message from the host.
    pub fn receive(&mut self, incoming: &Incoming) {
        if self.is_ended() {
            return;
        }
        match (&self.phase, incoming) {
            (Phase::AwaitingWelcome, Incoming::Welcome { welcome }) => {
                // A host older than C1 omits the service; a mismatch is a protocol error.
                if welcome.service.as_ref().is_some_and(|routed| *routed != self.service) {
                    self.end(SessionEnd::ConnectionLost);
                    return;
                }
                self.welcome = Some(welcome.clone());
                self.phase = Phase::AwaitingStarted;
            }
            (
                Phase::AwaitingStarted,
                Incoming::Control { control: Control::Started { session } },
            ) => {
                self.phase = Phase::Streaming { session: *session };
            }
            (_, Incoming::Control { control: Control::Refused { .. } }) => {
                self.end(SessionEnd::ConsentDenied);
            }
            (_, Incoming::Control { control: Control::Ended { reason } }) => {
                let end =
                    if self.stop_sent { SessionEnd::StoppedByViewer } else { host_end(reason) };
                self.end(end);
            }
            (_, Incoming::Unknown { .. }) => {}
            (_, Incoming::Control { control }) if passes_through(control) => {}
            _ => self.end(SessionEnd::ConnectionLost),
        }
    }

    /// The viewer sent stop.
    pub fn viewer_stopped(&mut self) {
        self.stop_sent = true;
    }

    /// The carrier closed or failed.
    pub fn connection_closed(&mut self) {
        if self.is_ended() {
            return;
        }
        let end =
            if self.stop_sent { SessionEnd::StoppedByViewer } else { SessionEnd::ConnectionLost };
        self.end(end);
    }
}

/// Messages that go to their own handlers, not the setup: service, bulk,
/// stream, stats, and the ones the Swift codec read as unknown (clipboard,
/// link). A cursor shape also passes: the Swift reducer listed every other
/// side message but not `cursor_shape` (added later, with the `cursor` cap),
/// so there a host's first cursor shape ended the session as a protocol error.
fn passes_through(control: &Control) -> bool {
    matches!(
        control,
        Control::Stats { .. }
            | Control::Service { .. }
            | Control::BulkCredit { .. }
            | Control::StreamOpen { .. }
            | Control::StreamOpened { .. }
            | Control::StreamRefused { .. }
            | Control::StreamClose { .. }
            | Control::CursorShape { .. }
            | Control::Clipboard { .. }
            | Control::LinkOffer { .. }
            | Control::LinkAnswer { .. }
            | Control::LinkCandidate { .. }
            | Control::LinkState { .. }
    )
}

/// What the host's `ended` means (`RemoteRdHandshake.hostEnd`): `cmux rd
/// serve` ends a session it could not run with `failed: <error>`
/// (cmux-rd-host `serve.rs`), and that error is kept for the card; any other
/// reason (stopped, the viewer left) is the host stopping.
pub fn host_end(reason: &str) -> SessionEnd {
    let text = reason.trim();
    let Some(rest) = text.strip_prefix("failed") else {
        return SessionEnd::HostStoppedSharing;
    };
    if !rest.is_empty() && !rest.starts_with(':') {
        return SessionEnd::HostStoppedSharing;
    }
    SessionEnd::HostFailed { reason: rest.trim_start_matches([':', ' ']).to_owned() }
}
