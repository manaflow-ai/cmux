//! Stateless reducer for desktop voice relay. Native hosts persist `RelayState` and
//! call [`reduce`] through the local daemon RPC.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub const MAX_QUEUE: usize = 32;
pub const SILENCE_MS: u64 = 800;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Idle,
    Connecting,
    Listening,
    Finalizing,
    Thinking,
    Speaking,
    Interrupted,
    Error,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RelayState {
    pub phase: Phase,
    pub generation: u64,
    pub provider_revision: u64,
    pub queue: VecDeque<QueuedText>,
    pub current: Option<QueuedText>,
    pub interrupted: Option<QueuedText>,
    pub seen_agent_ids: BTreeSet<String>,
    pub agent_buffers: BTreeMap<String, String>,
    pub agent_sequences: BTreeMap<String, u64>,
    pub sent_utterance_ids: BTreeSet<String>,
    pub speech_started_ms: Option<u64>,
    pub last_audio_ms: Option<u64>,
    pub error: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QueuedText {
    pub id: String,
    pub text: String,
}
impl Default for RelayState {
    fn default() -> Self {
        Self {
            phase: Phase::Idle,
            generation: 0,
            provider_revision: 0,
            queue: VecDeque::new(),
            current: None,
            interrupted: None,
            seen_agent_ids: BTreeSet::new(),
            agent_buffers: BTreeMap::new(),
            agent_sequences: BTreeMap::new(),
            sent_utterance_ids: BTreeSet::new(),
            speech_started_ms: None,
            last_audio_ms: None,
            error: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
#[allow(non_snake_case)]
pub enum RelayEvent {
    Start {
        providerRevision: u64,
        configured: bool,
    },
    Listening {
        generation: u64,
    },
    AudioActivity {
        generation: u64,
        level: f32,
        atMs: u64,
    },
    Tick {
        generation: u64,
        atMs: u64,
    },
    Transcript {
        generation: u64,
        id: String,
        text: String,
    },
    AgentText {
        generation: u64,
        id: String,
        text: String,
        done: bool,
        #[serde(default)]
        seq: Option<u64>,
    },
    SpeechFinished {
        generation: u64,
        id: String,
    },
    UserSpeechStarted {
        generation: u64,
    },
    UserSpeechStopped {
        generation: u64,
    },
    Cancel,
    Skip,
    ProviderChanged {
        revision: u64,
    },
    KeyRemoved,
    Restart {
        configured: bool,
    },
    Error {
        generation: u64,
        code: String,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Effect {
    StartListening,
    StopListening,
    SendPrompt { id: String, text: String },
    Speak { id: String, text: String },
    StopSpeaking,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Transition {
    pub state: RelayState,
    pub effects: Vec<Effect>,
}

pub fn reduce(mut state: RelayState, event: RelayEvent) -> Transition {
    let mut effects = Vec::new();
    let generation = state.generation;
    let live = |g: u64| g == generation;
    match event {
        RelayEvent::Start { providerRevision, configured } => {
            state.generation = generation.wrapping_add(1);
            state.provider_revision = providerRevision;
            state.queue.clear();
            state.current = None;
            state.interrupted = None;
            state.seen_agent_ids.clear();
            state.agent_buffers.clear();
            state.agent_sequences.clear();
            state.sent_utterance_ids.clear();
            state.error = None;
            if configured {
                state.phase = Phase::Connecting;
                effects.push(Effect::StartListening);
            } else {
                state.phase = Phase::Error;
                state.error = Some("keyMissing".into());
            }
        }
        RelayEvent::Listening { generation: g } if live(g) => {
            // Capture is re-armed while the agent thinks or speaks. The audio
            // device state must not erase the conversation phase.
            if matches!(state.phase, Phase::Idle | Phase::Connecting | Phase::Finalizing) {
                state.phase = Phase::Listening;
            }
            state.last_audio_ms = None;
            state.speech_started_ms = None;
        }
        RelayEvent::AudioActivity { generation: g, level, atMs } if live(g) && level > 0.02 => {
            state.last_audio_ms = Some(atMs);
            state.speech_started_ms.get_or_insert(atMs);
            // VAD is owned here so native clients cannot accidentally read
            // over a person's first spoken word.
            if let Some(current) = state.current.take() {
                state.interrupted = Some(current);
                state.phase = Phase::Interrupted;
                effects.push(Effect::StopSpeaking);
            }
        }
        RelayEvent::Tick { generation: g, atMs }
            if live(g)
                && !matches!(
                    state.phase,
                    Phase::Idle | Phase::Connecting | Phase::Finalizing | Phase::Error
                )
                && state.speech_started_ms.is_some()
                && state
                    .last_audio_ms
                    .map(|x| atMs.saturating_sub(x) >= SILENCE_MS)
                    .unwrap_or(false) =>
        {
            state.phase = Phase::Finalizing;
            effects.push(Effect::StopListening);
        }
        RelayEvent::Transcript { generation: g, id, text }
            if live(g) && !state.sent_utterance_ids.contains(&id) =>
        {
            if crate::is_noise(&text) {
                state.phase = if state.current.is_some() || state.interrupted.is_some() {
                    Phase::Speaking
                } else {
                    Phase::Listening
                };
                if let Some(item) = state.interrupted.take() {
                    state.queue.push_front(item);
                    speak_next(&mut state, &mut effects);
                }
                effects.push(Effect::StartListening);
            } else {
                state.sent_utterance_ids.insert(id.clone());
                state.current = None;
                state.queue.clear();
                state.interrupted = None;
                state.phase = Phase::Thinking;
                state.speech_started_ms = None;
                effects.push(Effect::StopSpeaking);
                effects.push(Effect::SendPrompt { id, text });
                effects.push(Effect::StartListening);
            }
        }
        RelayEvent::AgentText { generation: g, id, text, done, seq }
            if live(g) && !state.seen_agent_ids.contains(&id) =>
        {
            if let Some(n) = seq {
                if state.agent_sequences.get(&id).map(|last| n <= *last).unwrap_or(false) {
                    return Transition { state, effects };
                }
                state.agent_sequences.insert(id.clone(), n);
            }
            state.agent_buffers.entry(id.clone()).or_default().push_str(&text);
            if done {
                state.seen_agent_ids.insert(id.clone());
                let all = state.agent_buffers.remove(&id).unwrap_or_default();
                if let Some(text) = crate::speakable(&all, 1200, 40) {
                    if state.queue.len() < MAX_QUEUE {
                        state.queue.push_back(QueuedText { id, text });
                    }
                    speak_next(&mut state, &mut effects);
                }
            }
        }
        RelayEvent::SpeechFinished { generation: g, id }
            if live(g) && state.current.as_ref().map(|x| x.id.as_str()) == Some(id.as_str()) =>
        {
            state.current = None;
            speak_next(&mut state, &mut effects);
            if state.current.is_none() {
                state.phase = Phase::Thinking;
            }
        }
        RelayEvent::UserSpeechStarted { generation: g } if live(g) => {
            if let Some(current) = state.current.take() {
                state.interrupted = Some(current);
                effects.push(Effect::StopSpeaking);
                state.phase = Phase::Interrupted;
            }
        }
        RelayEvent::UserSpeechStopped { generation: g }
            if live(g) && state.phase == Phase::Interrupted =>
        {
            state.phase = Phase::Listening;
            if let Some(item) = state.interrupted.take() {
                state.queue.push_front(item);
                speak_next(&mut state, &mut effects);
            }
        }
        RelayEvent::Cancel => {
            effects.push(Effect::StopListening);
            effects.push(Effect::StopSpeaking);
            state = RelayState { generation: generation.wrapping_add(1), ..Default::default() };
        }
        RelayEvent::Skip => {
            // Skip is only for unread agent output. Keep the live session and
            // microphone so the next utterance can still become a prompt.
            state.queue.clear();
            state.current = None;
            state.interrupted = None;
            state.agent_buffers.clear();
            state.phase = match state.phase {
                Phase::Idle | Phase::Error | Phase::Listening => state.phase,
                _ => Phase::Thinking,
            };
            effects.push(Effect::StopSpeaking);
        }
        RelayEvent::ProviderChanged { revision } => {
            state.provider_revision = revision;
            if state.phase != Phase::Idle {
                state.phase = Phase::Error;
                state.error = Some("providerChangedRestartRequired".into());
                effects.push(Effect::StopListening);
                effects.push(Effect::StopSpeaking);
            }
        }
        RelayEvent::KeyRemoved if state.phase != Phase::Idle => {
            state.phase = Phase::Error;
            state.error = Some("keyMissing".into());
            effects.push(Effect::StopListening);
            effects.push(Effect::StopSpeaking);
        }
        RelayEvent::Restart { configured } => {
            effects.push(Effect::StopListening);
            effects.push(Effect::StopSpeaking);
            let next = RelayEvent::Start { providerRevision: state.provider_revision, configured };
            state = RelayState { generation, ..Default::default() };
            return reduce(state, next);
        }
        RelayEvent::Error { generation: g, code } if live(g) => {
            state.phase = Phase::Error;
            state.error = Some(code);
            effects.push(Effect::StopListening);
            effects.push(Effect::StopSpeaking);
        }
        _ => {}
    }
    Transition { state, effects }
}
fn speak_next(state: &mut RelayState, effects: &mut Vec<Effect>) {
    if state.current.is_none()
        && let Some(item) = state.queue.pop_front()
    {
        effects.push(Effect::Speak { id: item.id.clone(), text: item.text.clone() });
        state.current = Some(item);
        state.phase = Phase::Speaking;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn start() -> RelayState {
        reduce(RelayState::default(), RelayEvent::Start { providerRevision: 1, configured: true })
            .state
    }
    #[test]
    fn stale_events_cannot_send() {
        let s = start();
        let t = reduce(
            s,
            RelayEvent::Transcript { generation: 0, id: "x".into(), text: "do it".into() },
        );
        assert!(t.effects.is_empty());
    }
    #[test]
    fn transcript_dedup_and_noise_resume() {
        let mut s = start();
        s.phase = Phase::Speaking;
        s.current = Some(QueuedText { id: "a".into(), text: "hello".into() });
        s.interrupted = s.current.clone();
        s.current = None;
        let t = reduce(
            s,
            RelayEvent::Transcript { generation: 1, id: "n".into(), text: "thanks".into() },
        );
        assert!(t.effects.iter().any(|e| matches!(e,Effect::Speak{id,..} if id=="a")));
        let t = reduce(
            t.state,
            RelayEvent::Transcript { generation: 1, id: "n".into(), text: "do it".into() },
        );
        assert!(t.effects.iter().any(|e| matches!(e, Effect::SendPrompt { .. })));
    }
    #[test]
    fn silence_finalizes() {
        let mut s = start();
        s.phase = Phase::Listening;
        let s = reduce(s, RelayEvent::AudioActivity { generation: 1, level: 1.0, atMs: 1 }).state;
        let t = reduce(s, RelayEvent::Tick { generation: 1, atMs: 801 });
        assert_eq!(t.state.phase, Phase::Finalizing);
        assert!(t.effects.contains(&Effect::StopListening));
    }
    #[test]
    fn rearmed_capture_preserves_speaking_and_vad_barges_in() {
        let mut s = start();
        s.phase = Phase::Speaking;
        s.current = Some(QueuedText { id: "a".into(), text: "hello".into() });
        let s = reduce(s, RelayEvent::Listening { generation: 1 }).state;
        assert_eq!(s.phase, Phase::Speaking);
        let t = reduce(s, RelayEvent::AudioActivity { generation: 1, level: 1.0, atMs: 10 });
        assert_eq!(t.state.phase, Phase::Interrupted);
        assert!(t.state.interrupted.is_some());
        assert!(t.effects.contains(&Effect::StopSpeaking));
    }
    #[test]
    fn skip_discards_unread_speech_but_keeps_session() {
        let mut s = start();
        s.phase = Phase::Speaking;
        s.current = Some(QueuedText { id: "a".into(), text: "hello".into() });
        let t = reduce(s, RelayEvent::Skip);
        assert_eq!(t.state.phase, Phase::Thinking);
        assert!(t.state.current.is_none());
        assert!(!t.effects.contains(&Effect::StopListening));
    }
}
