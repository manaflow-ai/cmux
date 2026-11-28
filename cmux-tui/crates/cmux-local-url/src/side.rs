//! Which device opens a web link the person opens on the phone: a link in a
//! terminal, which the Mac's shell printed, tapped on the phone, or one a
//! program in a terminal the phone drives asks a browser for (the daemon's
//! `offer-link-to-phone`). The phone's `link_open_side` (cmux-mobile-link-ffi)
//! and the daemon read this one classifier.
//!
//! A public address (github.com) opens on the phone, in a browser with
//! Safari's passkeys. An address only the Mac can reach opens on the Mac, as
//! the Mac's Cmd-click does: its loopback (a dev server), a LAN or tailnet
//! host, a bare host name. Anything that is not an `http(s)` page opens nowhere.
//!
//! Hosts are read the way a browser reads them (WHATWG, the `url` crate):
//! lowercased, IDN as punycode, `2130706433` as `127.0.0.1`, userinfo apart
//! from the host, so `https://github.com@127.0.0.1/` is the Mac's loopback.

use std::net::{Ipv4Addr, Ipv6Addr};

use url::{Host, Url};

/// Where a web link opened on the phone goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkSide {
    /// A public address: the phone's own browser.
    Phone,
    /// An address only the Mac can reach: a browser tab on the Mac.
    Mac,
    /// Not a web page (`javascript:`, `file:`, an app's scheme, no host).
    NotWeb,
}

/// Name suffixes that resolve only on the Mac's own network: mDNS, MagicDNS,
/// the private-use names routers and companies hand out, and `.test` (RFC
/// 6761: never on the public internet, only in the Mac's own resolver).
const MAC_NETWORK_SUFFIXES: [&str; 7] =
    [".localhost", ".local", ".ts.net", ".lan", ".home.arpa", ".internal", ".test"];

/// Which device opens `text`, a link the person opened on the phone.
pub fn link_side(text: &str) -> LinkSide {
    let text = text.trim();
    let Ok(url) = Url::parse(text) else {
        return if port_only(text) { LinkSide::Mac } else { LinkSide::NotWeb };
    };
    if !matches!(url.scheme(), "http" | "https") {
        return LinkSide::NotWeb;
    }
    match url.host() {
        None => LinkSide::NotWeb,
        Some(Host::Ipv4(ip)) => side_of_v4(ip),
        Some(Host::Ipv6(ip)) => side_of_v6(ip),
        Some(Host::Domain(name)) => side_of_name(name),
    }
}

/// `http://:3000/`: a port with no host, which only the Mac's browser fills in
/// (with its own loopback).
fn port_only(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("http://:").or_else(|| lower.strip_prefix("https://:"))
    else {
        return false;
    };
    let port = rest.split(['/', '?', '#']).next().unwrap_or_default();
    !port.is_empty()
        && port.bytes().all(|byte| byte.is_ascii_digit())
        && port.parse::<u16>().is_ok()
}

fn side_of_name(name: &str) -> LinkSide {
    let name = name.strip_suffix('.').unwrap_or(name);
    if name.is_empty() {
        return LinkSide::NotWeb;
    }
    // A bare host name resolves through the Mac's search domains or hosts file.
    let mac_network = MAC_NETWORK_SUFFIXES.iter().any(|suffix| name.ends_with(suffix));
    if name == "localhost" || !name.contains('.') || mac_network {
        return LinkSide::Mac;
    }
    LinkSide::Phone
}

fn side_of_v4(ip: Ipv4Addr) -> LinkSide {
    let [a, b, ..] = ip.octets();
    // 100.64.0.0/10: carrier-grade NAT, where tailnet peers live.
    let shared = a == 100 && (64..=127).contains(&b);
    let local = ip.is_loopback()
        || ip.is_unspecified()
        || a == 0
        || ip.is_link_local()
        || ip.is_broadcast();
    if local || ip.is_private() || shared { LinkSide::Mac } else { LinkSide::Phone }
}

fn side_of_v6(ip: Ipv6Addr) -> LinkSide {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return side_of_v4(v4);
    }
    let [first, ..] = ip.segments();
    // fc00::/7 unique local (tailnet addresses among them), fe80::/10 link-local.
    let unique_local = first & 0xfe00 == 0xfc00;
    let link_local = first & 0xffc0 == 0xfe80;
    if ip.is_loopback() || ip.is_unspecified() || unique_local || link_local {
        LinkSide::Mac
    } else {
        LinkSide::Phone
    }
}

#[cfg(test)]
#[path = "side_tests.rs"]
mod tests;
