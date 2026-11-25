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
//! [`Mode::Enforce`] refuses the rest; [`Mode::Log`] only reports it. The mode
//! is `CMUX_EGRESS` (`enforce`, `log` or `off`) when set, else enforce in a
//! debug build and log in a release build; the app sets `CMUX_EGRESS=enforce`
//! for nightly. Every refusal (or would-be refusal) prints one
//! `egress.unlisted host=H site=S mode=M` line to stderr and is kept in
//! [`unlisted`] for diagnostics.
//!
//! tests/test_egress_gate.py finds every client the code makes by hand
//! instead; tests/egress_ungated.json lists those not moved here yet.

#![forbid(unsafe_code)]

#[cfg(feature = "capture")]
pub mod capture;

use std::collections::BTreeSet;
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

const DEFAULT_MODE: Mode = if cfg!(debug_assertions) { Mode::Enforce } else { Mode::Log };

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
                .unwrap_or(DEFAULT_MODE);
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// docs/privacy.md lists it.
    Listed,
    /// The person named it in a setting ([`allow_named`]).
    Named,
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

fn is_local(host: &str) -> bool {
    host.parse::<IpAddr>().is_ok()
        || host == "localhost"
        || [".localhost", ".test", ".example", ".invalid", ".local", ".home.arpa"]
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
    if mode == Mode::Off || verdict(host_or_url) != Verdict::Unlisted {
        return Ok(());
    }
    let host = host_of(host_or_url);
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

/// A builder with the capture CA trusted when capture is on (feature `capture`).
fn trusting_capture(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    #[cfg(feature = "capture")]
    if let Some(root) = capture::root() {
        return builder.add_root_certificate(root);
    }
    builder
}

fn install_crypto_provider() {
    // reqwest is built without a default rustls provider; a client built before one is installed panics.
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// A reqwest client builder whose every connection passes the gate. `site`
/// names the caller (`"cmux_cloud_api::http"`) for the refusal line. A proxy
/// set on the builder is resolved (and checked) in place of the target.
pub fn client_builder(site: &'static str) -> reqwest::ClientBuilder {
    install_crypto_provider();
    trusting_capture(reqwest::Client::builder().dns_resolver(Arc::new(Gate::new(site))))
}

/// [`client_builder`] with the gate in front of `resolver` instead of the
/// system's lookup.
pub fn client_builder_with(
    site: &'static str,
    resolver: impl Resolve + 'static,
) -> reqwest::ClientBuilder {
    install_crypto_provider();
    trusting_capture(
        reqwest::Client::builder().dns_resolver(Arc::new(Gate::wrapping(site, resolver))),
    )
}

/// [`client_builder`] for reqwest's blocking client (feature `blocking`).
#[cfg(feature = "blocking")]
pub fn blocking_client_builder(site: &'static str) -> reqwest::blocking::ClientBuilder {
    install_crypto_provider();
    let builder = reqwest::blocking::Client::builder().dns_resolver(Arc::new(Gate::new(site)));
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

    /// Turns `request` into a handshake request and checks its host.
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

    /// A gated connect over a TCP stream the caller dials itself (a raced or
    /// remembered route, `dial` given a copy of the request): the request's host is
    /// checked before `dial` runs, and
    /// the upgrade and TLS then run over the dialed stream as
    /// `tokio_tungstenite::client_async_tls_with_config` runs them.
    pub async fn connect_dialed<R, D, F>(request: R, site: &'static str, dial: D) -> Connected
    where
        R: IntoClientRequest,
        D: FnOnce(Request) -> F,
        F: Future<Output = Result<TcpStream, WsError>>,
    {
        let request = checked(request, site)?;
        #[cfg(feature = "capture")]
        if let Some(connected) = captured(&request, None).await {
            return connected;
        }
        let stream = dial(request.clone()).await?;
        tokio_tungstenite::client_async_tls_with_config(request, stream, None, None).await
    }

    /// With capture on, a `wss://` upgrade to a listed or person-named host goes
    /// to the capture server instead; `None` when it does not.
    #[cfg(feature = "capture")]
    async fn captured(request: &Request, config: Option<WebSocketConfig>) -> Option<Connected> {
        if request.uri().scheme_str() != Some("wss") {
            return None;
        }
        let (addr, tls) = request.uri().host().and_then(crate::capture::ws_redirect)?;
        let stream = match TcpStream::connect(addr).await {
            Ok(stream) => stream,
            Err(error) => return Some(Err(WsError::Io(error))),
        };
        Some(
            tokio_tungstenite::client_async_tls_with_config(
                request.clone(),
                stream,
                config,
                Some(Connector::Rustls(tls)),
            )
            .await,
        )
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
        #[cfg(feature = "capture")]
        if let Some(connected) = captured(&request, config).await {
            return connected;
        }
        tokio_tungstenite::connect_async_tls_with_config(request, config, disable_nagle, connector)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listed_hosts_and_patterns_pass() {
        assert_eq!(verdict("cloud-api.cmux.dev"), Verdict::Listed);
        assert_eq!(verdict("https://Cloud-API.cmux.dev:443/v1/x?y"), Verdict::Listed);
        assert_eq!(verdict("acme.atlassian.net"), Verdict::Listed);
        assert_eq!(verdict("atlassian.net"), Verdict::Unlisted);
        assert_eq!(verdict("a.b.atlassian.net"), Verdict::Unlisted);
        assert_eq!(verdict("cmux-api-preview-42.debussy.workers.dev"), Verdict::Listed);
        assert_eq!(verdict("other-42.debussy.workers.dev"), Verdict::Unlisted);
    }

    #[test]
    fn local_and_reserved_pass() {
        for host in [
            "127.0.0.1",
            "http://[::1]:8080/",
            "localhost",
            "app.localhost",
            "x.test",
            "example.com",
        ] {
            assert_eq!(verdict(host), Verdict::Local, "{host}");
        }
    }

    #[test]
    fn named_hosts_pass_and_the_rest_are_refused() {
        set_mode(Mode::Enforce);
        assert_eq!(verdict("git.self-hosted-gate-test.org"), Verdict::Unlisted);
        let refused = check("https://evil-gate-test.org/x", "cmux_egress::tests").unwrap_err();
        assert_eq!(refused.host, "evil-gate-test.org");
        assert!(unlisted().contains(&("evil-gate-test.org".to_owned(), "cmux_egress::tests")));
        allow_named("https://user@git.self-hosted-gate-test.org:8443/repo");
        assert_eq!(verdict("git.self-hosted-gate-test.org"), Verdict::Named);
        set_mode(Mode::Log);
        assert!(check("evil-gate-test.org", "cmux_egress::tests").is_ok());
        set_mode(Mode::Enforce);
    }

    #[test]
    fn star_matches_within_one_label() {
        assert!(label_matches("cmux-api-preview-*", "cmux-api-preview-7"));
        assert!(!label_matches("cmux-api-preview-*", "cmux-api-preview-"));
        assert!(label_matches("*", "anything"));
        assert!(!label_matches("*", ""));
        assert!(label_matches("a*b*c", "a-x-b-y-c"));
        assert!(!label_matches("a*b*c", "a-x-c"));
    }

    #[tokio::test]
    async fn a_gated_client_refuses_before_resolving() {
        set_mode(Mode::Enforce);
        let client = client_builder("cmux_egress::tests").build().unwrap();
        let err = client.get("https://refused-gate-test.org/").send().await.unwrap_err();
        let mut source: Option<&(dyn Error + 'static)> = Some(&err);
        let mut found = false;
        while let Some(e) = source {
            found |= e.downcast_ref::<Refused>().is_some();
            source = e.source();
        }
        assert!(found, "{err:?}");
    }

    #[tokio::test]
    async fn a_wrapped_resolver_is_asked_only_for_passing_hosts() {
        use std::sync::atomic::AtomicUsize;
        #[derive(Clone)]
        struct Counting(Arc<AtomicUsize>);
        impl Resolve for Counting {
            fn resolve(&self, _: Name) -> Resolving {
                self.0.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(Box::new(Vec::new().into_iter()) as Addrs) })
            }
        }
        set_mode(Mode::Enforce);
        let asked = Arc::new(AtomicUsize::new(0));
        let client =
            client_builder_with("cmux_egress::tests", Counting(asked.clone())).build().unwrap();
        assert!(client.get("https://refused-wrap-test.org/").send().await.is_err());
        assert_eq!(asked.load(Ordering::SeqCst), 0);
        let _ = client.get("https://cloud-api.cmux.dev/").send().await;
        assert_eq!(asked.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_websocket_to_an_unlisted_host_is_refused_before_connecting() {
        set_mode(Mode::Enforce);
        let err = ws::connect_async("wss://refused-ws-test.org/socket", "cmux_egress::tests")
            .await
            .unwrap_err();
        let text = err.to_string();
        assert!(text.contains("refused-ws-test.org"), "{text}");
        assert!(ws::checked("ws://127.0.0.1:9/x", "cmux_egress::tests").is_ok());
    }
}
