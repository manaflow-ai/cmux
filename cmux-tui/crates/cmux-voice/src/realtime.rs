//! The speech-to-speech wire as a relay: the session the iPhone opens
//! (`AgentVoiceSessionConfig`, `RealtimeEvents.swift`), here once for every client.
//!
//! The voice model never answers on its own (`create_response: false`, no tools): it reads the
//! agent's words it is handed, out of band and word for word ([`read_event`]), and the person's
//! speech is transcribed and becomes a prompt ([`relay_event`] maps the service's events to the
//! [`crate::relay`] reducer's). Server voice detection still stops the reading (barge-in).
//!
//! Only the JSON lives here; the transport (WebRTC on a device, a WebSocket on a server) carries
//! it.

use serde_json::{Value, json};

use crate::relay::{Event, Refusal};

/// The transcription model asked for first, and the one tried when the service refuses it.
pub const TRANSCRIPTION_MODEL: &str = "gpt-live-transcribe";
pub const FALLBACK_TRANSCRIPTION_MODEL: &str = "gpt-4o-mini-transcribe";

/// What voice mode opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayConfig {
    pub model: String,
    pub voice: String,
    /// The agent the voice speaks for (`Claude`, `Codex`).
    pub agent_name: String,
    pub transcription_model: String,
}

impl RelayConfig {
    /// How every reading is told to read: verbatim, nothing added.
    pub fn read_instructions(&self) -> String {
        format!(
            "You are the voice of {}, a coding agent, in a voice-only relay. Read the user message \
             aloud exactly as written, word for word, in a calm natural voice. Do not answer it, \
             summarize it, add to it, greet, or comment. Say file names and numbers naturally.",
            self.agent_name
        )
    }

    /// The session: audio out only, no tools, and speech never answered by the model.
    pub fn session(&self) -> Value {
        json!({
            "type": "realtime",
            "model": self.model,
            "instructions": self.read_instructions(),
            "output_modalities": ["audio"],
            "audio": {
                "input": {
                    "transcription": {"model": self.transcription_model},
                    // What the person says is a prompt for the agent; speaking still stops the
                    // voice (barge-in).
                    "turn_detection": {
                        "type": "semantic_vad", "create_response": false, "interrupt_response": true,
                    },
                    "noise_reduction": {"type": "near_field"},
                },
                "output": {"voice": self.voice},
            },
            "tools": [],
            "tool_choice": "none",
        })
    }

    /// An out-of-band response that reads `text` aloud and leaves the conversation empty, so
    /// earlier readings never colour the next.
    pub fn read_event(&self, text: &str) -> Value {
        json!({
            "type": "response.create",
            "response": {
                "conversation": "none",
                "output_modalities": ["audio"],
                "instructions": self.read_instructions(),
                "input": [{"type": "message", "role": "user",
                           "content": [{"type": "input_text", "text": text}]}],
            },
        })
    }
}

/// Stop the reading in flight.
pub fn cancel_event() -> Value {
    json!({"type": "response.cancel"})
}

/// Drop the agent's unplayed audio.
pub fn clear_output_event() -> Value {
    json!({"type": "output_audio_buffer.clear"})
}

/// Switch input transcription to `model` (the first was refused).
pub fn transcription_model_event(model: &str) -> Value {
    json!({"type": "session.update",
           "session": {"type": "realtime", "audio": {"input": {"transcription": {"model": model}}}}})
}

/// What the transport should do with a service event besides feeding the reducer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wire {
    /// A reducer event.
    Relay(Event),
    /// The transcription model was refused: send [`transcription_model_event`] with the fallback
    /// (once).
    TranscriptionRefused,
}

/// One service event as the reducer's, or `None` for the ones voice mode ignores.
pub fn relay_event(message: &Value) -> Option<Wire> {
    let s = |k: &str| message.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let item = s("item_id");
    let event = match message.get("type").and_then(Value::as_str)? {
        "input_audio_buffer.speech_started" => {
            Event::SpeechStarted { item: (!item.is_empty()).then_some(item) }
        }
        "input_audio_buffer.speech_stopped" => Event::SpeechStopped,
        "conversation.item.input_audio_transcription.delta" => {
            Event::UserDelta { item, text: s("delta") }
        }
        "conversation.item.input_audio_transcription.completed" => {
            Event::UserDone { item, text: s("transcript") }
        }
        "conversation.item.input_audio_transcription.failed" => Event::UserFailed { item },
        "response.created" => Event::ReadingStarted,
        "response.output_audio_transcript.delta" | "response.output_text.delta" => {
            Event::AgentCaptionDelta { item, text: s("delta") }
        }
        "response.output_audio_transcript.done" => {
            Event::AgentCaptionDone { item, text: s("transcript") }
        }
        "response.output_text.done" => Event::AgentCaptionDone { item, text: s("text") },
        "output_audio_buffer.started" => Event::OutputStarted,
        "output_audio_buffer.stopped" | "output_audio_buffer.cleared" => Event::OutputStopped,
        "response.done" => {
            let status = message.pointer("/response/status").and_then(Value::as_str);
            Event::ReadingDone { cancelled: status == Some("cancelled") }
        }
        "error" => {
            let field = |k: &str| message.pointer(&format!("/error/{k}")).and_then(Value::as_str);
            if field("code") == Some("conversation_already_has_active_response") {
                Event::ReadingRefused(Refusal::Busy)
            } else if field("param").is_some_and(|p| p.contains("transcription")) {
                return Some(Wire::TranscriptionRefused);
            } else {
                // Refuses our reading if one is waiting to start; the reducer ignores it otherwise.
                Event::ReadingRefused(Refusal::Other)
            }
        }
        _ => return None,
    };
    Some(Wire::Relay(event))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> RelayConfig {
        RelayConfig {
            model: "gpt-realtime-2.1".into(),
            voice: "cedar".into(),
            agent_name: "Codex".into(),
            transcription_model: TRANSCRIPTION_MODEL.into(),
        }
    }

    #[test]
    fn the_session_never_answers_speech_on_its_own() {
        let s = config().session();
        assert_eq!(s.pointer("/audio/input/turn_detection/create_response"), Some(&json!(false)));
        assert_eq!(s.pointer("/audio/input/turn_detection/interrupt_response"), Some(&json!(true)));
        assert_eq!(s["tools"], json!([]));
        assert_eq!(s["model"], "gpt-realtime-2.1");
        assert_eq!(s.pointer("/audio/output/voice"), Some(&json!("cedar")));
    }

    #[test]
    fn a_reading_is_out_of_band_and_verbatim() {
        let e = config().read_event("All 43 tests pass.");
        assert_eq!(e["type"], "response.create");
        assert_eq!(e.pointer("/response/conversation"), Some(&json!("none")));
        assert_eq!(
            e.pointer("/response/input/0/content/0/text"),
            Some(&json!("All 43 tests pass."))
        );
        let instructions = e.pointer("/response/instructions").and_then(Value::as_str);
        assert!(instructions.is_some_and(|i| i.contains("word for word") && i.contains("Codex")));
    }

    fn ev(v: Value) -> Option<Wire> {
        relay_event(&v)
    }

    #[test]
    fn service_events_map_to_the_reducer() {
        assert_eq!(
            ev(json!({"type": "input_audio_buffer.speech_started", "item_id": "u1"})),
            Some(Wire::Relay(Event::SpeechStarted { item: Some("u1".into()) }))
        );
        assert_eq!(
            ev(json!({"type": "conversation.item.input_audio_transcription.completed",
                      "item_id": "u1", "transcript": "Run it."})),
            Some(Wire::Relay(Event::UserDone { item: "u1".into(), text: "Run it.".into() }))
        );
        assert_eq!(
            ev(json!({"type": "response.done", "response": {"status": "cancelled", "output": []}})),
            Some(Wire::Relay(Event::ReadingDone { cancelled: true }))
        );
        assert_eq!(
            ev(json!({"type": "response.done", "response": {"status": "completed"}})),
            Some(Wire::Relay(Event::ReadingDone { cancelled: false }))
        );
        assert_eq!(
            ev(json!({"type": "error",
                      "error": {"code": "conversation_already_has_active_response"}})),
            Some(Wire::Relay(Event::ReadingRefused(Refusal::Busy)))
        );
        assert_eq!(
            ev(json!({"type": "error", "error": {"code": "rate_limit_exceeded"}})),
            Some(Wire::Relay(Event::ReadingRefused(Refusal::Other)))
        );
        assert_eq!(
            ev(json!({"type": "error",
                      "error": {"param": "session.audio.input.transcription.model"}})),
            Some(Wire::TranscriptionRefused)
        );
        assert_eq!(ev(json!({"type": "session.updated"})), None);
        assert_eq!(ev(json!({"no": "type"})), None);
    }

    #[test]
    fn client_events() {
        assert_eq!(cancel_event()["type"], "response.cancel");
        assert_eq!(clear_output_event()["type"], "output_audio_buffer.clear");
        assert_eq!(
            transcription_model_event(FALLBACK_TRANSCRIPTION_MODEL)
                .pointer("/session/audio/input/transcription/model"),
            Some(&json!("gpt-4o-mini-transcribe"))
        );
    }
}
