//! The browser tab rules of the Mac app's `CmuxNextBrowserTabs`: the engine a
//! new tab gets (`BrowserEngineResolver`), whether a Chromium tab that
//! committed a page moves to WebKit for its `browser.siteEngines` rule
//! (`BrowserSiteEngineNavigation`, and the follower's per-page step), where a
//! machine's new browser tab goes (`BrowserTabRoute`), which live tab a
//! page-requested tab reuses (`BrowserTabMatch`), the machine browser record
//! (`MachineBrowserRecord`) and whether a tab may open while the cmux browser
//! is off (`BrowserAvailability`). Pure.
//!
//! Addresses arrive as the app's `URL.absoluteString`, so they are already
//! well formed; [`Url`] splits one as RFC 3986 (and `URLComponents`) does.

use serde::{Deserialize, Serialize};

// MARK: Addresses

/// An address split as RFC 3986 appendix B does
/// (`^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Url<'a> {
    pub scheme: Option<&'a str>,
    pub authority: Option<&'a str>,
    pub path: &'a str,
    pub query: Option<&'a str>,
    pub fragment: Option<&'a str>,
}

impl<'a> Url<'a> {
    pub fn split(text: &'a str) -> Self {
        let (rest, fragment) = match text.find('#') {
            Some(at) => (&text[..at], Some(&text[at + 1..])),
            None => (text, None),
        };
        let (rest, query) = match rest.find('?') {
            Some(at) => (&rest[..at], Some(&rest[at + 1..])),
            None => (rest, None),
        };
        let (scheme, rest) = match rest.find(|c| matches!(c, ':' | '/')) {
            Some(at) if at > 0 && rest.as_bytes()[at] == b':' => {
                (Some(&rest[..at]), &rest[at + 1..])
            }
            _ => (None, rest),
        };
        let (authority, path) = match rest.strip_prefix("//") {
            Some(after) => {
                let end = after.find('/').unwrap_or(after.len());
                (Some(&after[..end]), &after[end..])
            }
            None => (None, rest),
        };
        Url { scheme, authority, path, query, fragment }
    }

    /// The scheme, lowercased.
    pub fn scheme_lowercased(&self) -> Option<String> {
        self.scheme.map(str::to_lowercase)
    }

    /// The authority's host (no user info, no port, no IPv6 brackets).
    pub fn host(&self) -> Option<&'a str> {
        let (_, host, _) = self.authority_parts()?;
        Some(host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host))
    }

    /// The authority as user info (with its `@`), host (with any brackets) and port (with its `:`).
    fn authority_parts(&self) -> Option<(&'a str, &'a str, &'a str)> {
        let authority = self.authority?;
        let host_at = authority.rfind('@').map_or(0, |at| at + 1);
        let (user, rest) = authority.split_at(host_at);
        let port_at = if rest.starts_with('[') {
            rest.find(']').map_or(rest.len(), |end| end + 1)
        } else {
            rest.find(':').unwrap_or(rest.len())
        };
        let (host, port) = rest.split_at(port_at);
        Some((user, host, port))
    }

    /// Whether the scheme is http or https.
    pub fn is_web(&self) -> bool {
        matches!(self.scheme_lowercased().as_deref(), Some("http" | "https"))
    }

    /// The query's items as `URLComponents.queryItems` reads them: split on
    /// `&`, name and value split at the first `=` (no `=`: no value), each
    /// percent-decoded (a `+` stays a `+`). None without a query.
    pub fn query_items(&self) -> Option<Vec<(String, Option<String>)>> {
        let query = self.query?;
        if query.is_empty() {
            return Some(Vec::new());
        }
        Some(
            query
                .split('&')
                .map(|item| match item.split_once('=') {
                    Some((name, value)) => (percent_decode(name), Some(percent_decode(value))),
                    None => (percent_decode(item), None),
                })
                .collect(),
        )
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[at] == b'%'
            && let (Some(high), Some(low)) =
                (bytes.get(at + 1).copied().and_then(hex), bytes.get(at + 2).copied().and_then(hex))
        {
            out.push((high * 16 + low) as u8);
            at += 3;
            continue;
        }
        out.push(bytes[at]);
        at += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// MARK: Engines

/// A browser tab's engine, as the daemon tags it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Engine {
    Cef,
    Webkit,
}

/// `browser.defaultEngine`, and a `browser.siteEngines` rule's engine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DefaultEngine {
    Chromium,
    Webkit,
}

impl DefaultEngine {
    fn engine(self) -> Engine {
        match self {
            DefaultEngine::Chromium => Engine::Cef,
            DefaultEngine::Webkit => Engine::Webkit,
        }
    }
}

/// The engine a request names (`cef`, `chromium`, `chrome`, `webkit`,
/// `safari`, any case), None when it names none.
pub fn requested_engine(requested: Option<&str>) -> Option<Engine> {
    match requested?.to_lowercase().as_str() {
        "cef" | "chromium" | "chrome" => Some(Engine::Cef),
        "webkit" | "safari" => Some(Engine::Webkit),
        _ => None,
    }
}

/// The engine a new browser tab gets, and why (`BrowserEngineChoice`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Choice {
    pub engine: Engine,
    /// Chromium could not be used and the tab opens in WebKit: the choice's
    /// fallback is the reason Chromium cannot open a tab now.
    pub fallback: bool,
    /// The engine came from an existing record or page, not the default.
    pub inherited: bool,
    /// Someone asked for this engine (`--engine`, a `browser.siteEngines` rule).
    pub pinned: bool,
}

/// What a new tab does (`BrowserEngineResolver.Outcome`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    /// The tab opens on this choice.
    Open(Choice),
    /// An explicit Chromium request Chromium cannot serve: refused with the reason.
    Refuse,
}

/// The facts `BrowserEngineResolver` reads.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Resolve {
    pub default_engine: DefaultEngine,
    /// Chromium cannot open a tab now.
    #[serde(default)]
    pub cef_unavailable: bool,
    #[serde(default)]
    pub requested: Option<String>,
    #[serde(default)]
    pub inherited: Option<String>,
    /// The `browser.siteEngines` rule for the tab's URL.
    #[serde(default)]
    pub site_engine: Option<DefaultEngine>,
}

/// Picks the engine for a browser tab: an explicit engine wins (an explicit
/// Chromium request Chromium cannot serve is refused), else an inherited
/// engine, else the site rule, else `browser.defaultEngine`; a Chromium pick
/// Chromium cannot serve falls back to WebKit.
pub fn resolve(facts: &Resolve) -> Outcome {
    let open = |engine, fallback, inherited, pinned| {
        Outcome::Open(Choice { engine, fallback, inherited, pinned })
    };
    match requested_engine(facts.requested.as_deref()) {
        Some(Engine::Webkit) => return open(Engine::Webkit, false, false, true),
        Some(Engine::Cef) if facts.cef_unavailable => return Outcome::Refuse,
        Some(Engine::Cef) => return open(Engine::Cef, false, false, true),
        None => {}
    }
    let (wanted, inherited, pinned) =
        if let Some(engine) = requested_engine(facts.inherited.as_deref()) {
            (engine, true, false)
        } else if let Some(site) = facts.site_engine {
            (site.engine(), false, true)
        } else {
            (facts.default_engine.engine(), false, false)
        };
    if wanted != Engine::Cef || !facts.cef_unavailable {
        return open(wanted, false, inherited, pinned);
    }
    open(Engine::Webkit, true, inherited, false)
}

// MARK: Site engine moves

/// Whether a Chromium tab that committed a page moves to WebKit for its
/// `browser.siteEngines` rule (`BrowserSiteEngineNavigation`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SiteEngineMove {
    pub site_engine: Option<DefaultEngine>,
    pub engine_is_chromium: bool,
    pub arrived_fresh: bool,
    pub keeps_opener: bool,
    pub engine_pinned: bool,
    pub already_reopened: bool,
    pub agent_driven: bool,
}

impl SiteEngineMove {
    /// True when the tab reopens in WebKit at the committed address.
    pub fn reopens_in_webkit(&self) -> bool {
        self.site_engine == Some(DefaultEngine::Webkit)
            && self.engine_is_chromium
            && self.arrived_fresh
            && !self.keeps_opener
            && !self.engine_pinned
            && !self.already_reopened
            && !self.agent_driven
    }
}

/// A Chromium page's memory in `BrowserSiteEngineFollower`: the last page it
/// committed and whether the person typed the address it commits next.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PageMemory {
    pub last: Option<String>,
    pub typed: bool,
}

/// What a commit of `url` does to the page's memory, and whether it is
/// checked (`fresh`: the page arrived fresh). The same page committed again
/// is not checked.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Committed {
    pub memory: PageMemory,
    /// None: no check; else whether the page arrived fresh.
    pub check: Option<bool>,
}

/// The follower's step on a committed page: a page is fresh when the person
/// typed its address or the page before it was no web page.
pub fn committed(memory: &PageMemory, url: &str) -> Committed {
    if memory.last.as_deref() == Some(url) {
        return Committed { memory: memory.clone(), check: None };
    }
    let previous_web = memory.last.as_deref().is_some_and(|last| Url::split(last).is_web());
    let fresh = memory.typed || !previous_web;
    Committed {
        memory: PageMemory { last: Some(url.to_string()), typed: false },
        check: Some(fresh),
    }
}

// MARK: Routes

/// Where a new browser tab of a pane's machine goes (`BrowserTabRoute`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    /// The machine's daemon makes the tab.
    Daemon,
    /// A WebKit page this app keeps for the session.
    SessionLocal,
    /// Another machine that is not connected: refused, naming it.
    RefuseNotConnected,
}

pub fn route(is_local: bool, connected: bool, serves_tabs: bool) -> Route {
    if !is_local && !connected {
        Route::RefuseNotConnected
    } else if serves_tabs {
        Route::Daemon
    } else {
        Route::SessionLocal
    }
}

/// Whether a session-local (WebKit) tab may stand in: never for a Chromium
/// request or a Chromium internal page (`needs_chromium`, the app's
/// `ChromiumInternalURL.needsChromium` of the tab's URL).
pub fn allows_session_local_tab(requested: Option<&str>, needs_chromium: bool) -> bool {
    requested_engine(requested) != Some(Engine::Cef) && !needs_chromium
}

// MARK: Tab match

/// One live browser tab of a pane (`BrowserTabMatch.Candidate`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Candidate {
    pub id: String,
    /// None: WebKit, the record's default.
    pub engine: Option<String>,
    pub profile: String,
    /// The page it shows.
    pub shown: Option<String>,
}

/// The default browser profile's id (`BrowserProfileRecord.defaultID`).
pub const DEFAULT_PROFILE: &str = "default";

/// The first of `candidates` (strip order) that shows `url` in `profile`
/// (None: the default profile) on `engine` (`BrowserTabMatch.first(in:)`).
pub fn first_match<'a>(
    candidates: &'a [Candidate],
    url: &str,
    engine: &str,
    profile: Option<&str>,
) -> Option<&'a Candidate> {
    let profile = profile.unwrap_or(DEFAULT_PROFILE);
    candidates.iter().find(|tab| {
        tab.profile == profile
            && tab.engine.as_deref().unwrap_or("webkit") == engine
            && tab.shown.as_deref().is_some_and(|shown| same_page(shown, url))
    })
}

/// Whether a foreground reuse of a tab showing `shown` loads `url`: only its
/// fragment differs.
pub fn navigates(shown: Option<&str>, url: &str) -> bool {
    shown.and_then(|shown| Url::split(shown).fragment) != Url::split(url).fragment
}

/// Whether two addresses are the same page: scheme and host compare
/// case-insensitively, a trailing slash and the fragment are ignored.
pub fn same_page(a: &str, b: &str) -> bool {
    page_key(a) == page_key(b)
}

fn page_key(text: &str) -> String {
    let url = Url::split(text);
    let mut key = String::new();
    if let Some(scheme) = url.scheme {
        key.push_str(&scheme.to_lowercase());
        key.push(':');
    }
    let mut path = url.path;
    if let Some((user, host, port)) = url.authority_parts() {
        key.push_str("//");
        key.push_str(user);
        key.push_str(&host.to_lowercase());
        key.push_str(port);
        if path.is_empty() {
            path = "/";
        }
    }
    if path.chars().count() > 1
        && let Some(trimmed) = path.strip_suffix('/')
    {
        path = trimmed;
    }
    key.push_str(path);
    if let Some(query) = url.query {
        key.push('?');
        key.push_str(query);
    }
    key
}

// MARK: Machine browser record

/// A machine browser record: `cmux://remote-browser?machine=<id>[&url=<first page>]`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineRecord {
    pub machine: String,
    /// The page to open first (http or https only).
    pub initial_url: Option<String>,
}

/// The record `text` names, None when it is none (the loopback `?address=`
/// record is another record).
pub fn machine_record(text: &str) -> Option<MachineRecord> {
    let url = Url::split(text);
    if url.scheme_lowercased().as_deref() != Some("cmux")
        || url.host().map(str::to_lowercase).as_deref() != Some("remote-browser")
    {
        return None;
    }
    let items = url.query_items()?;
    if items.iter().any(|(name, _)| name == "address") {
        return None;
    }
    let machine = items.iter().find(|(name, _)| name == "machine")?.1.clone()?;
    if machine.is_empty() {
        return None;
    }
    let initial_url = items
        .iter()
        .find(|(name, _)| name == "url")
        .and_then(|(_, value)| value.clone())
        .filter(|value| Url::split(value).is_web());
    Some(MachineRecord { machine, initial_url })
}

/// The record in `text` when it names `machine`, the machine whose tree holds the tab.
pub fn owned_record(text: Option<&str>, machine: &str) -> Option<MachineRecord> {
    machine_record(text?).filter(|record| record.machine == machine)
}

// MARK: Availability

/// A page cmux draws itself: `cmux://` (but a machine's browser record) and `cmux-page://`.
pub fn is_cmux_page(text: &str) -> bool {
    match Url::split(text).scheme_lowercased().as_deref() {
        Some("cmux-page") => true,
        Some("cmux") => machine_record(text).is_none(),
        _ => false,
    }
}

/// Whether a tab for `address` may open while `enabled` (`browser.enabled`)
/// says whether the cmux browser is on: off, only cmux's own pages open.
pub fn allows(enabled: bool, address: Option<&str>) -> bool {
    enabled || address.is_some_and(is_cmux_page)
}

#[cfg(test)]
#[path = "browser_tabs_tests.rs"]
mod tests;
