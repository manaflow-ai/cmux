//! FETCH-PRIVATE-RANGES under a proxy (browser-egress.md 7.3, ff finding
//! 2026-10-07). A proxied response reports the PROXY's address as its
//! remote address (Chromium 143, tests/chromium/proxy_ranges.rs), so the
//! after-the-fact rebinding check never sees where the proxy went, and a
//! page behind a proxy loads and is readable before that check could stop
//! it. So:
//! - a remote (relay) session sets no proxy (7.3: a session's own exit is
//!   for sessions on this machine only);
//! - a proxy's own address meets the range rule (link-local and metadata
//!   are refused to every session), by literal and by this machine's
//!   resolver;
//! - while the session's new tabs use a proxy, a URL name this machine
//!   resolves into a refused range is refused before dispatch. A name that
//!   does not resolve here is the proxy's to resolve (for a vendor exit, an
//!   accepted risk; for cmux exits the exit enforces the rule, later).
//!
//! The owner policy's allow list still overrides the range rule.

use super::Gate;
use crate::policy::egress::ip_range;
use crate::protocol::{DriverError, ErrorCode};
use serde_json::Value;
use std::net::{IpAddr, ToSocketAddrs};
use std::sync::atomic::Ordering;
use std::sync::{Arc, PoisonError};
use url::{Host, Url};

/// Resolves `(host, port)` to its addresses on this machine (none when the
/// name does not resolve).
pub type NameResolver = Arc<dyn Fn(&str, u16) -> Vec<IpAddr> + Send + Sync>;

/// This machine's resolver.
pub fn system_resolver() -> NameResolver {
    Arc::new(|host, port| {
        (host, port)
            .to_socket_addrs()
            .map(|addrs| addrs.map(|a| a.ip()).collect())
            .unwrap_or_default()
    })
}

/// The proxy URLs of a Chromium `proxyServer` value: `host:port`,
/// `scheme://host:port`, or `;`-separated `scheme=` rules. `None` when a part
/// cannot be read (the configure is refused: fail closed).
fn proxy_urls(server: &str) -> Option<Vec<Url>> {
    let mut urls = Vec::new();
    for rule in server.split(';').map(str::trim).filter(|rule| !rule.is_empty()) {
        let proxy = match rule.split_once('=') {
            Some((_, proxy)) if !rule.contains("://") || rule.find('=') < rule.find("://") => proxy,
            _ => rule,
        };
        for proxy in proxy.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            if proxy == "direct://" {
                continue;
            }
            let text =
                if proxy.contains("://") { proxy.to_owned() } else { format!("http://{proxy}") };
            let url = Url::parse(&text).ok()?;
            url.host_str()?;
            urls.push(url);
        }
    }
    Some(urls)
}

impl Gate {
    /// Why this session's `session.configure {proxy}` is refused, if it is.
    pub(super) fn proxy_refusal(&self, params: &Value) -> Option<String> {
        let proxy = params.get("proxy").filter(|proxy| !proxy.is_null())?;
        if self.grants.isolated.is_some() {
            return Some(
                "session.configure: a session on a Cloud machine cannot set a proxy (the host's egress filter is its only exit)"
                    .into(),
            );
        }
        if self.grants.remote {
            return Some(
                "session.configure: a remote session cannot set a proxy (a session's own exit is for sessions on this machine)"
                    .into(),
            );
        }
        let server = proxy.get("server").and_then(Value::as_str).unwrap_or("");
        let Some(urls) = proxy_urls(server) else {
            return Some(format!(
                "session.configure: proxy server {server:?} is not a proxy address"
            ));
        };
        urls.iter().find_map(|url| {
            self.range_refusal_here(url).map(|reason| {
                format!(
                    "session.configure: proxy {} is blocked: {reason}",
                    url.host_str().unwrap_or("")
                )
            })
        })
    }

    /// Keeps whether the session's new tabs use a proxy (a configure's answer).
    pub(super) fn note_configured(&self, answer: &Value) {
        if let Some(proxied) = answer.get("proxy").and_then(Value::as_bool) {
            self.proxied.store(proxied, Ordering::SeqCst);
        }
    }

    /// For a proxied session: why `url`'s name, as this machine resolves
    /// it, is refused.
    pub(super) fn proxied_name_refusal(&self, url: &str) -> Option<String> {
        if !self.proxied.load(Ordering::SeqCst) {
            return None;
        }
        let parsed = Url::parse(url).ok()?;
        matches!(parsed.host(), Some(Host::Domain(_))).then_some(())?;
        self.range_refusal_here(&parsed)
    }

    /// The range rule for `url`'s literal host, then for every address this
    /// machine resolves its name to.
    fn range_refusal_here(&self, url: &Url) -> Option<String> {
        let literal = {
            let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
            policy.egress_refusal(url, self.grants.remote)
        };
        if literal.is_some() {
            return literal;
        }
        let Some(Host::Domain(name)) = url.host() else { return None };
        let addresses = (self.resolver)(name, url.port_or_known_default().unwrap_or(80));
        let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner);
        addresses.into_iter().find_map(|ip| {
            policy
                .range_refusal(url, ip_range(ip), self.grants.remote)
                .map(|reason| format!("{name} resolves to {ip} on this machine: {reason}"))
        })
    }
}

/// A refusal of a call this module checks.
pub(super) fn refused(message: String) -> DriverError {
    DriverError::new(ErrorCode::Forbidden, message)
}

#[cfg(test)]
mod tests {
    use super::proxy_urls;

    #[test]
    fn proxy_server_values_name_their_proxies() {
        let hosts = |server: &str| {
            proxy_urls(server).map(|urls| {
                urls.iter().map(|u| u.host_str().unwrap().to_owned()).collect::<Vec<_>>()
            })
        };
        assert_eq!(hosts("127.0.0.1:8080"), Some(vec!["127.0.0.1".into()]));
        assert_eq!(hosts("socks5://p.test:1080"), Some(vec!["p.test".into()]));
        assert_eq!(
            hosts("http=a.test:1;https=b.test:2,direct://"),
            Some(vec!["a.test".into(), "b.test".into()])
        );
        assert_eq!(hosts("http://[::1]:3128"), Some(vec!["[::1]".into()]));
        assert_eq!(hosts("http://"), None);
    }
}
