//! The provider trait and the HTTP batch wires.
//!
//! [`DictationProvider`] is what a caller holds: what it can do, `transcribe` a whole recording,
//! and `check` the endpoint and key without sending audio. [`provider_for`] picks the
//! implementation for an [`Endpoint`]'s wire; today that is [`HttpBatch`] for both HTTP wires.
//! Streaming and real-time providers come later as more implementations (crate doc).

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use serde_json::Value;

use crate::catalog::{Capability, KeyUse, Wire};
use crate::endpoint::Endpoint;
use crate::error::{ErrorCode, VoiceError};
use crate::multipart::{self, Part};

/// A boxed future, so the trait is object safe.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The most bytes of an answer read.
pub const MAX_ANSWER_BYTES: usize = 1_048_576;

/// The network limits of one call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Http {
    pub connect_timeout: Duration,
    pub total_timeout: Duration,
}

impl Default for Http {
    /// Connect 10 s, the whole request 60 s.
    fn default() -> Self {
        Self { connect_timeout: Duration::from_secs(10), total_timeout: Duration::from_secs(60) }
    }
}

/// One recording to transcribe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatchRequest<'a> {
    /// The WAV file's bytes.
    pub audio: &'a [u8],
    /// A BCP 47 tag (`en-US`); the wire sends its primary subtag.
    pub language: Option<&'a str>,
}

/// What the provider heard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transcript {
    pub text: String,
}

/// A dictation provider.
pub trait DictationProvider: Send + Sync {
    /// What this provider does; callers offer only these.
    fn capabilities(&self) -> &'static [Capability];

    /// The whole recording to text.
    fn transcribe<'a>(
        &'a self,
        request: BatchRequest<'a>,
    ) -> BoxFuture<'a, Result<Transcript, VoiceError>>;

    /// The cheapest call that proves the endpoint and the key; sends no audio.
    fn check(&self) -> BoxFuture<'_, Result<(), VoiceError>>;
}

/// The provider for `endpoint`, sending `key` when the endpoint takes one. `key_missing` when the
/// provider requires a key and there is none; `not_configured` for the on-device engine.
pub fn provider_for(
    endpoint: Endpoint,
    key: Option<String>,
    http: Http,
) -> Result<Box<dyn DictationProvider>, VoiceError> {
    let key = key
        .map(|k| k.trim().to_owned())
        .filter(|k| !k.is_empty())
        .filter(|_| endpoint.key_allowed && endpoint.provider.key != KeyUse::None);
    if endpoint.provider.key == KeyUse::Required && key.is_none() {
        return Err(VoiceError::new(
            ErrorCode::KeyMissing,
            &format!("no {} key is saved for {}", endpoint.provider.label, endpoint.origin),
            None,
        ));
    }
    match endpoint.provider.wire {
        Wire::Builtin => Err(VoiceError::bare(ErrorCode::NotConfigured)),
        Wire::OpenaiTranscriptions | Wire::WhisperCppInference => {
            Ok(Box::new(HttpBatch { endpoint, key, http }))
        }
    }
}

/// The two HTTP batch wires.
pub struct HttpBatch {
    endpoint: Endpoint,
    key: Option<String>,
    http: Http,
}

/// The primary subtag of a BCP 47 tag (`en-US` -> `en`), or `None` when it is not 2 to 8 letters.
pub fn primary_language(tag: &str) -> Option<String> {
    let primary = tag.trim().split(['-', '_']).next()?;
    let ok = (2..=8).contains(&primary.len()) && primary.chars().all(|c| c.is_ascii_alphabetic());
    ok.then(|| primary.to_ascii_lowercase())
}

impl HttpBatch {
    fn key(&self) -> Option<&str> {
        self.key.as_deref()
    }

    fn client(&self) -> Result<reqwest::Client, VoiceError> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut builder = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(self.http.connect_timeout)
            .timeout(self.http.total_timeout)
            .user_agent(concat!("cmux-voice/", env!("CARGO_PKG_VERSION")));
        // A server on this Mac or the LAN is reached directly, never through a proxy.
        if self.endpoint.base_url.starts_with("http://") {
            builder = builder.no_proxy();
        }
        builder.build().map_err(|e| {
            VoiceError::new(ErrorCode::ProviderError, &format!("cannot start HTTP: {e}"), None)
        })
    }

    fn authorize(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        match self.key() {
            Some(key) => request.header("Authorization", format!("Bearer {key}")),
            None => request,
        }
    }

    /// Sends `request`: the status and up to [`MAX_ANSWER_BYTES`] of the body.
    async fn send(&self, request: reqwest::RequestBuilder) -> Result<(u16, Vec<u8>), VoiceError> {
        let mut response = request.send().await.map_err(|e| transport_error(&e, self.key()))?;
        let status = response.status().as_u16();
        let mut body = Vec::new();
        while let Some(chunk) =
            response.chunk().await.map_err(|e| transport_error(&e, self.key()))?
        {
            if body.len().saturating_add(chunk.len()) > MAX_ANSWER_BYTES {
                return Err(VoiceError::new(
                    ErrorCode::BadResponse,
                    "the answer is too long",
                    None,
                ));
            }
            body.extend_from_slice(&chunk);
        }
        Ok((status, body))
    }

    async fn transcribe_now(&self, request: BatchRequest<'_>) -> Result<Transcript, VoiceError> {
        let language = request.language.and_then(primary_language);
        let mut parts = vec![Part::file("file", "recording.wav", "audio/wav", request.audio)];
        let path = match self.endpoint.provider.wire {
            Wire::WhisperCppInference => "inference",
            Wire::OpenaiTranscriptions | Wire::Builtin => {
                if !self.endpoint.model.is_empty() {
                    parts.push(Part::text("model", &self.endpoint.model));
                }
                "audio/transcriptions"
            }
        };
        parts.push(Part::text("response_format", "json"));
        if let Some(language) = &language {
            parts.push(Part::text("language", language));
        }
        let boundary = multipart::boundary(&parts);
        let body = multipart::body(&boundary, &parts);
        let client = self.client()?;
        let request = client
            .post(self.endpoint.url_for(path))
            .header("Content-Type", multipart::content_type(&boundary))
            .header("Accept", "application/json")
            .body(body);
        let (status, answer) = self.send(self.authorize(request)).await?;
        if !(200..300).contains(&status) {
            return Err(status_error(status, &answer, self.key()));
        }
        let text = serde_json::from_slice::<Value>(&answer)
            .ok()
            .and_then(|v| v.get("text").and_then(Value::as_str).map(str::to_owned))
            .ok_or_else(|| {
                VoiceError::new(ErrorCode::BadResponse, "the answer has no text", None)
            })?;
        Ok(Transcript { text: text.trim().to_owned() })
    }

    async fn check_now(&self) -> Result<(), VoiceError> {
        let url = match self.endpoint.provider.wire {
            Wire::WhisperCppInference => self.endpoint.base_url.clone(),
            Wire::OpenaiTranscriptions | Wire::Builtin => self.endpoint.url_for("models"),
        };
        let client = self.client()?;
        let (status, answer) = self.send(self.authorize(client.get(url))).await?;
        if (200..300).contains(&status) {
            Ok(())
        } else {
            Err(status_error(status, &answer, self.key()))
        }
    }
}

impl DictationProvider for HttpBatch {
    fn capabilities(&self) -> &'static [Capability] {
        self.endpoint.provider.capabilities
    }

    fn transcribe<'a>(
        &'a self,
        request: BatchRequest<'a>,
    ) -> BoxFuture<'a, Result<Transcript, VoiceError>> {
        Box::pin(self.transcribe_now(request))
    }

    fn check(&self) -> BoxFuture<'_, Result<(), VoiceError>> {
        Box::pin(self.check_now())
    }
}

/// A failed request (no status): `timeout`, else `offline`. The detail is the error's causes,
/// without the URL.
fn transport_error(e: &reqwest::Error, key: Option<&str>) -> VoiceError {
    let code = if e.is_timeout() { ErrorCode::Timeout } else { ErrorCode::Offline };
    let mut causes = Vec::new();
    let mut source = std::error::Error::source(e);
    while let Some(s) = source {
        causes.push(s.to_string());
        source = s.source();
    }
    let detail = if causes.is_empty() { e.to_string() } else { causes.join(": ") };
    VoiceError::new(code, &detail, key)
}

/// The provider's own words in an error answer: `error.message`, `error`, `message` or
/// `detail`, else the body as text.
fn provider_message(body: &[u8]) -> String {
    if let Ok(v) = serde_json::from_slice::<Value>(body) {
        let found = [
            v.pointer("/error/message"),
            v.get("error"),
            v.get("message"),
            v.get("detail"),
            v.pointer("/detail/0/msg"),
        ]
        .into_iter()
        .flatten()
        .find_map(Value::as_str);
        return found.map(str::to_owned).unwrap_or_default();
    }
    String::from_utf8_lossy(body).into_owned()
}

/// A non-2xx answer as its code.
pub fn status_error(status: u16, body: &[u8], key: Option<&str>) -> VoiceError {
    let code = match status {
        401 | 403 => ErrorCode::KeyInvalid,
        404 | 405 => ErrorCode::BadEndpoint,
        408 => ErrorCode::Timeout,
        413 => ErrorCode::TooLarge,
        429 => ErrorCode::RateLimited,
        300..=399 => ErrorCode::BadEndpoint,
        400..=499 => ErrorCode::Rejected,
        500..=599 => ErrorCode::ProviderError,
        _ => ErrorCode::BadResponse,
    };
    let message = provider_message(body);
    let message = message.trim();
    let detail = if (300..400).contains(&status) {
        format!("{status}: the server redirects (not followed)")
    } else if message.is_empty() {
        status.to_string()
    } else {
        format!("{status}: {message}")
    };
    VoiceError::new(code, &detail, key)
}

#[cfg(test)]
#[path = "provider_tests.rs"]
mod tests;
