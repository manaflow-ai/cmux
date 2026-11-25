//! The omnibar's text rules and how it shows an address.
//!
//! Ported 1:1 from the app's Swift (`CmuxNextBrowser`, Omnibox/): `OmnibarRules`
//! (OmnibarRules.swift) and `BrowserURLDisplay` (BrowserURLDisplay.swift). The typed-text
//! resolution they call (`BrowserURLResolver`) is `cmux-url-input`'s [`TypedInput`].
//!
//! Offsets and lengths are UTF-16 units, as `NSRange` and `NSTextView` count them. Swift's
//! `Character` counts (`typed.count`, `dropFirst`) are grapheme clusters, so those use
//! `unicode-segmentation`. URLs travel as the string `URL.absoluteString` gives; the pieces
//! [`Url`] reads out of it are the ones `URLComponents` gives for a URL the app built.
//!
//! Known edges, not modelled (the app half's side-by-side test compares them before the Swift
//! copy goes): `Character.isLetter`/`isNumber` are approximated by `char::is_alphabetic`/
//! `is_numeric`, a percent-encoded host is not decoded, and `javascript:` followed by a
//! combining mark is not told from `javascript:`.
//!
//! The wire is the shape Swift's synthesized `Codable` gives the app's types (see
//! [`crate::links`]): [`Suggestion`] is `BrowserSuggestion` with its `Kind` as
//! `{"navigate": {}}`, [`Range`] is `NSRange` (`{location, length}`).

use cmux_url_input::TypedInput;
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// `NSNotFound`: a selection that has no location.
pub const NOT_FOUND: i64 = i64::MAX;

/// An `NSRange`: UTF-16 units.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Range {
    pub location: i64,
    pub length: i64,
}

/// What kind of row a suggestion is (`BrowserSuggestion.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    /// Load the typed URL.
    Navigate {},
    /// Search for the typed or suggested query.
    Search {},
    /// A page from history.
    History {},
    /// A bookmarked page.
    Bookmark {},
    /// An extension's suggestion in a keyword session.
    Keyword {},
    /// An open tab of the same profile: Enter reveals it.
    SwitchToTab {},
    /// A calculator answer: Enter copies it, never navigates.
    Answer {},
}

fn yes() -> bool {
    true
}

/// One row of the address bar dropdown (`BrowserSuggestion`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub kind: Kind,
    /// Main line: page title or query.
    pub title: String,
    /// Second line: display URL, or empty.
    #[serde(default)]
    pub detail: String,
    /// The row's URL (`URL.absoluteString`).
    pub url: String,
    #[serde(default)]
    pub score: f64,
    /// Keyword rows: the text sent to the extension and put in the field.
    #[serde(default)]
    pub content: Option<String>,
    /// Inline autocomplete may complete the typed text to this row.
    #[serde(default = "yes")]
    pub inline_completable: bool,
    /// Switch to Tab rows: the tab to reveal.
    #[serde(default)]
    pub tab_key: Option<String>,
}

/// The pieces of an absolute URL string, as `URLComponents` reads them.
#[derive(Debug, Default)]
struct Url<'a> {
    scheme: Option<&'a str>,
    /// The authority was present (`//` after the scheme).
    has_authority: bool,
    /// The host as written: an IPv6 literal keeps its brackets.
    raw_host: Option<&'a str>,
    port: Option<&'a str>,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

impl<'a> Url<'a> {
    fn parse(text: &'a str) -> Self {
        let mut url = Url::default();
        let mut rest = text;
        if let Some((scheme, after)) = text.split_once(':') {
            let mut chars = scheme.chars();
            let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
                && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
            if valid {
                url.scheme = Some(scheme);
                rest = after;
            }
        }
        if let Some((before, fragment)) = rest.split_once('#') {
            url.fragment = Some(fragment);
            rest = before;
        }
        if let Some((before, query)) = rest.split_once('?') {
            url.query = Some(query);
            rest = before;
        }
        if let Some(after) = rest.strip_prefix("//") {
            url.has_authority = true;
            let end = after.find('/').unwrap_or(after.len());
            let authority = &after[..end];
            rest = &after[end..];
            let host_port =
                authority.rsplit_once('@').map_or(authority, |(_, host_port)| host_port);
            if host_port.starts_with('[') {
                match host_port.find(']') {
                    Some(close) => {
                        url.raw_host = Some(&host_port[..=close]);
                        url.port = host_port[close + 1..].strip_prefix(':');
                    }
                    None => url.raw_host = Some(host_port),
                }
            } else if let Some((host, port)) = host_port.rsplit_once(':') {
                url.raw_host = Some(host);
                url.port = Some(port);
            } else {
                url.raw_host = Some(host_port);
            }
        }
        url.path = rest;
        url
    }

    fn scheme_lowercased(&self) -> Option<String> {
        self.scheme.map(str::to_lowercase)
    }

    /// `URL.host(percentEncoded: false)`: no brackets around an IPv6 literal.
    fn host(&self) -> Option<&'a str> {
        self.raw_host
            .map(|host| host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host))
    }

    fn is_file(&self) -> bool {
        self.scheme_lowercased().as_deref() == Some("file")
    }
}

/// `www.` is dropped from a host with more than two labels.
fn without_www(host: &str) -> &str {
    let lower = host.to_lowercase();
    if lower.starts_with("www.") && host.split('.').filter(|label| !label.is_empty()).count() > 2 {
        // `www.` is four ASCII characters in the original too, whatever case it was typed in.
        &host[4..]
    } else {
        host
    }
}

/// `String.removingPercentEncoding`: `None` for a malformed escape or bytes that are not UTF-8.
fn removing_percent_encoding(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let value = u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?;
            out.push(value);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn is_new_tab_page(url: &str) -> bool {
    matches!(url.to_lowercase().as_str(), "about:blank" | "chrome://newtab/" | "chrome://newtab")
}

fn is_remote_desktop_page(url: &Url) -> bool {
    url.scheme_lowercased().as_deref() == Some("cmux")
        && url.host().is_some_and(|host| host.to_lowercase() == "remote-view")
}

/// Compact text shown when the field is not being edited: no `https://`, no `www.`, no trailing
/// slash on a bare host, percent escapes decoded. `http://` is kept so insecure pages stay
/// recognizable; `chrome://` and `chrome-extension://` are kept as Chromium keeps them. A file
/// shows its path, `~/…` under `home`. `None` is no page (`BrowserURLDisplay.displayText`).
pub fn display_text(url: Option<&str>, home: &str) -> String {
    let Some(text) = url else { return String::new() };
    let parsed = Url::parse(text);
    if is_new_tab_page(text) || is_remote_desktop_page(&parsed) {
        return String::new();
    }
    if parsed.is_file() {
        return tilde_path(&file_path(&parsed), home);
    }
    let Some(host) = parsed.raw_host.filter(|host| !host.is_empty()) else {
        return text.to_owned();
    };
    let scheme = parsed.scheme_lowercased();
    let host = without_www(host);
    let mut shown = format!("//{host}");
    if let Some(port) = parsed.port {
        shown.push(':');
        shown.push_str(port);
    }
    shown.push_str(parsed.path);
    if let Some(query) = parsed.query {
        shown.push('?');
        shown.push_str(query);
    }
    if let Some(fragment) = parsed.fragment {
        shown.push('#');
        shown.push_str(fragment);
    }
    shown.drain(..2);
    if parsed.path == "/" && parsed.query.is_none() && parsed.fragment.is_none() {
        shown.pop();
    }
    let shown = removing_percent_encoding(&shown).unwrap_or(shown);
    match scheme.as_deref() {
        Some(scheme @ ("http" | "chrome" | "chrome-extension")) => format!("{scheme}://{shown}"),
        _ => shown,
    }
}

/// `URL.path(percentEncoded: false)` of a file URL.
fn file_path(url: &Url) -> String {
    removing_percent_encoding(url.path).unwrap_or_else(|| url.path.to_owned())
}

/// What the address bar shows at rest: a web page's host alone (no scheme, no `www.`, no path,
/// query or fragment; a port stays). A page that is not on the web shows [`display_text`]
/// (`BrowserURLDisplay.restingText`).
pub fn resting_text(url: Option<&str>, home: &str) -> String {
    if let Some(text) = url {
        let parsed = Url::parse(text);
        let web = matches!(parsed.scheme_lowercased().as_deref(), Some("https" | "http"));
        if let (true, Some(host)) = (web, parsed.host().filter(|host| !host.is_empty())) {
            let host = without_www(host);
            let host = if host.contains(':') { format!("[{host}]") } else { host.to_owned() };
            return match parsed.port {
                Some(port) => format!("{host}:{port}"),
                None => host,
            };
        }
    }
    display_text(url, home)
}

/// `path` with `home` (and only home, never a sibling such as `/Users/me2`) replaced by `~`
/// (`BrowserURLDisplay.tildePath`).
pub fn tilde_path(path: &str, home: &str) -> String {
    let mut home = home;
    while home.chars().count() > 1 && home.ends_with('/') {
        home = &home[..home.len() - 1];
    }
    if home.chars().count() <= 1 {
        return path.to_owned();
    }
    let mut trimmed = path;
    while trimmed.chars().count() > 1 && trimmed.ends_with('/') {
        trimmed = &trimmed[..trimmed.len() - 1];
    }
    if trimmed == home {
        return "~".to_owned();
    }
    match path.strip_prefix(home) {
        Some(rest) if rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_owned(),
    }
}

/// The host's UTF-16 range inside `text` (the compact text or the full URL), which the omnibar
/// draws at full strength while the rest is dimmed. `None` for file URLs and blank pages
/// (`BrowserURLDisplay.hostRange`).
pub fn host_range(text: &str, url: Option<&str>) -> Option<Range> {
    let parsed = Url::parse(url?);
    if parsed.is_file() {
        return None;
    }
    let full_host = parsed.host().filter(|host| !host.is_empty())?;
    let host = without_www(full_host);
    let scheme = parsed.scheme_lowercased().unwrap_or_default();
    let lowered = text.to_lowercase();
    let prefix = if !scheme.is_empty() && lowered.starts_with(&format!("{scheme}://")) {
        format!("{scheme}://")
    } else {
        String::new()
    };
    let rest = lowered.strip_prefix(&prefix.to_lowercase()).unwrap_or(&lowered);
    for candidate in [host, full_host] {
        let host_text = if candidate.contains(':') && !candidate.starts_with('[') {
            format!("[{candidate}]")
        } else {
            candidate.to_owned()
        };
        if rest.starts_with(&host_text.to_lowercase()) {
            return Some(Range {
                location: prefix.encode_utf16().count() as i64,
                length: host_text.encode_utf16().count() as i64,
            });
        }
    }
    None
}

/// Full text placed in the field when editing starts (`BrowserURLDisplay.editingText`).
pub fn editing_text(url: Option<&str>) -> String {
    match url {
        Some(text) if !is_new_tab_page(text) && !is_remote_desktop_page(&Url::parse(text)) => {
            text.to_owned()
        }
        _ => String::new(),
    }
}

/// Text a row puts in the field when it is selected with the arrow keys
/// (`OmnibarRules.fillText`).
pub fn fill_text(row: &Suggestion) -> String {
    match row.kind {
        Kind::Search {} => row.title.clone(),
        Kind::Keyword {} | Kind::Answer {} => {
            row.content.clone().unwrap_or_else(|| row.title.clone())
        }
        Kind::Navigate {} | Kind::History {} | Kind::Bookmark {} | Kind::SwitchToTab {} => {
            editing_text(Some(&row.url))
        }
    }
}

/// Swift's `Character.isWhitespace`: the first scalar's White_Space property.
fn grapheme_is_whitespace(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(char::is_whitespace)
}

/// `CharacterSet.whitespaces`: space, tab and the Zs separators.
fn is_set_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

fn trim_whitespaces(text: &str) -> &str {
    text.trim_matches(is_set_whitespace)
}

/// Spellings the user may be typing: the compact display text and the full URL.
fn completion_forms(url: &str, home: &str) -> Vec<String> {
    let mut forms = vec![display_text(Some(url), home)];
    let parsed = Url::parse(url);
    let full = if url.ends_with('/') && parsed.path == "/" { &url[..url.len() - 1] } else { url };
    forms.push(full.to_owned());
    forms.retain(|form| !form.is_empty());
    forms
}

/// The suffix that completes `typed` to `row`'s URL, or `None`. Only navigation, history and
/// bookmark rows marked `inlineCompletable` complete, only on a prefix of the URL as shown (no
/// scheme, no `www.`) or of the full URL, and never for a trailing space
/// (`OmnibarRules.inlineCompletion`).
pub fn inline_completion(row: &Suggestion, typed: &str, home: &str) -> Option<String> {
    if !row.inline_completable
        || matches!(
            row.kind,
            Kind::Search {} | Kind::Keyword {} | Kind::SwitchToTab {} | Kind::Answer {}
        )
        || typed.is_empty()
        || typed.graphemes(true).next_back().is_none_or(grapheme_is_whitespace)
    {
        return None;
    }
    let lowered = typed.to_lowercase();
    let typed_count = typed.graphemes(true).count();
    for form in completion_forms(&row.url, home) {
        if form.to_lowercase().starts_with(&lowered) && form.graphemes(true).count() > typed_count {
            return Some(form.graphemes(true).skip(typed_count).collect());
        }
    }
    None
}

/// The Control-Enter URL for `typed`: `www.` and `.com` around a host that has no dot
/// (`example`, `google/maps`, `www.example`), `None` for anything else (a scheme, a port, spaces,
/// a host with a TLD) (`OmnibarRules.desiredTLDURL`).
pub fn desired_tld_url(typed: &str, resolver: &TypedInput) -> Option<String> {
    let text = trim_whitespaces(typed);
    if text.is_empty() || text.graphemes(true).any(grapheme_is_whitespace) || text.contains(':') {
        return None;
    }
    let host_end = text.find(['/', '?', '#']).unwrap_or(text.len());
    let mut host = text[..host_end].to_lowercase();
    if host.starts_with("www.") {
        host.drain(..4);
    }
    if host.is_empty()
        || host.contains('.')
        || host.contains('@')
        || !host.chars().all(|c| c.is_alphabetic() || c.is_numeric() || c == '-')
    {
        return None;
    }
    resolver.resolve(&format!("www.{host}.com{}", &text[host_end..]))
}

/// Swift's `CharacterSet.newlines`.
fn is_newline_scalar(c: char) -> bool {
    matches!(c, '\u{A}'..='\u{D}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Pasted text on one line: every line break becomes a space, so UTF-16 offsets (and the caret)
/// stay where they were (`OmnibarRules.singleLine`).
pub fn single_line(text: &str) -> String {
    text.chars().map(|c| if is_newline_scalar(c) { ' ' } else { c }).collect()
}

/// Text dropped on the omnibox, as Chromium `OmniboxViewViews::PerformDrop` cleans it: runs of
/// whitespace become one space, the ends are trimmed, and leading `javascript:` schemes (any
/// case, with the spaces after them) are stripped (`OmnibarRules.droppedText`).
pub fn dropped_text(text: &str) -> String {
    let mut cleaned = text
        .split(char::is_whitespace)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let scheme = "javascript:";
    while cleaned.to_lowercase().starts_with(scheme) {
        cleaned = trim_whitespaces(&cleaned[scheme.len()..]).to_owned();
    }
    cleaned
}

/// `selection` limited to a text of `length` UTF-16 units. A caret stays a caret at its own
/// location (`OmnibarRules.clamped`).
pub fn clamped(selection: Range, length: i64) -> Range {
    if selection.location == NOT_FOUND {
        return Range { location: length, length: 0 };
    }
    let location = selection.location.max(0).min(length);
    Range { location, length: selection.length.max(0).min(length - location) }
}

/// The text's length in UTF-16 units (`OmnibarRules.length`).
pub fn utf16_length(text: &str) -> i64 {
    text.encode_utf16().count() as i64
}

/// `url` is the https upgrade of scheme-less typed `text`: the text names no scheme and resolves
/// to this https URL by itself (`OmnibarRules.isHTTPSUpgrade`).
pub fn is_https_upgrade(text: &str, url: &str, resolver: &TypedInput) -> bool {
    let trimmed = trim_whitespaces(text);
    if Url::parse(url).scheme_lowercased().as_deref() != Some("https") || trimmed.contains("://") {
        return false;
    }
    resolver.resolve(trimmed).as_deref() == Some(url)
}
