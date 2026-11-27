//! The redirect URLs the hosted sign-in page sends Stack, and Stack's check of them against an
//! auth project's trusted domains, so a test can prove a build's sign-in passes before anyone
//! clicks "Continue with Google".
//!
//! Stack never sees the app's callback scheme: [`crate::config::sign_in_url`] nests
//! `<scheme>://auth-callback` inside `after_auth_return_to`, a query value of a URL on the auth web
//! origin. What Stack checks is the page's own address: the OAuth `redirect_uri`
//! (`/handler/oauth-callback`), `after_callback_redirect_url` and `error_redirect_url`, and the
//! magic link's `callback_url` (`/handler/magic-link-callback`). Its check compares only the scheme,
//! host and port of each (`validateRedirectUrl` in the Stack SDK's shared `utils/redirect-urls`), so
//! one trusted origin covers every build whose sign-in page lives there, whatever its tag.
//!
//! A refused URL fails the page with `REDIRECT_URL_NOT_WHITELISTED` before the app is reached.

use serde::{Deserialize, Serialize};

use crate::origin;

/// One auth project's redirect allowlist, as its dashboard holds it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedDomains {
    /// The dashboard's "allow localhost" switch: any loopback URL passes.
    pub allow_localhost: bool,
    /// The trusted domains: `https://cmux.com`, or a pattern (`https://*.cmux.com`, `https://host:*`).
    pub trusted_domains: Vec<String>,
}

/// The URLs the hosted sign-in page on `auth_web_origin` sends Stack, every one of which Stack
/// checks: the OAuth callback, the page the OAuth trip returns to, the error page, and the magic
/// link callback.
pub fn hosted_page_redirect_urls(auth_web_origin: &str) -> Vec<String> {
    let origin = auth_web_origin.trim_end_matches('/');
    ["oauth-callback", "sign-in", "error", "magic-link-callback"]
        .iter()
        .map(|page| format!("{origin}/handler/{page}"))
        .collect()
}

/// Whether Stack accepts `url` as a redirect for a project with `trusted` (the SDK's
/// `validateRedirectUrl`): loopback when localhost is allowed, else a trusted domain with the same
/// scheme, host and port. Path and query never matter.
pub fn redirect_url_trusted(url: &str, trusted: &TrustedDomains) -> bool {
    let Some(parts) = origin::parse(url).filter(|parts| !parts.host.is_empty()) else {
        return false;
    };
    if trusted.allow_localhost && is_localhost(&parts.host) {
        return true;
    }
    trusted.trusted_domains.iter().any(|pattern| matches_trusted_domain(&parts, pattern))
}

/// The origin (`scheme://host[:port]`) of a URL Stack refused, for the error a person reads.
pub fn rejected_origin(url: &str) -> Option<String> {
    let parts = origin::parse(url).filter(|parts| !parts.host.is_empty())?;
    let host = if parts.host.contains(':') { format!("[{}]", parts.host) } else { parts.host };
    Some(match parts.port.filter(|port| !port.is_empty()) {
        Some(port) => format!("{}://{host}:{port}", parts.scheme),
        None => format!("{}://{host}", parts.scheme),
    })
}

fn is_localhost(host: &str) -> bool {
    host == "localhost"
        || host.ends_with(".localhost")
        || host == "::1"
        || host
            .strip_prefix("127.")
            .is_some_and(|rest| rest.split('.').count() == 3 && rest.split('.').all(is_decimal))
}

fn is_decimal(part: &str) -> bool {
    !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())
}

/// The port Stack compares: the explicit one, else the scheme's default.
fn effective_port(scheme: &str, port: Option<&str>) -> Option<String> {
    match port.filter(|port| !port.is_empty()) {
        Some(port) => Some(port.to_owned()),
        None => match scheme {
            "https" => Some("443".to_owned()),
            "http" => Some("80".to_owned()),
            _ => None,
        },
    }
}

fn is_default_port(scheme: &str, port: Option<&str>) -> bool {
    match port.filter(|port| !port.is_empty()) {
        None => true,
        Some(port) => (scheme == "https" && port == "443") || (scheme == "http" && port == "80"),
    }
}

fn host_with_port(parts: &origin::Parts<'_>) -> String {
    match effective_port(&parts.scheme, parts.port) {
        Some(port) => format!("{}:{port}", parts.host),
        None => parts.host.clone(),
    }
}

fn matches_trusted_domain(url: &origin::Parts<'_>, pattern: &str) -> bool {
    let Some((scheme, rest)) = pattern.split_once("://") else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case(&url.scheme) {
        return false;
    }
    let host_pattern = rest.split(['/', '?', '#']).next().unwrap_or_default().to_ascii_lowercase();
    if host_pattern.is_empty() {
        return false;
    }
    if !pattern.contains('*') {
        let Some(base) = origin::parse(pattern) else {
            return false;
        };
        return base.host == url.host
            && effective_port(&base.scheme, base.port) == effective_port(&url.scheme, url.port);
    }
    if has_explicit_port(&host_pattern) {
        wildcard_match(host_pattern.as_bytes(), host_with_port(url).as_bytes())
    } else {
        wildcard_match(host_pattern.as_bytes(), url.host.as_bytes())
            && is_default_port(&url.scheme, url.port)
    }
}

fn has_explicit_port(host_pattern: &str) -> bool {
    host_pattern.rsplit_once(':').is_some_and(|(_, port)| port == "*" || is_decimal(port))
}

/// Stack's host pattern: `**` matches anything, `*` anything but a dot, the rest itself.
fn wildcard_match(pattern: &[u8], text: &[u8]) -> bool {
    match pattern {
        [] => text.is_empty(),
        [b'*', b'*', rest @ ..] => (0..=text.len())
            .any(|skip| text.get(skip..).is_some_and(|tail| wildcard_match(rest, tail))),
        [b'*', rest @ ..] => {
            let run = text.iter().take_while(|byte| **byte != b'.').count();
            (0..=run).any(|skip| text.get(skip..).is_some_and(|tail| wildcard_match(rest, tail)))
        }
        [first, rest @ ..] => match text {
            [head, tail @ ..] => head == first && wildcard_match(rest, tail),
            [] => false,
        },
    }
}

#[cfg(test)]
#[path = "stack_redirects_tests.rs"]
mod tests;
