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

/// The resolver every gated client uses: [`check`], then the system's lookup.
#[derive(Clone, Copy, Debug)]
pub struct Gate {
    site: &'static str,
}

impl Gate {
    pub fn new(site: &'static str) -> Gate {
        Gate { site }
    }
}

impl Resolve for Gate {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        let site = self.site;
        Box::pin(async move {
            check(&host, site)
                .map_err(|refused| Box::new(refused) as Box<dyn Error + Send + Sync>)?;
            let addrs: Vec<_> = tokio::net::lookup_host((host.as_str(), 0)).await?.collect();
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

/// A reqwest client builder whose every connection passes the gate. `site`
/// names the caller (`"cmux_cloud_api::http"`) for the refusal line. A proxy
/// set on the builder is resolved (and checked) in place of the target.
pub fn client_builder(site: &'static str) -> reqwest::ClientBuilder {
    // reqwest is built without a default rustls provider; a client built before one is installed panics.
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder().dns_resolver(Arc::new(Gate::new(site)))
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
}
