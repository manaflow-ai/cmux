//! The voice-mode relay state machine.
//!
//! Voice mode keeps the chat agent as the only brain. The voice provider hears
//! the person and reads the agent's text, while this reducer emits the one
//! prompt that the chat should receive and the one text the speaker should
//! read. It has no network, microphone, playback, or agent implementation in
//! it, so macOS, iPhone, and web clients can share the lifecycle rules.

#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

/// The visible lifecycle of a voice relay session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceState {
    Idle,
    Connecting,
    Listening,
    Thinking,
    Speaking,
    Interrupted,
    Error,
}

/// Errors that end a running session and need a person-facing action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceError {
    ProviderChanged,
    Message(String),
}

/// Inputs from the microphone, agent, provider, and controls.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceEvent {
    Start,
    Connected,
    UserFinishedSpeaking {
        transcript: String,
    },
    AgentText {
        text: String,
    },
    AgentFinished,
    /// `noise` means voice activity was detected without a usable utterance.
    BargeIn {
        noise: bool,
    },
    ProviderChanged,
    Failed(VoiceError),
    Retry,
    Stop,
}

/// Work for the owning surface to perform after applying an event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceEffect {
    Connect,
    SendPrompt(String),
    Speak(String),
    StopSpeaking,
}

/// The reducer's complete state. Agent output is retained so a noise-only
/// interruption can re-read the same response, while a real interruption
/// drops only the unread suffix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceSession {
    state: VoiceState,
    response: String,
    unread_response: String,
    error: Option<VoiceError>,
}

impl Default for VoiceSession {
    fn default() -> Self {
        Self::new()
    }
}

impl VoiceSession {
    pub fn new() -> Self {
        Self {
            state: VoiceState::Idle,
            response: String::new(),
            unread_response: String::new(),
            error: None,
        }
    }

    pub fn state(&self) -> VoiceState {
        self.state
    }

    pub fn error(&self) -> Option<&VoiceError> {
        self.error.as_ref()
    }

    /// Apply one lifecycle event. Invalid events are ignored, which keeps a
    /// late provider callback from reviving a stopped or failed session.
    pub fn apply(&mut self, event: VoiceEvent) -> Vec<VoiceEffect> {
        let mut effects = Vec::new();
        match event {
            VoiceEvent::Start if self.state == VoiceState::Idle => {
                self.error = None;
                self.state = VoiceState::Connecting;
                effects.push(VoiceEffect::Connect);
            }
            VoiceEvent::Connected if self.state == VoiceState::Connecting => {
                self.state = VoiceState::Listening;
            }
            VoiceEvent::UserFinishedSpeaking { transcript }
                if matches!(self.state, VoiceState::Listening | VoiceState::Interrupted)
                    && !transcript.trim().is_empty() =>
            {
                self.response.clear();
                self.unread_response.clear();
                self.state = VoiceState::Thinking;
                effects.push(VoiceEffect::SendPrompt(transcript));
            }
            VoiceEvent::AgentText { text } if self.state == VoiceState::Thinking => {
                self.response.push_str(&text);
                self.unread_response.push_str(&text);
            }
            VoiceEvent::AgentFinished
                if self.state == VoiceState::Thinking && !self.response.is_empty() =>
            {
                self.state = VoiceState::Speaking;
                effects.push(VoiceEffect::Speak(self.unread_response.clone()));
            }
            VoiceEvent::BargeIn { noise } if self.state == VoiceState::Speaking && noise => {
                effects.push(VoiceEffect::StopSpeaking);
                effects.push(VoiceEffect::Speak(self.unread_response.clone()));
            }
            VoiceEvent::BargeIn { noise: false } if self.state == VoiceState::Speaking => {
                self.state = VoiceState::Interrupted;
                self.unread_response.clear();
                effects.push(VoiceEffect::StopSpeaking);
            }
            VoiceEvent::ProviderChanged if self.state != VoiceState::Idle => {
                self.fail(VoiceError::ProviderChanged, &mut effects);
            }
            VoiceEvent::Failed(error) if self.state != VoiceState::Idle => {
                self.fail(error, &mut effects);
            }
            VoiceEvent::Retry if self.state == VoiceState::Error => {
                self.error = None;
                self.state = VoiceState::Connecting;
                effects.push(VoiceEffect::Connect);
            }
            VoiceEvent::Stop if self.state != VoiceState::Idle => {
                self.state = VoiceState::Idle;
                self.error = None;
                self.response.clear();
                self.unread_response.clear();
                effects.push(VoiceEffect::StopSpeaking);
            }
            _ => {}
        }
        effects
    }

    fn fail(&mut self, error: VoiceError, effects: &mut Vec<VoiceEffect>) {
        self.state = VoiceState::Error;
        self.error = Some(error);
        self.unread_response.clear();
        effects.push(VoiceEffect::StopSpeaking);
    }
}

#[cfg(test)]
mod tests {
    use super::{VoiceEffect, VoiceError, VoiceEvent, VoiceSession, VoiceState};

    #[test]
    fn relay_sends_finished_utterance_to_the_agent() {
        let mut session = VoiceSession::new();
        assert_eq!(session.apply(VoiceEvent::Start), vec![VoiceEffect::Connect]);
        assert_eq!(session.apply(VoiceEvent::Connected), Vec::new());
        assert_eq!(session.state(), VoiceState::Listening);

        assert_eq!(
            session
                .apply(VoiceEvent::UserFinishedSpeaking { transcript: "open the report".into() }),
            vec![VoiceEffect::SendPrompt("open the report".into())]
        );
        assert_eq!(session.state(), VoiceState::Thinking);
    }

    #[test]
    fn completed_agent_text_is_read_aloud_without_creating_a_second_brain() {
        let mut session = listening_session();
        session.apply(VoiceEvent::UserFinishedSpeaking { transcript: "summarize it".into() });
        session.apply(VoiceEvent::AgentText { text: "The report is ready.".into() });

        assert_eq!(
            session.apply(VoiceEvent::AgentFinished),
            vec![VoiceEffect::Speak("The report is ready.".into())]
        );
        assert_eq!(session.state(), VoiceState::Speaking);
    }

    #[test]
    fn noise_restarts_reading_but_a_real_barge_in_drops_unread_text() {
        let mut session = speaking_session();
        assert_eq!(
            session.apply(VoiceEvent::BargeIn { noise: true }),
            vec![VoiceEffect::StopSpeaking, VoiceEffect::Speak("hello from the agent".into())]
        );
        assert_eq!(session.state(), VoiceState::Speaking);

        assert_eq!(
            session.apply(VoiceEvent::BargeIn { noise: false }),
            vec![VoiceEffect::StopSpeaking]
        );
        assert_eq!(session.state(), VoiceState::Interrupted);
        assert_eq!(
            session
                .apply(VoiceEvent::UserFinishedSpeaking { transcript: "wait, change that".into() }),
            vec![VoiceEffect::SendPrompt("wait, change that".into())]
        );
    }

    #[test]
    fn failure_stops_playback_and_retry_reconnects() {
        let mut session = listening_session();
        assert_eq!(
            session.apply(VoiceEvent::Failed(VoiceError::Message("offline".into()))),
            vec![VoiceEffect::StopSpeaking]
        );
        assert_eq!(session.state(), VoiceState::Error);
        assert_eq!(session.error(), Some(&VoiceError::Message("offline".into())));
        assert_eq!(session.apply(VoiceEvent::Retry), vec![VoiceEffect::Connect]);
        assert_eq!(session.state(), VoiceState::Connecting);
    }

    #[test]
    fn stop_makes_late_callbacks_no_ops() {
        let mut session = speaking_session();
        assert_eq!(session.apply(VoiceEvent::Stop), vec![VoiceEffect::StopSpeaking]);
        assert_eq!(session.state(), VoiceState::Idle);
        assert!(session.apply(VoiceEvent::AgentFinished).is_empty());
        assert!(session.apply(VoiceEvent::Connected).is_empty());
    }

    fn listening_session() -> VoiceSession {
        let mut session = VoiceSession::new();
        session.apply(VoiceEvent::Start);
        session.apply(VoiceEvent::Connected);
        session
    }

    fn speaking_session() -> VoiceSession {
        let mut session = listening_session();
        session.apply(VoiceEvent::UserFinishedSpeaking { transcript: "hello".into() });
        session.apply(VoiceEvent::AgentText { text: "hello from the agent".into() });
        session.apply(VoiceEvent::AgentFinished);
        session
    }
}
