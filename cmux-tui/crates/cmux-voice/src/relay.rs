//! Voice mode as a pure reducer: a spoken line to the chat's agent (events in, effects out).
//!
//! Voice mode is a **relay** (design `docs/design/voice-byo-providers.md`, decision 1): what the
//! person says becomes a prompt to the chat's agent, and what the agent writes is read aloud. The
//! voice never answers on its own and holds no tools. This is the iPhone's `AgentVoiceSession`
//! (`cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileRealtime/AgentVoiceSession.swift`) moved here so
//! the desktop, the iPhone and the web page draw one lifecycle instead of writing it again.
//!
//! The reducer does no I/O and reads no clock. Two transports drive it with the same events:
//!
//! - **Cascade** ([`Transport::Cascade`]): any dictation provider hears the person ([`Event::UserDone`]
//!   per utterance), local voice detection ([`crate::vad`]) reports speech start and stop, and a
//!   text-to-speech engine (the system voice, or an OpenAI-style `/audio/speech` endpoint) carries out
//!   [`Effect::Read`]. Local voice detection is the only barge-in, so a person who starts speaking
//!   over a reading makes the reducer cancel it ([`Effect::CancelReading`]).
//! - **Speech to speech** ([`Transport::Realtime`]): the service the iPhone uses, configured as a relay
//!   ([`crate::realtime`]): server voice detection cuts the reading off itself, so the reducer only
//!   records that the reading was cancelled.
//!
//! The rules, each kept from the iPhone (and its 2026-11-03 review):
//!
//! - Readings go one at a time, in order; text queued behind a reading goes out as one reading.
//! - Nothing is read over the person: a reading waits for speech to stop.
//! - A finished utterance that is noise ([`crate::speech::is_noise`]) is never a prompt.
//! - A reading cut off by the person's voice is said again when what followed was only noise, and
//!   dropped when the person said something real.
//! - A reading refused because another response is active is said again once it ends; a reading
//!   refused for any other reason is retried once, then dropped, and voice mode goes on.
//! - Skip stops the reading and drops the queue. Ending reports once.
//! - Text relayed while connecting is read once live.

use crate::error::{ErrorCode, VoiceError};
use crate::speech::is_noise;

/// How the person's voice and the agent's reading travel (the `realtimeVoice` capability's two
/// shapes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    /// A dictation provider in, a text-to-speech engine out, local voice detection for barge-in.
    Cascade,
    /// One speech-to-speech service doing both, with server voice detection.
    Realtime,
}

/// Where voice mode stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    /// The transport is being opened; text relayed now is read once live.
    Connecting,
    Live,
    /// Over, with the failure if any.
    Ended(Option<VoiceError>),
}

/// Whose words a caption holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// What the person said: sent to the agent.
    You,
    /// The agent's words, as read aloud.
    Agent,
}

/// One caption.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub id: String,
    pub role: Role,
    pub text: String,
    pub is_final: bool,
}

/// Captions only need the recent past.
pub const MAX_LINES: usize = 40;

/// Why a reading was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// Another response is active: say it again once that one ends.
    Busy,
    /// Anything else (a rate limit, invalid input): retry once, then drop.
    Other,
}

/// What happened, from the transport, the agent or the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The transport is open.
    Connected,
    /// New words from the agent, already speakable ([`crate::speech::Speech::speakable`]).
    AgentText(String),
    /// The person started speaking (voice detection). `item` names the utterance when known.
    SpeechStarted {
        item: Option<String>,
    },
    SpeechStopped,
    /// More of what the person is saying.
    UserDelta {
        item: String,
        text: String,
    },
    /// The person's finished utterance.
    UserDone {
        item: String,
        text: String,
    },
    /// The utterance could not be transcribed.
    UserFailed {
        item: String,
    },
    /// The reading in flight started (`response.created`; a cascade's speech engine began).
    ReadingStarted,
    /// The reading in flight ended; `cancelled` when it was cut off.
    ReadingDone {
        cancelled: bool,
    },
    /// The reading asked for was refused and will not start.
    ReadingRefused(Refusal),
    /// Caption words of the reading (a speech-to-speech service's transcript of its own audio).
    AgentCaptionDelta {
        item: String,
        text: String,
    },
    AgentCaptionDone {
        item: String,
        text: String,
    },
    /// The agent's audio started or stopped playing.
    OutputStarted,
    OutputStopped,
    /// The person tapped the voice: stop the reading and drop the queue.
    Skip,
    SetMuted(bool),
    /// The person ended voice mode.
    End,
    /// The transport failed.
    Failed(VoiceError),
    /// The transport closed.
    Closed,
}

/// What the transport (or the app) does next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Read this text aloud, out of band, word for word.
    Read(String),
    /// Stop the reading in flight.
    CancelReading,
    /// Drop audio already queued for playback.
    ClearOutput,
    /// Send this to the chat's agent as a prompt.
    Prompt(String),
    /// Turn the microphone on or off.
    Microphone(bool),
    /// Close the transport; voice mode is over (reported once).
    End(Option<VoiceError>),
}

/// One voice mode session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Relay {
    transport: Transport,
    phase: Phase,
    lines: Vec<Line>,
    user_speaking: bool,
    agent_speaking: bool,
    muted: bool,
    /// Text waiting to be read, oldest first.
    queue: Vec<String>,
    /// A reading was asked for and has not finished.
    reading: bool,
    /// The text of the reading in flight, said again if it is refused.
    in_flight: Option<String>,
    /// The reading in flight started.
    in_flight_started: bool,
    /// The reading in flight was refused once already: a second refusal drops it.
    in_flight_retried: bool,
    /// A reading cut off by the person's voice: said again when what followed was only noise.
    interrupted: Option<String>,
}

impl Relay {
    pub fn new(transport: Transport) -> Self {
        Self {
            transport,
            phase: Phase::Connecting,
            lines: Vec::new(),
            user_speaking: false,
            agent_speaking: false,
            muted: false,
            queue: Vec::new(),
            reading: false,
            in_flight: None,
            in_flight_started: false,
            in_flight_retried: false,
            interrupted: None,
        }
    }

    pub fn transport(&self) -> Transport {
        self.transport
    }
    pub fn phase(&self) -> &Phase {
        &self.phase
    }
    pub fn lines(&self) -> &[Line] {
        &self.lines
    }
    pub fn user_speaking(&self) -> bool {
        self.user_speaking
    }
    pub fn agent_speaking(&self) -> bool {
        self.agent_speaking
    }
    pub fn muted(&self) -> bool {
        self.muted
    }
    pub fn is_live(&self) -> bool {
        self.phase == Phase::Live
    }
    pub fn has_ended(&self) -> bool {
        matches!(self.phase, Phase::Ended(_))
    }

    /// Applies `event`; the effects to carry out, in order. An event after the end does nothing.
    pub fn apply(&mut self, event: Event) -> Vec<Effect> {
        let mut out = Vec::new();
        if self.has_ended() {
            return out;
        }
        match event {
            Event::Connected => {
                if self.phase == Phase::Connecting {
                    self.phase = Phase::Live;
                    out.push(Effect::Microphone(!self.muted));
                    self.read_next(&mut out);
                }
            }
            Event::AgentText(text) => {
                let text = text.trim();
                if !text.is_empty() {
                    self.queue.push(text.to_owned());
                    self.read_next(&mut out);
                }
            }
            Event::SpeechStarted { item } => {
                self.user_speaking = true;
                if let Some(item) = item {
                    self.upsert(&item, Role::You, Some(""), None, false);
                }
                // The cascade's barge-in: nothing on the far side stops the reading for us.
                if self.transport == Transport::Cascade && self.reading && self.in_flight_started {
                    out.push(Effect::CancelReading);
                    out.push(Effect::ClearOutput);
                }
            }
            Event::SpeechStopped => {
                self.user_speaking = false;
                self.read_next(&mut out);
            }
            Event::UserDelta { item, text } => {
                self.upsert(&item, Role::You, Some(&text), None, false);
            }
            Event::UserDone { item, text } => {
                let said = text.trim();
                if is_noise(said) {
                    // Never a prompt: transcription invents words from noise.
                    self.lines.retain(|l| l.id != item);
                    self.resume_interrupted(&mut out);
                } else {
                    self.upsert(&item, Role::You, None, Some(&text), true);
                    self.interrupted = None;
                    out.push(Effect::Prompt(said.to_owned()));
                }
                // A cascade's transcript comes after the speech stopped; a lost stop must not
                // leave the reading blocked.
                if self.transport == Transport::Cascade && self.user_speaking {
                    self.user_speaking = false;
                    self.read_next(&mut out);
                }
            }
            Event::UserFailed { item } => {
                self.lines.retain(|l| !(l.id == item && l.text.is_empty()));
                self.resume_interrupted(&mut out);
            }
            Event::AgentCaptionDelta { item, text } => {
                self.upsert(&item, Role::Agent, Some(&text), None, false);
            }
            Event::AgentCaptionDone { item, text } => {
                self.upsert(&item, Role::Agent, None, Some(&text), true);
            }
            Event::OutputStarted => self.agent_speaking = true,
            Event::OutputStopped => self.agent_speaking = false,
            Event::ReadingStarted => {
                if self.reading {
                    self.in_flight_started = true;
                }
            }
            Event::ReadingDone { cancelled } => {
                self.reading = false;
                // Cut off by the person's voice (not by Skip, which clears in_flight first).
                if cancelled && let Some(text) = self.in_flight.take() {
                    self.interrupted = Some(text);
                }
                self.in_flight = None;
                self.in_flight_retried = false;
                self.in_flight_started = false;
                if self.transport == Transport::Cascade {
                    self.agent_speaking = false;
                }
                for line in &mut self.lines {
                    if line.role == Role::Agent {
                        line.is_final = true;
                    }
                }
                self.read_next(&mut out);
            }
            Event::ReadingRefused(Refusal::Busy) => {
                // Our reading was refused: say it again once the other ends.
                if self.reading {
                    self.reading = false;
                    if let Some(text) = self.in_flight.take() {
                        self.queue.insert(0, text);
                    }
                    self.in_flight_started = false;
                }
            }
            Event::ReadingRefused(Refusal::Other) => {
                if self.reading && !self.in_flight_started {
                    // No end is coming for it: free the line, retry once, go on with the queue.
                    self.reading = false;
                    match self.in_flight.take() {
                        Some(text) if !self.in_flight_retried => {
                            self.queue.insert(0, text);
                            self.in_flight_retried = true;
                        }
                        _ => self.in_flight_retried = false,
                    }
                    self.read_next(&mut out);
                }
            }
            Event::Skip => {
                if self.is_live() {
                    self.queue.clear();
                    self.in_flight = None;
                    self.interrupted = None;
                    if self.reading {
                        out.push(Effect::CancelReading);
                    }
                    out.push(Effect::ClearOutput);
                    self.agent_speaking = false;
                }
            }
            Event::SetMuted(muted) => {
                self.muted = muted;
                if self.is_live() {
                    out.push(Effect::Microphone(!muted));
                }
            }
            Event::End => self.finish(None, &mut out),
            Event::Failed(error) => self.finish(Some(error), &mut out),
            Event::Closed => {
                let error = if self.is_live() {
                    VoiceError::new(ErrorCode::Offline, "the voice connection dropped", None)
                } else {
                    VoiceError::new(ErrorCode::Offline, "the voice connection closed", None)
                };
                self.finish(Some(error), &mut out);
            }
        }
        out
    }

    /// Starts the next reading when nothing is being read and the person is not talking. Queued
    /// pieces go out as one reading, in order.
    fn read_next(&mut self, out: &mut Vec<Effect>) {
        if !self.is_live() || self.reading || self.user_speaking || self.queue.is_empty() {
            return;
        }
        let text = self.queue.join("\n\n");
        self.queue.clear();
        self.reading = true;
        self.in_flight = Some(text.clone());
        self.in_flight_started = false;
        out.push(Effect::Read(text));
    }

    /// A reading cut off by noise goes back to the front of the queue.
    fn resume_interrupted(&mut self, out: &mut Vec<Effect>) {
        if let Some(text) = self.interrupted.take() {
            self.queue.insert(0, text);
            self.read_next(out);
        }
    }

    fn upsert(
        &mut self,
        id: &str,
        role: Role,
        append: Option<&str>,
        replace: Option<&str>,
        is_final: bool,
    ) {
        if let Some(line) = self.lines.iter_mut().rev().find(|l| l.id == id) {
            if let Some(replace) = replace.filter(|r| !r.is_empty()) {
                replace.clone_into(&mut line.text);
            }
            if let Some(append) = append {
                line.text.push_str(append);
            }
            line.is_final = is_final;
        } else {
            let text = replace.or(append).unwrap_or_default().to_owned();
            self.lines.push(Line { id: id.to_owned(), role, text, is_final });
            if self.lines.len() > MAX_LINES {
                let extra = self.lines.len() - MAX_LINES;
                self.lines.drain(..extra);
            }
        }
    }

    fn finish(&mut self, failure: Option<VoiceError>, out: &mut Vec<Effect>) {
        self.phase = Phase::Ended(failure.clone());
        self.user_speaking = false;
        self.agent_speaking = false;
        self.queue.clear();
        self.reading = false;
        self.in_flight = None;
        self.interrupted = None;
        self.lines.retain(|l| !l.text.is_empty());
        out.push(Effect::End(failure));
    }
}

#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;
