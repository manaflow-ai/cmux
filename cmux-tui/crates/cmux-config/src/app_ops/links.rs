//! Where a web link opens (`browser.*` link keys of cmux-next.json): the
//! Mac app's CmuxNextSettings `LinkRouting`, `SignInPage` and `LinkRules/*`
//! (classic cmux's `BrowserExternalURLPolicy`), as ops.
//!
//! - `links.parse` `{root}` answers `{routing, diagnostics}`: the six keys,
//!   typed and defaulted from the schema; a value of the wrong type keeps its
//!   default and adds an `invalidValue` diagnostic at its path.
//!   `browser.openTerminalLinksInCmuxBrowser`, classic's name for
//!   `openLinksInCmuxBrowser`, is read only when the new key is absent.
//! - `links.target` `{routing?, url, otherTarget?, explicit?}` answers
//!   `{target}`: `"cmuxBrowser"` or `"system"`.
//! - `links.opens_in_cmux` `{routing?, url, explicit?}` answers `{opensInCmux}`.
//! - `links.sign_in_page` `{url}` answers `{signIn}`.
//! - `links.external_match` `{patterns, target}` answers `{matches}`: the
//!   `browser.urlsToAlwaysOpenExternally` matcher on its own (plain text is a
//!   case-insensitive substring, `*`/`?` a glob, `re:` a bounded regex).
//!
//! A `routing` is the object `links.parse` answers; a missing member is its
//! default. `url` is the link's absolute string as the app holds it: external
//! rules match that text unchanged.
//!
//! The matcher works on Unicode scalar values where Swift works on grapheme
//! clusters; the two agree on every URL that is not a combining sequence.

use serde_json::{Value, json};

use super::{OpError, string};
use crate::schema::Schema;

/// The link ops; None for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "links.parse" => parse_op(request),
        "links.target" => target_op(request),
        "links.opens_in_cmux" => opens_in_cmux_op(request),
        "links.sign_in_page" => {
            string(request, "url").map(|url| json!({"signIn": is_sign_in_page(url)}))
        }
        "links.external_match" => external_match_op(request),
        _ => return None,
    })
}

const ENABLED: &str = "browser.enabled";
const OPEN: &str = "browser.openLinksInCmuxBrowser";
const LEGACY_OPEN: &str = "browser.openTerminalLinksInCmuxBrowser";
const SIGN_IN: &str = "browser.openSignInPagesInCmux";
const PULL_REQUESTS: &str = "browser.openPullRequestsInGitHubPage";
const HOSTS: &str = "browser.hostsToOpenInEmbeddedBrowser";
const RULES: &str = "browser.urlsToAlwaysOpenExternally";

/// The link keys, typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkRouting {
    /// `browser.openLinksInCmuxBrowser`: false sends every link that is not a
    /// kept sign-in page to the default browser.
    pub opens_in_cmux_browser: bool,
    /// `browser.hostsToOpenInEmbeddedBrowser`: empty is every host.
    pub embedded_hosts: Vec<String>,
    /// `browser.urlsToAlwaysOpenExternally`.
    pub external_rules: Vec<String>,
    /// `browser.enabled`: false sends every link to the system.
    pub browser_enabled: bool,
    /// `browser.openSignInPagesInCmux`.
    pub sign_in_pages_in_cmux: bool,
    /// `browser.openPullRequestsInGitHubPage`.
    pub pull_requests_in_github_page: bool,
}

/// Where one link goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// A cmux browser tab.
    CmuxBrowser,
    /// The default browser for a web link, the scheme's app for any other.
    System,
}

impl Target {
    fn name(self) -> &'static str {
        match self {
            Target::CmuxBrowser => "cmuxBrowser",
            Target::System => "system",
        }
    }
}

impl Default for LinkRouting {
    /// Every key's schema default (schemas/settings/source/browser.json).
    fn default() -> Self {
        let schema = Schema::embedded();
        let flag = |key: &str, fallback: bool| {
            schema
                .row(key)
                .and_then(|row| row.default.as_ref())
                .and_then(Value::as_bool)
                .unwrap_or(fallback)
        };
        let list = |key: &str| {
            schema.row(key).and_then(|row| row.default.as_ref()).and_then(lines).unwrap_or_default()
        };
        LinkRouting {
            opens_in_cmux_browser: flag(OPEN, true),
            embedded_hosts: list(HOSTS),
            external_rules: list(RULES),
            browser_enabled: flag(ENABLED, true),
            sign_in_pages_in_cmux: flag(SIGN_IN, true),
            pull_requests_in_github_page: flag(PULL_REQUESTS, false),
        }
    }
}

impl LinkRouting {
    /// The link keys of the settings `root`, and a diagnostic per value of the wrong type.
    pub fn parse(root: &Value) -> (LinkRouting, Vec<Value>) {
        let mut setting = LinkRouting::default();
        let mut diagnostics = Vec::new();
        let Some(browser) = root.get("browser").and_then(Value::as_object) else {
            return (setting, diagnostics);
        };
        let mut invalid = |path: &str, message: &str| {
            diagnostics.push(json!({"kind": "invalidValue", "path": path, "message": message}));
        };
        let open = if browser.contains_key(leaf(OPEN)) { OPEN } else { LEGACY_OPEN };
        let flags: [(&str, &mut bool); 4] = [
            (ENABLED, &mut setting.browser_enabled),
            (SIGN_IN, &mut setting.sign_in_pages_in_cmux),
            (PULL_REQUESTS, &mut setting.pull_requests_in_github_page),
            (open, &mut setting.opens_in_cmux_browser),
        ];
        for (path, field) in flags {
            let Some(value) = browser.get(leaf(path)) else { continue };
            match value.as_bool() {
                Some(flag) => *field = flag,
                None => invalid(path, "expected true or false"),
            }
        }
        for (path, field) in
            [(HOSTS, &mut setting.embedded_hosts), (RULES, &mut setting.external_rules)]
        {
            let Some(value) = browser.get(leaf(path)) else { continue };
            // An array, as the Settings rows accept; classic's line text is only in its preferences.
            match value.as_array().and(lines(value)) {
                Some(lines) => *field = lines,
                None => invalid(path, "expected an array of strings"),
            }
        }
        (setting, diagnostics)
    }

    /// The routing as the ops answer it.
    pub fn to_json(&self) -> Value {
        json!({
            "opensInCmuxBrowser": self.opens_in_cmux_browser,
            "embeddedHosts": self.embedded_hosts,
            "externalRules": self.external_rules,
            "browserEnabled": self.browser_enabled,
            "signInPagesInCmux": self.sign_in_pages_in_cmux,
            "pullRequestsInGitHubPage": self.pull_requests_in_github_page,
        })
    }

    /// A routing object as [`LinkRouting::to_json`] writes it; a missing member is its default.
    pub fn from_json(value: &Value) -> Result<LinkRouting, OpError> {
        let mut routing = LinkRouting::default();
        let Some(object) = value.as_object() else {
            return Err(OpError::Invalid("expected a `routing` object".to_owned()));
        };
        let flags: [(&str, &mut bool); 4] = [
            ("opensInCmuxBrowser", &mut routing.opens_in_cmux_browser),
            ("browserEnabled", &mut routing.browser_enabled),
            ("signInPagesInCmux", &mut routing.sign_in_pages_in_cmux),
            ("pullRequestsInGitHubPage", &mut routing.pull_requests_in_github_page),
        ];
        for (key, field) in flags {
            let Some(value) = object.get(key) else { continue };
            *field = value
                .as_bool()
                .ok_or_else(|| OpError::Invalid(format!("expected a boolean `routing.{key}`")))?;
        }
        for (key, field) in [
            ("embeddedHosts", &mut routing.embedded_hosts),
            ("externalRules", &mut routing.external_rules),
        ] {
            let Some(value) = object.get(key) else { continue };
            *field = strings(value)
                .ok_or_else(|| OpError::Invalid(format!("expected strings in `routing.{key}`")))?;
        }
        Ok(routing)
    }

    /// Where `url` opens. Only an http(s) link can open in cmux. `other_target`
    /// (Shift-Command on a click) asks for the target the setting does not pick;
    /// `explicit` is a click that picked a cmux browser profile (the toggle does
    /// not apply, the rules do).
    pub fn target(&self, url: &str, other_target: bool, explicit: bool) -> Target {
        let parsed = ParsedUrl::new(url);
        let web = parsed.scheme.is_some_and(|scheme| {
            scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
        });
        if !self.browser_enabled || !web {
            return Target::System;
        }
        let cmux = self.opens_in_cmux(url, explicit);
        if !other_target {
            return if cmux { Target::CmuxBrowser } else { Target::System };
        }
        if cmux || normalized_host(parsed.host.as_deref().unwrap_or("")).is_none() {
            Target::System
        } else {
            Target::CmuxBrowser
        }
    }

    /// True when this http(s) link opens in a cmux browser tab: the browser is
    /// on, no external rule matches, the host is usable, and the link is a kept
    /// sign-in page or the setting (or `explicit`) and host list let it in.
    pub fn opens_in_cmux(&self, url: &str, explicit: bool) -> bool {
        if !self.browser_enabled {
            return false;
        }
        if !self.external_rules.is_empty()
            && ExternalMatcher::new(&self.external_rules).matches(url)
        {
            return false;
        }
        let parsed = ParsedUrl::new(url);
        let Some(host) = normalized_host(parsed.host.as_deref().unwrap_or("")) else {
            return false;
        };
        if self.keeps_sign_in_page_in_cmux(url) {
            return true;
        }
        if !(self.opens_in_cmux_browser || explicit) {
            return false;
        }
        if self.embedded_hosts.is_empty() {
            return true;
        }
        self.embedded_hosts.iter().any(|raw| {
            let pattern = raw.trim().to_lowercase();
            if let Some(rest) = pattern.strip_prefix("*.") {
                let Some(suffix) = normalized_host(rest) else { return false };
                return host == suffix || host.ends_with(&format!(".{suffix}"));
            }
            normalized_host(&pattern).as_deref() == Some(host.as_str())
        })
    }

    /// Whether `url` is a sign-in page `browser.openSignInPagesInCmux` keeps in cmux.
    pub fn keeps_sign_in_page_in_cmux(&self, url: &str) -> bool {
        self.browser_enabled && self.sign_in_pages_in_cmux && is_sign_in_page(url)
    }
}

fn leaf(path: &str) -> &str {
    path.rsplit('.').next().unwrap_or(path)
}

fn parse_op(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".to_owned()))?;
    let (routing, diagnostics) = LinkRouting::parse(root);
    Ok(json!({"routing": routing.to_json(), "diagnostics": diagnostics}))
}

fn routing_of(request: &Value) -> Result<LinkRouting, OpError> {
    request.get("routing").map_or_else(|| Ok(LinkRouting::default()), LinkRouting::from_json)
}

fn flag_of(request: &Value, key: &str) -> Result<bool, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(value) => {
            value.as_bool().ok_or_else(|| OpError::Invalid(format!("expected a boolean `{key}`")))
        }
    }
}

fn target_op(request: &Value) -> Result<Value, OpError> {
    let routing = routing_of(request)?;
    let url = string(request, "url")?;
    let target =
        routing.target(url, flag_of(request, "otherTarget")?, flag_of(request, "explicit")?);
    Ok(json!({"target": target.name()}))
}

fn opens_in_cmux_op(request: &Value) -> Result<Value, OpError> {
    let routing = routing_of(request)?;
    let url = string(request, "url")?;
    Ok(json!({"opensInCmux": routing.opens_in_cmux(url, flag_of(request, "explicit")?)}))
}

fn external_match_op(request: &Value) -> Result<Value, OpError> {
    let patterns = request
        .get("patterns")
        .and_then(strings)
        .ok_or_else(|| OpError::Invalid("expected strings in `patterns`".to_owned()))?;
    let target = string(request, "target")?;
    Ok(json!({"matches": ExternalMatcher::new(&patterns).matches(target)}))
}

fn strings(value: &Value) -> Option<Vec<String>> {
    value.as_array()?.iter().map(|item| item.as_str().map(str::to_owned)).collect()
}

/// Swift's `CharacterSet.newlines`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// An array of strings, or classic's one-per-line text; blank lines and `#` comments dropped.
pub fn lines(value: &Value) -> Option<Vec<String>> {
    let texts = match value {
        Value::String(text) => vec![text.clone()],
        Value::Array(_) => strings(value)?,
        _ => return None,
    };
    Some(
        texts
            .iter()
            .flat_map(|text| text.split(is_newline))
            .map(|line| line.trim_matches(|c: char| c.is_whitespace() && !is_newline(c)))
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(str::to_owned)
            .collect(),
    )
}

// MARK: URLs

/// The parts of an absolute URL the routing reads, as Foundation's `URL` splits them.
struct ParsedUrl<'a> {
    scheme: Option<&'a str>,
    /// Percent-decoded, without brackets or port; None when empty.
    host: Option<String>,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

impl<'a> ParsedUrl<'a> {
    fn new(text: &'a str) -> Self {
        let (scheme, mut rest) = match text.split_once(':') {
            Some((scheme, rest)) if is_scheme(scheme) => (Some(scheme), rest),
            _ => (None, text),
        };
        let mut host = None;
        if let Some(after) = rest.strip_prefix("//") {
            let end = after.find(['/', '?', '#']).unwrap_or(after.len());
            host = authority_host(&after[..end]);
            rest = &after[end..];
        }
        let (rest, fragment) = match rest.split_once('#') {
            Some((rest, fragment)) => (rest, Some(fragment)),
            None => (rest, None),
        };
        let (path, query) = match rest.split_once('?') {
            Some((path, query)) => (path, Some(query)),
            None => (rest, None),
        };
        ParsedUrl { scheme, host, path, query, fragment }
    }
}

fn is_scheme(text: &str) -> bool {
    let mut chars = text.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
}

fn authority_host(authority: &str) -> Option<String> {
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = match host_port.strip_prefix('[') {
        Some(inner) => inner.split_once(']').map_or(inner, |(host, _)| host),
        None => host_port.split_once(':').map_or(host_port, |(host, _)| host),
    };
    Some(percent_decode(host)).filter(|host| !host.is_empty())
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && let Some(hex) = text.get(index + 1..index + 3)
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            index += 3;
            continue;
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Classic's host normalizer (`RemoteLoopbackProxyAlias.normalizeHost`):
/// lowercase, no scheme, path, port, brackets or outer dots, IDN as punycode.
pub fn normalized_host(raw: &str) -> Option<String> {
    let mut value = raw.trim().to_lowercase();
    if value.is_empty() {
        return None;
    }
    if let Some(host) = ParsedUrl::new(&value).host {
        return trimmed_host(&host);
    }
    if let Some(start) = value.find("://") {
        value = value[start + 3..].to_owned();
    }
    if let Some(end) = value.find(['/', '?', '#']) {
        value.truncate(end);
    }
    if let Some(inner) = value.strip_prefix('[') {
        value = inner.split_once(']').map_or(inner, |(host, _)| host).to_owned();
    } else if let Some((host, port)) = value.rsplit_once(':')
        && port.chars().all(char::is_numeric)
        && value.matches(':').count() == 1
    {
        value = host.to_owned();
    }
    trimmed_host(&value)
}

fn trimmed_host(raw: &str) -> Option<String> {
    let trimmed = raw.trim_matches('.');
    if trimmed.is_empty() {
        return None;
    }
    if !trimmed.is_ascii()
        && let Ok(url::Host::Domain(domain)) = url::Host::parse(trimmed)
    {
        return Some(domain);
    }
    Some(trimmed.to_owned())
}

// MARK: Sign-in pages

/// Whether `url` is an http(s) page where a person signs in or approves a
/// device (CmuxNextSettings `SignInPage`): a `user_code` in the query or
/// fragment, an `authorize` or `devicelogin` segment, a last segment of
/// `login`, `signin`, `sign-in`, `sign_in` or `activate`, a `device` last
/// segment with a `code` query item or in a path of at most two segments, an
/// `auth` last segment after `oauth`/`oauth2`, or a `signin.`/`device.sso.` host.
pub fn is_sign_in_page(url: &str) -> bool {
    let parsed = ParsedUrl::new(url);
    let web = parsed.scheme.is_some_and(|scheme| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    });
    let Some(host) = parsed.host.as_deref().map(str::to_lowercase).filter(|_| web) else {
        return false;
    };
    let segments: Vec<String> = parsed
        .path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .map(|segment| percent_decode(segment).to_lowercase())
        .collect();
    let query: Vec<String> = parsed
        .query
        .map(|query| {
            query
                .split('&')
                .map(|item| {
                    percent_decode(item.split_once('=').map_or(item, |(name, _)| name))
                        .to_lowercase()
                })
                .collect()
        })
        .unwrap_or_default();
    let fragment = parsed.fragment.unwrap_or("").to_lowercase();
    let last = segments.last().map_or("", String::as_str);
    let has = |list: &[String], name: &str| list.iter().any(|item| item == name);
    has(&query, "user_code")
        || fragment.contains("user_code=")
        || has(&segments, "authorize")
        || has(&segments, "devicelogin")
        || matches!(last, "login" | "signin" | "sign-in" | "sign_in" | "activate")
        || (last == "device" && (has(&query, "code") || segments.len() <= 2))
        || (last == "auth"
            && segments[..segments.len() - 1]
                .iter()
                .any(|segment| segment == "oauth" || segment == "oauth2"))
        || ["signin.", "device.sso."].iter().any(|prefix| host.starts_with(prefix))
}

// MARK: External rules

const MAX_TARGET_BYTES: usize = 16_384;
const MAX_OPERATIONS_PER_PATTERN: i64 = 32_768;
const MAX_PATTERNS: usize = 256;
const MAX_INPUT_VALUES: usize = 512;
const MAX_PATTERN_BYTES: usize = 4096;
const MAX_TOTAL_PATTERN_CHARS: usize = 65_536;
const MAX_EXPRESSION_BYTES: usize = 8192;

/// `browser.urlsToAlwaysOpenExternally`'s matcher (classic's
/// `BrowserExternalURLPolicy`): every rule compiled once, each match bounded.
pub struct ExternalMatcher {
    compiled: Vec<Compiled>,
}

enum Compiled {
    Literal(String),
    LiteralFallback(String, Option<regex::Regex>),
    Wildcard(Wildcard),
    Regex(Option<regex::Regex>),
    Unmatchable,
}

impl ExternalMatcher {
    /// The matcher of `patterns`, one rule per value or line.
    pub fn new(patterns: &[String]) -> Self {
        ExternalMatcher {
            compiled: normalized_patterns(patterns)
                .iter()
                .map(|pattern| compile(pattern))
                .collect(),
        }
    }

    /// Whether a rule matches `target`.
    pub fn matches(&self, target: &str) -> bool {
        if target.len() > MAX_TARGET_BYTES {
            return false;
        }
        let lowered = target.to_lowercase();
        let chars: Vec<char> =
            if self.compiled.iter().any(|pattern| matches!(pattern, Compiled::Wildcard(_))) {
                lowered.chars().collect()
            } else {
                Vec::new()
            };
        self.compiled.iter().any(|pattern| {
            let mut budget = MAX_OPERATIONS_PER_PATTERN;
            match pattern {
                Compiled::Wildcard(wildcard) => wildcard.matches(&chars, &lowered, &mut budget),
                Compiled::Literal(literal) => lowered.contains(literal.as_str()),
                Compiled::LiteralFallback(literal, regex) => {
                    lowered.contains(literal.as_str())
                        || regex.as_ref().is_some_and(|regex| regex.is_match(target))
                }
                Compiled::Regex(regex) => {
                    regex.as_ref().is_some_and(|regex| regex.is_match(target))
                }
                Compiled::Unmatchable => false,
            }
        })
    }
}

fn normalized_patterns(values: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::new();
    let mut total = 0;
    for value in values.iter().take(MAX_INPUT_VALUES) {
        if total >= MAX_TOTAL_PATTERN_CHARS {
            return result;
        }
        let bounded: String = value.chars().take(MAX_TOTAL_PATTERN_CHARS).collect();
        for token in bounded.split(is_newline) {
            let normalized = token.trim();
            if normalized.is_empty()
                || normalized.starts_with('#')
                || !seen.insert(normalized.to_owned())
            {
                continue;
            }
            let count = normalized.chars().count();
            if result.len() >= MAX_PATTERNS || total + count > MAX_TOTAL_PATTERN_CHARS {
                return result;
            }
            result.push(normalized.to_owned());
            total += count;
        }
    }
    result
}

fn compile(pattern: &str) -> Compiled {
    if pattern.len() > MAX_PATTERN_BYTES {
        return Compiled::Unmatchable;
    }
    let prefix: String = pattern.chars().take(3).collect::<String>().to_lowercase();
    if prefix == "re:" {
        let expression = pattern.chars().skip(3).collect::<String>();
        let expression = expression.trim();
        if let Some(wildcard) = linear_wildcard(expression) {
            return Compiled::Wildcard(wildcard);
        }
        return Compiled::Regex(make_regex(expression));
    }
    if (pattern.contains('*') || pattern.contains('?')) && !is_legacy_regex_wildcard(pattern) {
        return Wildcard::new(pattern).map_or(Compiled::Unmatchable, Compiled::Wildcard);
    }
    let regex_shaped = pattern.contains(|c| "\\^$+()[]{}|".contains(c))
        || pattern.contains(".*")
        || pattern.contains(".+");
    if regex_shaped {
        if let Some(wildcard) = linear_wildcard(pattern) {
            return Compiled::Wildcard(wildcard);
        }
        return Compiled::LiteralFallback(pattern.to_lowercase(), make_regex(pattern));
    }
    Compiled::Literal(pattern.to_lowercase())
}

fn make_regex(expression: &str) -> Option<regex::Regex> {
    if !regex_is_safe(expression) {
        return None;
    }
    regex::RegexBuilder::new(expression).case_insensitive(true).build().ok()
}

fn is_legacy_regex_wildcard(pattern: &str) -> bool {
    let mut legacy = false;
    let mut escaping = false;
    let mut after_dot = false;
    for c in pattern.chars() {
        if escaping {
            escaping = false;
            after_dot = false;
            continue;
        }
        if c == '\\' {
            escaping = true;
            after_dot = false;
            continue;
        }
        if c == '?' {
            return false;
        }
        if c == '*' || c == '+' {
            if after_dot {
                legacy = true;
            } else if c == '*' {
                // A standalone star is a glob wildcard, even when a later
                // literal period happens to form the text `.*`.
                return false;
            }
        }
        after_dot = c == '.';
    }
    legacy
}

/// The legacy `.*`/`.+` regex subset as the bounded glob; None for anything
/// the glob cannot say (anchors, groups, classes, letter or digit escapes).
fn linear_wildcard(expression: &str) -> Option<Wildcard> {
    let chars: Vec<char> = expression.chars().collect();
    let mut glob = String::new();
    let mut quantified = false;
    let mut index = 0;
    let literal = |c: char, glob: &mut String| {
        if matches!(c, '\\' | '*' | '?') {
            glob.push('\\');
        }
        glob.push(c);
    };
    while index < chars.len() {
        let c = chars[index];
        match (c, chars.get(index + 1)) {
            ('.', Some('*')) => {
                glob.push('*');
                quantified = true;
                index += 2;
            }
            ('.', Some('+')) => {
                glob.push_str("?*");
                quantified = true;
                index += 2;
            }
            ('.', _) => {
                glob.push('?');
                index += 1;
            }
            ('\\', escaped) => {
                let escaped = *escaped?;
                if escaped.is_alphabetic() || escaped.is_numeric() {
                    return None;
                }
                literal(escaped, &mut glob);
                index += 2;
            }
            _ if "^$()[]{}|+?*".contains(c) => return None,
            _ => {
                literal(c, &mut glob);
                index += 1;
            }
        }
    }
    if quantified { Wildcard::new(&glob) } else { None }
}

/// Classic's `BrowserExternalURLRegexSafety`: at most two quantifiers, one
/// of them variable, one alternation; no backreferences, `(?` forms, or
/// quantified groups that hold a quantifier or alternation.
fn regex_is_safe(expression: &str) -> bool {
    const MAX_QUANTIFIERS: usize = 2;
    const MAX_ALTERNATIONS: usize = 1;
    const MAX_VARIABLE: usize = 1;
    #[derive(PartialEq)]
    enum Atom {
        None,
        Ordinary,
        Group,
        Quantified,
    }
    if expression.is_empty() || expression.len() > MAX_EXPRESSION_BYTES {
        return false;
    }
    let chars: Vec<char> = expression.chars().collect();
    let mut groups: Vec<(bool, bool)> = Vec::new(); // (has quantifier, has alternation)
    let mut previous = Atom::None;
    let mut previous_complex = false;
    let mut escaping = false;
    let mut in_class = false;
    let (mut quantifiers, mut variables, mut alternations) = (0, 0, 0);
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if escaping {
            if c.is_numeric() || matches!(c, 'k' | 'K' | 'g' | 'G') {
                return false;
            }
            escaping = false;
            previous = Atom::Ordinary;
            previous_complex = false;
            index += 1;
            continue;
        }
        if c == '\\' {
            escaping = true;
            index += 1;
            continue;
        }
        if in_class {
            if c == ']' {
                in_class = false;
                previous = Atom::Ordinary;
                previous_complex = false;
            }
            index += 1;
            continue;
        }
        match c {
            '[' => {
                in_class = true;
                previous = Atom::Ordinary;
                previous_complex = false;
            }
            '(' => {
                if chars.get(index + 1) == Some(&'?') {
                    return false;
                }
                groups.push((false, false));
                previous = Atom::None;
                previous_complex = false;
            }
            ')' => {
                let Some((quantifier, alternation)) = groups.pop() else { return false };
                if let Some(outer) = groups.last_mut() {
                    outer.0 |= quantifier;
                    outer.1 |= alternation;
                }
                previous = Atom::Group;
                previous_complex = quantifier || alternation;
            }
            '|' => {
                alternations += 1;
                if alternations > MAX_ALTERNATIONS {
                    return false;
                }
                if let Some(group) = groups.last_mut() {
                    group.1 = true;
                }
                previous = Atom::None;
                previous_complex = false;
            }
            '*' | '+' | '?' | '{' => {
                let (end, variable) = if c == '{' {
                    match bounded_quantifier(&chars, index) {
                        Some(found) => found,
                        None => return false,
                    }
                } else {
                    (index + 1, c != '?')
                };
                if !matches!(previous, Atom::Ordinary | Atom::Group)
                    || (previous == Atom::Group && previous_complex)
                {
                    return false;
                }
                quantifiers += 1;
                if quantifiers > MAX_QUANTIFIERS {
                    return false;
                }
                if variable {
                    variables += 1;
                    if variables > MAX_VARIABLE {
                        return false;
                    }
                }
                if let Some(group) = groups.last_mut() {
                    group.0 = true;
                }
                previous = Atom::Quantified;
                previous_complex = false;
                index = end;
                continue;
            }
            '^' | '$' => {
                previous = Atom::None;
                previous_complex = false;
            }
            _ => {
                previous = Atom::Ordinary;
                previous_complex = false;
            }
        }
        index += 1;
    }
    !escaping && !in_class && groups.is_empty()
}

/// The end of a `{m}`, `{m,}` or `{m,n}` quantifier starting at `start`, and whether it is variable.
fn bounded_quantifier(chars: &[char], start: usize) -> Option<(usize, bool)> {
    let close = start + 1 + chars[start + 1..].iter().position(|&c| c == '}')?;
    let body: String = chars[start + 1..close].iter().collect();
    let number = |text: &str| {
        (!text.is_empty() && text.chars().all(|c| c.is_ascii_digit()))
            .then(|| text.parse::<u32>().ok())
            .flatten()
            .filter(|&n| n <= 16_384)
    };
    let parts: Vec<&str> = body.split(',').collect();
    let lower = number(parts[0])?;
    let upper = match parts.as_slice() {
        [_] => Some(lower),
        [_, ""] => None,
        [_, upper] => Some(number(upper).filter(|&upper| upper >= lower)?),
        _ => return None,
    };
    Some((close + 1, upper != Some(lower)))
}

#[derive(Clone, Copy, PartialEq)]
enum Token {
    Star,
    Any,
    Literal(char),
}

/// A `*`/`?` glob with an implicit `*` at both ends, matched by a bounded greedy scan.
struct Wildcard {
    anchor: Option<String>,
    tokens: Vec<Token>,
}

impl Wildcard {
    fn new(pattern: &str) -> Option<Wildcard> {
        if pattern.len() > MAX_PATTERN_BYTES {
            return None;
        }
        let mut tokens = vec![Token::Star];
        let mut escaping = false;
        let mut current = String::new();
        let mut longest = String::new();
        let end_literal = |current: &mut String, longest: &mut String| {
            if current.chars().count() > longest.chars().count() {
                *longest = std::mem::take(current);
            }
            current.clear();
        };
        for c in pattern.chars() {
            if escaping || !matches!(c, '\\' | '*' | '?') {
                escaping = false;
                for lower in c.to_lowercase() {
                    tokens.push(Token::Literal(lower));
                    current.push(lower);
                }
                continue;
            }
            match c {
                '\\' => escaping = true,
                '*' => {
                    if tokens.last() != Some(&Token::Star) {
                        tokens.push(Token::Star);
                    }
                    end_literal(&mut current, &mut longest);
                }
                _ => {
                    tokens.push(Token::Any);
                    end_literal(&mut current, &mut longest);
                }
            }
        }
        if escaping {
            tokens.push(Token::Literal('\\'));
            current.push('\\');
        }
        end_literal(&mut current, &mut longest);
        if tokens.last() != Some(&Token::Star) {
            tokens.push(Token::Star);
        }
        Some(Wildcard { anchor: (longest.chars().count() >= 2).then_some(longest), tokens })
    }

    fn matches(&self, chars: &[char], lowered: &str, budget: &mut i64) -> bool {
        if self.anchor.as_deref().is_some_and(|anchor| !lowered.contains(anchor)) {
            return false;
        }
        let tokens = &self.tokens;
        let (mut token, mut index) = (0, 0);
        let mut last_star: Option<usize> = None;
        let mut star_match = 0;
        while index < chars.len() {
            *budget -= 1;
            if *budget < 0 {
                return false;
            }
            match tokens.get(token) {
                Some(Token::Any) => {
                    token += 1;
                    index += 1;
                    continue;
                }
                Some(Token::Literal(c)) if *c == chars[index] => {
                    token += 1;
                    index += 1;
                    continue;
                }
                Some(Token::Star) => {
                    last_star = Some(token);
                    token += 1;
                    star_match = index;
                    continue;
                }
                _ => {}
            }
            match last_star {
                Some(star) if star_match < chars.len() => {
                    token = star + 1;
                    star_match += 1;
                    index = star_match;
                }
                _ => return false,
            }
        }
        while tokens.get(token) == Some(&Token::Star) {
            token += 1;
        }
        token == tokens.len()
    }
}
