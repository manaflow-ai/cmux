//! Domain policy, enforced in the host below the agent's JS VM.
//!
//! Two layers: the base layer (set by the user, or the session's creator
//! within its grant, and lockable) and the agent layer (set from VM code).
//! A URL must pass both, so VM code can only narrow what the base allows.
//! Pattern syntax and matching follow PR #15570's `agent-tools.js`
//! (browser-use's `allowed_domains`).

use cmux_browser_grants::Tier;
use std::fmt;
use url::{Host, Url};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyError(pub String);

impl fmt::Display for PolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PolicyError {}

/// `example.com`, `*.example.com`, `https://example.com`, `example.com:8443`, `*`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DomainPattern {
    pub raw: String,
    scheme: Option<String>,
    host: String,
    port: Option<String>,
}

impl DomainPattern {
    pub fn parse(raw: &str) -> Result<Self, PolicyError> {
        let trimmed = raw.trim().to_ascii_lowercase();
        if trimmed.is_empty() {
            return Err(PolicyError(format!("expected a domain pattern, got {raw:?}")));
        }
        let (scheme, rest) = match trimmed.split_once("://") {
            Some((scheme, rest))
                if !scheme.is_empty()
                    && scheme
                        .chars()
                        .next()
                        .is_some_and(|c| c.is_ascii_lowercase() || c == '*')
                    && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.*-".contains(c)) =>
            {
                (Some(scheme.to_owned()), rest.to_owned())
            }
            _ => (None, trimmed.clone()),
        };
        let mut host = rest.split('/').next().unwrap_or("").to_owned();
        let mut port = None;
        if !host.starts_with('[')
            && let Some((h, p)) = host.rsplit_once(':')
            && (p == "*" || (!p.is_empty() && p.chars().all(|c| c.is_ascii_digit())))
        {
            port = (p != "*").then(|| p.to_owned());
            host = h.to_owned();
        }
        if host != "*" {
            let stars = host.matches('*').count();
            if stars > 1 {
                return Err(PolicyError(format!("{raw:?}: only one wildcard is allowed")));
            }
            if host.ends_with(".*") {
                return Err(PolicyError(format!(
                    "{raw:?}: wildcard top-level domains are not allowed"
                )));
            }
            if stars == 1 && !host.starts_with("*.") {
                return Err(PolicyError(format!(
                    "{raw:?}: use *.example.com; other wildcards are not allowed"
                )));
            }
            if host.is_empty() || host.chars().any(char::is_whitespace) {
                return Err(PolicyError(format!("{raw:?}: expected a domain")));
            }
            host = match host.strip_prefix("*.") {
                Some(base) => format!("*.{}", normalize_host(raw, base)?),
                None => normalize_host(raw, &host)?,
            };
        }
        Ok(DomainPattern { raw: raw.to_owned(), scheme, host, port })
    }

    /// `secure`: without a scheme, match https only (http on loopback), as
    /// secret typing does; otherwise http and https, as navigation checks do.
    pub fn matches(&self, url: &Url, secure: bool) -> bool {
        let scheme = url.scheme();
        // `evil.com.` is the same site as `evil.com` (fully qualified name).
        let Some(host) =
            url.host_str().map(|h| h.strip_suffix('.').unwrap_or(h).to_ascii_lowercase())
        else {
            return false;
        };
        let scheme_ok = match &self.scheme {
            Some(pattern) => glob_match(pattern, scheme),
            None if secure => scheme == "https" || (scheme == "http" && is_loopback(url)),
            None => scheme == "http" || scheme == "https",
        };
        if !scheme_ok {
            return false;
        }
        if let Some(port) = &self.port {
            let actual = url.port_or_known_default().map(|p| p.to_string()).unwrap_or_default();
            if &actual != port {
                return false;
            }
        }
        if self.host == "*" {
            return true;
        }
        if let Some(base) = self.host.strip_prefix("*.") {
            return host == base || host.ends_with(&format!(".{base}"));
        }
        if host == self.host {
            return true;
        }
        // A root domain also covers www.
        self.host.split('.').count() == 2 && host == format!("www.{}", self.host)
    }
}

/// A host name as URLs carry it: no trailing dot, lower case, and
/// internationalized labels in Punycode (main's normalizeHost).
fn normalize_host(raw: &str, host: &str) -> Result<String, PolicyError> {
    let host = host.trim_end_matches('.');
    if host.is_empty() {
        return Err(PolicyError(format!("{raw:?}: expected a domain")));
    }
    if host.is_ascii() || host.starts_with('[') {
        return Ok(host.to_ascii_lowercase());
    }
    match Host::parse(host) {
        Ok(Host::Domain(domain)) => Ok(domain),
        Ok(other) => Ok(other.to_string()),
        Err(_) => Err(PolicyError(format!("{raw:?}: expected a domain"))),
    }
}

/// The site (registrable domain) of a host: one copy for the host and the
/// daemon's browser grants (RFD 0125 D7.2).
pub use cmux_browser_grants::site_of;

fn glob_match(pattern: &str, text: &str) -> bool {
    match pattern.split_once('*') {
        None => pattern == text,
        Some((head, tail)) => {
            text.len() >= head.len() + tail.len() && text.starts_with(head) && text.ends_with(tail)
        }
    }
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(ip)) => ip.is_loopback(),
        Some(Host::Ipv6(ip)) => ip.is_loopback(),
        None => false,
    }
}

/// One policy layer.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Layer {
    /// `None`: every domain is allowed by this layer.
    pub allowed: Option<Vec<DomainPattern>>,
    pub prohibited: Vec<DomainPattern>,
    pub block_ips: bool,
}

impl Layer {
    pub fn is_active(&self) -> bool {
        self.allowed.is_some() || !self.prohibited.is_empty() || self.block_ips
    }

    /// Reason texts match the runtime's goldens (PR #15570 agent-tools.js).
    fn refusal(&self, url: &Url) -> Option<String> {
        if self.block_ips && matches!(url.host(), Some(Host::Ipv4(_) | Host::Ipv6(_))) {
            return Some("IP addresses are blocked (session.blockIPAddresses)".into());
        }
        if let Some(allowed) = &self.allowed
            && !allowed.iter().any(|p| p.matches(url, false))
        {
            let list: Vec<&str> = allowed.iter().map(|p| p.raw.as_str()).collect();
            return Some(format!("not in session.allowedDomains ({})", list.join(", ")));
        }
        self.prohibited
            .iter()
            .find(|p| p.matches(url, false))
            .map(|p| format!("prohibited by {} (session.prohibitedDomains)", p.raw))
    }
}

/// Who changes the policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Writer {
    /// A user-origin op, or the session's creator mux within its grant.
    Owner,
    /// Code running in the session's VM.
    Agent,
}

#[derive(Debug, Clone, Default)]
pub struct Policy {
    base: Layer,
    agent: Layer,
    /// The base layer is locked (by its owner).
    locked: bool,
    /// The session layer is locked (by VM code, against later VM code).
    agent_locked: bool,
    /// Browser grants (RFD 0125 D7.2): `Some` when the session drives the
    /// person's profile and holds at least one grant there. Then a document,
    /// a fetch or a cookie reaches only a site with a live lease; the
    /// layers above still narrow it. `None` (no grant): today's
    /// allowedDomains/prohibitedDomains behaviour, unchanged.
    leases: Option<cmux_browser_grants::Leases>,
    /// Commit leases spent by their one approved action (D7.4): a later
    /// `set_leases` with the same row does not lend it again.
    spent: Vec<cmux_browser_grants::Lease>,
}

/// Schemes an agent may never open, whatever the policy.
const FORBIDDEN_SCHEMES: &[&str] = &[
    "file",
    "chrome",
    "chrome-extension",
    "devtools",
    "view-source",
    "javascript",
    "chrome-search",
    "chrome-untrusted",
];

/// Chromium's own pages (WebUI, extensions, DevTools): an agent may not open
/// them, run script in them or read them. The same rule as the app's
/// `AgentURLPolicy` (CmuxNextBrowser/Core/AgentURLPolicy.swift); change both.
const BROWSER_PAGE_SCHEMES: &[&str] = &[
    "chrome",
    "chrome-extension",
    "chrome-untrusted",
    "chrome-search",
    "devtools",
    "chrome-devtools",
    "view-source",
    // cmux's internal pages (cmux://history, cmux://bookmarks, ...).
    "cmux",
];

/// True when `text` names one of Chromium's own pages. Like Chromium, tabs
/// and newlines anywhere and leading spaces and control characters do not
/// count; `about:` pages other than blank and srcdoc are `chrome://` pages;
/// `blob:` and `filesystem:` take the origin of their inner URL.
pub fn is_browser_page(text: &str) -> bool {
    is_browser_page_within(text, 0)
}

/// First-party pages (`cmux-page://cmux`, `cmux-page://cmux.<id>`, and
/// single-label shared hosts such as `cmux-page://shell`) are refused; third-party app pages stay allowed. Fail closed on an empty host
/// or a percent escape. The same rule as the Swift and C++ copies.
fn is_reserved_page_host(rest: &str) -> bool {
    let after = rest.trim_start_matches(['/', '\\']);
    let mut host = after.split(['/', '\\', '?', '#']).next().unwrap_or("");
    if host.contains('%') {
        return true;
    }
    if let Some((_, tail)) = host.rsplit_once('@') {
        host = tail;
    }
    if let Some((name, _)) = host.split_once(':') {
        host = name;
    }
    let name = host.to_lowercase();
    let name = name.trim_end_matches('.');
    // A third-party app id always has a dot; a single label ("shell") is a shared first-party host.
    name.is_empty() || name == "cmux" || name.starts_with("cmux.") || !name.contains('.')
}

/// More nested `blob:`/`filesystem:` wrappers than this are refused (fail
/// closed), as in the Swift and C++ copies (schemas/agent-url-policy/vectors.json).
const MAX_WRAPPER_DEPTH: usize = 2;

fn is_browser_page_within(text: &str, wrappers: usize) -> bool {
    if wrappers > MAX_WRAPPER_DEPTH {
        return true;
    }
    let cleaned: String = text.chars().filter(|c| !matches!(c, '\t' | '\n' | '\r')).collect();
    let trimmed = cleaned.trim_start_matches(|c: char| (c as u32) <= 0x20);
    let Some((scheme, rest)) = trimmed.split_once(':') else {
        return false;
    };
    let scheme = scheme.to_lowercase();
    let mut chars = scheme.chars();
    if !chars.next().is_some_and(char::is_alphabetic)
        || !chars.all(|c| c.is_alphanumeric() || "+-.".contains(c))
    {
        return false;
    }
    if BROWSER_PAGE_SCHEMES.contains(&scheme.as_str()) {
        return true;
    }
    if scheme == "cmux-page" {
        return is_reserved_page_host(rest);
    }
    if matches!(scheme.as_str(), "blob" | "filesystem") {
        return is_browser_page_within(rest, wrappers + 1);
    }
    if scheme == "about" {
        let page = rest.split(['?', '#']).next().unwrap_or("").to_lowercase();
        return !matches!(page.as_str(), "blank" | "srcdoc");
    }
    false
}

impl Policy {
    pub fn locked(&self) -> bool {
        self.locked || self.agent_locked
    }

    pub fn base(&self) -> &Layer {
        &self.base
    }

    pub fn agent(&self) -> &Layer {
        &self.agent
    }

    /// The session's leases (`None`: it holds no grant).
    pub fn leases(&self) -> Option<&cmux_browser_grants::Leases> {
        self.leases.as_ref()
    }

    /// Replaces the session's leases (the owner's, from the daemon's
    /// `browser_grants` rows). `None` returns the session to its domain
    /// policy alone.
    pub fn set_leases(&mut self, leases: Option<cmux_browser_grants::Leases>) {
        let now = now_ms();
        self.spent.retain(|lease| lease.live_at(now));
        self.leases = leases.map(|mut leases| {
            leases.0.retain(|lease| !self.spent.contains(lease));
            leases
        });
    }

    /// Something limits where the session goes: a layer or its leases.
    pub fn is_active(&self) -> bool {
        self.base.is_active() || self.agent.is_active() || self.leases.is_some()
    }

    /// Why the session's leases do not reach `url` now, or `None`.
    pub fn lease_refusal(&self, url: &Url) -> Option<String> {
        self.lease_refusal_at(url, now_ms())
    }

    /// [`Policy::lease_refusal`] at `now_ms` (milliseconds since the epoch).
    pub fn lease_refusal_at(&self, url: &Url, now_ms: u64) -> Option<String> {
        self.lease_tier_refusal_at(url, Tier::Read, now_ms)
    }

    /// Why the session's leases do not allow an action that needs `needed`
    /// on a page or request at `url` at `now_ms`, or `None`. The host goes
    /// through the grants crate's one normalization (punycode, no IPv6
    /// brackets), the same as the grant row.
    pub fn lease_tier_refusal_at(&self, url: &Url, needed: Tier, now_ms: u64) -> Option<String> {
        let leases = self.leases.as_ref()?;
        if matches!(url.scheme(), "data" | "blob" | "about") {
            return None;
        }
        match url.host_str() {
            Some(host) => leases.refusal_for(host, needed, now_ms),
            None => Some(format!("its scheme {}: has no host", url.scheme())),
        }
    }

    /// Allows one action that needs `needed` on the page or request at
    /// `url`: refused unless a live lease of that tier covers its site. A
    /// commit lease that is the only cover is spent by this action.
    pub fn authorize_lease(&mut self, url: &Url, needed: Tier) -> Result<(), String> {
        let now = now_ms();
        if let Some(reason) = self.lease_tier_refusal_at(url, needed, now) {
            return Err(reason);
        }
        let (Some(leases), Some(host)) = (self.leases.as_mut(), url.host_str()) else {
            return Ok(());
        };
        if let Some(spent) = leases.authorize(host, needed, now)? {
            self.spent.push(spent);
        }
        Ok(())
    }

    /// Replaces a layer. The base layer needs `Writer::Owner` and refuses
    /// changes once locked; the agent layer is always writable by the agent.
    pub fn set(&mut self, writer: Writer, layer: Layer, lock: bool) -> Result<(), PolicyError> {
        match writer {
            Writer::Owner if self.locked => {
                Err(PolicyError("the domain policy is locked for this session".into()))
            }
            Writer::Owner => {
                self.base = layer;
                self.locked |= lock;
                Ok(())
            }
            Writer::Agent if self.agent_locked => {
                Err(PolicyError("the domain policy is locked for this session".into()))
            }
            Writer::Agent => {
                // A session lock only freezes the session layer; the base
                // layer still bounds it.
                self.agent = layer;
                self.agent_locked |= lock;
                Ok(())
            }
        }
    }

    /// Why an agent may not open `url` as a document (navigation, new tab,
    /// popup, fetch), or `None` when it may.
    pub fn navigation_refusal(&self, url: &str) -> Option<String> {
        if is_browser_page(url) {
            return Some(format!("{} is a browser page, not available to agents", url.trim()));
        }
        let parsed = match Url::parse(url) {
            Ok(parsed) => parsed,
            Err(_) => match Url::parse(&format!("https://{url}")) {
                Ok(parsed) if !url.contains("://") => parsed,
                _ => return Some("not a valid URL".into()),
            },
        };
        let scheme = parsed.scheme();
        if FORBIDDEN_SCHEMES.contains(&scheme) {
            return Some(format!("{scheme}: URLs are not available to agents"));
        }
        if scheme == "about" {
            return match parsed.path() {
                "blank" | "srcdoc" => None,
                _ => Some(format!("{url} is not available to agents")),
            };
        }
        if scheme == "data" || scheme == "blob" {
            return None;
        }
        self.subresource_refusal(&parsed).or_else(|| self.lease_refusal(&parsed))
    }

    /// Why a request may not load (subresources, child frames, fetch).
    pub fn subresource_refusal(&self, url: &Url) -> Option<String> {
        if matches!(url.scheme(), "data" | "blob" | "about") {
            return None;
        }
        if (self.base.is_active() || self.agent.is_active()) && url.host_str().is_none() {
            return Some(format!("its scheme {}: has no host", url.scheme()));
        }
        self.base.refusal(url).or_else(|| self.agent.refusal(url))
    }

    /// Whether a connection to `host` (a name or an IP literal) on `port`
    /// may open (crate::policy_proxy: a WebSocket, or any connection, with
    /// no scheme known): the policy allows the host over http or https.
    pub fn allows_connection(&self, host: &str, port: u16) -> bool {
        let host = match host.parse::<std::net::Ipv6Addr>() {
            Ok(_) => format!("[{host}]"),
            Err(_) => host.to_owned(),
        };
        ["http", "https"].iter().any(|scheme| {
            Url::parse(&format!("{scheme}://{host}:{port}/"))
                .is_ok_and(|url| self.subresource_refusal(&url).is_none())
        })
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

mod cookies;
pub mod egress;

/// Parses a list of patterns.
pub fn parse_patterns(list: &[String]) -> Result<Vec<DomainPattern>, PolicyError> {
    list.iter().map(|raw| DomainPattern::parse(raw)).collect()
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
