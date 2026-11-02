//! The typed policy: what a person types into an address bar, ported line by
//! line from CmuxNextBrowserCore `Omnibox/BrowserURLResolver.swift` (the app
//! omnibox, the New Tab field and `newTab.submit`). The daemon policy,
//! [`crate::normalize_url`], is a separate rule set on purpose: agents and
//! the CLI navigate `data:` and other schemes that typed text never loads.
//!
//! Rules, in order:
//! 1. Line breaks and tabs from a wrapped terminal paste are removed only when
//!    the break comes after the URL's authority (host) has ended, so
//!    `https://example.com/very/\nlong/path` loads while `example.\ncom` searches.
//! 2. Explicit `http`, `https`, `file`, and `about:blank` load; with
//!    `allows_chromium_schemes` (Chromium tabs) also `chrome://` WebUI and
//!    `chrome-extension://` pages and `about:` aliases of WebUI pages, in
//!    Chromium's canonical form; every tab also takes the `chrome://` pages
//!    cmux shows itself, `cmux://stashed` (the App opens it), and Mac Screen
//!    addresses (`cmux://mac-screen`; an old `cmux-vnc://pair?…` pairing link,
//!    which the host refuses with a word and never loads). Every other scheme
//!    (`javascript:`, `data:`, `mailto:`, ...) is searched, so typed text can
//!    never run script or open another app.
//! 3. `/abs/path`, `~`, and `~/path` are file URLs, spaces allowed.
//! 4. Remaining text with whitespace is a search, except an explicit `http`,
//!    `https` or `file` URL whose spaces all come after its host: it loads
//!    with them percent-encoded, as in Chrome.
//! 5. Scheme-less text: userinfo (`user@host`) is refused, loopback hosts and
//!    non-unique hosts (private IPs, `devbox:8080`, `router/`, `nas.local`)
//!    get `http`, other dotted hosts, IPv6 literals or hosts with a port get
//!    `https`, and single words search.

use crate::chromium::{chromium_page_route, internal_url_with_scheme};
use crate::text::split_before;
use crate::uri::{file_url, parse_lenient, parse_strict};

/// cmux's own pages that are no browser page, which the App opens instead of
/// loading. Every other `cmux:` link (`cmux://tab/…`) is searched, never run.
pub const CMUX_APP_PAGE_HOSTS: [&str; 1] = ["stashed"];

/// The typed policy for one tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TypedInput<'a> {
    /// The person's home folder as a path (`/Users/me` or `/Users/me/`): `~`
    /// and `~/path` resolve in it.
    pub home: &'a str,
    /// Chromium tabs also load `chrome://` WebUI and extension pages.
    pub allows_chromium_schemes: bool,
}

/// Whether `text` holds an old Mac Screen pairing link (`cmux-vnc://pair?…`
/// or `cmux-vnc:pair?…`, any case, anywhere in the text). The link carries a
/// room secret, so no input surface loads, searches or sends such text.
pub fn contains_pairing_link(text: &str) -> bool {
    let lower = text.to_lowercase();
    let mut rest = lower.as_str();
    while let Some((_, after)) = rest.split_once("cmux-vnc:") {
        if after.starts_with("pair") || after.starts_with("//pair") {
            return true;
        }
        rest = after;
    }
    false
}

/// `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`, and `0.0.0.0`. `host` is
/// lowercased, IPv6 brackets stripped.
pub fn is_loopback_host(host: &str) -> bool {
    if host == "localhost" || host.ends_with(".localhost") || host == "::1" || host == "0.0.0.0" {
        return true;
    }
    let octets: Vec<&str> = host.split('.').collect();
    matches!(octets.as_slice(), ["127", _, _, _])
        && octets.iter().all(|octet| octet.parse::<u8>().is_ok())
}

/// Names and addresses that are not globally unique, so they never get a
/// public certificate: private, shared (CGNAT, tailnet) and link-local IPv4,
/// unique-local and link-local IPv6, single-label hosts, and the reserved or
/// intranet suffixes (RFC 6761, RFC 6762, `home.arpa`, `internal`).
/// Chromium's `net::IsHostnameNonUnique`.
fn is_non_unique_host(host: &str) -> bool {
    if host.contains(':') {
        let lower = host.to_lowercase();
        return ["fc", "fd", "fe8", "fe9", "fea", "feb"]
            .iter()
            .any(|prefix| lower.starts_with(prefix));
    }
    let labels: Vec<&str> = host.split('.').collect();
    let octets: Vec<u8> = labels.iter().filter_map(|label| label.parse::<u8>().ok()).collect();
    if labels.len() == 4
        && let [first, second, _, _] = octets.as_slice()
    {
        return matches!(
            (*first, *second),
            (10, _) | (192, 168) | (169, 254) | (172, 16..=31) | (100, 64..=127)
        );
    }
    if labels.iter().any(|label| label.is_empty()) {
        return false;
    }
    if labels.len() == 1 {
        return !host.chars().all(char::is_numeric);
    }
    const SUFFIXES: [&str; 11] = [
        "local",
        "lan",
        "internal",
        "intranet",
        "corp",
        "home",
        "localdomain",
        "test",
        "example",
        "invalid",
        "home.arpa",
    ];
    SUFFIXES.iter().any(|suffix| {
        host == *suffix || host.strip_suffix(suffix).is_some_and(|name| name.ends_with('.'))
    })
}

/// Lowercased host (brackets stripped from IPv6) and whether a numeric port
/// follows it. A non-numeric "port" yields an empty host.
fn split_host_and_port(authority: &str) -> (String, bool) {
    let lower = authority.to_lowercase();
    if let Some(after_open) = lower.strip_prefix('[') {
        let Some((host, rest)) = after_open.split_once(']') else {
            return (String::new(), false);
        };
        let host = host.to_string();
        if rest.is_empty() {
            return (host, false);
        }
        return match rest.strip_prefix(':') {
            Some(port) if is_port(port) => (host, true),
            _ => (String::new(), false),
        };
    }
    match lower.split_once(':') {
        None => (lower, false),
        Some((host, port)) if is_port(port) => (host.to_string(), true),
        Some(_) => (String::new(), false),
    }
}

fn is_port(text: &str) -> bool {
    !text.is_empty() && text.chars().all(char::is_numeric) && text.parse::<u16>().is_ok()
}

/// A host with at least two labels whose last label looks like a TLD
/// (letters, or a numeric IPv4 address).
fn is_dotted_host(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 || labels.iter().any(|label| label.is_empty()) {
        return false;
    }
    if labels.len() == 4 && labels.iter().all(|label| label.parse::<u8>().is_ok()) {
        return true;
    }
    let Some(tld) = labels.last() else {
        return false;
    };
    tld.chars().count() >= 2 && (tld.chars().all(char::is_alphabetic) || tld.starts_with("xn--"))
}

fn is_wrap_break(c: char) -> bool {
    // Swift's `Character.isNewline`, and tabs.
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}' | '\t')
}

fn is_authority_end(c: char) -> bool {
    matches!(c, '/' | '?' | '#')
}

/// Byte offset just after the first `://`, or 0.
fn authority_start(text: &str) -> usize {
    text.find("://").map_or(0, |at| at + 3)
}

impl TypedInput<'_> {
    /// A URL to load, or `None` when the text should be searched.
    pub fn resolve(&self, input: &str) -> Option<String> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return None;
        }
        let text = removing_wrap_breaks(trimmed)?;
        if let Some(file) = self.file_url(&text) {
            return Some(file);
        }
        if text.chars().any(char::is_whitespace) {
            return self.encoding_spaces(&text);
        }
        if let Some(scheme) = explicit_scheme(&text) {
            return self.explicit_url(&text, &scheme);
        }
        scheme_less_url(&text)
    }

    /// An `http`, `https` or `file` URL with spaces only after its host: the
    /// spaces percent-encoded. `None` for everything else with a space.
    fn encoding_spaces(&self, text: &str) -> Option<String> {
        let scheme = explicit_scheme(text)?;
        if !matches!(scheme.as_str(), "http" | "https" | "file") {
            return None;
        }
        let start = text.find("://")? + 3;
        let authority_end = start + text.get(start..)?.find(is_authority_end)?;
        let first_space = text.find(char::is_whitespace)?;
        if authority_end >= first_space || text.chars().any(|c| c.is_whitespace() && c != ' ') {
            return None;
        }
        self.explicit_url(&text.replace(' ', "%20"), &scheme)
    }

    fn file_url(&self, text: &str) -> Option<String> {
        if text.starts_with('/') {
            return Some(file_url(text));
        }
        if text == "~" {
            let home = self.home;
            return Some(if home.ends_with('/') {
                file_url(home)
            } else {
                file_url(&format!("{home}/"))
            });
        }
        let rest = text.strip_prefix("~/")?;
        Some(file_url(&format!("{}/{rest}", self.home.trim_end_matches('/'))))
    }

    fn explicit_url(&self, text: &str, scheme: &str) -> Option<String> {
        match scheme {
            "http" | "https" => {
                let parts = parse_strict(text)?;
                parts.host.filter(|host| !host.is_empty())?;
                Some(text.to_string())
            }
            "file" => {
                let url = parse_lenient(text)?;
                parse_strict(&url).filter(|parts| parts.path.starts_with('/'))?;
                Some(url)
            }
            "about" => {
                if text.to_lowercase() == "about:blank" {
                    return Some("about:blank".to_string());
                }
                self.chromium_page(text, scheme)
            }
            "chrome" | "chrome-extension" => self.chromium_page(text, scheme),
            "cmux-vnc" => mac_screen_address(text, scheme),
            "cmux" => mac_screen_address(text, scheme).or_else(|| cmux_app_page(text)),
            _ => None,
        }
    }

    /// A Chromium internal page in canonical form. A WebKit tab takes only the
    /// pages cmux shows itself (`chrome://history`, `chrome://bookmarks`,
    /// `chrome://settings`).
    fn chromium_page(&self, text: &str, scheme: &str) -> Option<String> {
        let page = internal_url_with_scheme(text, scheme)?;
        if self.allows_chromium_schemes {
            return Some(page);
        }
        chromium_page_route(&page).is_some_and(|route| route.is_cmux_owned()).then_some(page)
    }
}

/// The text with wrap breaks removed, the text unchanged when it has none, or
/// `None` when a break sits inside what would be the host.
fn removing_wrap_breaks(text: &str) -> Option<String> {
    let Some(first_break) = text.find(is_wrap_break) else {
        return Some(text.to_string());
    };
    let start = authority_start(text);
    if start > first_break {
        return None;
    }
    let authority_end = start + text.get(start..)?.find(is_authority_end)?;
    if authority_end >= first_break {
        return None;
    }
    let compacted: String = text.chars().filter(|c| !is_wrap_break(*c)).collect();
    (!compacted.chars().any(char::is_whitespace)).then_some(compacted)
}

/// The lowercased scheme when the text starts with one. `localhost:3000` and
/// `example.com:8080/x` are host-and-port, not schemes.
fn explicit_scheme(text: &str) -> Option<String> {
    let (candidate, after_colon) = text.split_once(':')?;
    let mut chars = candidate.chars();
    let first = chars.next()?;
    if !first.is_alphabetic()
        || !chars.all(|c| c.is_alphabetic() || c.is_numeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let (port, rest) = split_before(after_colon, |c| !c.is_numeric());
    if !port.is_empty()
        && !after_colon.starts_with("//")
        && rest.chars().next().is_none_or(is_authority_end)
    {
        return None;
    }
    Some(candidate.to_lowercase())
}

/// A Mac Screen address the host handles itself, never searched: a Mac Screen
/// tab record (`cmux://mac-screen`), or an old pairing link (`cmux-vnc://pair?…`).
fn mac_screen_address(text: &str, scheme: &str) -> Option<String> {
    let url = parse_lenient(text)?;
    if scheme == "cmux-vnc" {
        return contains_pairing_link(text).then_some(url);
    }
    let host = parse_strict(&url)?.host?.to_lowercase();
    (host == "mac-screen").then_some(url)
}

/// `cmux://stashed` in canonical form, with any path, query or fragment dropped.
fn cmux_app_page(text: &str) -> Option<String> {
    let url = parse_lenient(text)?;
    let host = parse_strict(&url)?.host?.to_lowercase();
    CMUX_APP_PAGE_HOSTS.contains(&host.as_str()).then(|| format!("cmux://{host}"))
}

fn scheme_less_url(text: &str) -> Option<String> {
    let (authority, after_authority) = split_before(text, is_authority_end);
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, has_port) = split_host_and_port(authority);
    if host.is_empty() {
        return None;
    }
    let has_path = after_authority.starts_with('/');
    let scheme = if is_loopback_host(&host) {
        "http"
    } else if is_non_unique_host(&host) {
        // Chromium never upgrades IP literals in private ranges or non-unique
        // (intranet) names to https: a router, NAS or dev server has no
        // certificate. A single label needs a port or a path ("devbox:8080",
        // "router/"); alone it is a search (`AutocompleteInput::Parse`).
        if !(host.contains(['.', ':']) || has_port || has_path) {
            return None;
        }
        "http"
    } else if has_port || is_dotted_host(&host) || host.contains(':') {
        "https"
    } else {
        return None;
    };
    let url = format!("{scheme}://{text}");
    parse_strict(&url)?.host.filter(|host| !host.is_empty())?;
    Some(url)
}
