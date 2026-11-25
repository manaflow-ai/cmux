//! The omnibox history ranking, ported 1:1 from the app's Swift: `BrowserHistoryRanker`
//! (Omnibox/BrowserHistoryRanker.swift: the score, the dedupe key), `OmniboxQuickScore` and
//! `OmniboxText` (Omnibox/Suggest/OmniboxQuickScore.swift: the quick index score and its text
//! rules) and the display URL they rank on (`BrowserURLDisplay.displayText`).
//!
//! Times are seconds since 2001-01-01 as a `Double`, what `JSONEncoder` writes for a `Date`
//! (`now` and `lastVisit` are on the same clock, so only their difference matters). Floating
//! point runs in the Swift's operation order, so a score is the same number the Swift gave.
//!
//! Text is compared by Unicode scalar, not by Swift grapheme cluster: the two agree on every
//! URL and word the omnibox sees, and differ only for text built of combining marks.

use serde::{Deserialize, Serialize};

/// A visited page (`BrowserHistoryEntry`). `url` is the URL's `absoluteString`.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub url: String,
    #[serde(default)]
    pub title: Option<String>,
    pub visit_count: i64,
    /// Visits typed in the omnibar. Entries written before it existed decode with 0.
    #[serde(default)]
    pub typed_count: i64,
    pub last_visit: f64,
}

const DAY: f64 = 86_400.0;

/// Score for `entry` given `text`, or `None` when it does not match.
///
/// Every whitespace-separated token must match the URL or the title.
/// Host-prefix matches score highest (typing "git" should offer
/// github.com first), then URL prefix, then word starts in the title,
/// then any substring. Frequency and recency break ties.
pub fn score(entry: &HistoryEntry, text: &str, now: f64, home: &str) -> Option<f64> {
    let lowered = text.to_lowercase();
    let tokens: Vec<&str> = lowered.split_whitespace().collect();
    if tokens.is_empty() {
        return None;
    }

    let host = stripped_host(&entry.url);
    let url_text = display_text(Some(&entry.url), home).to_lowercase();
    let title = entry.title.as_deref().map(str::to_lowercase).unwrap_or_default();

    let mut matched: f64 = 0.0;
    for (index, token) in tokens.iter().enumerate() {
        let token_score: f64 = if index == 0 && host.starts_with(token) {
            600.0
        } else if index == 0 && url_text.starts_with(token) {
            450.0
        } else if title.starts_with(token) || title.contains(&format!(" {token}")) {
            300.0
        } else if url_text.contains(token) || title.contains(token) {
            150.0
        } else {
            return None;
        };
        matched += token_score;
    }
    matched /= tokens.len() as f64;

    let frequency = ((entry.visit_count.max(1)) as f64).log2() * 40.0;
    let age_days = (now - entry.last_visit).max(0.0) / DAY;
    let recency = 120.0 * (-age_days / 14.0).exp();
    // Shorter URLs win among equal matches: the site root beats deep pages.
    let brevity = (40.0 - url_text.chars().count() as f64 / 4.0).max(0.0);
    Some(matched + frequency + recency + brevity)
}

/// Key that treats `http`/`https`, `www.`, and a trailing slash as equal.
pub fn dedupe_key(url: &str, home: &str) -> String {
    let mut text = display_text(Some(url), home).to_lowercase();
    if let Some(rest) = text.strip_prefix("http://") {
        text = rest.to_owned();
    }
    if text.ends_with('/') {
        text.pop();
    }
    text
}

fn stripped_host(url: &str) -> String {
    let host = Parts::of(url).host().map(|host| percent_decode(&host).unwrap_or(host));
    let host = host.unwrap_or_default().to_lowercase();
    host.strip_prefix("www.").map(str::to_owned).unwrap_or(host)
}

// MARK: display text

/// Schemes Chromium shows with the scheme (`ChromiumInternalURL.chromiumSchemes`).
const CHROMIUM_SCHEMES: [&str; 2] = ["chrome", "chrome-extension"];

/// A URL split the way `URLComponents` splits it.
struct Parts<'a> {
    scheme: Option<&'a str>,
    /// The text after `//` up to the path, when the URL has an authority.
    authority: Option<&'a str>,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

impl<'a> Parts<'a> {
    fn of(url: &'a str) -> Parts<'a> {
        let (rest, fragment) = match url.split_once('#') {
            Some((rest, fragment)) => (rest, Some(fragment)),
            None => (url, None),
        };
        let (rest, query) = match rest.split_once('?') {
            Some((rest, query)) => (rest, Some(query)),
            None => (rest, None),
        };
        let mut scheme = None;
        let mut rest = rest;
        if let Some((candidate, after)) = rest.split_once(':') {
            let mut chars = candidate.chars();
            let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
                && chars.all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.');
            if valid {
                scheme = Some(candidate);
                rest = after;
            }
        }
        let (authority, path) = match rest.strip_prefix("//") {
            Some(after) => match after.find('/') {
                Some(slash) => (Some(&after[..slash]), &after[slash..]),
                None => (Some(after), ""),
            },
            None => (None, rest),
        };
        Parts { scheme, authority, path, query, fragment }
    }

    /// `(user info including its @, host as written, port with its colon)`.
    fn authority_parts(&self) -> Option<(&'a str, &'a str, &'a str)> {
        let authority = self.authority?;
        let (user, hostport) = match authority.rfind('@') {
            Some(at) => (&authority[..=at], &authority[at + 1..]),
            None => ("", authority),
        };
        let (host, port) = if hostport.starts_with('[') {
            match hostport.find(']') {
                Some(end) => (&hostport[..=end], &hostport[end + 1..]),
                None => (hostport, ""),
            }
        } else {
            match hostport.rfind(':') {
                Some(colon) if hostport[colon + 1..].chars().all(|c| c.is_ascii_digit()) => {
                    (&hostport[..colon], &hostport[colon..])
                }
                _ => (hostport, ""),
            }
        };
        Some((user, host, port))
    }

    /// The host without IPv6 brackets (`URL.host()`).
    fn host(&self) -> Option<String> {
        let (_, host, _) = self.authority_parts()?;
        let host = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
        Some(host.to_owned())
    }
}

/// `text` with percent escapes decoded, or `None` when `text` has a malformed escape or the
/// decoded bytes are not UTF-8 (`String.removingPercentEncoding`).
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok().filter(|_| !hex.starts_with('+'))?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// True for the New Tab page and the blank page (`BrowserNewTabPage.isNewTabPage`).
pub fn is_new_tab_page(text: &str) -> bool {
    matches!(text.to_lowercase().as_str(), "about:blank" | "chrome://newtab/" | "chrome://newtab")
}

fn is_remote_desktop_page(parts: &Parts) -> bool {
    parts.scheme.is_some_and(|s| s.eq_ignore_ascii_case("cmux"))
        && parts.host().is_some_and(|h| h.eq_ignore_ascii_case("remote-view"))
}

/// `path` with `home` (and only home, never a sibling such as `/Users/me2`) replaced by `~`.
pub fn tilde_path(path: &str, home: &str) -> String {
    let mut home: Vec<char> = home.chars().collect();
    while home.len() > 1 && home.last() == Some(&'/') {
        home.pop();
    }
    if home.len() <= 1 {
        return path.to_owned();
    }
    let mut trimmed: Vec<char> = path.chars().collect();
    let all: Vec<char> = trimmed.clone();
    while trimmed.len() > 1 && trimmed.last() == Some(&'/') {
        trimmed.pop();
    }
    if trimmed == home {
        return "~".to_owned();
    }
    let mut prefix = home.clone();
    prefix.push('/');
    if !all.starts_with(&prefix) {
        return path.to_owned();
    }
    let rest: String = all[home.len()..].iter().collect();
    format!("~{rest}")
}

/// Compact text shown when the field is not being edited: no `https://`,
/// no `www.`, no trailing slash on a bare host, percent escapes decoded.
/// `http://` is kept so insecure pages stay recognizable; `chrome://`
/// and `chrome-extension://` are kept as Chromium keeps them. A file
/// shows its path, `~/…` under `home` (the user's home folder), as a shell
/// and the Markdown tab's mock show it.
pub fn display_text(url: Option<&str>, home: &str) -> String {
    let Some(url) = url else { return String::new() };
    let parts = Parts::of(url);
    if is_new_tab_page(url) || is_remote_desktop_page(&parts) {
        return String::new();
    }
    if parts.scheme.is_some_and(|s| s.eq_ignore_ascii_case("file")) {
        let path = percent_decode(parts.path).unwrap_or_else(|| parts.path.to_owned());
        return tilde_path(&path, home);
    }
    let Some((_, host, port)) = parts.authority_parts() else { return url.to_owned() };
    let bare = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
    if bare.is_empty() {
        return url.to_owned();
    }
    let scheme = parts.scheme.map(str::to_lowercase);
    let mut shown_host = host.to_owned();
    if host.to_lowercase().starts_with("www.")
        && host.split('.').filter(|l| !l.is_empty()).count() > 2
    {
        shown_host = host[4..].to_owned();
    }
    let mut text = format!("{shown_host}{port}{}", parts.path);
    if let Some(query) = parts.query {
        text.push('?');
        text.push_str(query);
    }
    if let Some(fragment) = parts.fragment {
        text.push('#');
        text.push_str(fragment);
    }
    if parts.path == "/" && parts.query.is_none() && parts.fragment.is_none() {
        text.pop();
    }
    text = percent_decode(&text).unwrap_or(text);
    // Chromium's own pages keep their scheme, as Chromium shows them
    // (`chrome://extensions`, never a bare `extensions`).
    if let Some(scheme) = scheme
        && (scheme == "http" || CHROMIUM_SCHEMES.contains(&scheme.as_str()))
    {
        return format!("{scheme}://{text}");
    }
    text
}

// MARK: OmniboxText

/// Longer input gets only the what-you-typed row: no index lookup and no remote fetch.
pub const MAX_INPUT_LENGTH: usize = 2_048;
/// Tokens past this many are ignored.
pub const MAX_TOKENS: usize = 8;

/// Lowercased, whitespace-separated tokens of typed text.
pub fn query_tokens(text: &str) -> Vec<String> {
    text.to_lowercase().split_whitespace().take(MAX_TOKENS).map(str::to_owned).collect()
}

/// Lowercased runs of letters and digits ("github.com/manaflow-ai" is github, com, manaflow, ai).
pub fn words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    for character in text.to_lowercase().chars() {
        if character.is_alphabetic() || character.is_numeric() {
            current.push(character);
        } else if !current.is_empty() {
            words.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

/// Space, tab and the Unicode space separators (`CharacterSet.whitespaces`).
fn is_inline_space(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Typed text as the start of a URL: lowercased, without a scheme and a
/// leading `www.`, the way `BrowserURLDisplay` shows hosts.
pub fn url_prefix(text: &str) -> String {
    let mut text = text.trim_matches(is_inline_space).to_lowercase();
    for scheme in ["https://", "http://"] {
        if text.starts_with(scheme) {
            text.drain(..scheme.len());
        }
    }
    if text.starts_with("www.") {
        text.drain(..4);
    }
    text
}

// MARK: OmniboxQuickScore

/// The quick index score, pure and deterministic
/// (plans/cmux-next/omnibar-suggestions.md, "Quick history index"):
///
/// ```text
/// match + typedBoost + log2(visitCount) * 40 + recency + brevity
/// ```
///
/// `match` is the mean over input tokens of 600 (host prefix, first token),
/// 450 (URL prefix, first token), 300 (title word start) or 150 (substring);
/// a token that matches nothing drops the row. `typedBoost` is 200 when the
/// URL was typed at least once, `recency` is `120 * exp(-ageDays / 14)` and
/// `brevity` is `max(0, 40 - urlLength / 4)` (the site root beats deep pages).
pub mod quick {
    pub const HOST_PREFIX: f64 = 600.0;
    pub const URL_PREFIX: f64 = 450.0;
    pub const TITLE_WORD: f64 = 300.0;
    pub const SUBSTRING: f64 = 150.0;
    pub const TYPED_BOOST: f64 = 200.0;
    /// The most `recency` adds (an upper bound for pruning).
    pub const MAX_RECENCY: f64 = 120.0;

    /// The match term for lowercased `tokens`, or `None` when a token matches
    /// neither the URL nor the title. `spaced` is each token with a leading
    /// space; `title_spaced` is the lowercased title with one.
    pub fn match_term(
        tokens: &[String],
        spaced: &[String],
        host: &str,
        url: &str,
        title_spaced: &str,
    ) -> Option<f64> {
        if tokens.is_empty() {
            return None;
        }
        let mut total: f64 = 0.0;
        for (index, token) in tokens.iter().enumerate() {
            if index == 0 && host.starts_with(token.as_str()) {
                total += HOST_PREFIX;
            } else if index == 0 && url.starts_with(token.as_str()) {
                total += URL_PREFIX;
            } else if title_spaced.contains(spaced.get(index)?.as_str()) {
                total += TITLE_WORD;
            } else if url.contains(token.as_str()) || title_spaced.contains(token.as_str()) {
                total += SUBSTRING;
            } else {
                return None;
            }
        }
        Some(total / tokens.len() as f64)
    }

    /// `typedBoost + log2(visitCount) * 40`: the part that does not depend
    /// on the input or the time.
    pub fn usage(visit_count: i64, typed_count: i64) -> f64 {
        (if typed_count > 0 { TYPED_BOOST } else { 0.0 })
            + (visit_count.max(1) as f64).log2() * 40.0
    }

    pub fn recency(last_visit: f64, now: f64) -> f64 {
        120.0 * (-(now - last_visit).max(0.0) / 86_400.0 / 14.0).exp()
    }

    pub fn brevity(url_length: i64) -> f64 {
        (40.0 - url_length as f64 / 4.0).max(0.0)
    }

    /// The whole score of a row whose input matched with `matched`.
    pub fn score(
        matched: f64,
        visit_count: i64,
        typed_count: i64,
        last_visit: f64,
        now: f64,
        url_length: i64,
    ) -> f64 {
        matched + usage(visit_count, typed_count) + recency(last_visit, now) + brevity(url_length)
    }

    /// Inline autocomplete may complete to a row only when the input is the
    /// start of its URL at the host (a label boundary, "git" for
    /// github.com/) and the URL was typed once or visited at least 4 times.
    pub fn allows_inline_completion(host_prefix: bool, visit_count: i64, typed_count: i64) -> bool {
        host_prefix && (typed_count > 0 || visit_count >= 4)
    }
}
