//! The site (registrable domain) of a host. Moved here from the browser
//! host's policy so the daemon's grant rows and the host's enforcement
//! name a site the same way: both go through [`normalize_host`], then the
//! full Public Suffix List (the `psl` crate, ICANN and private sections).

use std::net::{Ipv4Addr, Ipv6Addr};

/// One spelling of a host for grants and matching: lowercase, no trailing
/// dot, a Unicode name in its punycode (IDNA) form, an IP address in its
/// canonical form and an IPv6 address without brackets. `None` when it is
/// not a host.
pub fn normalize_host(host: &str) -> Option<String> {
    let h = host.trim().trim_end_matches('.');
    if h.is_empty() {
        return None;
    }
    let bare = h.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(h);
    if let Ok(ip) = bare.parse::<Ipv6Addr>() {
        return Some(ip.to_string());
    }
    if bare.len() != h.len() {
        return None;
    }
    match url::Host::parse(h).ok()? {
        url::Host::Domain(domain) => Some(domain),
        url::Host::Ipv4(ip) => Some(ip.to_string()),
        url::Host::Ipv6(ip) => Some(ip.to_string()),
    }
}

fn is_ip(host: &str) -> bool {
    host.parse::<Ipv4Addr>().is_ok() || host.parse::<Ipv6Addr>().is_ok()
}

/// Whether `host` (normalized) is itself a public suffix on the list
/// (`com`, `co.uk`, `github.io`, `co.ke`).
pub(crate) fn is_public_suffix(host: &str) -> bool {
    psl::suffix(host.as_bytes())
        .is_some_and(|suffix| suffix.is_known() && suffix.as_bytes() == host.as_bytes())
}

/// The site (registrable domain) of a host, for leases, cookie scoping and
/// storageState. An IP address, a single label, a host whose suffix is not
/// on the list, or one that is not a host at all is its own site, so it
/// never shares a key with another host (fail closed).
pub fn site_of(host: &str) -> String {
    let Some(h) = normalize_host(host) else {
        return host.trim().to_ascii_lowercase();
    };
    if is_ip(&h) || !h.contains('.') {
        return h;
    }
    let known = psl::suffix(h.as_bytes()).is_some_and(|suffix| suffix.is_known());
    if !known {
        return h;
    }
    match psl::domain(h.as_bytes()).and_then(|domain| std::str::from_utf8(domain.as_bytes()).ok()) {
        Some(domain) => domain.to_owned(),
        // The host is a public suffix itself.
        None => h,
    }
}
