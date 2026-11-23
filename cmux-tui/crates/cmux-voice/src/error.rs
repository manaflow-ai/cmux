//! The closed set of dictation error codes, and the short scrubbed detail each carries.

use serde::Serialize;

/// The most characters a `detail` carries.
pub const MAX_DETAIL_CHARS: usize = 200;

/// What went wrong, as the app maps it to a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The provider needs a key and none is saved for this origin.
    KeyMissing,
    /// 401 or 403.
    KeyInvalid,
    /// DNS or connect failure.
    Offline,
    /// Connect (10 s) or whole request (60 s) ran out, or a 408.
    Timeout,
    /// 429.
    RateLimited,
    /// A bad or forbidden URL, a 404 or 405, or a redirect (never followed).
    BadEndpoint,
    /// 400 or 422 (and any other 4xx): the provider refused the request.
    Rejected,
    /// 413, or a recording over the cap before anything is sent.
    TooLarge,
    /// 5xx.
    ProviderError,
    /// Not the expected JSON.
    BadResponse,
    /// The engine is on-device, or a provider that needs a URL has none.
    NotConfigured,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::KeyMissing => "key_missing",
            Self::KeyInvalid => "key_invalid",
            Self::Offline => "offline",
            Self::Timeout => "timeout",
            Self::RateLimited => "rate_limited",
            Self::BadEndpoint => "bad_endpoint",
            Self::Rejected => "rejected",
            Self::TooLarge => "too_large",
            Self::ProviderError => "provider_error",
            Self::BadResponse => "bad_response",
            Self::NotConfigured => "not_configured",
        }
    }
}

/// `{code, detail}`: `detail` is at most [`MAX_DETAIL_CHARS`] characters on one line and never
/// holds the key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VoiceError {
    pub code: ErrorCode,
    pub detail: String,
}

impl VoiceError {
    /// An error whose detail is `detail` made safe: `key` (when there is one) replaced, whitespace
    /// folded to single spaces, capped.
    pub fn new(code: ErrorCode, detail: &str, key: Option<&str>) -> Self {
        Self { code, detail: scrub(detail, key) }
    }

    /// An error with an empty detail.
    pub fn bare(code: ErrorCode) -> Self {
        Self { code, detail: String::new() }
    }
}

impl std::fmt::Display for VoiceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.detail.is_empty() {
            f.write_str(self.code.as_str())
        } else {
            write!(f, "{}: {}", self.code.as_str(), self.detail)
        }
    }
}

impl std::error::Error for VoiceError {}

/// `text` with `key` replaced by `[key]`, control characters and runs of whitespace folded to
/// one space, trimmed, and cut to [`MAX_DETAIL_CHARS`] characters.
pub fn scrub(text: &str, key: Option<&str>) -> String {
    let replaced = match key.map(str::trim).filter(|k| !k.is_empty()) {
        Some(k) => text.replace(k, "[key]"),
        None => text.to_owned(),
    };
    let folded =
        replaced.split(|c: char| c.is_whitespace() || c.is_control()).filter(|w| !w.is_empty());
    let mut out = String::new();
    for word in folded {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
    }
    // The key could still appear once whitespace inside it was folded; check again.
    if let Some(k) = key.map(str::trim).filter(|k| !k.is_empty()) {
        out = out.replace(k, "[key]");
    }
    out.chars().take(MAX_DETAIL_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_serialize_snake_case() {
        let e = VoiceError::bare(ErrorCode::RateLimited);
        assert_eq!(
            serde_json::to_value(&e).unwrap(),
            serde_json::json!({"code": "rate_limited", "detail": ""})
        );
        for code in [
            ErrorCode::KeyMissing,
            ErrorCode::KeyInvalid,
            ErrorCode::Offline,
            ErrorCode::Timeout,
            ErrorCode::RateLimited,
            ErrorCode::BadEndpoint,
            ErrorCode::Rejected,
            ErrorCode::TooLarge,
            ErrorCode::ProviderError,
            ErrorCode::BadResponse,
            ErrorCode::NotConfigured,
        ] {
            assert_eq!(serde_json::to_value(code).unwrap(), serde_json::json!(code.as_str()));
        }
    }

    #[test]
    fn detail_is_scrubbed_folded_and_capped() {
        let e = VoiceError::new(
            ErrorCode::KeyInvalid,
            "bad key sk-secret-123\n\n  try again",
            Some("sk-secret-123"),
        );
        assert_eq!(e.detail, "bad key [key] try again");
        let long = "é".repeat(500);
        assert_eq!(scrub(&long, None).chars().count(), MAX_DETAIL_CHARS);
        assert_eq!(scrub("a\u{0}b", None), "a b");
        assert_eq!(scrub("no key here", Some("")), "no key here");
    }
}
