//! `browser.newTabPage` address rule (Swift `BrowserNewTabPage.url(from:)`).
//!
//! A value with a scheme must use http, https, file or about. A value
//! without one gets `https://` and must then have a host and contain a dot
//! (`example.com` is fine, `localhost` is not).

use crate::text::trim_whitespaces;

const SCHEMES: [&str; 4] = ["http", "https", "file", "about"];

/// Whether `text` names a web, file or about address.
pub fn new_tab_page_url_is_valid(text: &str) -> bool {
    let trimmed = trim_whitespaces(text);
    if trimmed.is_empty() || trimmed.contains(' ') {
        return false;
    }
    if let Some(scheme) = scheme(trimmed) {
        return SCHEMES.contains(&scheme.to_ascii_lowercase().as_str());
    }
    trimmed.contains('.') && has_host(&format!("https://{trimmed}"))
}

/// Swift `SettingDescriptor.httpOrigin`: an http or https address with a
/// host and nothing else (no user info, no path other than `/`, no query, no
/// fragment, no whitespace), such as `http://mini.tail1234.ts.net:7320`.
pub fn is_http_origin(text: &str) -> bool {
    if text.chars().any(|c| c.is_whitespace() || matches!(c, '?' | '#' | '@')) {
        return false;
    }
    let lower = text.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("http://").or_else(|| lower.strip_prefix("https://"))
    else {
        return false;
    };
    let (authority, path) =
        rest.split_once('/').map_or((rest, ""), |(authority, path)| (authority, path));
    if !path.is_empty() {
        return false;
    }
    let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
        let Some((host, after)) = bracketed.split_once(']') else { return false };
        match after {
            "" => (host, None),
            _ => match after.strip_prefix(':') {
                Some(port) => (host, Some(port)),
                None => return false,
            },
        }
    } else {
        match authority.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        }
    };
    // An empty port (`http://host:`) is no port, as Swift `URLComponents` reads it.
    let port_ok =
        port.is_none_or(|port| port.len() <= 5 && port.bytes().all(|byte| byte.is_ascii_digit()));
    let host_ok = if authority.starts_with('[') {
        !host.is_empty()
    } else {
        !host.is_empty() && !host.contains(':')
    };
    host_ok && port_ok
}

/// The RFC 3986 scheme of `text`, as `URL(string:)` finds it: a letter, then
/// letters, digits, `+`, `-` or `.`, then `:`.
fn scheme(text: &str) -> Option<&str> {
    let colon = text.find(':')?;
    let candidate = &text[..colon];
    let mut chars = candidate.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    valid.then_some(candidate)
}

/// Whether the authority of an `https://` address has a non-empty host.
fn has_host(url: &str) -> bool {
    let rest = url.strip_prefix("https://").unwrap_or(url);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(bracketed) = host_port.strip_prefix('[') {
        bracketed.split(']').next().unwrap_or("")
    } else {
        host_port.rsplit_once(':').map_or(host_port, |(host, _)| host)
    };
    !host.is_empty()
}
