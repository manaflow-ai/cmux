//! Secrets in text this daemon shows elsewhere (hq#2509): API keys, tokens,
//! private keys and credentials a person pasted into a prompt, found and
//! replaced by a mask naming what each one is, such as
//! `[GitHub Personal Access Token]` or `[Slack Bot token]`.
//!
//! The rules are gitleaks' default set (MIT, `rules/secrets/gitleaks.toml`,
//! pinned and refreshed by `rules/secrets/refresh.ts`), read with gitleaks'
//! semantics: a rule's keywords gate it, its secret is its secret group or
//! first non-empty group, a secret at or under the rule's entropy is not
//! one, and the rule's and the global allowlists drop placeholders and
//! examples. Each rule's mask is its label in `rules/secrets/labels.toml`,
//! the noun phrase of its description. After them come a few rules of cmux's
//! own for shapes gitleaks leaves to context (auth headers outside curl,
//! credentials in URLs, truncated private keys, `NAME=value` secrets), and a
//! high-entropy fallback modelled on detect-secrets' base64 plugin: no code
//! is copied from either. Nothing here ever verifies a secret with its
//! provider; that would send it off the machine.
//!
//! This is a destructive transform, not a visual cover: `mask` returns new
//! text that no longer holds the secret, so a client or an acpmux peer that
//! reads only the masked copy never has the source to reveal. The original
//! stays wherever it already was (the transcript, the store, and the
//! summary's raw fields beside the lane).
//!
//! What it leaves alone on purpose: git SHAs and other hex, UUIDs, file
//! paths, and `data:...;base64,` payloads (an inline image is not a secret).
//! What it misses: a secret with no known shape that is short or has no
//! digit (an 8-letter password in prose).

use std::collections::HashMap;
use std::ops::Range;
use std::sync::LazyLock;

use regex::bytes::{Regex, RegexBuilder};
use serde::Deserialize;

/// One secret: the rule that found it, what it is, and its byte range.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// The gitleaks rule id (`github-pat`), or `cmux-...` for cmux's own.
    pub rule: &'static str,
    /// What it is (`GitHub Personal Access Token`); its mask is `[label]`.
    pub label: &'static str,
    pub range: Range<usize>,
}

const GITLEAKS: &str = include_str!("../rules/secrets/gitleaks.toml");
const LABELS: &str = include_str!("../rules/secrets/labels.toml");

#[derive(Deserialize)]
struct Config {
    #[serde(default)]
    allowlist: AllowConfig,
    rules: Vec<RuleConfig>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuleConfig {
    id: String,
    regex: Option<String>,
    #[serde(default)]
    entropy: f64,
    #[serde(default)]
    keywords: Vec<String>,
    #[serde(default)]
    secret_group: usize,
    /// A rule for one kind of file (`*.tf`): text has no path, so it never applies.
    path: Option<String>,
    #[serde(default)]
    allowlists: Vec<AllowConfig>,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct AllowConfig {
    regexes: Vec<String>,
    stopwords: Vec<String>,
    paths: Vec<String>,
    regex_target: Option<String>,
    condition: Option<String>,
}

#[derive(Deserialize)]
struct LabelsConfig {
    labels: HashMap<String, String>,
}

/// What an allowlist regex is matched against.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Target {
    Secret,
    Match,
    Line,
}

struct Allow {
    regexes: Vec<Regex>,
    stopwords: Vec<String>,
    target: Target,
    /// gitleaks' `condition = "AND"`: every check given must match. A path
    /// check never does here (text has no path), so such a list never applies.
    and: bool,
    paths: bool,
}

impl Allow {
    fn of(config: &AllowConfig) -> Option<Self> {
        let regexes = config.regexes.iter().filter_map(|p| compile(p)).collect::<Vec<_>>();
        let stopwords = config.stopwords.iter().map(|s| s.to_ascii_lowercase()).collect::<Vec<_>>();
        if regexes.is_empty() && stopwords.is_empty() {
            return None;
        }
        let target = match config.regex_target.as_deref() {
            Some("match") => Target::Match,
            Some("line") => Target::Line,
            _ => Target::Secret,
        };
        let and = config.condition.as_deref().is_some_and(|c| c.eq_ignore_ascii_case("and"));
        Some(Self { regexes, stopwords, target, and, paths: !config.paths.is_empty() })
    }

    fn allows(&self, secret: &[u8], whole: &[u8], line: &[u8]) -> bool {
        let target = match self.target {
            Target::Secret => secret,
            Target::Match => whole,
            Target::Line => line,
        };
        let regex =
            (!self.regexes.is_empty()).then(|| self.regexes.iter().any(|re| re.is_match(target)));
        let lower = secret.to_ascii_lowercase();
        let stop = (!self.stopwords.is_empty()).then(|| {
            self.stopwords.iter().any(|w| lower.windows(w.len()).any(|win| win == w.as_bytes()))
        });
        if self.and {
            !self.paths && regex.unwrap_or(true) && stop.unwrap_or(true)
        } else {
            regex.unwrap_or(false) || stop.unwrap_or(false)
        }
    }
}

struct Rule {
    id: String,
    label: String,
    re: Regex,
    /// The secret's capture group; 0 picks the first non-empty group, else the match.
    group: usize,
    entropy: f64,
    keywords: Vec<String>,
    allow: Vec<Allow>,
}

struct Rules {
    rules: Vec<Rule>,
    global: Vec<Allow>,
    /// cmux's own: hex (git SHAs, hashes) and UUIDs are ids, not secrets, as the
    /// value of a `NAME=value` whose name does not say secret or password
    /// (`GIT_COMMIT=<sha>`). A rule that names a header or a key keeps them.
    ids: Allow,
}

/// A Go RE2 pattern as the `regex` crate reads it: Go takes a `{` that
/// starts no repetition (`{{ env }}`) as a literal, `regex` wants it escaped.
fn translate(pattern: &str) -> String {
    let mut out = String::with_capacity(pattern.len() + 8);
    let mut class = false;
    let mut chars = pattern.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            out.push(c);
            // The escaped character is copied as it is; a trailing `\` stays.
            if let Some(escaped) = chars.next() {
                out.push(escaped);
            }
            continue;
        }
        match c {
            '[' if !class => class = true,
            ']' if class => class = false,
            '{' if !class && !repetition(chars.as_str()) => {
                out.push_str("\\{");
                continue;
            }
            _ => {}
        }
        out.push(c);
    }
    out
}

/// `n}`, `n,}` or `n,m}` at the start of `after`, the text after a `{`.
fn repetition(after: &str) -> bool {
    let Some((inner, _)) = after.split_once('}') else { return false };
    let mut parts = inner.splitn(2, ',');
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    match (parts.next(), parts.next()) {
        (Some(n), None) => digits(n),
        (Some(n), Some(m)) => digits(n) && (m.is_empty() || digits(m)),
        _ => false,
    }
}

/// Go's classes (`\w`, `\s`, `\b`) are ASCII; so are these.
fn compile(pattern: &str) -> Option<Regex> {
    RegexBuilder::new(&translate(pattern)).unicode(false).size_limit(1 << 24).build().ok()
}

#[allow(
    clippy::expect_used,
    reason = "INVARIANT: every caller passes a constant pattern; tests::the_constant_patterns_compile builds them"
)]
fn own(id: &str, label: &str, pattern: &str, group: usize) -> Rule {
    Rule {
        id: id.to_owned(),
        label: label.to_owned(),
        re: compile(pattern).expect("constant pattern"), // crash-allow: constant pattern
        group,
        entropy: 0.0,
        keywords: Vec::new(),
        allow: Vec::new(),
    }
}

/// gitleaks' rules in file order, then cmux's own, then gitleaks' `generic-*`,
/// so a known shape names its kind where a generic match overlaps it.
#[allow(
    clippy::expect_used,
    reason = "INVARIANT: the bundled gitleaks and label files and constant patterns; tests::the_constant_patterns_compile builds them"
)]
static RULES: LazyLock<Rules> = LazyLock::new(|| {
    let config: Config = toml::from_str(GITLEAKS).expect("constant pattern"); // crash-allow: constant pattern
    let labels: LabelsConfig = toml::from_str(LABELS).expect("constant pattern"); // crash-allow: constant pattern
    let mut rules: Vec<Rule> = config
        .rules
        .iter()
        .filter(|rule| rule.path.is_none())
        .filter_map(|rule| {
            let re = compile(rule.regex.as_deref()?)?;
            Some(Rule {
                label: labels
                    .labels
                    .get(&rule.id)
                    .cloned()
                    .unwrap_or_else(|| rule.id.replace('-', " ")),
                id: rule.id.clone(),
                re,
                group: rule.secret_group,
                entropy: rule.entropy,
                keywords: rule.keywords.iter().map(|k| k.to_ascii_lowercase()).collect(),
                allow: rule.allowlists.iter().filter_map(Allow::of).collect(),
            })
        })
        .collect();
    let generic: Vec<Rule> = rules.extract_if(.., |rule| rule.id.starts_with("generic")).collect();
    rules.extend([
        own(
            "cmux-private-key",
            "Private Key",
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?s:.*?)(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)",
            0,
        ),
        own(
            "cmux-auth-header",
            "auth token",
            r"(?i)\b(?:proxy-)?authorization\s*[:=]\s*(?:bearer|basic|token|digest)\s+([A-Za-z0-9._~+/-]+=*)",
            1,
        ),
        own("cmux-bearer", "auth token", r"(?i)\bbearer\s+([A-Za-z0-9._~+/-]{16,}=*)", 1),
        own(
            "cmux-api-key-header",
            "auth token",
            r#"(?i)\b(?:x-api-key|api-key|x-auth-token)["']?\s*[:=]\s*["']?([A-Za-z0-9._~+/-]{8,})"#,
            1,
        ),
        own("cmux-url-credentials", "credentials", r"\b[a-zA-Z][a-zA-Z0-9+.-]*://([^\s/?#@:]+:[^\s/?#@]+)@", 1),
        own(
            "cmux-assignment",
            "secret",
            r#"(?i)\b[a-z0-9_-]*(?:api[_-]?key|secret|token|passw(?:or)?d|credentials?|private[_-]?key|access[_-]?key)[a-z0-9_-]*["']?\s*[=:]\s*(?:"([^"\s]{6,})"|'([^'\s]{6,})'|([^\s"',;]{6,}))"#,
            0,
        ),
    ]);
    rules.extend(generic);
    let global: Vec<Allow> = Allow::of(&config.allowlist).into_iter().collect();
    let ids = Allow::of(&AllowConfig {
        regexes: vec![
            r"^[0-9a-fA-F]{7,128}$".into(),
            r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$".into(),
        ],
        ..AllowConfig::default()
    })
    .expect("constant pattern"); // crash-allow: constant pattern
    Rules { rules, global, ids }
});

#[allow(
    clippy::expect_used,
    reason = "INVARIANT: constant patterns; tests::the_constant_patterns_compile builds them"
)]
static ENTROPY_CANDIDATE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"[A-Za-z0-9+_-]{32,}=*").expect("constant pattern")); // crash-allow: constant pattern
#[allow(
    clippy::expect_used,
    reason = "INVARIANT: constant patterns; tests::the_constant_patterns_compile builds them"
)]
static DATA_URI: LazyLock<Regex> = LazyLock::new(|| {
    compile(r"data:[A-Za-z]+/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+").expect("constant pattern") // crash-allow: constant pattern
});

/// Shannon entropy in bits per byte, as gitleaks measures a secret.
fn entropy(s: &[u8]) -> f64 {
    let mut counts = [0u32; 256];
    for &b in s {
        // 256 slots, one per byte value.
        if let Some(count) = counts.get_mut(usize::from(b)) {
            *count += 1;
        }
    }
    let n = s.len() as f64;
    counts.iter().filter(|&&c| c > 0).map(|&c| f64::from(c) / n).map(|p| -p * p.log2()).sum()
}

/// A run that reads as a random token: upper and lower case, at least three
/// digits, and a spread no word or identifier has. Hex (git SHAs, hashes)
/// and UUIDs lack one of the cases, so they never qualify.
fn looks_random(s: &[u8]) -> bool {
    s.iter().any(u8::is_ascii_uppercase)
        && s.iter().any(u8::is_ascii_lowercase)
        && s.iter().filter(|b| b.is_ascii_digit()).count() >= 3
        && entropy(s) >= 4.3
}

/// A placeholder or a reference, not a value: `$TOKEN`, `${TOKEN}`,
/// `${{ secrets.X }}`, `<your key>`, `#{password}`, a mask (`[secret]`, or the
/// `[Shopify` a later scan reads of `[Shopify private app access token]`),
/// `process.env.TOKEN`, a `Password:` label. A value that only starts with
/// `$` or `#` (`$up3rS3cret9`) is still a value.
fn is_placeholder(value: &str) -> bool {
    let v = value.trim_matches(['"', '\'']);
    v.starts_with('<')
        || v.ends_with(':')
        || v.chars().all(|c| c == '*' || c == 'x' || c == 'X')
        || PLACEHOLDER.is_match(v.as_bytes())
        || CODE_PATH.is_match(v.as_bytes())
}

#[allow(
    clippy::expect_used,
    reason = "INVARIANT: constant patterns; tests::the_constant_patterns_compile builds them"
)]
static PLACEHOLDER: LazyLock<Regex> = LazyLock::new(|| {
    compile(r"^(?:\$\{\{.*|\$\{?(?:[A-Z_][A-Z0-9_]*|[a-z_][a-z0-9_]*)\}?|#\{[^}]*\}|\[[A-Za-z][A-Za-z .-]*\]?)$").expect("constant pattern") // crash-allow: constant pattern
});

/// `process.env.TOKEN`, `config.password`, `os.environ`: a name, not a value.
#[allow(
    clippy::expect_used,
    reason = "INVARIANT: constant patterns; tests::the_constant_patterns_compile builds them"
)]
static CODE_PATH: LazyLock<Regex> = LazyLock::new(|| {
    compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?:\(\))?$")
        .expect("constant pattern") // crash-allow: constant pattern
});

/// An assignment's value that can be a secret: not a placeholder, not a
/// path (`secret_scan::mask`, `/en/docs`), not a call (`compute_secret(x)`),
/// and with a letter and a digit, so a count (`max_tokens: 100000`) or a word
/// (`token: expired`) is left alone. A name that says secret or password
/// (`strong`) takes a word too when it is assigned (`password = open_sesame`)
/// or quoted, but not a type (`password: String`) or the name again
/// (`passwordLabel: "Password"`).
fn is_value(value: &[u8], strong: bool, assigned: bool) -> bool {
    let v = String::from_utf8_lossy(value);
    let v = v.trim_matches(['"', '\'']);
    let lower = v.to_ascii_lowercase();
    let mixed = v.bytes().any(|b| b.is_ascii_alphabetic()) && v.bytes().any(|b| b.is_ascii_digit());
    let word = strong && assigned && !lower.contains("passw") && !lower.contains("secret");
    !is_placeholder(v) && !v.starts_with([':', '/']) && !v.contains('(') && (mixed || word)
}

/// An assignment whose name says secret or password (`GITHUB_SECRET=`,
/// `password =`): its value is one even when it looks like an id or a word.
fn strong_name(whole: &[u8]) -> bool {
    let lower = whole.to_ascii_lowercase();
    [&b"secret"[..], b"passw"].iter().any(|w| lower.windows(w.len()).any(|win| win == *w))
}

/// Whether the name before a value says it is an id (`before` is its line up
/// to the value): a bare `key`, a cache, restore or idempotency key, an etag
/// or a commit. Any other key name (`encryption_key`, `DD_APP_KEY`, "the
/// signing key") may hold a real key, which is often hex.
fn names_an_id(before: &[u8]) -> bool {
    let lower = before.to_ascii_lowercase();
    let end = lower.iter().rposition(|b| !b" \t:=\"'`,>|?".contains(b)).map_or(0, |i| i + 1);
    let name = lower.get(..end).unwrap_or_default();
    let word = |b: &u8| b.is_ascii_alphanumeric() || b"_.-".contains(b);
    let start = name.iter().rposition(|b| !word(b)).map_or(0, |i| i + 1);
    let (head, last) = name.split_at_checked(start).unwrap_or((&[], name));
    let token: Vec<u8> =
        last.iter().map(|&b| if b == b'-' || b == b'.' { b'_' } else { b }).collect();
    match token.as_slice() {
        b"cache_key" | b"cachekey" | b"restore_key" | b"restorekey" | b"idempotency_key"
        | b"idempotencykey" | b"etag" | b"commit" | b"commit_sha" | b"commit_id" => true,
        // A bare key, or the second word of "cache key" and the like.
        b"key" => {
            let before = head.trim_ascii_end();
            let from = before.iter().rposition(|b| !b.is_ascii_alphanumeric()).map_or(0, |i| i + 1);
            matches!(
                before.get(from..).unwrap_or_default(),
                b"" | b"cache" | b"restore" | b"idempotency"
            )
        }
        _ => false,
    }
}

/// The line of `text` around `range`.
fn line_of(text: &[u8], range: &Range<usize>) -> Range<usize> {
    let before = text.get(..range.start).unwrap_or_default();
    let start = before.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    let after = text.get(range.end..).unwrap_or_default();
    let end = after.iter().position(|&b| b == b'\n').map_or(text.len(), |i| range.end + i);
    start..end
}

/// `range` widened to whole characters of `text`.
fn on_chars(text: &str, mut range: Range<usize>) -> Range<usize> {
    while !text.is_char_boundary(range.start) {
        range.start -= 1;
    }
    while !text.is_char_boundary(range.end) {
        range.end += 1;
    }
    range
}

/// Every secret in `text`, in order, with overlapping finds merged into one.
pub fn find(text: &str) -> Vec<Found> {
    let rules = &*RULES;
    let bytes = text.as_bytes();
    let lower = text.to_ascii_lowercase();
    let data: Vec<Range<usize>> = DATA_URI.find_iter(bytes).map(|m| m.range()).collect();
    let inside_data = |r: &Range<usize>| data.iter().any(|d| d.start <= r.start && r.end <= d.end);
    let mut all: Vec<(usize, Found)> = Vec::new();
    for (order, rule) in rules.rules.iter().enumerate() {
        if !rule.keywords.is_empty() && !rule.keywords.iter().any(|k| lower.contains(k.as_str())) {
            continue;
        }
        for caps in rule.re.captures_iter(bytes) {
            let Some(whole) = caps.get(0) else { continue };
            let secret = match rule.group {
                0 => (1..caps.len())
                    .find_map(|g| caps.get(g).filter(|m| !m.is_empty()))
                    .unwrap_or(whole),
                g => match caps.get(g) {
                    Some(m) if !m.is_empty() => m,
                    _ => continue,
                },
            };
            let s = secret.as_bytes();
            if rule.entropy > 0.0 && entropy(s) <= rule.entropy {
                continue;
            }
            let assignment = rule.id == "cmux-assignment";
            // The secret is a group of `whole`, so it starts inside it.
            let name = whole.as_bytes().get(..secret.start() - whole.start()).unwrap_or_default();
            let strong = assignment && strong_name(name);
            let assigned = name.contains(&b'=') || name.ends_with(b"\"") || name.ends_with(b"'");
            if assignment && !is_value(s, strong, assigned) {
                continue;
            }
            let line_range = line_of(bytes, &secret.range());
            let line_start = line_range.start;
            let line = bytes.get(line_range).unwrap_or_default();
            if rule.allow.iter().chain(&rules.global).any(|a| a.allows(s, whole.as_bytes(), line)) {
                continue;
            }
            // Only a bare `NAME=value`, or a generic match behind a name that says
            // it is an id (a cache key, a commit), drops an id: a header's, a
            // token's or a signing key's hex is its secret.
            let generic = rule.id.starts_with("generic");
            let id_name = (assignment && !strong)
                || (generic
                    && names_an_id(bytes.get(line_start..secret.start()).unwrap_or_default()));
            if id_name && rules.ids.allows(s, whole.as_bytes(), line) {
                continue;
            }
            let range = on_chars(text, secret.range());
            if inside_data(&range) {
                continue;
            }
            all.push((order, Found { rule: &rule.id, label: &rule.label, range }));
        }
    }
    for m in ENTROPY_CANDIDATE.find_iter(bytes) {
        if !inside_data(&m.range()) && looks_random(m.as_bytes()) {
            all.push((
                rules.rules.len(),
                Found { rule: "cmux-high-entropy", label: "secret", range: m.range() },
            ));
        }
    }
    all.sort_by_key(|(order, f)| (f.range.start, *order));
    let mut merged: Vec<Found> = Vec::new();
    for (_, f) in all {
        match merged.last_mut() {
            Some(last) if f.range.start < last.range.end => {
                last.range.end = last.range.end.max(f.range.end)
            }
            _ => merged.push(f),
        }
    }
    merged
}

/// `text` with every secret replaced by `[its label]`.
pub fn mask(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    // Finds are merged, in order, and on character boundaries (`on_chars`).
    for f in find(text) {
        out.push_str(text.get(at..f.range.start).unwrap_or_default());
        out.push('[');
        out.push_str(f.label);
        out.push(']');
        at = f.range.end;
    }
    out.push_str(text.get(at..).unwrap_or_default());
    out
}

#[cfg(test)]
#[path = "secret_scan_tests.rs"]
mod tests;
