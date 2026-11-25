//! An organization's URL blocklist and allowlist in Chrome's filter format (`BrowserURLFilter`,
//! `BrowserURLFilterRule`).
//!
//! Chrome's `URLBlocklist` / `URLAllowlist` policies, support.google.com/chrome/a/answer/9942583:
//! `[scheme://][.]host[:port][/path][?query]`, `*` for every URL. A host matches itself and its
//! subdomains unless it starts with a dot; a path is a prefix; query parameters must all be
//! present. When a URL matches both lists, the more specific filter wins (longer host, then longer
//! path, then more query parameters); on a tie the allowlist wins, as in Chrome. cmux's own pages
//! and `about:` are never blocked.
//!
//! ```
//! use cmux_browser_rules::url_filter::UrlFilter;
//! let filter = UrlFilter::new(&["*"], &["example.com"]);
//! assert!(!filter.blocks("https://www.example.com/a"));
//! assert!(filter.blocks("https://other.org"));
//! ```
//!
//! The app reads a `URL`; here the URL is its `absoluteString`, read the way `URL(string:)` reads
//! it ([`cmux_url_input::url_parts`]).

use cmux_url_input::{UrlParts, url_parts};
use serde::{Deserialize, Serialize};

/// Chrome reads at most this many filters per list (`BrowserURLFilter.maximumFilters`).
pub const MAXIMUM_FILTERS: usize = 1000;

/// cmux's own pages and blank pages, which a filter never blocks (Chrome exempts its internal
/// pages the same way).
pub const EXEMPT_SCHEMES: &[&str] = &["about", "cmux", "cmux-page"];

/// An organization's URL blocklist and allowlist (`BrowserURLFilter`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct UrlFilter {
    pub blocked: Vec<UrlFilterRule>,
    pub allowed: Vec<UrlFilterRule>,
}

/// The two lists as the app holds them (`BrowserURLFilter(blocklist:allowlist:)`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct UrlFilterLists {
    /// Chrome `URLBlocklist` filters; an unreadable filter is ignored.
    #[serde(default)]
    pub blocklist: Vec<String>,
    /// Chrome `URLAllowlist` filters, exceptions to the blocklist.
    #[serde(default)]
    pub allowlist: Vec<String>,
}

impl UrlFilter {
    /// No filter: every URL loads (`BrowserURLFilter.none`).
    pub const NONE: UrlFilter = UrlFilter { blocked: Vec::new(), allowed: Vec::new() };

    /// - `blocklist`: Chrome `URLBlocklist` filters; an unreadable filter is ignored.
    /// - `allowlist`: Chrome `URLAllowlist` filters, exceptions to the blocklist.
    pub fn new<S: AsRef<str>>(blocklist: &[S], allowlist: &[S]) -> Self {
        let read = |list: &[S]| {
            list.iter()
                .take(MAXIMUM_FILTERS)
                .filter_map(|pattern| UrlFilterRule::parse(pattern.as_ref()))
                .collect()
        };
        UrlFilter { blocked: read(blocklist), allowed: read(allowlist) }
    }

    /// The filter of the app's two lists.
    pub fn of(lists: &UrlFilterLists) -> Self {
        Self::new(lists.blocklist.as_slice(), lists.allowlist.as_slice())
    }

    /// True when no filter is set.
    pub fn is_empty(&self) -> bool {
        self.blocked.is_empty()
    }

    /// Whether the organization blocks loading `url`. A text `URL(string:)` cannot read (so the app
    /// has no `URL` for it) or one without a scheme is not blocked, as a `URL` without a scheme is
    /// not.
    pub fn blocks(&self, url: &str) -> bool {
        if self.blocked.is_empty() {
            return false;
        }
        let Some(parts) = url_parts(url) else {
            return false;
        };
        let scheme = parts.scheme.to_lowercase();
        if EXEMPT_SCHEMES.contains(&scheme.as_str()) {
            return false;
        }
        let best = |rules: &[UrlFilterRule]| {
            rules
                .iter()
                .filter(|rule| rule.matches_parts(&parts))
                .map(UrlFilterRule::specificity)
                .max()
        };
        let Some(block) = best(&self.blocked) else {
            return false;
        };
        let Some(allow) = best(&self.allowed) else {
            return true;
        };
        block > allow
    }
}

/// How specific a filter is, to choose between a block and an allow match. Compared host, then
/// path, then query (the field order).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Specificity {
    pub host: usize,
    pub path: usize,
    pub query: usize,
}

/// One parsed filter of [`UrlFilter`] (Chrome's URL filter format; `BrowserURLFilterRule`).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct UrlFilterRule {
    /// Lowercased scheme, `None` for any.
    pub scheme: Option<String>,
    /// Lowercased host without a trailing dot, empty for any host.
    pub host: String,
    /// The host matches its subdomains too (no leading dot, not an IP address).
    pub matches_subdomains: bool,
    pub port: Option<i64>,
    /// Path prefix, empty for any path.
    pub path: String,
    /// Query parameters the URL must carry (`name=value`, or `name` for any value).
    pub query: Vec<String>,
}

impl UrlFilterRule {
    pub fn specificity(&self) -> Specificity {
        Specificity {
            host: self.host.chars().count(),
            path: self.path.chars().count(),
            query: self.query.len(),
        }
    }

    /// The filter `raw` names; `None` when it is unreadable (empty, or a `*` inside the host).
    pub fn parse(raw: &str) -> Option<Self> {
        let mut text = raw.trim();
        if text.is_empty() {
            return None;
        }
        if text == "*" {
            return Some(UrlFilterRule {
                scheme: None,
                host: String::new(),
                matches_subdomains: true,
                port: None,
                path: String::new(),
                query: Vec::new(),
            });
        }
        let mut scheme = None;
        if let Some((name, rest)) = text.split_once("://") {
            let name = name.to_lowercase();
            scheme = (name != "*").then_some(name);
            text = rest;
        }
        let mut query = Vec::new();
        if let Some((rest, after)) = text.split_once('?') {
            query = after.split('&').filter(|item| !item.is_empty()).map(str::to_string).collect();
            text = rest;
        }
        let mut path = String::new();
        if let Some(slash) = text.find('/') {
            let (rest, tail) = text.split_at(slash);
            path = tail.to_string();
            text = rest;
        }
        if path == "/" || path == "/*" {
            path.clear();
        }
        if path.ends_with('*') {
            path.pop();
        }
        let mut host = text.to_lowercase();
        let mut port = None;
        let colon_port = host
            .rfind(':')
            .filter(|_| !host.ends_with(']'))
            .and_then(|colon| Some((colon, swift_int(host.get(colon + 1..)?)?)));
        if let Some((colon, number)) = colon_port {
            port = Some(number);
            host.truncate(colon);
        } else if host.ends_with(":*") {
            host.truncate(host.len() - 2);
        }
        let mut subdomains = true;
        if let Some(rest) = host.strip_prefix('.') {
            subdomains = false;
            host = rest.to_string();
        }
        while host.ends_with('.') {
            host.pop();
        }
        if host == "*" {
            host.clear();
        }
        if is_ip_address(&host) {
            subdomains = false;
        }
        if host.contains('*') {
            return None;
        }
        // "file://*" style filters name a scheme without a host.
        if host.is_empty() && scheme.is_none() && path.is_empty() && !raw.contains('*') {
            return None;
        }
        Some(UrlFilterRule { scheme, host, matches_subdomains: subdomains, port, path, query })
    }

    /// Whether the filter matches `url` (its `absoluteString`); a text `URL(string:)` cannot read
    /// matches nothing.
    pub fn matches(&self, url: &str) -> bool {
        url_parts(url).is_some_and(|parts| self.matches_parts(&parts))
    }

    fn matches_parts(&self, url: &UrlParts) -> bool {
        let url_scheme = url.scheme.to_lowercase();
        if self.scheme.as_ref().is_some_and(|scheme| *scheme != url_scheme) {
            return false;
        }
        if !self.host.is_empty() {
            let mut url_host = percent_decode(url.host.as_deref().unwrap_or("")).to_lowercase();
            while url_host.ends_with('.') {
                url_host.pop();
            }
            let url_host = strip_brackets(&url_host);
            let bare = strip_brackets(&self.host);
            let subdomain = self.matches_subdomains
                && url_host.strip_suffix(bare).is_some_and(|head| head.ends_with('.'));
            if url_host != bare && !subdomain {
                return false;
            }
        }
        if let Some(port) = self.port
            && Some(port) != url.port.or_else(|| default_port(&url_scheme))
        {
            return false;
        }
        if !self.path.is_empty() {
            let url_path = if url.path.is_empty() { "/" } else { url.path.as_str() };
            if !url_path.starts_with(&self.path) {
                return false;
            }
        }
        if !self.query.is_empty() {
            let items = query_items(url.query.as_deref());
            for wanted in &self.query {
                // Swift's `split(separator: "=", maxSplits: 1)` drops empty pieces.
                let mut parts = wanted.splitn(2, '=').filter(|part| !part.is_empty());
                let name = parts.next().unwrap_or("");
                let value = parts.next();
                let present = items.iter().any(|(item_name, item_value)| {
                    *item_name == name && (value.is_none() || *item_value == value)
                });
                if !present {
                    return false;
                }
            }
        }
        true
    }
}

/// The port a scheme loads on when the URL names none.
pub fn default_port(scheme: &str) -> Option<i64> {
    match scheme {
        "http" | "ws" => Some(80),
        "https" | "wss" => Some(443),
        "ftp" => Some(21),
        _ => None,
    }
}

/// A bracketed IPv6 literal, or four dot-separated numbers each of 0 to 255.
pub fn is_ip_address(host: &str) -> bool {
    if host.starts_with('[') {
        return true;
    }
    let parts: Vec<&str> = host.split('.').collect();
    parts.len() == 4
        && parts.iter().all(|part| swift_int(part).is_some_and(|n| (0..=255).contains(&n)))
}

/// `Int(text)`: an optional `+` or `-` and at least one ASCII digit, nothing else.
fn swift_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

fn strip_brackets(host: &str) -> &str {
    host.strip_prefix('[').and_then(|inner| inner.strip_suffix(']')).unwrap_or(host)
}

/// `URLComponents.percentEncodedQueryItems`: `&`-separated items, each `name` or `name=value` as
/// written.
fn query_items(query: Option<&str>) -> Vec<(&str, Option<&str>)> {
    let Some(query) = query else {
        return Vec::new();
    };
    query
        .split('&')
        .map(|item| match item.split_once('=') {
            Some((name, value)) => (name, Some(value)),
            None => (item, None),
        })
        .collect()
}

/// `%HH` escapes decoded (`host(percentEncoded: false)`); bytes that are not UTF-8 become U+FFFD.
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        let hex = bytes
            .get(index + 1..index + 3)
            .and_then(|pair| std::str::from_utf8(pair).ok())
            .and_then(|pair| u8::from_str_radix(pair, 16).ok());
        match (byte, hex) {
            (b'%', Some(decoded)) => {
                out.push(decoded);
                index += 3;
            }
            _ => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
