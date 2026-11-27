//! Removes secrets from text before it is journaled: auth headers, cookies, bearer and API tokens,
//! JWTs, URL credentials and secret query values, and long opaque blobs. The rules of the Swift
//! `ErrorRedactor` they replace, byte for byte: a journal line stamped with [`Redactor::rules_digest`]
//! is not redacted again on open.

use crate::fingerprint::fingerprint;
use crate::text::is_swift_alphanumeric;
use regex::Regex;
use std::sync::OnceLock;

/// The replacement rules, in order: pattern (as the digest names it) and template.
pub const PATTERNS: [(&str, &str); 6] = [
    // URL credentials: scheme://user:password@host
    (r"([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#\s]+@", "$1<redacted>@"),
    // Cookie and authorization headers contain structured lists whose later fields are just as
    // sensitive as the first one.
    (r"(?i)\b((?:proxy-)?authorization|(?:set-)?cookie)(\s*[:=]\s*)[^\r\n]+", "$1$2<redacted>"),
    (r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}", "<jwt>"),
    (
        r"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs]|AKIA|ASIA)[-_]?[A-Za-z0-9_-]{12,}",
        "<redacted>",
    ),
    // Long opaque runs (keys, hashes, base64 payloads).
    (r"[A-Za-z0-9+/_=-]{48,}", "<blob>"),
];
/// Finds `key=` / `key: ` / `"key":` assignments; the key is group 1.
pub const ANCHOR_PATTERN: &str = r#"\b([A-Za-z_][A-Za-z0-9_-]*)((?:(?:\\+)?["'])?\s*[:=]\s*)"#;
/// The query-key pattern the Swift rules used; [`query_assignments`] matches it by hand (the
/// regex crate has no lookahead).
pub const QUERY_PATTERN: &str = r#"(?=(^|[?#&;\s="'=(:,])([^=?&#;\s"']+)=)"#;
/// Bump when the matching code changes what [`Redactor::redact`] returns without a pattern or key
/// list changing.
const LOGIC_REVISION: u32 = 1;

const SENSITIVE_ASSIGNMENT_COMPONENTS: [&str; 10] = [
    "auth",
    "authorization",
    "cookie",
    "credential",
    "credentials",
    "password",
    "passwd",
    "pwd",
    "secret",
    "token",
];
const KEY_SHAPE_COMPONENTS: [&str; 5] = ["access", "api", "client", "private", "session"];
const EXACT_QUERY_KEYS: [&str; 15] = [
    "access_token",
    "refresh_token",
    "token",
    "key",
    "api_key",
    "apikey",
    "sig",
    "signature",
    "code",
    "auth",
    "authorization",
    "password",
    "passwd",
    "pwd",
    "secret",
];
const SENSITIVE_QUERY_COMPONENTS: [&str; 13] = [
    "auth",
    "authorization",
    "code",
    "credential",
    "credentials",
    "key",
    "password",
    "passwd",
    "pwd",
    "secret",
    "sig",
    "signature",
    "token",
];

/// The compiled rules. One per process: [`Redactor::shared`].
pub struct Redactor {
    rules: Vec<(Regex, String)>,
    anchors: Option<Regex>,
    complete: bool,
    rules_digest: String,
}

/// Swift's `$1` template as the regex crate's `${1}`.
fn rust_template(template: &str) -> String {
    let mut out = String::new();
    let mut chars = template.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '$' && chars.peek().is_some_and(char::is_ascii_digit) {
            let mut digits = String::new();
            while let Some(digit) = chars.peek().copied().filter(char::is_ascii_digit) {
                digits.push(digit);
                chars.next();
            }
            out.push_str(&format!("${{{digits}}}"));
        } else if character == '$' {
            out.push_str("$$");
        } else {
            out.push(character);
        }
    }
    out
}

impl Default for Redactor {
    fn default() -> Self {
        Self::new()
    }
}

impl Redactor {
    /// Compiles the built-in rules.
    pub fn new() -> Self {
        let rules: Vec<(Regex, String)> = PATTERNS
            .iter()
            .filter_map(|(pattern, replacement)| {
                Regex::new(pattern).ok().map(|regex| (regex, rust_template(replacement)))
            })
            .collect();
        let anchors = Regex::new(ANCHOR_PATTERN).ok();
        let complete = rules.len() == PATTERNS.len() && anchors.is_some();
        Self { rules, anchors, complete, rules_digest: rules_digest() }
    }

    /// The process's redactor.
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<Redactor> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    /// 16 hex digits naming these rules (see [`rules_digest`]).
    pub fn rules_digest(&self) -> &str {
        &self.rules_digest
    }

    /// `text` with every secret replaced by a placeholder; "<redacted>" when a rule failed to
    /// compile (fails closed).
    pub fn redact(&self, text: &str) -> String {
        let Some(anchors) = self.anchors.as_ref().filter(|_| self.complete) else {
            return "<redacted>".to_owned();
        };
        let mut text = text.to_owned();
        for (rule, replacement) in &self.rules {
            text = rule.replace_all(&text, replacement.as_str()).into_owned();
        }
        let text = redact_assignments(&text, anchors);
        redact_query_assignments(&text)
    }
}

/// Names the rules: the fingerprint of every pattern and replacement, the anchor and query
/// patterns, the four key lists (sorted, comma-joined) and the logic revision, joined by U+1E.
pub fn rules_digest() -> String {
    let mut parts: Vec<String> = PATTERNS
        .iter()
        .flat_map(|(pattern, replacement)| [(*pattern).to_owned(), (*replacement).to_owned()])
        .collect();
    parts.push(ANCHOR_PATTERN.to_owned());
    parts.push(QUERY_PATTERN.to_owned());
    for list in [
        &SENSITIVE_ASSIGNMENT_COMPONENTS[..],
        &KEY_SHAPE_COMPONENTS[..],
        &EXACT_QUERY_KEYS[..],
        &SENSITIVE_QUERY_COMPONENTS[..],
    ] {
        let mut sorted = list.to_vec();
        sorted.sort_unstable();
        parts.push(sorted.join(","));
    }
    parts.push(LOGIC_REVISION.to_string());
    fingerprint("redaction", &parts.join("\u{1e}"), None)
}

fn replace_ranges(text: &str, ranges: &[(usize, usize)]) -> String {
    let mut result = text.to_owned();
    for &(start, end) in ranges.iter().rev() {
        result.replace_range(start..end, "<redacted>");
    }
    result
}

fn redact_assignments(text: &str, anchors: &Regex) -> String {
    let mut ranges = Vec::new();
    let mut covered_until = 0;
    for captures in anchors.captures_iter(text) {
        let Some(whole) = captures.get(0) else { continue };
        if whole.start() < covered_until {
            continue;
        }
        let Some(key) = captures.get(1) else { continue };
        if !is_sensitive_assignment_key(key.as_str()) {
            continue;
        }
        let value_start = whole.end();
        let value_end = assignment_value_end(text.as_bytes(), value_start);
        ranges.push((value_start, value_end));
        covered_until = value_end;
    }
    replace_ranges(text, &ranges)
}

fn is_query_key_character(character: char) -> bool {
    !matches!(character, '=' | '?' | '&' | '#' | ';' | '"' | '\'') && !character.is_whitespace()
}

fn is_query_key_lead(character: char) -> bool {
    matches!(character, '?' | '#' | '&' | ';' | '=' | '"' | '\'' | '(' | ':' | ',')
        || character.is_whitespace()
}

/// The byte ranges of the keys [`QUERY_PATTERN`] finds, in order: at each character position,
/// `(^|lead)(key+)=` looked ahead.
pub fn query_assignments(text: &str) -> Vec<(usize, usize)> {
    let key_end = |start: usize| -> Option<usize> {
        let rest = text.get(start..).unwrap_or_default();
        let length: usize =
            rest.chars().take_while(|&c| is_query_key_character(c)).map(char::len_utf8).sum();
        (length > 0 && rest.get(length..).is_some_and(|after| after.starts_with('=')))
            .then_some(start + length)
    };
    let mut keys = Vec::new();
    for (position, character) in text.char_indices() {
        if position == 0
            && let Some(end) = key_end(0)
        {
            keys.push((0, end));
            continue;
        }
        if is_query_key_lead(character) {
            let start = position + character.len_utf8();
            if let Some(end) = key_end(start) {
                keys.push((start, end));
            }
        }
    }
    keys
}

fn redact_query_assignments(text: &str) -> String {
    let mut ranges = Vec::new();
    let mut covered_until = 0;
    for (start, end) in query_assignments(text) {
        if !is_sensitive_query_key(text.get(start..end).unwrap_or_default()) {
            continue;
        }
        let value_start = end + 1;
        if value_start < covered_until {
            continue;
        }
        let value_end = query_value_end(text.as_bytes(), value_start);
        ranges.push((value_start, value_end));
        covered_until = value_end;
    }
    replace_ranges(text, &ranges)
}

/// Swift's `removingPercentEncoding`: None on a bad escape or bytes that are not UTF-8.
fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let byte = byte_at(bytes, index);
        if byte == b'%' {
            let high = (byte_at(bytes, index + 1) as char).to_digit(16)?;
            let low = (byte_at(bytes, index + 2) as char).to_digit(16)?;
            out.push((high * 16 + low) as u8);
            index += 3;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn is_sensitive_query_key(key: &str) -> bool {
    let encoded = key.replace('+', " ");
    let decoded = percent_decoded(&encoded).unwrap_or(encoded);
    let lowered = decoded.to_lowercase();
    let components: Vec<&str> =
        lowered.split(|c: char| !is_swift_alphanumeric(c)).filter(|c| !c.is_empty()).collect();
    EXACT_QUERY_KEYS.contains(&components.join("_").as_str())
        || components.iter().any(|component| SENSITIVE_QUERY_COMPONENTS.contains(component))
}

fn is_sensitive_assignment_key(key: &str) -> bool {
    let normalized = normalized_assignment_key(key);
    let components: Vec<&str> = normalized.split('_').filter(|c| !c.is_empty()).collect();
    if components.iter().any(|component| SENSITIVE_ASSIGNMENT_COMPONENTS.contains(component)) {
        return true;
    }
    components.contains(&"key")
        && components.iter().any(|component| KEY_SHAPE_COMPONENTS.contains(component))
}

/// snake_case of a camelCase, SCREAMING or kebab key: `secretAccessKey` → `secret_access_key`.
fn normalized_assignment_key(key: &str) -> String {
    let characters: Vec<char> = key.chars().collect();
    let mut normalized = String::new();
    for (index, &character) in characters.iter().enumerate() {
        if !(character.is_alphabetic() || character.is_numeric()) {
            if !normalized.ends_with('_') {
                normalized.push('_');
            }
            continue;
        }
        let previous = index.checked_sub(1).and_then(|i| characters.get(i).copied());
        let next = characters.get(index + 1).copied();
        if character.is_uppercase()
            && (previous.is_some_and(|p| p.is_lowercase() || p.is_numeric())
                || (previous.is_some_and(char::is_uppercase)
                    && next.is_some_and(char::is_lowercase)))
            && !normalized.ends_with('_')
        {
            normalized.push('_');
        }
        normalized.extend(character.to_lowercase());
    }
    normalized.trim_matches('_').to_owned()
}

/// The byte at `index`, or 0 past the end: callers check the length first, and 0 matches no
/// boundary, quote or key byte, so a missed check reads as "not here" instead of panicking.
fn byte_at(source: &[u8], index: usize) -> u8 {
    source.get(index).copied().unwrap_or(0)
}

fn is_unquoted_boundary(byte: u8) -> bool {
    matches!(byte, 10 | 13 | 38 | 44 | 59 | 125)
}

fn is_horizontal_whitespace(byte: u8) -> bool {
    matches!(byte, 9 | 11 | 12 | 32)
}

fn is_assignment_key_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_'
}

fn is_assignment_key_character(byte: u8) -> bool {
    is_assignment_key_start(byte)
        || byte.is_ascii_digit()
        || matches!(byte, b'-' | b'.' | b'[' | b']')
}

/// Where an assignment's value ends: at the closing quote of a quoted value (escaped quotes of the
/// value's own depth skipped), else at a line, `&`, `,`, `;` or `}` boundary, or before
/// whitespace that starts the next `key=`.
fn assignment_value_end(source: &[u8], start: usize) -> usize {
    let mut quote_index = start;
    while quote_index < source.len() && byte_at(source, quote_index) == b'\\' {
        quote_index += 1;
    }
    if quote_index >= source.len() {
        return source.len();
    }
    let quote = byte_at(source, quote_index);
    if quote != b'"' && quote != b'\'' {
        let mut end = start;
        while end < source.len() && !is_unquoted_boundary(byte_at(source, end)) {
            if is_horizontal_whitespace(byte_at(source, end))
                && has_assignment_after_whitespace(source, end)
            {
                return end;
            }
            end += 1;
        }
        return end;
    }
    let depth = quote_index - start;
    let mut index = quote_index + 1;
    while index < source.len() {
        let character = byte_at(source, index);
        if character == 10 || character == 13 {
            return index;
        }
        if character == b'\\' {
            let run_start = index;
            while index < source.len() && byte_at(source, index) == b'\\' {
                index += 1;
            }
            if index < source.len() && byte_at(source, index) == quote {
                if index - run_start == depth {
                    return index + 1;
                }
                index += 1;
            }
            continue;
        }
        if depth == 0 && character == quote {
            return index + 1;
        }
        index += 1;
    }
    source.len()
}

fn has_assignment_after_whitespace(source: &[u8], start: usize) -> bool {
    let mut index = start;
    while index < source.len() && is_horizontal_whitespace(byte_at(source, index)) {
        index += 1;
    }
    if index >= source.len() || !is_assignment_key_start(byte_at(source, index)) {
        return false;
    }
    index += 1;
    while index < source.len() && is_assignment_key_character(byte_at(source, index)) {
        index += 1;
    }
    while index < source.len() && is_horizontal_whitespace(byte_at(source, index)) {
        index += 1;
    }
    index < source.len() && matches!(byte_at(source, index), b':' | b'=')
}

fn query_value_end(source: &[u8], start: usize) -> usize {
    let mut end = start;
    while end < source.len() && !matches!(byte_at(source, end), 10 | 13 | 35 | 38 | 59 | 125) {
        if is_horizontal_whitespace(byte_at(source, end))
            && has_assignment_after_whitespace(source, end)
        {
            return end;
        }
        end += 1;
    }
    end
}
