//! Secrets in text this daemon shows elsewhere (hq#2509): API keys, tokens,
//! private keys and credentials a person pasted into a prompt, found and
//! replaced by a typed mask such as `[github token]`.
//!
//! This is a destructive transform, not a visual cover: `mask` returns new
//! text that no longer holds the secret, so a client or an acpmux peer that
//! receives it never has the source to reveal. The original stays wherever
//! it already was (the transcript, the store); only the masked copy leaves.
//!
//! The lanes view's step line (`hub::views::lane`) is the first user. The
//! module only reads text, so transcripts, notifications and the phone relay
//! can share it.
//!
//! What it does not catch: a secret with no known shape that is shorter than
//! 32 characters or not mixed-case alphanumeric (an 8-character password in
//! prose), and a base64 run split by `/` into short pieces. What it leaves
//! alone on purpose: git SHAs and other hex, UUIDs, file paths, and
//! `data:...;base64,` payloads (an inline image is not a secret).

use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;

/// What a found secret looked like; its mask says so.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecretKind {
    PrivateKey,
    AnthropicKey,
    OpenAiKey,
    StripeKey,
    GithubToken,
    SlackToken,
    AwsKey,
    GoogleKey,
    Jwt,
    AuthHeader,
    UrlCredentials,
    /// The value of `NAME=value` or `"name": "value"` where the name says
    /// key, token, secret or password.
    Assignment,
    /// A long mixed-case alphanumeric run with a random-looking spread.
    HighEntropy,
}

impl SecretKind {
    /// The text that replaces it.
    pub fn mask(self) -> &'static str {
        match self {
            Self::PrivateKey => "[private key]",
            Self::AnthropicKey => "[anthropic key]",
            Self::OpenAiKey => "[openai key]",
            Self::StripeKey => "[stripe key]",
            Self::GithubToken => "[github token]",
            Self::SlackToken => "[slack token]",
            Self::AwsKey => "[aws key]",
            Self::GoogleKey => "[google key]",
            Self::Jwt => "[jwt]",
            Self::AuthHeader => "[auth token]",
            Self::UrlCredentials => "[credentials]",
            Self::Assignment | Self::HighEntropy => "[secret]",
        }
    }
}

/// One secret: its kind and its byte range in the text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub kind: SecretKind,
    pub range: Range<usize>,
}

/// A shape, and the capture group that is the secret (0 for the whole match;
/// a group keeps a header name, a URL's scheme or a variable name visible).
struct Rule {
    kind: SecretKind,
    re: Regex,
    group: usize,
}

/// Earlier rules win where matches overlap: a known shape names its kind
/// better than the generic header, assignment or entropy rules.
static RULES: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    use SecretKind::*;
    [
        (PrivateKey, r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?s:.*?)(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)", 0),
        (AnthropicKey, r"\bsk-ant-[A-Za-z0-9_-]{16,}", 0),
        (OpenAiKey, r"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}", 0),
        (StripeKey, r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|\bwhsec_[A-Za-z0-9]{16,}", 0),
        (GithubToken, r"\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}", 0),
        (SlackToken, r"\bxox[abposr]-[A-Za-z0-9-]{10,}|\bxapp-[0-9]+-[A-Za-z0-9-]{10,}", 0),
        (AwsKey, r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b", 0),
        (GoogleKey, r"\bAIza[0-9A-Za-z_-]{35}", 0),
        (Jwt, r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", 0),
        (
            AuthHeader,
            r"(?i)\b(?:proxy-)?authorization\s*[:=]\s*(?:bearer|basic|token|digest)\s+([A-Za-z0-9._~+/-]+=*)",
            1,
        ),
        (AuthHeader, r"(?i)\bbearer\s+([A-Za-z0-9._~+/-]{16,}=*)", 1),
        (AuthHeader, r#"(?i)\b(?:x-api-key|api-key|x-auth-token)["']?\s*[:=]\s*["']?([A-Za-z0-9._~+/-]{8,})"#, 1),
        (UrlCredentials, r"\b[a-zA-Z][a-zA-Z0-9+.-]*://([^\s/?#@:]+:[^\s/?#@]+)@", 1),
        (
            Assignment,
            r#"(?i)\b[a-z0-9_-]*(?:api[_-]?key|secret|token|passw(?:or)?d|credentials?|private[_-]?key|access[_-]?key)[a-z0-9_-]*["']?\s*[=:]\s*("[^"\s]{6,}"|'[^'\s]{6,}'|[^\s"',;]{6,})"#,
            1,
        ),
    ]
    .into_iter()
    .map(|(kind, pattern, group)| Rule { kind, re: Regex::new(pattern).expect("constant pattern"), group }) // crash-allow: constant pattern
    .collect()
});

static ENTROPY_CANDIDATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[A-Za-z0-9+_-]{32,}=*").expect("constant pattern")); // crash-allow: constant pattern
static DATA_URI: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"data:[A-Za-z]+/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+").expect("constant pattern") // crash-allow: constant pattern
});

/// Bits per character; random base62 runs about 5, English words in
/// camelCase about 4.
fn entropy(s: &str) -> f64 {
    let mut counts = [0u32; 256];
    for b in s.bytes() {
        counts[b as usize] += 1;
    }
    let n = s.len() as f64;
    counts.iter().filter(|&&c| c > 0).map(|&c| f64::from(c) / n).map(|p| -p * p.log2()).sum()
}

/// A run that reads as a random token: upper and lower case, at least three
/// digits, and a spread no word or identifier has. Hex (git SHAs, hashes)
/// and UUIDs lack one of the cases, so they never qualify.
fn looks_random(s: &str) -> bool {
    s.bytes().any(|b| b.is_ascii_uppercase())
        && s.bytes().any(|b| b.is_ascii_lowercase())
        && s.bytes().filter(u8::is_ascii_digit).count() >= 3
        && entropy(s) >= 4.3
}

/// A placeholder, not a value: `$TOKEN`, `${{ secrets.X }}`, `<your key>`.
fn is_placeholder(value: &str) -> bool {
    let v = value.trim_matches(['"', '\'']);
    v.starts_with(['$', '<', '[']) || v.chars().all(|c| c == '*' || c == 'x' || c == 'X')
}

/// Every secret in `text`, in order, with overlapping finds merged into one.
pub fn find(text: &str) -> Vec<Found> {
    let mut all: Vec<(usize, Found)> = Vec::new();
    for (order, rule) in RULES.iter().enumerate() {
        for caps in rule.re.captures_iter(text) {
            let Some(m) = caps.get(rule.group) else { continue };
            if rule.kind == SecretKind::Assignment && is_placeholder(m.as_str()) {
                continue;
            }
            // `sk-learn-preprocessing-pipelines` is a package, not a key: a key has digits and capitals.
            let mixed = |s: &str| s.bytes().any(|b| b.is_ascii_digit()) && s.bytes().any(|b| b.is_ascii_uppercase());
            if rule.kind == SecretKind::OpenAiKey && !mixed(m.as_str()) {
                continue;
            }
            all.push((order, Found { kind: rule.kind, range: m.range() }));
        }
    }
    let data: Vec<Range<usize>> = DATA_URI.find_iter(text).map(|m| m.range()).collect();
    for m in ENTROPY_CANDIDATE.find_iter(text) {
        let inside_data = data.iter().any(|d| d.start <= m.start() && m.end() <= d.end);
        if !inside_data && looks_random(m.as_str()) {
            all.push((RULES.len(), Found { kind: SecretKind::HighEntropy, range: m.range() }));
        }
    }
    all.sort_by_key(|(order, f)| (f.range.start, *order));
    let mut merged: Vec<Found> = Vec::new();
    for (_, f) in all {
        match merged.last_mut() {
            Some(last) if f.range.start < last.range.end => last.range.end = last.range.end.max(f.range.end),
            _ => merged.push(f),
        }
    }
    merged
}

/// `text` with every secret replaced by its kind's mask.
pub fn mask(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    for f in find(text) {
        out.push_str(&text[at..f.range.start]);
        out.push_str(f.kind.mask());
        at = f.range.end;
    }
    out.push_str(&text[at..]);
    out
}

#[cfg(test)]
#[path = "secret_scan_tests.rs"]
mod tests;
