//! Part of `Hub`; see `hub/mod.rs`. What an API connection failure says is wrong, and when the
//! harness tries again, for the chat's status row.
//!
//! Lucas Ribeiro's Mac, 2026-11-23: 40 `api_error` "Can't reach the API server (ENOTFOUND
//! api.anthropic.com)" in 18 minutes (11:25-11:43Z) and the chat showed nothing, the sessions sat
//! idle until DNS came back. Rust classifies the failure ([`classify`]) and computes the deadline
//! of the next try ([`retry_at`]); `turn_retrying` records carry `cause`, `host` and `retryAt`
//! (epoch ms), and the webview only draws them (`conversation/thinkingModel.ts`).

use serde_json::Value;

/// What a connection failure names: the kind of failure and, when the text names one, the host
/// that could not be reached.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Outage {
    /// `dns`, `refused`, `timeout` or `unreachable`.
    pub cause: &'static str,
    pub host: Option<String>,
}

/// Hosts named when the text names no other: the model APIs the agents call.
const KNOWN_HOSTS: &[&str] = &["api.anthropic.com", "api.openai.com", "chatgpt.com", "claude.ai"];

/// Whether `text` (an agent's error, or the strings of a retry line) says the API could not be
/// reached, and why. Only failures of the connection: a 503 or an overloaded model is the
/// provider's answer, not an outage of ours.
pub(crate) fn classify(text: &str) -> Option<Outage> {
    let m = text.to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| m.contains(w));
    let cause = if has(&["enotfound", "eai_again", "getaddrinfo", "could not resolve", "dns"]) {
        "dns"
    } else if has(&["econnrefused", "connection refused"]) {
        "refused"
    } else if has(&["etimedout", "timed out", "timeout"]) {
        "timeout"
    } else if has(&[
        "can't reach the api",
        "cannot reach the api",
        "unable to connect",
        "ehostunreach",
        "enetunreach",
        "network is unreachable",
        "no route to host",
    ]) {
        "unreachable"
    } else {
        return None;
    };
    Some(Outage { cause, host: host_in(text) })
}

/// The host the text names: the word after the error code (`ENOTFOUND api.anthropic.com`), the
/// host of a URL, else one of [`KNOWN_HOSTS`].
fn host_in(text: &str) -> Option<String> {
    let word = |w: &str| {
        // A URL names its host between the scheme and the port or path.
        let w = w.split_once("://").map_or(w, |(_, rest)| rest);
        let w = w.split(['/', ':']).next().unwrap_or("");
        let w = w.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '.' || c == '-'));
        let hostish = w.contains('.')
            && w.chars().any(|c| c.is_ascii_alphabetic())
            && !w.starts_with('.')
            && !w.ends_with('.');
        hostish.then(|| w.to_lowercase())
    };
    let words: Vec<&str> = text.split_whitespace().collect();
    for (i, w) in words.iter().enumerate() {
        let lw = w.to_lowercase();
        if (lw.contains("enotfound") || lw.contains("econnrefused") || lw.contains("etimedout"))
            && let Some(host) = words.get(i + 1).and_then(|n| word(n))
        {
            return Some(host);
        }
        if let Some(rest) = lw.split("://").nth(1) {
            let host = rest.split(['/', ':', ')', '"', ',']).next().unwrap_or("");
            if let Some(host) = word(host) {
                return Some(host);
            }
        }
    }
    let m = text.to_lowercase();
    KNOWN_HOSTS.iter().find(|h| m.contains(*h)).map(|h| (*h).to_owned())
}

/// Every string in `line`, joined: Claude Code's retry line names a failure under `error`,
/// `message` or a `cause`, depending on its version.
pub(crate) fn strings_of(line: &Value) -> String {
    fn walk(v: &Value, out: &mut Vec<String>, depth: u8) {
        match v {
            Value::String(s) => out.push(s.clone()),
            Value::Array(a) if depth < 4 => a.iter().for_each(|v| walk(v, out, depth + 1)),
            Value::Object(o) if depth < 4 => o.values().for_each(|v| walk(v, out, depth + 1)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(line, &mut out, 0);
    out.join(" ")
}

/// The moment (epoch ms) the harness tries again: `now_ms` plus its announced delay; none when it
/// announced none.
pub(crate) fn retry_at(now_ms: u64, delay_ms: Option<u64>) -> Option<u64> {
    delay_ms.map(|d| now_ms.saturating_add(d))
}

#[cfg(test)]
#[path = "outage_tests.rs"]
mod tests;
