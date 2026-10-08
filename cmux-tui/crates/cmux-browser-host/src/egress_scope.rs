//! EGRESS-ISOLATED (cx-d0d.7; spec browser-use.md: "Egress policy for agent
//! browsing (block cloud metadata IPs and private ranges by default) is
//! enforced in the host"; decisions D39). On a Cloud machine the browser
//! host refuses cloud metadata, link-local, private, CGNAT and local-use
//! addresses to EVERY caller, not only to remote ones.
//!
//! The machine's own loopback is the exception (chief decision, 2026-10-08:
//! an agent browsing its own dev server is the main Cloud workflow): a
//! LITERAL loopback target (127/8, ::1, `localhost`) is allowed unless a
//! cmux service listens on that port (crate::egress_services): the daemon,
//! acpmux, this host's own listener. A public name that resolves to
//! loopback stays refused (DNS rebinding), and so does 0.0.0.0.
//!
//! Where the rule is enforced: every Chromium the host launches on such a
//! machine sends every connection through the host's own SOCKS5 listener
//! (crate::egress_proxy). The listener resolves a name itself, checks EVERY
//! address of the answer, and dials only the addresses it checked, so a DNS
//! answer that changes between a check and the connect (DNS rebinding)
//! cannot reach a refused address. Each redirect hop, subresource, page
//! `fetch`, WebSocket and host `net.fetch` is its own connection through it.
//! Chromium resolves no name itself (`--host-resolver-rules` maps every name
//! but the listener's to NOTFOUND) and sends no UDP outside the proxy
//! (WebRTC `disable_non_proxied_udp`).
//!
//! The gate keeps a literal and resolved check before agent navigations and
//! fetches (a clear reason for the agent), skips the after-the-fact response
//! address check (a proxied response reports the listener's own address),
//! and refuses session proxies (a session's own exit would bypass the
//! listener).
//!
//! Which scope: isolated on a baked cmux Cloud image
//! (`/etc/cmux/bake-instance-id`) or when `CMUX_VM_ID` is set, whatever
//! `CMUX_BROWSER_HOST_EGRESS` says; elsewhere `CMUX_BROWSER_HOST_EGRESS` =
//! `isolated` turns it on. Any value other than `machine` is isolated (fail
//! closed).
//!
//! The only exception is the machine owner's allow list,
//! `CMUX_BROWSER_HOST_EGRESS_ALLOW`: comma-separated `ip:port`, `[ip6]:port`
//! or `localhost:port` (both loopback addresses), for example a dev server the
//! agent should test. It applies to literal and `localhost` targets only (a
//! public name that resolves to an allowed address is refused: rebinding),
//! and never allows a link-local or metadata address.
//!
//! Remote localhost (plans/cmux-next/remote-localhost.md) is untouched: a
//! person's Mac tab reaches the Cloud machine's loopback through the
//! daemon's `loopback-forward-v1` streams and the app's own 127.0.0.1 proxy
//! route on the Mac (`cloud.browser.open`), never through this host's
//! Chromium on the machine.

use crate::gate::{NameResolver, system_resolver};
use crate::policy::egress::{Range, ip_range, is_metadata_name};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex, PoisonError};
use url::{Host, Url};

/// Selects the scope: `isolated` or `machine`.
pub const SCOPE_VAR: &str = "CMUX_BROWSER_HOST_EGRESS";
/// The machine owner's allow list.
pub const ALLOW_VAR: &str = "CMUX_BROWSER_HOST_EGRESS_ALLOW";
/// Files only a baked cmux Cloud image has.
pub const CLOUD_MARKERS: &[&str] = &["/etc/cmux/bake-instance-id"];

/// Which destinations the host's browsers may reach.
#[derive(Debug, Clone, Default)]
pub enum EgressScope {
    /// The machine is the caller's own: FETCH-PRIVATE-RANGES (policy/egress.rs).
    #[default]
    Machine,
    /// A Cloud machine: every caller is refused every limited range.
    Isolated(Arc<IsolatedEgress>),
}

impl EgressScope {
    pub fn isolated(&self) -> Option<&Arc<IsolatedEgress>> {
        match self {
            EgressScope::Machine => None,
            EgressScope::Isolated(isolated) => Some(isolated),
        }
    }

    /// The scope from the environment, plus a warning per ignored setting.
    pub fn from_env() -> (EgressScope, Vec<String>) {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        let on_cloud = var("CMUX_VM_ID").is_some()
            || CLOUD_MARKERS.iter().any(|path| std::path::Path::new(path).exists());
        EgressScope::decide(
            var(SCOPE_VAR).as_deref(),
            on_cloud,
            &var(ALLOW_VAR).unwrap_or_default(),
            system_resolver(),
        )
    }

    /// The scope for a `CMUX_BROWSER_HOST_EGRESS` value, whether the host
    /// runs on a Cloud machine, and an allow list.
    pub fn decide(
        scope: Option<&str>,
        on_cloud: bool,
        allow: &str,
        resolver: NameResolver,
    ) -> (EgressScope, Vec<String>) {
        let mut warnings = Vec::new();
        let isolated = match scope.map(str::trim).filter(|s| !s.is_empty()) {
            // A Cloud machine is always isolated: an agent that starts its
            // own host with its own environment cannot turn it off.
            Some("machine") if on_cloud => {
                warnings.push(format!("{SCOPE_VAR}=machine is ignored on a Cloud machine"));
                true
            }
            Some("machine") => false,
            Some("isolated") => true,
            Some(other) => {
                warnings
                    .push(format!("{SCOPE_VAR}={other:?} is not isolated or machine: isolated"));
                true
            }
            None => on_cloud,
        };
        if !isolated {
            return (EgressScope::Machine, warnings);
        }
        let (allow, errors) = parse_allow(allow);
        warnings.extend(errors.into_iter().map(|e| format!("{ALLOW_VAR}: {e} (ignored)")));
        let rule = EgressRule::new(allow, resolver);
        (EgressScope::Isolated(Arc::new(IsolatedEgress::new(rule))), warnings)
    }
}

/// Parses an allow list; invalid entries are returned as errors (they only
/// ever add destinations, so dropping them fails closed).
pub fn parse_allow(text: &str) -> (Vec<SocketAddr>, Vec<String>) {
    let (mut allow, mut errors) = (Vec::new(), Vec::new());
    for entry in text.split([',', ' ', '\n', '\t']).map(str::trim).filter(|e| !e.is_empty()) {
        if let Some(port) = entry.strip_prefix("localhost:") {
            match port.parse::<u16>() {
                Ok(port) if port != 0 => {
                    allow.push(SocketAddr::from((Ipv4Addr::LOCALHOST, port)));
                    allow.push(SocketAddr::from((Ipv6Addr::LOCALHOST, port)));
                }
                _ => errors.push(format!("{entry:?} has no port")),
            }
            continue;
        }
        match entry.parse::<SocketAddr>() {
            Ok(addr) if addr.port() == 0 => errors.push(format!("{entry:?} has no port")),
            Ok(addr) if ip_range(addr.ip()) == Some(Range::LinkLocal) => {
                errors.push(format!("{entry:?} is link-local or cloud metadata, never allowed"));
            }
            Ok(addr) => allow.push(canonical(addr)),
            Err(_) => errors.push(format!("{entry:?} is not ip:port or localhost:port")),
        }
    }
    (allow, errors)
}

/// 127/8 and ::1 (IPv4-mapped forms are canonical already).
fn is_loopback(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_loopback(),
        IpAddr::V6(ip) => ip == Ipv6Addr::LOCALHOST,
    }
}

/// IPv4-mapped IPv6 addresses compare as their IPv4 address.
fn canonical(addr: SocketAddr) -> SocketAddr {
    match addr.ip() {
        IpAddr::V6(ip) => match ip.to_ipv4_mapped() {
            Some(v4) => SocketAddr::from((v4, addr.port())),
            None => addr,
        },
        IpAddr::V4(_) => addr,
    }
}

/// Why a destination is not dialed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// A refused address or name.
    Blocked(String),
    /// The name has no address.
    Unresolved(String),
}

impl Refusal {
    pub fn reason(&self) -> &str {
        match self {
            Refusal::Blocked(reason) | Refusal::Unresolved(reason) => reason,
        }
    }
}

/// A connection target as the SOCKS5 request names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Address(SocketAddr),
    Name(String, u16),
}

impl std::fmt::Display for Target {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Target::Address(addr) => write!(f, "{addr}"),
            Target::Name(name, port) => write!(f, "{name}:{port}"),
        }
    }
}

/// The isolated range rule: one resolution per connection, every address
/// checked, only checked addresses returned.
pub struct EgressRule {
    allow: Vec<SocketAddr>,
    resolver: NameResolver,
    /// Why a loopback port is a cmux service's (crate::egress_services).
    services: crate::egress_services::ServiceCheck,
    /// Tests: one loopback address that counts as public (a stand-in for
    /// an internet host the test can dial).
    #[cfg(test)]
    test_public: Option<SocketAddr>,
}

impl std::fmt::Debug for EgressRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EgressRule").field("allow", &self.allow).finish_non_exhaustive()
    }
}

impl EgressRule {
    pub fn new(allow: Vec<SocketAddr>, resolver: NameResolver) -> EgressRule {
        EgressRule {
            allow: allow.into_iter().map(canonical).collect(),
            resolver,
            services: crate::egress_services::system_check(),
            #[cfg(test)]
            test_public: None,
        }
    }

    /// Replaces the cmux service check (tests).
    pub fn with_service_check(
        mut self,
        services: crate::egress_services::ServiceCheck,
    ) -> EgressRule {
        self.services = services;
        self
    }

    #[cfg(test)]
    pub(crate) fn with_test_public(mut self, addr: SocketAddr) -> EgressRule {
        self.test_public = Some(addr);
        self
    }

    /// Why `addr` is refused, if it is.
    pub fn address_refusal(&self, addr: SocketAddr) -> Option<String> {
        self.refusal(addr, true)
    }

    /// The range rule for one address; `literal` (a literal or `localhost`
    /// target) applies the owner's allow list and the machine's own
    /// loopback: a public name that resolves to an allowed private address
    /// or to loopback is DNS rebinding.
    fn refusal(&self, addr: SocketAddr, literal: bool) -> Option<String> {
        let addr = canonical(addr);
        #[cfg(test)]
        if self.test_public == Some(addr) {
            return None;
        }
        let range = ip_range(addr.ip())?;
        match range {
            Range::LinkLocal => {
                Some(format!("{} is a link-local or cloud metadata address", addr.ip()))
            }
            Range::Private if literal && self.allow.contains(&addr) => None,
            Range::Private if literal && is_loopback(addr.ip()) => (self.services)(addr),
            Range::Private => Some(format!(
                "{} is a loopback, private or local-network address, which browsing on a Cloud machine may not reach",
                addr.ip()
            )),
        }
    }

    /// The addresses to dial for `target`: every one checked. A name is
    /// resolved exactly once here; the caller dials only what this returns.
    pub fn resolve(&self, target: &Target) -> Result<Vec<SocketAddr>, Refusal> {
        let (name, port) = match target {
            Target::Address(addr) => {
                return match self.address_refusal(*addr) {
                    Some(reason) => Err(Refusal::Blocked(reason)),
                    None => Ok(vec![*addr]),
                };
            }
            Target::Name(name, port) => (name.trim_end_matches('.').to_ascii_lowercase(), *port),
        };
        if is_metadata_name(&name) {
            return Err(Refusal::Blocked(format!("{name} is a cloud metadata name")));
        }
        let (ips, literal) = if name == "localhost" || name.ends_with(".localhost") {
            // Never from DNS (RFC 6761); the hosts file is not consulted either.
            (vec![IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)], true)
        } else if let Ok(ip) = name.trim_matches(['[', ']']).parse::<IpAddr>() {
            (vec![ip], true)
        } else {
            ((self.resolver)(&name, port), false)
        };
        if ips.is_empty() {
            return Err(Refusal::Unresolved(format!("{name} does not resolve")));
        }
        let addrs: Vec<SocketAddr> = ips.into_iter().map(|ip| SocketAddr::new(ip, port)).collect();
        // One refused address refuses the name: an answer that mixes a
        // public and a private address is a rebinding attempt.
        if let Some(reason) = addrs.iter().find_map(|addr| self.refusal(*addr, literal)) {
            return Err(Refusal::Blocked(format!(
                "{name} resolves to a refused address: {reason}"
            )));
        }
        Ok(addrs)
    }

    /// The rule for a URL's literal host only (an IP, `localhost`, a
    /// metadata name), with no lookup: the request filter's check, which
    /// runs on a driver thread for every request. Names go to the listener.
    pub fn literal_refusal(&self, url: &Url) -> Option<String> {
        let host = url.host()?;
        if let Host::Domain(name) = &host {
            let name = name.trim_end_matches('.').to_ascii_lowercase();
            if !(is_metadata_name(&name) || name == "localhost" || name.ends_with(".localhost")) {
                return None;
            }
        }
        self.url_refusal(url)
    }

    /// The rule for a URL the agent opens or fetches (its host, literal or
    /// resolved); `None` for URLs without a network host.
    pub fn url_refusal(&self, url: &Url) -> Option<String> {
        if !matches!(url.scheme(), "http" | "https" | "ws" | "wss" | "ftp") {
            return None;
        }
        let port = url.port_or_known_default().unwrap_or(80);
        let target = match url.host()? {
            Host::Ipv4(ip) => Target::Address(SocketAddr::from((ip, port))),
            Host::Ipv6(ip) => Target::Address(SocketAddr::from((ip, port))),
            Host::Domain(name) => Target::Name(name.to_owned(), port),
        };
        match self.resolve(&target) {
            Ok(_) => None,
            Err(Refusal::Blocked(reason)) => Some(reason),
            // Unresolved here is the engine's own error to report.
            Err(Refusal::Unresolved(_)) => None,
        }
    }
}

/// An isolated host's rule and its listener (started on first use).
#[derive(Debug)]
pub struct IsolatedEgress {
    rule: Arc<EgressRule>,
    /// The running listener (a failed start is retried at the next launch).
    listener: Mutex<Option<SocketAddr>>,
}

impl IsolatedEgress {
    pub fn new(rule: EgressRule) -> IsolatedEgress {
        IsolatedEgress { rule: Arc::new(rule), listener: Mutex::new(None) }
    }

    pub fn rule(&self) -> &EgressRule {
        &self.rule
    }

    /// The listener every browser of this host uses, started once. An
    /// error fails that launch (closed); the next launch tries again.
    pub fn listener(&self) -> Result<SocketAddr, String> {
        let mut slot = self.listener.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(addr) = *slot {
            return Ok(addr);
        }
        let addr = crate::egress_proxy::start(self.rule.clone())
            .map_err(|e| format!("the browser egress listener did not start: {e}"))?;
        *slot = Some(addr);
        Ok(addr)
    }

    /// The listener's address once it runs (a proxied response reports it).
    pub fn listener_addr(&self) -> Option<SocketAddr> {
        *self.listener.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The Chromium switches that send all of a browser's traffic through
    /// the listener.
    pub fn chromium_args(&self) -> Result<Vec<String>, String> {
        Ok(chromium_args(self.listener()?))
    }
}

/// Every connection through `listener` (SOCKS5: Chromium sends names, never
/// resolves them itself), loopback included (`<-loopback>` drops Chromium's
/// implicit bypass), no name resolution in Chromium at all, no UDP outside
/// the proxy.
pub fn chromium_args(listener: SocketAddr) -> Vec<String> {
    vec![
        format!("--proxy-server=socks5://{listener}"),
        "--proxy-bypass-list=<-loopback>".into(),
        format!("--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE {}", listener.ip()),
        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp".into(),
    ]
}

#[cfg(test)]
#[path = "egress_scope_tests.rs"]
mod tests;
