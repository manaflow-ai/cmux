//! The daemon's egress gate (docs/privacy.md, "Egress gate").
//!
//! docs/privacy.md lists every host the app connects to (its `connects` rows);
//! `hosts.txt` beside this crate is that list, kept equal to the doc by
//! tests/test_egress_gate.py. Every HTTP client cmux makes for itself is built
//! with [`client_builder`], whose DNS resolver asks [`check`] before it looks a
//! name up, so a connection to a host the doc does not list is refused before
//! a packet leaves, whatever URL the code was handed (a redirect, a URL from a
//! server's answer, a value from a file).
//!
//! Passes, besides the listed hosts:
//! - hosts the person named (a self-hosted server, an API endpoint, an SSH or
//!   git host): the code that reads such a setting calls [`allow_named`];
//! - loopback, IP literals and reserved names (`localhost`, `.test`,
//!   `.example`, `.invalid`, `.local`), which never reach a third party by
//!   name.
//!
//! - a host a server's answer handed this process for one transfer (a
//!   presigned object URL): the code holds [`allow_session`]'s guard for the
//!   transfer, and only an answer from a host that passes counts.
//!
//! A proxy (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, less `NO_PROXY`) is
//! chosen by the gate too: the request's own host is checked before the proxy
//! is picked, so a proxy never carries a request the gate would refuse.
//!
//! [`Mode::Enforce`] refuses the rest; [`Mode::Log`] only reports it. The mode
//! is `CMUX_EGRESS` (`enforce`, `log` or `off`) when set, else enforce in a
//! debug build and in a binary inside a NIGHTLY, DEV or staging app bundle
//! ([`bundle_mode`]), else log; the app also sets `CMUX_EGRESS=enforce` for
//! the children it starts in those builds. Every refusal (or would-be refusal) prints one
//! `egress.unlisted host=H site=S mode=M` line to stderr and is kept in
//! [`unlisted`] for diagnostics.
//!
//! The audit trail: every connection the gate sees, allowed or refused, is
//! kept once per (host, site, verdict) in [`audit`]; when `CMUX_EGRESS_AUDIT`
//! names a file, each new entry is also appended to it as one JSON line
//! (`{"ts":…,"host":…,"site":…,"verdict":…,"mode":…,"refused":…}`).
//!
//! tests/test_egress_gate.py finds every client the code makes by hand
//! instead; tests/egress_ungated.json lists those not moved here yet.

#![forbid(unsafe_code)]

#[cfg(feature = "capture")]
pub mod capture;

use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;
use std::net::IpAddr;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};

/// The `connects` hosts of docs/privacy.md, one per line; `*` stands for one
/// part of a name filled in at run time (`*.atlassian.net`).
const HOSTS_TXT: &str = include_str!("../hosts.txt");

/// The environment variable that picks the mode.
pub const MODE_ENV: &str = "CMUX_EGRESS";

/// The environment variable naming the audit file (JSON lines, appended).
pub const AUDIT_ENV: &str = "CMUX_EGRESS_AUDIT";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Refuse an unlisted host.
    Enforce,
    /// Report an unlisted host and let it through.
    Log,
    /// Check nothing.
    Off,
}

impl Mode {
    pub fn parse(text: &str) -> Option<Mode> {
        match text.trim().to_ascii_lowercase().as_str() {
            "enforce" | "1" | "on" => Some(Mode::Enforce),
            "log" => Some(Mode::Log),
            "off" | "0" => Some(Mode::Off),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Mode::Enforce => "enforce",
            Mode::Log => "log",
            Mode::Off => "off",
        }
    }

    fn code(self) -> u8 {
        match self {
            Mode::Enforce => 1,
            Mode::Log => 2,
            Mode::Off => 3,
        }
    }
}

/// The mode when nothing set one: enforce in a debug build; in a release build, the mode of the
/// app bundle this binary sits in ([`bundle_mode`] of [`bundle_id_of_exe`]), else log. A NIGHTLY's
/// bundled `cmux` started from a shell outside cmux (no `CMUX_EGRESS` inherited) still enforces.
fn default_mode() -> Mode {
    if cfg!(debug_assertions) {
        return Mode::Enforce;
    }
    std::env::current_exe()
        .ok()
        .and_then(|exe| bundle_id_of_exe(&exe))
        .and_then(|id| bundle_mode(&id))
        .unwrap_or(Mode::Log)
}

/// The mode a macOS app's bundle id names, by the app's build kinds (BuildIdentity.Kind):
/// NIGHTLY (`com.cmuxterm.app.nightly[.x]`), DEV (`com.cmuxterm.app.debug[.tag]` or any other
/// `com.cmuxterm.app.x`) and staging (`com.cmuxterm.app.staging[.tag]`) enforce; stable
/// (`com.cmuxterm.app`), rc (`com.cmuxterm.app.rc[.x]`) and any other bundle keep the default (None).
pub fn bundle_mode(bundle_id: &str) -> Option<Mode> {
    let id = bundle_id.trim();
    let rest = id.strip_prefix("com.cmuxterm.app.")?;
    if rest.is_empty() || rest == "rc" || rest.starts_with("rc.") {
        return None;
    }
    Some(Mode::Enforce)
}

/// The `CFBundleIdentifier` of the nearest `*.app` bundle holding `exe` (symlinks resolved, so
/// `/usr/local/bin/cmux` names the app it points into), from its XML `Contents/Info.plist`.
/// None outside a bundle or for a plist that is not XML.
pub fn bundle_id_of_exe(exe: &std::path::Path) -> Option<String> {
    let exe = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
    let app = exe.ancestors().find(|dir| dir.extension().is_some_and(|ext| ext == "app"))?;
    let plist = std::fs::read_to_string(app.join("Contents/Info.plist")).ok()?;
    let after = plist.split_once("<key>CFBundleIdentifier</key>")?.1.trim_start();
    let value = after.strip_prefix("<string>")?.split_once("</string>")?.0.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

static MODE: AtomicU8 = AtomicU8::new(0);

/// This process's mode: [`set_mode`]'s, else `CMUX_EGRESS`'s, else the build's default.
pub fn mode() -> Mode {
    match MODE.load(Ordering::Relaxed) {
        1 => Mode::Enforce,
        2 => Mode::Log,
        3 => Mode::Off,
        _ => {
            let mode = std::env::var(MODE_ENV)
                .ok()
                .as_deref()
                .and_then(Mode::parse)
                .unwrap_or_else(default_mode);
            MODE.store(mode.code(), Ordering::Relaxed);
            mode
        }
    }
}

/// Sets the mode for the rest of the process (the daemon's start, tests).
pub fn set_mode(mode: Mode) {
    MODE.store(mode.code(), Ordering::Relaxed);
}

/// Why a host may be reached.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Verdict {
    /// docs/privacy.md lists it.
    Listed,
    /// The person named it in a setting ([`allow_named`]).
    Named,
    /// A server's answer handed it for a transfer still running ([`allow_session`]).
    Session,
    /// Loopback, an IP literal or a reserved name.
    Local,
    /// None of the above.
    Unlisted,
}

fn listed() -> &'static [Vec<String>] {
    static LISTED: OnceLock<Vec<Vec<String>>> = OnceLock::new();
    LISTED.get_or_init(|| {
        HOSTS_TXT
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(|host| host.to_ascii_lowercase().split('.').map(str::to_owned).collect())
            .collect()
    })
}

fn named() -> &'static Mutex<BTreeSet<String>> {
    static NAMED: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();
    NAMED.get_or_init(Mutex::default)
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Listed => "listed",
            Verdict::Named => "named",
            Verdict::Session => "session",
            Verdict::Local => "local",
            Verdict::Unlisted => "unlisted",
        }
    }
}

/// One connection the gate saw, kept once per process.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct AuditEntry {
    pub host: String,
    pub site: &'static str,
    pub verdict: Verdict,
    /// The gate refused it ([`Mode::Enforce`] and [`Verdict::Unlisted`]).
    pub refused: bool,
}

fn audit_log() -> &'static Mutex<BTreeSet<AuditEntry>> {
    static AUDIT: OnceLock<Mutex<BTreeSet<AuditEntry>>> = OnceLock::new();
    AUDIT.get_or_init(Mutex::default)
}

fn audit_path() -> Option<&'static std::path::Path> {
    static PATH: OnceLock<Option<std::path::PathBuf>> = OnceLock::new();
    PATH.get_or_init(|| std::env::var_os(AUDIT_ENV).filter(|p| !p.is_empty()).map(Into::into))
        .as_deref()
}

/// Every connection the gate saw in this process, allowed and refused, once
/// per (host, site, verdict).
pub fn audit() -> Vec<AuditEntry> {
    audit_log().lock().map(|seen| seen.iter().cloned().collect()).unwrap_or_default()
}

fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn audit_line(entry: &AuditEntry, mode: Mode, ts: u64) -> String {
    format!(
        "{{\"ts\":{ts},\"host\":{},\"site\":{},\"verdict\":\"{}\",\"mode\":\"{}\",\"refused\":{}}}\n",
        json_string(&entry.host),
        json_string(entry.site),
        entry.verdict.as_str(),
        mode.as_str(),
        entry.refused,
    )
}

fn record(entry: AuditEntry, mode: Mode) {
    let first = audit_log().lock().is_ok_and(|mut seen| seen.insert(entry.clone()));
    if !first {
        return;
    }
    let Some(path) = audit_path() else { return };
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let line = audit_line(&entry, mode, ts);
    let written = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut file| std::io::Write::write_all(&mut file, line.as_bytes()));
    if let Err(error) = written {
        eprintln!("egress.audit could not append to {}: {error}", path.display());
    }
}

fn session() -> &'static Mutex<BTreeMap<String, usize>> {
    static SESSION: OnceLock<Mutex<BTreeMap<String, usize>>> = OnceLock::new();
    SESSION.get_or_init(Mutex::default)
}

fn unlisted_log() -> &'static Mutex<BTreeSet<(String, &'static str)>> {
    static SEEN: OnceLock<Mutex<BTreeSet<(String, &'static str)>>> = OnceLock::new();
    SEEN.get_or_init(Mutex::default)
}

/// Lets `host` through: the person named it in a setting (a self-hosted
/// server's URL, an API endpoint, an SSH or git host). Takes a host name or a
/// URL. Never call it with a host from the code or from a server's answer.
pub fn allow_named(host_or_url: &str) {
    let host = host_of(host_or_url);
    if !host.is_empty()
        && let Ok(mut set) = named().lock()
    {
        set.insert(host);
    }
}

/// A host [`allow_session`] lets through while this guard lives.
#[must_use = "the host passes only while the guard lives"]
#[derive(Debug)]
pub struct SessionHost {
    host: Option<String>,
}

impl SessionHost {
    /// Whether the answer's origin passed, so the host was let through.
    pub fn granted(&self) -> bool {
        self.host.is_some()
    }
}

impl Drop for SessionHost {
    fn drop(&mut self) {
        if let Some(host) = self.host.take()
            && let Ok(mut map) = session().lock()
            && let Some(count) = map.get_mut(&host)
        {
            *count -= 1;
            if *count == 0 {
                map.remove(&host);
            }
        }
    }
}

/// Lets `host_or_url` through while the returned guard lives: a server at
/// `answered_by` (a URL or host the gate already passes, such as the cloud API
/// or a self-hosted server the person named) handed it for one transfer (a
/// presigned object URL). An answer from a host that does not pass grants
/// nothing. Never call it with a host from the code or a file.
pub fn allow_session(host_or_url: &str, answered_by: &str) -> SessionHost {
    let host = host_of(host_or_url);
    if host.is_empty() || verdict(answered_by) == Verdict::Unlisted {
        return SessionHost { host: None };
    }
    if let Ok(mut map) = session().lock() {
        *map.entry(host.clone()).or_default() += 1;
    }
    SessionHost { host: Some(host) }
}

/// The lower-cased host of a URL or bare host name, without port or trailing dot.
fn host_of(text: &str) -> String {
    let text = text.trim();
    let rest = text.split_once("://").map_or(text, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let authority = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(bracketed) = authority.strip_prefix('[') {
        bracketed.split(']').next().unwrap_or_default()
    } else {
        authority
            .rsplit_once(':')
            .filter(|(_, port)| port.chars().all(|c| c.is_ascii_digit()))
            .map_or(authority, |(h, _)| h)
    };
    host.trim_end_matches('.').to_ascii_lowercase()
}

/// Whether `label` matches `pattern`, where each `*` stands for one or more characters.
fn label_matches(pattern: &str, label: &str) -> bool {
    fn glob(pattern: &[u8], label: &[u8]) -> bool {
        match pattern.split_first() {
            None => label.is_empty(),
            Some((b'*', rest)) => {
                (1..=label.len()).any(|at| label.get(at..).is_some_and(|tail| glob(rest, tail)))
            }
            Some((c, rest)) => {
                label.split_first().is_some_and(|(first, tail)| first == c && glob(rest, tail))
            }
        }
    }
    glob(pattern.as_bytes(), label.as_bytes())
}

/// A host that never reaches a third party by name: an IP literal, a dotless name (resolved by
/// the person's own search domains), a reserved suffix, or a private-network suffix (tailnet,
/// `.internal`, `.lan`).
fn is_local(host: &str) -> bool {
    host.parse::<IpAddr>().is_ok()
        || host == "localhost"
        || (!host.is_empty() && !host.contains('.'))
        || [
            ".localhost",
            ".test",
            ".example",
            ".invalid",
            ".local",
            ".home.arpa",
            ".ts.net",
            ".internal",
            ".lan",
        ]
        .iter()
        .any(|suffix| host.ends_with(suffix))
        || host == "example.com"
        || host.ends_with(".example.com")
}

/// Why `host` (a host name or URL) may be reached, or [`Verdict::Unlisted`].
pub fn verdict(host_or_url: &str) -> Verdict {
    let host = host_of(host_or_url);
    if is_local(&host) {
        return Verdict::Local;
    }
    let labels: Vec<&str> = host.split('.').collect();
    let hit = listed().iter().any(|pattern| {
        pattern.len() == labels.len()
            && pattern.iter().zip(&labels).all(|(p, l)| label_matches(p, l))
    });
    if hit {
        return Verdict::Listed;
    }
    if named().lock().is_ok_and(|set| set.contains(&host)) {
        return Verdict::Named;
    }
    if session().lock().is_ok_and(|map| map.contains_key(&host)) {
        return Verdict::Session;
    }
    Verdict::Unlisted
}

/// A connection the gate refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub host: String,
    pub site: &'static str,
}

impl fmt::Display for Refused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "egress gate: {} is not a host docs/privacy.md lists (from {}); list it there with what it receives",
            self.host, self.site
        )
    }
}

impl Error for Refused {}

/// Checks one connection to `host` (a host name or URL) made for `site` (the
/// caller, as `crate::module`). Err only in [`Mode::Enforce`].
pub fn check(host_or_url: &str, site: &'static str) -> Result<(), Refused> {
    let mode = mode();
    if mode == Mode::Off {
        return Ok(());
    }
    let verdict = verdict(host_or_url);
    let host = host_of(host_or_url);
    let refused = verdict == Verdict::Unlisted && mode == Mode::Enforce;
    record(AuditEntry { host: host.clone(), site, verdict, refused }, mode);
    if verdict != Verdict::Unlisted {
        return Ok(());
    }
    let first = unlisted_log().lock().is_ok_and(|mut seen| seen.insert((host.clone(), site)));
    if first {
        eprintln!("egress.unlisted host={host} site={site} mode={}", mode.as_str());
    }
    if mode == Mode::Enforce { Err(Refused { host, site }) } else { Ok(()) }
}

/// Every (host, site) the gate found unlisted in this process, refused or not.
pub fn unlisted() -> Vec<(String, &'static str)> {
    unlisted_log().lock().map(|seen| seen.iter().cloned().collect()).unwrap_or_default()
}

/// The resolver every gated client uses: [`check`], then the inner resolver's
/// lookup (the system's, unless [`client_builder_with`] names another).
#[derive(Clone)]
pub struct Gate {
    site: &'static str,
    inner: Option<Arc<dyn Resolve>>,
}

impl fmt::Debug for Gate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Gate").field("site", &self.site).finish_non_exhaustive()
    }
}

impl Gate {
    pub fn new(site: &'static str) -> Gate {
        Gate { site, inner: None }
    }

    /// The gate in front of `inner` (acpmux's IPv6-first resolver).
    pub fn wrapping(site: &'static str, inner: impl Resolve + 'static) -> Gate {
        Gate { site, inner: Some(Arc::new(inner)) }
    }
}

impl Resolve for Gate {
    fn resolve(&self, name: Name) -> Resolving {
        if name.as_str() == REFUSED_PROXY_HOST {
            // The proxy [`gated_proxy`] picks for a refused request: refuse it here.
            let refused = Refused { host: REFUSED_PROXY_HOST.to_owned(), site: self.site };
            return Box::pin(async move { Err(Box::new(refused) as Box<dyn Error + Send + Sync>) });
        }
        if let Err(refused) = check(name.as_str(), self.site) {
            return Box::pin(async move { Err(Box::new(refused) as Box<dyn Error + Send + Sync>) });
        }
        #[cfg(feature = "capture")]
        if let Some(addr) = capture::redirect(name.as_str()) {
            return Box::pin(async move { Ok(Box::new(std::iter::once(addr)) as Addrs) });
        }
        if let Some(inner) = &self.inner {
            return inner.resolve(name);
        }
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let addrs: Vec<_> = tokio::net::lookup_host((host.as_str(), 0)).await?.collect();
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

/// Whether the seeded-secret capture is on (feature `capture`): a caller that
/// sets its own TLS configuration keeps the builder's capture CA instead.
pub fn capturing() -> bool {
    #[cfg(feature = "capture")]
    if capture::root().is_some() {
        return true;
    }
    false
}

/// A builder with the capture CA trusted when capture is on (feature `capture`).
fn trusting_capture(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    #[cfg(feature = "capture")]
    if let Some(root) = capture::root() {
        return builder.add_root_certificate(root);
    }
    builder
}

/// The host of the proxy a refused request is sent to: [`Gate`] refuses it, so
/// the request fails before a packet leaves even when another proxy is set.
const REFUSED_PROXY_HOST: &str = "egress-refused.cmux.invalid";

/// Reads one environment variable (the process's, or a test's).
type Env = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

fn process_env() -> Env {
    Arc::new(|name| std::env::var(name).ok())
}

/// The proxy the environment names for `scheme` (`HTTPS_PROXY` for https,
/// `HTTP_PROXY` for http, else `ALL_PROXY`; either case).
fn env_proxy(scheme: &str, env: &Env) -> Option<reqwest::Url> {
    let names: [&str; 4] = if scheme == "https" {
        ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    } else {
        ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    };
    let raw = names
        .iter()
        .find_map(|name| env(name).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()))?;
    reqwest::Url::parse(&raw)
        .ok()
        .filter(|url| url.has_host())
        .or_else(|| reqwest::Url::parse(&format!("http://{raw}")).ok())
}

/// Whether `NO_PROXY` (either case) sends `host` direct: `*`, the host, or a
/// parent domain (`example.com` and `.example.com` both cover `a.example.com`).
fn no_proxy_covers(host: &str, env: &Env) -> bool {
    let list = env("NO_PROXY").or_else(|| env("no_proxy")).unwrap_or_default();
    list.split(',').map(str::trim).filter(|entry| !entry.is_empty()).any(|entry| {
        if entry == "*" {
            return true;
        }
        let entry = host_of(entry);
        let domain = entry.trim_start_matches('.');
        !domain.is_empty() && (host == domain || host.ends_with(&format!(".{domain}")))
    })
}

/// The proxy for one request to `url` made for `site`: a refused host gets
/// [`REFUSED_PROXY_HOST`] (whatever proxy is set), a passing one the
/// environment's proxy unless `NO_PROXY` covers it, else none (direct, and
/// the resolver checks the host again).
fn gated_proxy(url: &reqwest::Url, site: &'static str, env: &Env) -> Option<reqwest::Url> {
    let host = host_of(url.host_str()?);
    if check(&host, site).is_err() {
        return reqwest::Url::parse(&format!("http://{REFUSED_PROXY_HOST}:9")).ok();
    }
    if no_proxy_covers(&host, env) {
        return None;
    }
    env_proxy(url.scheme(), env)
}

/// reqwest's proxy for a gated client, in place of its own reading of the
/// environment: [`gated_proxy`] for each connection.
fn gated_proxy_matcher(site: &'static str, env: Env) -> reqwest::Proxy {
    reqwest::Proxy::custom(move |url| gated_proxy(url, site, &env))
}

fn install_crypto_provider() {
    // reqwest is built without a default rustls provider; a client built before one is installed panics.
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// A reqwest client builder whose every connection passes the gate. `site`
/// names the caller (`"cmux_cloud_api::http"`) for the refusal line. The
/// environment's proxy is picked by the gate after the target host passes; a
/// proxy the caller adds comes after it, so it too sees only passing hosts.
pub fn client_builder(site: &'static str) -> reqwest::ClientBuilder {
    install_crypto_provider();
    trusting_capture(
        reqwest::Client::builder()
            .dns_resolver(Arc::new(Gate::new(site)))
            .proxy(gated_proxy_matcher(site, process_env())),
    )
}

/// [`client_builder`] with the gate in front of `resolver` instead of the
/// system's lookup.
pub fn client_builder_with(
    site: &'static str,
    resolver: impl Resolve + 'static,
) -> reqwest::ClientBuilder {
    install_crypto_provider();
    trusting_capture(
        reqwest::Client::builder()
            .dns_resolver(Arc::new(Gate::wrapping(site, resolver)))
            .proxy(gated_proxy_matcher(site, process_env())),
    )
}

/// [`client_builder`] for reqwest's blocking client (feature `blocking`).
#[cfg(feature = "blocking")]
pub fn blocking_client_builder(site: &'static str) -> reqwest::blocking::ClientBuilder {
    install_crypto_provider();
    let builder = reqwest::blocking::Client::builder()
        .dns_resolver(Arc::new(Gate::new(site)))
        .proxy(gated_proxy_matcher(site, process_env()));
    #[cfg(feature = "capture")]
    if let Some(root) = capture::root() {
        return builder.add_root_certificate(root);
    }
    builder
}

/// A gated `reqwest::Client::new()`: a client with reqwest's defaults whose
/// every connection passes the gate. Err where `Client::new()` would panic
/// (no TLS backend).
pub fn client(site: &'static str) -> reqwest::Result<reqwest::Client> {
    client_builder(site).build()
}

/// A gated `reqwest::get(url)`.
pub async fn get<U: reqwest::IntoUrl>(
    url: U,
    site: &'static str,
) -> reqwest::Result<reqwest::Response> {
    client(site)?.get(url).send().await
}

/// The WebSocket half of the gate: tokio-tungstenite's connects, the request's
/// host checked first. A WebSocket handshake follows no redirect, so checking
/// the request's own host covers the whole connection.
pub mod ws {
    use super::check;
    use tokio::net::TcpStream;
    use tokio_tungstenite::tungstenite::Error as WsError;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    use tokio_tungstenite::tungstenite::handshake::client::{Request, Response};
    use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
    use tokio_tungstenite::{Connector, MaybeTlsStream, WebSocketStream};

    /// What a connect returns, as tokio-tungstenite's do.
    pub type Connected = Result<(WebSocketStream<MaybeTlsStream<TcpStream>>, Response), WsError>;

    /// Turns `request` into a handshake request and checks its host. A caller
    /// that then dials the checked request itself (its own proxy hops or TLS
    /// trust) asks [`capture_route`] first, so the seeded-secret capture sees
    /// its upgrade as it sees this module's connects.
    pub fn checked<R: IntoClientRequest>(
        request: R,
        site: &'static str,
    ) -> Result<Request, WsError> {
        let request = request.into_client_request()?;
        let host = request.uri().host().unwrap_or_default().to_owned();
        check(&host, site).map_err(|refused| {
            WsError::Io(std::io::Error::new(std::io::ErrorKind::PermissionDenied, refused))
        })?;
        Ok(request)
    }

    /// A gated `tokio_tungstenite::connect_async`.
    pub async fn connect_async<R: IntoClientRequest + Unpin>(
        request: R,
        site: &'static str,
    ) -> Connected {
        connect(checked(request, site)?, None, false, None).await
    }

    /// A gated `tokio_tungstenite::connect_async_with_config`.
    pub async fn connect_async_with_config<R: IntoClientRequest + Unpin>(
        request: R,
        config: Option<WebSocketConfig>,
        disable_nagle: bool,
        site: &'static str,
    ) -> Connected {
        connect(checked(request, site)?, config, disable_nagle, None).await
    }

    /// A gated `tokio_tungstenite::connect_async_tls_with_config`.
    pub async fn connect_async_tls_with_config<R: IntoClientRequest + Unpin>(
        request: R,
        config: Option<WebSocketConfig>,
        disable_nagle: bool,
        connector: Option<Connector>,
        site: &'static str,
    ) -> Connected {
        connect(checked(request, site)?, config, disable_nagle, connector).await
    }

    /// Where a `wss://` upgrade of `request` goes instead, and the TLS config
    /// that trusts the capture CA: `Some` only with capture on (feature
    /// `capture`, tests) and the host one it takes (listed or person-named).
    /// Always `None` in a build without the feature.
    pub fn capture_route(
        request: &Request,
    ) -> Option<(std::net::SocketAddr, std::sync::Arc<rustls::ClientConfig>)> {
        #[cfg(feature = "capture")]
        if request.uri().scheme_str() == Some("wss") {
            return request.uri().host().and_then(crate::capture::ws_redirect);
        }
        let _ = request;
        None
    }

    /// The connect of a checked request. With capture on (feature `capture`), a
    /// `wss://` upgrade to a listed or person-named host goes to the capture
    /// server, which keeps the upgrade request (its target and headers) and
    /// answers `200`, so the connect fails after the request was seen.
    async fn connect(
        request: Request,
        config: Option<WebSocketConfig>,
        disable_nagle: bool,
        connector: Option<Connector>,
    ) -> Connected {
        if let Some((addr, tls)) = capture_route(&request) {
            let stream = TcpStream::connect(addr).await.map_err(WsError::Io)?;
            return tokio_tungstenite::client_async_tls_with_config(
                request,
                stream,
                config,
                Some(Connector::Rustls(tls)),
            )
            .await;
        }
        tokio_tungstenite::connect_async_tls_with_config(request, config, disable_nagle, connector)
            .await
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
