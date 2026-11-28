//! A pasted model API key, made whole and asked about before it is saved
//! (`_acpmux/connections/key.check`).
//!
//! A paste carries what the copy added: a line break where a terminal or a web page wrapped the
//! key, spaces around it, a zero-width space from a rich-text page. No provider's key holds any of
//! those, so [`without_whitespace`] takes every one out. [`shape_ok`] then asks whether what is
//! left reads as the provider's key (OpenAI `sk-`, Anthropic `sk-ant-`, OpenRouter `sk-or-`,
//! Google `AIza`, xAI `xai-`), and [`check`] asks the provider itself with one cheap
//! authenticated read (its model list, or OpenRouter's key endpoint), so a wrong key is said at
//! the paste instead of at the first chat turn.
//!
//! A provider that does not answer (network, timeout, 5xx) is [`Verdict::Unreachable`]: the key
//! is saved anyway. The key never reaches a log, an error or the answer.

use std::time::Duration;

/// How long the provider has to answer before the key is saved unasked.
// timeout: past it the key is saved unchecked (Verdict::Unreachable); the save never fails on it.
pub const CHECK_TIMEOUT: Duration = Duration::from_secs(8);

/// What the provider said about a key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The provider accepted it.
    Ok,
    /// It does not read as this provider's key (no request was made).
    BadShape,
    /// The provider refused it (HTTP status).
    BadKey(u16),
    /// The provider was not reached or answered something else: save anyway.
    Unreachable(String),
}

impl Verdict {
    pub fn as_str(&self) -> &'static str {
        match self {
            Verdict::Ok => "ok",
            Verdict::BadShape => "bad_shape",
            Verdict::BadKey(_) => "bad_key",
            Verdict::Unreachable(_) => "unreachable",
        }
    }

    /// Whether the key should not be saved.
    pub fn rejects(&self) -> bool {
        matches!(self, Verdict::BadShape | Verdict::BadKey(_))
    }

    /// The person's sentence for a refused key (Settings > Models shows it); None when it saves.
    pub fn sentence(&self, provider: &str) -> Option<String> {
        let name = name(provider);
        match self {
            Verdict::BadKey(_) => Some(format!("Key rejected by {name}")),
            Verdict::BadShape => Some(match prefix(provider) {
                Some(p) => format!("Not a key from {name}: {name} keys start with {p}"),
                None => "That is not an API key".to_owned(),
            }),
            _ => None,
        }
    }
}

/// The provider's name as a person reads it.
pub fn name(provider: &str) -> &str {
    match provider {
        "openai" => "OpenAI",
        "anthropic" => "Anthropic",
        "openrouter" => "OpenRouter",
        "google" => "Google",
        "xai" => "xAI",
        other => other,
    }
}

/// SECRET with every whitespace character and invisible space (zero-width space, non-joiner,
/// joiner, word joiner, BOM) taken out.
pub fn without_whitespace(secret: &str) -> String {
    secret
        .chars()
        .filter(|c| {
            !c.is_whitespace()
                && !matches!(c, '\u{200B}' | '\u{200C}' | '\u{200D}' | '\u{2060}' | '\u{FEFF}')
        })
        .collect()
}

/// What a Claude Code setup token starts with.
pub const CLAUDE_TOKEN_PREFIX: &str = "sk-ant-oat";

/// The prefix a provider's keys start with; None: no shape is checked.
fn prefix(provider: &str) -> Option<&'static str> {
    match provider {
        "openai" => Some("sk-"),
        "anthropic" => Some("sk-ant-"),
        "openrouter" => Some("sk-or-"),
        "google" => Some("AIza"),
        "xai" => Some("xai-"),
        _ => None,
    }
}

/// Whether KEY reads as PROVIDER's key: printable ASCII with no spaces, at most 512 bytes, and the
/// provider's prefix (with something after it) when it has one.
pub fn shape_ok(provider: &str, key: &str) -> bool {
    let printable =
        !key.is_empty() && key.len() <= 512 && key.bytes().all(|b| b.is_ascii_graphic());
    printable && prefix(provider).is_none_or(|p| key.starts_with(p) && key.len() > p.len() + 4)
}

/// Where PROVIDER is asked by default.
pub fn default_base(provider: &str) -> Option<&'static str> {
    match provider {
        "openai" => Some("https://api.openai.com"),
        "anthropic" => Some("https://api.anthropic.com"),
        "openrouter" => Some("https://openrouter.ai"),
        "google" => Some("https://generativelanguage.googleapis.com"),
        "xai" => Some("https://api.x.ai"),
        _ => None,
    }
}

/// The authenticated read that proves a key, under BASE (no trailing slash).
fn probe(
    provider: &str,
    base: &str,
    key: &str,
    client: &reqwest::Client,
) -> reqwest::RequestBuilder {
    match provider {
        // A Claude Code setup token (`claude setup-token`) is an OAuth bearer, not an API key:
        // Anthropic reads it from Authorization with the OAuth beta header (cmux#57418).
        "anthropic" if key.starts_with(CLAUDE_TOKEN_PREFIX) => client
            .get(format!("{base}/v1/models?limit=1"))
            .bearer_auth(key)
            .header("anthropic-beta", "oauth-2025-04-20")
            .header("anthropic-version", "2023-06-01"),
        "anthropic" => client
            .get(format!("{base}/v1/models?limit=1"))
            .header("x-api-key", key)
            .header("anthropic-version", "2023-06-01"),
        // OpenRouter's model list is public: its key endpoint is not.
        "openrouter" => client.get(format!("{base}/api/v1/key")).bearer_auth(key),
        "google" => {
            client.get(format!("{base}/v1beta/models?pageSize=1")).header("x-goog-api-key", key)
        }
        _ => client.get(format!("{base}/v1/models")).bearer_auth(key),
    }
}

/// Asks PROVIDER (at BASE, else [`default_base`]) whether KEY is good. A key of the wrong shape is
/// refused without a request; a provider with no known base is `Unreachable` (save anyway).
pub async fn check(provider: &str, key: &str, base: Option<&str>, timeout: Duration) -> Verdict {
    if !shape_ok(provider, key) {
        return Verdict::BadShape;
    }
    let Some(base) = base.or_else(|| default_base(provider)) else {
        return Verdict::Unreachable("no check for this provider".into());
    };
    let base = base.trim_end_matches('/');
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = match crate::happy_dial::http_client()
        .timeout(timeout)
        // timeout: connecting to a model provider to check a pasted key; the whole check keeps CHECK_TIMEOUT
        .connect_timeout(timeout.min(Duration::from_secs(5)))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(client) => client,
        Err(_) => return Verdict::Unreachable("cannot make the request".into()),
    };
    let response = match probe(provider, base, key, &client).send().await {
        Ok(response) => response,
        Err(e) if e.is_timeout() => {
            return Verdict::Unreachable(format!("no answer in {} s", timeout.as_secs()));
        }
        Err(_) => return Verdict::Unreachable("not reached".into()),
    };
    let status = response.status().as_u16();
    match status {
        200..=299 => Verdict::Ok,
        401 | 403 => Verdict::BadKey(status),
        // Google and xAI answer a key they do not know with 400.
        400 if matches!(provider, "google" | "xai") => Verdict::BadKey(status),
        _ => Verdict::Unreachable(format!("HTTP {status}")),
    }
}

#[cfg(test)]
#[path = "key_check_tests.rs"]
mod tests;
