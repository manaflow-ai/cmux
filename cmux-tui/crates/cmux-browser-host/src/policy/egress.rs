//! FETCH-PRIVATE-RANGES (a9, 2026-10-04): which hosts agent requests and
//! navigations may reach by address range, for fetch and navigation alike.
//!
//! - Link-local and cloud metadata (169.254.0.0/16 with 169.254.169.254,
//!   fe80::/10, the AWS IPv6 endpoint fd00:ec2::254, the provider metadata
//!   and host addresses below, metadata names) are refused in every session.
//! - Loopback, private and local-use ranges (127/8, 10/8, 172.16/12,
//!   192.168/16, 100.64/10, 0/8, 192.0.0/24, 198.18/15, multicast and
//!   reserved, ::, ::1, fc00::/7, fec0::/10, ff00::/8, `localhost` names) are
//!   allowed when the session's origin is local to the machine the browser
//!   runs on, and refused for remote (relay) sessions. On a Cloud machine
//!   every caller is refused them (crate::egress_scope).
//! - IPv6 forms that carry an IPv4 address (IPv4-mapped ::ffff:a.b.c.d,
//!   IPv4-compatible ::a.b.c.d, NAT64 64:ff9b::/96, 6to4 2002::/16) take the
//!   class of the IPv4 address they carry.
//! - Only the machine owner's policy (the base layer's allow list naming
//!   the host) allows a refused host.

use super::Policy;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use url::{Host, Url};

/// Cloud metadata service names.
const METADATA_NAMES: &[&str] =
    &["metadata.google.internal", "metadata.goog", "instance-data", "instance-data.ec2.internal"];

/// Provider metadata and host-agent addresses outside 169.254/16: Alibaba
/// (100.100.100.200) and Azure's host endpoint (168.63.129.16).
const METADATA_V4: &[Ipv4Addr] =
    &[Ipv4Addr::new(100, 100, 100, 200), Ipv4Addr::new(168, 63, 129, 16)];

/// AWS's IPv6 instance metadata endpoint (fd00:ec2::254).
const METADATA_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254);

/// Whether `name` (any case, trailing dot or not) is a cloud metadata name.
pub fn is_metadata_name(name: &str) -> bool {
    METADATA_NAMES.contains(&name.trim_end_matches('.').to_ascii_lowercase().as_str())
}

/// The class of an address that the range rule limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Range {
    LinkLocal,
    Private,
}

fn v4_range(ip: Ipv4Addr) -> Option<Range> {
    let [a, b, c, _] = ip.octets();
    if (a == 169 && b == 254) || METADATA_V4.contains(&ip) {
        return Some(Range::LinkLocal);
    }
    let private = a == 127
        || a == 10
        || a == 0
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 100 && (64..=127).contains(&b))
        || (a == 192 && b == 0 && c == 0)
        || (a == 198 && (18..=19).contains(&b))
        // Multicast, reserved and broadcast.
        || a >= 224;
    private.then_some(Range::Private)
}

/// The IPv4 address an IPv6 address carries: IPv4-mapped, IPv4-compatible
/// (deprecated, but a socket still reaches the IPv4 host on some stacks),
/// NAT64 well-known prefix, 6to4.
fn embedded_v4(ip: Ipv6Addr) -> Option<Ipv4Addr> {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return Some(v4);
    }
    let s = ip.segments();
    let low = |hi: u16, lo: u16| Ipv4Addr::from(((hi as u32) << 16) | lo as u32);
    if s[..6] == [0; 6] && !(s[6] == 0 && s[7] <= 1) {
        return Some(low(s[6], s[7]));
    }
    if s[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
        return Some(low(s[6], s[7]));
    }
    (s[0] == 0x2002).then(|| low(s[1], s[2]))
}

fn v6_range(ip: Ipv6Addr) -> Option<Range> {
    if let Some(v4) = embedded_v4(ip) {
        return v4_range(v4);
    }
    let s = ip.segments();
    if s[0] & 0xffc0 == 0xfe80 || ip == METADATA_V6 {
        return Some(Range::LinkLocal);
    }
    let private = ip.is_loopback()
        || ip.is_unspecified()
        // Unique local (fc00::/7), site-local (fec0::/10), multicast.
        || s[0] & 0xfe00 == 0xfc00
        || s[0] & 0xffc0 == 0xfec0
        || s[0] & 0xff00 == 0xff00
        // Local-use NAT64 (64:ff9b:1::/48) and discard-only (100::/64).
        || (s[0] == 0x64 && s[1] == 0xff9b && s[2] == 1)
        || s[..4] == [0x100, 0, 0, 0];
    private.then_some(Range::Private)
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
            if is_metadata_name(&name) {
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
            "http://[fd00:ec2::254]/latest/meta-data/",
            "http://100.100.100.200/latest/meta-data/",
            "http://168.63.129.16/machine",
            "http://METADATA.google.internal./",
            "http://metadata.goog/",
            "http://instance-data.ec2.internal/",
            // IPv6 forms that carry 169.254.169.254.
            "http://[::a9fe:a9fe]/",
            "http://[64:ff9b::a9fe:a9fe]/",
            "http://[2002:a9fe:a9fe::1]/",
        ] {
            assert!(policy.egress_refusal(&url(text), false).is_some(), "{text}");
        }
    }

    #[test]
    fn every_address_class_has_its_range() {
        let range = |text: &str| ip_range(text.parse().unwrap());
        for text in
            ["169.254.169.254", "169.254.0.1", "fe80::1", "fd00:ec2::254", "::ffff:169.254.169.254"]
        {
            assert_eq!(range(text), Some(Range::LinkLocal), "{text}");
        }
        for text in [
            "127.0.0.1",
            "127.255.255.254",
            "10.0.0.1",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.0.1",
            "100.64.0.1",
            "100.127.255.255",
            "0.0.0.0",
            "192.0.0.8",
            "198.18.0.1",
            "224.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "fc00::1",
            "fd12:3456::1",
            "fec0::1",
            "ff02::1",
            "::ffff:10.0.0.1",
            "::ffff:127.0.0.1",
            "::ffff:100.64.0.1",
            "::10.0.0.1",
            "64:ff9b::7f00:1",
            "64:ff9b:1::1",
            "2002:c0a8:0101::1",
            "100::1",
        ] {
            assert_eq!(range(text), Some(Range::Private), "{text}");
        }
        for text in [
            "8.8.8.8",
            "172.32.0.1",
            "100.128.0.1",
            "198.20.0.1",
            "2606:4700::1111",
            "::ffff:8.8.8.8",
            "64:ff9b::808:808",
            "2002:0808:0808::1",
        ] {
            assert_eq!(range(text), None, "{text}");
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
