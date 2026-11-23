//! The cascade's reading voice over the OpenAI-style speech route: `POST <base>/audio/speech`
//! with `{model, voice, input, response_format: "pcm"}`, raw 24 kHz mono PCM16 back. Hosted
//! services take a key; local servers that copy the route (Kokoro, Piper wrappers) usually don't.
//!
//! The endpoint follows the dictation rules ([`crate::endpoint`]): https anywhere, http only to
//! loopback or (with no key) the LAN, and the key only to the origin it was saved for.

use std::time::Duration;

use serde_json::json;

use crate::endpoint::Endpoint;
use crate::error::{ErrorCode, VoiceError};
use crate::provider::{Http, status_error, transport_error};

/// The rate of the PCM the route answers.
pub const SPEECH_RATE: u32 = 24_000;
/// The most audio one reading may return: 5 minutes of 24 kHz PCM16.
pub const MAX_SPEECH_BYTES: usize = 5 * 60 * 24_000 * 2;
/// The default speech model and voice for the hosted service.
pub const DEFAULT_MODEL: &str = "gpt-4o-mini-tts";
pub const DEFAULT_VOICE: &str = "marin";

/// One reading to synthesize.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpeechRequest<'a> {
    pub text: &'a str,
    pub model: &'a str,
    pub voice: &'a str,
}

/// The JSON body of a reading.
pub fn body(request: &SpeechRequest<'_>) -> serde_json::Value {
    let or = |v: &str, d: &'static str| {
        if v.trim().is_empty() { d.to_owned() } else { v.trim().to_owned() }
    };
    json!({
        "model": or(request.model, DEFAULT_MODEL),
        "voice": or(request.voice, DEFAULT_VOICE),
        "input": request.text,
        "response_format": "pcm",
    })
}

/// Synthesizes `request` at `endpoint`: the PCM16 samples, little-endian bytes as sent.
pub async fn synthesize(
    endpoint: &Endpoint,
    key: Option<&str>,
    http: Http,
    request: &SpeechRequest<'_>,
) -> Result<Vec<u8>, VoiceError> {
    if request.text.trim().is_empty() {
        return Ok(Vec::new());
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut builder = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(http.connect_timeout)
        .timeout(http.total_timeout.max(Duration::from_secs(30)))
        .user_agent(concat!("cmux-voice/", env!("CARGO_PKG_VERSION")));
    if endpoint.base_url.starts_with("http://") {
        builder = builder.no_proxy();
    }
    let client = builder.build().map_err(|e| {
        VoiceError::new(ErrorCode::ProviderError, &format!("cannot start HTTP: {e}"), None)
    })?;
    let mut call = client
        .post(endpoint.url_for("audio/speech"))
        .header("Content-Type", "application/json")
        .body(body(request).to_string());
    if let Some(key) = key {
        call = call.header("Authorization", format!("Bearer {key}"));
    }
    let mut response = call.send().await.map_err(|e| transport_error(&e, key))?;
    let status = response.status().as_u16();
    let mut audio = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| transport_error(&e, key))? {
        if audio.len().saturating_add(chunk.len()) > MAX_SPEECH_BYTES {
            return Err(VoiceError::new(ErrorCode::TooLarge, "the reading is too long", None));
        }
        audio.extend_from_slice(&chunk);
    }
    if !(200..300).contains(&status) {
        return Err(status_error(status, &audio, key));
    }
    if audio.len() % 2 != 0 {
        audio.pop();
    }
    Ok(audio)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_body_asks_for_raw_pcm_with_defaults() {
        let b = body(&SpeechRequest { text: "Done.", model: "", voice: " " });
        assert_eq!(
            b,
            json!({"model": DEFAULT_MODEL, "voice": DEFAULT_VOICE, "input": "Done.",
                   "response_format": "pcm"})
        );
        let b = body(&SpeechRequest { text: "x", model: "kokoro", voice: "af_sky" });
        assert_eq!((b["model"].as_str(), b["voice"].as_str()), (Some("kokoro"), Some("af_sky")));
    }
}
