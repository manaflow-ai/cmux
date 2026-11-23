//! The streaming wire: audio goes up a WebSocket as it is spoken, words come back as partial and
//! final events.
//!
//! The wire is the realtime transcription mode of the OpenAI-style API (`wss://<host>/<base>/
//! realtime?intent=transcription`): a `session.update` names the model, the language and server
//! voice detection; audio goes as `input_audio_buffer.append` (PCM16, 24 kHz, mono, base64); the
//! server answers `input_audio_buffer.committed` per utterance, then
//! `conversation.item.input_audio_transcription.delta` and `.completed`. A stop sends
//! `input_audio_buffer.commit` for the last stretch.
//!
//! [`run`] owns one session: it connects, then feeds [`Command`]s up and provider events into the
//! [`Session`] reducer, sends what the reducer shows to `shown`, and returns the session's text or
//! the error that ended it. The key goes only as the `Authorization` header of the upgrade.

use std::time::Duration;

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest};

use crate::catalog::Capability;
use crate::endpoint::Endpoint;
use crate::error::{ErrorCode, VoiceError};
use crate::provider::{Http, primary_language, status_error};
use crate::session::{Effect, Event, Session, Shown};

/// The sample rate the app sends (the recording's own: 16 kHz mono PCM16).
pub const INPUT_RATE: u32 = 16_000;
/// The rate the wire takes.
pub const WIRE_RATE: u32 = 24_000;
/// How long a stopped session waits for its last words.
pub const FINALIZING_DEADLINE: Duration = Duration::from_secs(10);
/// The most bytes of one provider message read.
const MAX_MESSAGE_BYTES: usize = 1 << 20;

/// What the caller sends into a running session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// 16 kHz mono PCM16 samples, in speaking order.
    Audio(Vec<i16>),
    /// The person stopped: commit and wait for the last words.
    Stop,
    /// Esc: end now, show nothing more.
    Cancel,
}

/// The WebSocket URL of `endpoint`'s streaming wire, or `None` when its provider does not stream.
pub fn stream_url(endpoint: &Endpoint) -> Option<String> {
    if !endpoint.provider.supports(Capability::DictationStreaming) {
        return None;
    }
    let base = endpoint.base_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        return None;
    };
    Some(format!("{ws}/realtime?intent=transcription"))
}

/// The `session.update` that opens a transcription session.
pub fn session_update(model: &str, language: Option<&str>) -> Value {
    let mut transcription = json!({"model": model});
    if let Some(language) = language.and_then(primary_language) {
        transcription["language"] = json!(language);
    }
    json!({
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {"input": {
                "format": {"type": "audio/pcm", "rate": WIRE_RATE},
                "transcription": transcription,
                "turn_detection": {
                    "type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300,
                    "silence_duration_ms": 500,
                },
            }},
        },
    })
}

/// 16 kHz to 24 kHz, linear, across calls: three samples out for every two in.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Upsampler {
    last: Option<i16>,
    /// The next output's place between `last` and the next input, in thirds (0, 1 or 2).
    thirds: u8,
}

impl Upsampler {
    pub fn push(&mut self, input: &[i16], out: &mut Vec<i16>) {
        for &s in input {
            let Some(last) = self.last else {
                self.last = Some(s);
                out.push(s);
                self.thirds = 2;
                continue;
            };
            while self.thirds < 3 {
                let (a, b, t) = (i32::from(last), i32::from(s), i32::from(self.thirds));
                let v = a + (b - a) * t / 3;
                out.push(i16::try_from(v).unwrap_or(if v < 0 { i16::MIN } else { i16::MAX }));
                self.thirds += 2;
            }
            self.thirds -= 3;
            self.last = Some(s);
        }
    }
}

/// `samples` as the wire's little-endian base64.
pub fn pcm_base64(samples: &[i16]) -> String {
    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for s in samples {
        bytes.extend_from_slice(&s.to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// A provider message as a reducer event; `None` for the ones the session ignores.
pub fn provider_event(message: &Value, key: Option<&str>) -> Option<Event> {
    let text = |k: &str| message.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    match message.get("type").and_then(Value::as_str)? {
        "input_audio_buffer.committed" => Some(Event::Committed { item: text("item_id") }),
        "conversation.item.input_audio_transcription.delta" => {
            Some(Event::Delta { item: text("item_id"), text: text("delta") })
        }
        "conversation.item.input_audio_transcription.completed" => {
            Some(Event::Completed { item: text("item_id"), text: text("transcript") })
        }
        "conversation.item.input_audio_transcription.failed" => {
            Some(Event::ItemFailed { item: text("item_id") })
        }
        "error" => {
            let error = message.get("error").unwrap_or(&Value::Null);
            let field = |k: &str| error.get(k).and_then(Value::as_str).unwrap_or_default();
            let (code, kind, said) = (field("code"), field("type"), field("message"));
            if code == "input_audio_buffer_commit_empty" {
                return Some(Event::CommitEmpty);
            }
            let mapped = if code == "invalid_api_key" || kind == "authentication_error" {
                ErrorCode::KeyInvalid
            } else if code.contains("rate_limit") || kind.contains("rate_limit") {
                ErrorCode::RateLimited
            } else if kind == "invalid_request_error" {
                ErrorCode::Rejected
            } else {
                ErrorCode::ProviderError
            };
            let detail = if said.is_empty() { code } else { said };
            Some(Event::Failed(VoiceError::new(mapped, detail, key)))
        }
        _ => None,
    }
}

/// A failed upgrade: the provider's status when it answered one, else offline or timeout.
fn connect_error(e: tungstenite::Error, key: Option<&str>) -> VoiceError {
    match e {
        tungstenite::Error::Http(response) => {
            let body = response.body().clone().unwrap_or_default();
            status_error(response.status().as_u16(), &body, key)
        }
        tungstenite::Error::Url(why) => {
            VoiceError::new(ErrorCode::BadEndpoint, &why.to_string(), key)
        }
        other => VoiceError::new(ErrorCode::Offline, &other.to_string(), key),
    }
}

/// What woke the session loop.
enum Step {
    Command(Option<Command>),
    Message(Option<Result<Message, tungstenite::Error>>),
    Deadline,
}

/// Runs one streaming session on `endpoint` until it ends: the session's text, or the error that
/// ended it (the words shown before it are kept by the caller).
pub async fn run(
    endpoint: Endpoint,
    key: Option<String>,
    http: Http,
    language: Option<String>,
    mut commands: mpsc::Receiver<Command>,
    shown: mpsc::Sender<Shown>,
) -> Result<String, VoiceError> {
    let key = crate::provider::usable_key(&endpoint, key)?;
    let key_ref = key.as_deref();
    let Some(url) = stream_url(&endpoint) else {
        return Err(VoiceError::bare(ErrorCode::NotConfigured));
    };
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(|e| VoiceError::new(ErrorCode::BadEndpoint, &e.to_string(), key_ref))?;
    if let Some(key) = key_ref {
        let value = format!("Bearer {key}").parse().map_err(|_| {
            VoiceError::new(ErrorCode::KeyInvalid, "the key is not one header line", None)
        })?;
        request.headers_mut().insert("Authorization", value);
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_MESSAGE_BYTES));
    let connect = tokio_tungstenite::connect_async_with_config(request, Some(config), true);
    let (mut socket, _) = match tokio::time::timeout(http.connect_timeout, connect).await {
        Err(_) => {
            return Err(VoiceError::new(ErrorCode::Timeout, "connecting took too long", None));
        }
        Ok(Err(e)) => return Err(connect_error(e, key_ref)),
        Ok(Ok(pair)) => pair,
    };
    let update = session_update(&endpoint.model, language.as_deref()).to_string();
    socket
        .send(Message::Text(update.into()))
        .await
        .map_err(|e| VoiceError::new(ErrorCode::Offline, &e.to_string(), key_ref))?;

    let mut session = Session::new();
    let mut upsampler = Upsampler::default();
    let mut wire = Vec::new();
    let mut deadline: Option<tokio::time::Instant> = None;
    let mut commands_open = true;
    let mut pending = session.apply(Event::Ready);
    loop {
        for effect in std::mem::take(&mut pending) {
            match effect {
                Effect::Show(s) => {
                    // A caller that went away sees nothing; the session still ends cleanly.
                    let _ = shown.send(s).await;
                }
                Effect::Commit => {
                    let commit = json!({"type": "input_audio_buffer.commit"}).to_string();
                    if socket.send(Message::Text(commit.into())).await.is_err() {
                        pending.extend(session.apply(Event::Closed));
                    }
                }
                Effect::StartDeadline => {
                    deadline = Some(tokio::time::Instant::now() + FINALIZING_DEADLINE);
                }
                Effect::End(outcome) => {
                    let _ = socket.close(None).await;
                    return outcome.map(|()| session.text().to_owned());
                }
            }
        }
        let step = tokio::select! {
            command = commands.recv(), if commands_open => Step::Command(command),
            message = socket.next() => Step::Message(message),
            () = tokio::time::sleep_until(deadline.unwrap_or_else(tokio::time::Instant::now)),
                if deadline.is_some() => Step::Deadline,
        };
        let event = match step {
            Step::Command(Some(Command::Audio(samples))) => {
                if session.phase() != crate::session::Phase::Listening {
                    continue;
                }
                wire.clear();
                upsampler.push(&samples, &mut wire);
                let append =
                    json!({"type": "input_audio_buffer.append", "audio": pcm_base64(&wire)});
                match socket.send(Message::Text(append.to_string().into())).await {
                    Ok(()) => continue,
                    Err(_) => Event::Closed,
                }
            }
            Step::Command(Some(Command::Stop)) => Event::Stop,
            // A caller that dropped its sender cancels.
            Step::Command(Some(Command::Cancel) | None) => {
                commands_open = false;
                Event::Cancel
            }
            Step::Message(Some(Ok(Message::Text(text)))) => {
                let Ok(value) = serde_json::from_str::<Value>(&text) else { continue };
                match provider_event(&value, key_ref) {
                    Some(event) => event,
                    None => continue,
                }
            }
            Step::Message(Some(Ok(Message::Close(_))) | None) => Event::Closed,
            Step::Message(Some(Ok(_))) => continue,
            Step::Message(Some(Err(e))) => {
                Event::Failed(VoiceError::new(ErrorCode::Offline, &e.to_string(), key_ref))
            }
            Step::Deadline => {
                deadline = None;
                Event::Deadline
            }
        };
        pending = session.apply(event);
    }
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
