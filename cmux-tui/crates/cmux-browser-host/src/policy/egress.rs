//! FETCH-PRIVATE-RANGES (a9, 2026-10-04): which hosts agent requests and
//! navigations may reach by address range, for fetch and navigation alike.
//!
//! - Link-local and cloud metadata (169.254.0.0/16 with 169.254.169.254,
//!   fe80::/10, metadata names) are refused in every session.
//! - Loopback and private ranges (127/8, 10/8, 172.16/12, 192.168/16,
//!   100.64/10, 0/8, ::1, fc00::/7, `localhost` names) are allowed when the
//!   session's origin is local to the machine the browser runs on, and
//!   refused for remote (relay) sessions.
//! - Only the machine owner's policy (the base layer's allow list naming
//!   the host) allows a refused host.

use super::Policy;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use url::{Host, Url};

/// Cloud metadata service names.
const METADATA_NAMES: &[&str] =
    &["metadata.google.internal", "metadata.goog", "instance-data", "instance-data.ec2.internal"];

/// The class of an address that the range rule limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Range {
    LinkLocal,
    Private,
}

fn v4_range(ip: Ipv4Addr) -> Option<Range> {
    let [a, b, ..] = ip.octets();
    if a == 169 && b == 254 {
        return Some(Range::LinkLocal);
    }
    let private = a == 127
        || a == 10
        || a == 0
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 100 && (64..=127).contains(&b));
    private.then_some(Range::Private)
}

fn v6_range(ip: Ipv6Addr) -> Option<Range> {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return v4_range(v4);
    }
    let first = ip.segments()[0];
    if first & 0xffc0 == 0xfe80 {
        return Some(Range::LinkLocal);
    }
    (ip.is_loopback() || ip.is_unspecified() || first & 0xfe00 == 0xfc00).then_some(Range::Private)
}

/// The range of an IP address, if the rule limits it.
pub fn ip_range(ip: IpAddr) -> Option<Range> {
    match ip {
        IpAddr::V4(ip) => v4_range(ip),
        IpAddr::V6(ip) => v6_range(ip),
    }
}

/// The range of a URL's host, by literal address or by name.
pub fn host_range(url: &Url) -> Option<Range> {
    match url.host()? {
        Host::Ipv4(ip) => v4_range(ip),
        Host::Ipv6(ip) => v6_range(ip),
        Host::Domain(name) => {
            let name = name.trim_end_matches('.').to_ascii_lowercase();
            if METADATA_NAMES.contains(&name.as_str()) {
                Some(Range::LinkLocal)
            } else if name == "localhost" || name.ends_with(".localhost") {
                Some(Range::Private)
            } else {
                None
            }
        }
    }
}

impl Policy {
    /// Whether the machine owner's policy names this host in its allow list.
    fn owner_allows(&self, url: &Url) -> bool {
        let secure = url.scheme() == "https";
        self.base
            .allowed
            .as_ref()
            .is_some_and(|list| list.iter().any(|pattern| pattern.matches(url, secure)))
    }

    /// Why the range rule refuses `range` for this session, or `None`.
    pub fn range_refusal(&self, url: &Url, range: Option<Range>, remote: bool) -> Option<String> {
        let range = range?;
        if self.owner_allows(url) {
            return None;
        }
        let host = url.host_str().unwrap_or("");
        match range {
            Range::LinkLocal => Some(format!("{host} is a link-local or cloud metadata address")),
            Range::Private if remote => Some(format!(
                "{host} is a private or loopback address, which a remote session may not reach"
            )),
            Range::Private => None,
        }
    }

    /// The range rule for a URL's own host.
    pub fn egress_refusal(&self, url: &Url, remote: bool) -> Option<String> {
        self.range_refusal(url, host_range(url), remote)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::{Layer, Writer, parse_patterns};

    fn url(text: &str) -> Url {
        Url::parse(text).unwrap()
    }

    #[test]
    fn link_local_and_metadata_are_refused_everywhere() {
        let policy = Policy::default();
        for text in [
            "http://169.254.169.254/latest/meta-data/",
            "http://[fe80::1]/",
            "http://metadata.google.internal/computeMetadata/v1/",
            "http://[::ffff:169.254.169.254]/",
        ] {
            assert!(policy.egress_refusal(&url(text), false).is_some(), "{text}");
        }
    }

    #[test]
    fn private_ranges_are_refused_only_for_remote_sessions() {
        let policy = Policy::default();
        for text in [
            "http://127.0.0.1:8080/",
            "http://10.1.2.3/",
            "http://172.20.0.1/",
            "http://192.168.1.1/",
            "http://100.89.225.106/",
            "http://[::1]/",
            "http://[fd00::1]/",
            "http://localhost:3000/",
            "http://app.localhost/",
        ] {
            assert!(policy.egress_refusal(&url(text), false).is_none(), "local: {text}");
            assert!(policy.egress_refusal(&url(text), true).is_some(), "remote: {text}");
        }
        for text in ["https://example.com/", "http://172.32.0.1/", "http://8.8.8.8/"] {
            assert!(policy.egress_refusal(&url(text), true).is_none(), "{text}");
        }
    }

    #[test]
    fn only_the_owner_policy_allows_a_refused_host() {
        let mut policy = Policy::default();
        let layer = Layer {
            allowed: Some(parse_patterns(&["http://169.254.169.254".to_owned()]).unwrap()),
            ..Layer::default()
        };
        policy.set(Writer::Owner, layer.clone(), false).unwrap();
        assert!(policy.egress_refusal(&url("http://169.254.169.254/x"), true).is_none());
        let mut agent = Policy::default();
        agent.set(Writer::Agent, layer, false).unwrap();
        assert!(agent.egress_refusal(&url("http://169.254.169.254/x"), false).is_some());
    }
}
