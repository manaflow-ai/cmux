//! Where a module comes from (a git host, an owner, a repository) and what it
//! is pinned to (a full commit SHA or a tag). Branches are never installed.

use super::Refusal;

const MAX_SOURCE_LEN: usize = 512;
const MAX_PATH_SEGMENTS: usize = 8;
const MAX_TAG_LEN: usize = 128;
/// Hosts a module may not name: local, private, test and reserved suffixes.
const NON_PUBLIC_SUFFIXES: &[&str] = &[
    "localhost",
    "localdomain",
    "local",
    "internal",
    "intranet",
    "lan",
    "corp",
    "private",
    "home.arpa",
    "test",
    "invalid",
    "example",
];
const KNOWN_FORGES: &[&str] = &["github.com", "gitlab.com", "codeberg.org", "bitbucket.org"];

/// The only two transports a module may be fetched over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Https,
    Ssh,
}

/// A git repository reference after validation. Fields are private so the
/// only way to get one is [`GitSource::parse`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitSource {
    transport: Transport,
    host: String,
    path: String,
}

impl GitSource {
    /// Accepts `https://host/owner/repo[.git]`, `ssh://git@host/owner/repo`
    /// and `git@host:owner/repo`. Everything else is refused: no other
    /// scheme, no credentials, ports, queries, percent-encoding, IP literals,
    /// private or single-label hosts, and no option-looking input.
    pub fn parse(input: &str) -> Result<Self, Refusal> {
        if input.len() > MAX_SOURCE_LEN {
            return Err(Refusal::new("source.tooLong", "the source URL is longer than 512 bytes"));
        }
        if input.chars().any(|c| c.is_control() || c.is_whitespace()) {
            return Err(Refusal::new(
                "source.invalidChar",
                "the source has spaces or control characters",
            ));
        }
        if input.contains(['%', '?', '#', '\\']) {
            return Err(Refusal::new(
                "source.invalidChar",
                "the source has a query, fragment, percent-encoding or backslash",
            ));
        }
        if let Some(rest) = input.strip_prefix("https://") {
            return split_host_path(Transport::Https, rest);
        }
        if let Some(rest) = input.strip_prefix("ssh://") {
            let rest = match rest.strip_prefix("git@") {
                Some(rest) => rest,
                None if rest.contains('@') => {
                    return Err(Refusal::new("source.user", "ssh sources must use the git user"));
                }
                None => rest,
            };
            return split_host_path(Transport::Ssh, rest);
        }
        if let Some(rest) = input.strip_prefix("git@") {
            let (host, path) = rest.split_once(':').ok_or_else(|| {
                Refusal::new("source.scheme", "an ssh source is git@host:owner/repo")
            })?;
            return build(Transport::Ssh, host, path);
        }
        Err(Refusal::new(
            "source.scheme",
            "only https:// and ssh (git@host:owner/repo or ssh://git@host/owner/repo) sources are accepted",
        ))
    }

    pub fn transport(&self) -> Transport {
        self.transport
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    /// The lower-case first path segment: the publisher a module must claim.
    pub fn owner(&self) -> String {
        self.path.split('/').next().unwrap_or("").to_ascii_lowercase()
    }

    /// Identity of the module source: `host/path`, lower-cased, without `.git`.
    pub fn key(&self) -> String {
        format!("{}/{}", self.host, self.path.to_ascii_lowercase())
    }

    /// `https://host/path` as the user typed the path (never credentials).
    pub fn display_url(&self) -> String {
        format!("https://{}/{}", self.host, self.path)
    }

    /// The URL git connects to.
    pub fn clone_url(&self) -> String {
        match self.transport {
            Transport::Https => self.display_url(),
            Transport::Ssh => format!("ssh://git@{}/{}", self.host, self.path),
        }
    }

    /// GitHub, GitLab, Codeberg or Bitbucket: shown with a recognised label.
    pub fn is_known_forge(&self) -> bool {
        KNOWN_FORGES.contains(&self.host.as_str())
    }
}

fn split_host_path(transport: Transport, rest: &str) -> Result<GitSource, Refusal> {
    if rest.contains('@') {
        return Err(Refusal::new("source.credentials", "a source must not carry credentials"));
    }
    let (host, path) = rest
        .split_once('/')
        .ok_or_else(|| Refusal::new("source.path", "the source needs an owner and a repository"))?;
    build(transport, host, path)
}

fn build(transport: Transport, host: &str, path: &str) -> Result<GitSource, Refusal> {
    Ok(GitSource { transport, host: normalize_host(host)?, path: normalize_path(path)? })
}

/// Lower-cases a host and checks it is a public DNS name.
fn normalize_host(host: &str) -> Result<String, Refusal> {
    let lower = host.to_ascii_lowercase();
    let bad = |why: &str| Refusal::new("source.host", format!("{host:?}: {why}"));
    if lower.is_empty() || lower.len() > 253 {
        return Err(bad("empty or too long"));
    }
    if lower.contains(':') || lower.starts_with('[') {
        return Err(bad("ports and IPv6 literals are not accepted"));
    }
    if !lower.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.') {
        return Err(bad("only letters, digits, hyphens and dots"));
    }
    let labels: Vec<&str> = lower.split('.').collect();
    if labels.len() < 2 {
        return Err(bad("a single-label host is a local name"));
    }
    for label in &labels {
        if label.is_empty() || label.len() > 63 || label.starts_with('-') || label.ends_with('-') {
            return Err(bad("an empty or malformed label"));
        }
    }
    if labels.last().is_some_and(|l| l.bytes().all(|b| b.is_ascii_digit())) {
        return Err(Refusal::new(
            "source.ip",
            format!("{host:?} is an IP address, not a host name"),
        ));
    }
    if NON_PUBLIC_SUFFIXES.iter().any(|s| lower == *s || lower.ends_with(&format!(".{s}"))) {
        return Err(Refusal::new("source.private", format!("{host:?} is a local or private name")));
    }
    Ok(lower)
}

/// Checks `owner/repo[/...]`, drops one trailing `/` and one `.git`.
fn normalize_path(path: &str) -> Result<String, Refusal> {
    let bad = |why: &str| Refusal::new("source.path", format!("{path:?}: {why}"));
    let trimmed = path.strip_suffix('/').unwrap_or(path);
    let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
    let segments: Vec<&str> = trimmed.split('/').collect();
    if segments.len() < 2 || segments.len() > MAX_PATH_SEGMENTS {
        return Err(bad("an owner and a repository, at most 8 segments"));
    }
    for segment in &segments {
        if segment.is_empty() || segment.contains("..") {
            return Err(bad("an empty or dot segment"));
        }
        if segment.starts_with('.') || segment.starts_with('-') {
            return Err(bad("a segment starts with a dot or a hyphen"));
        }
        if !segment.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')) {
            return Err(bad("a segment has a character outside letters, digits, . _ -"));
        }
    }
    Ok(trimmed.to_string())
}

/// Whether a host name may be contacted from a module: a public DNS name with
/// a dot, not an IP literal and not a local, private or test name.
pub fn is_public_host(host: &str) -> bool {
    normalize_host(host).is_ok()
}

/// What a module is pinned to. A tag is resolved to a commit at review time
/// and the approval records that commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pin {
    /// Lower-case hex, 40 characters (SHA-1) or 64 (SHA-256).
    Commit(String),
    /// A git tag name.
    Tag(String),
}

impl Pin {
    /// A full lower-case commit SHA, or a tag name. Short or upper-case hex is
    /// refused: it could be a commit or a tag, so the pin would be ambiguous.
    pub fn parse(input: &str) -> Result<Self, Refusal> {
        if input.is_empty() {
            return Err(Refusal::new("pin.invalid", "the pin is empty"));
        }
        if input.bytes().all(|b| b.is_ascii_hexdigit()) {
            let full = matches!(input.len(), 40 | 64)
                && input.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
            if full {
                return Ok(Pin::Commit(input.to_string()));
            }
            if (7..=64).contains(&input.len()) {
                return Err(Refusal::new(
                    "pin.ambiguous",
                    "a hex pin must be a full lower-case commit SHA (40 or 64 characters)",
                ));
            }
        }
        validate_tag_name(input)?;
        Ok(Pin::Tag(input.to_string()))
    }

    pub fn as_str(&self) -> &str {
        match self {
            Pin::Commit(c) | Pin::Tag(c) => c.as_str(),
        }
    }
}

/// Git's ref-name rules for the subset a tag may use here.
fn validate_tag_name(tag: &str) -> Result<(), Refusal> {
    let bad = |why: &str| Refusal::new("pin.invalid", format!("{tag:?}: {why}"));
    if tag.is_empty() || tag.len() > MAX_TAG_LEN {
        return Err(bad("empty or longer than 128 bytes"));
    }
    if tag == "HEAD" {
        return Err(bad("HEAD is not a tag"));
    }
    if !tag.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'/' | b'-')) {
        return Err(bad("only letters, digits and . _ / -"));
    }
    if tag.starts_with(['-', '.', '/'])
        || tag.ends_with(['/', '.'])
        || tag.ends_with(".lock")
        || tag.contains("..")
        || tag.contains("//")
        || tag.contains("/.")
    {
        return Err(bad("not a valid git ref name"));
    }
    Ok(())
}

/// Splits `<source>#<pin>`. A pin is required: no pin, no install.
pub fn parse_install_spec(input: &str) -> Result<(GitSource, Pin), Refusal> {
    let mut parts = input.split('#');
    let source = parts.next().unwrap_or("");
    let pin = parts.next().ok_or_else(|| {
        Refusal::new("pin.required", "pin the module to a tag or a commit: <source>#<pin>")
    })?;
    if parts.next().is_some() {
        return Err(Refusal::new("spec.invalid", "the install spec has more than one '#'"));
    }
    Ok((GitSource::parse(source)?, Pin::parse(pin)?))
}
