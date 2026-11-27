//! Remote server URLs: what may be connected at all (threat model T3, T4),
//! and the facts the card shows (host, publisher, IDN).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use url::{Host, Url};

use crate::Refusal;

/// A remote URL that passed the rules.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteTarget {
    /// The URL as it will be used (normalized by the URL parser).
    pub url: String,
    /// The host in ASCII (punycode for an international name).
    pub host: String,
    /// The registrable domain the card shows as "By".
    pub publisher: String,
    /// The host has an international (`xn--`) label: the card says so and
    /// it is never verified.
    pub idn: bool,
    /// `http://` to this machine (a local development server).
    pub loopback: bool,
}

/// Hosting suffixes under which each name belongs to a different owner, so
/// the publisher is one label more than the suffix.
const SHARED_SUFFIXES: [&str; 14] = [
    "co.uk",
    "org.uk",
    "ac.uk",
    "com.au",
    "co.jp",
    "com.br",
    "co.nz",
    "github.io",
    "vercel.app",
    "pages.dev",
    "workers.dev",
    "netlify.app",
    "herokuapp.com",
    "fly.dev",
];

/// The registrable domain of `host`: its last two labels, or three under a
/// shared suffix (`a.github.io`). An IP is its own publisher.
pub fn publisher_of(host: &str) -> String {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host.parse::<IpAddr>().is_ok() || host.starts_with('[') {
        return host;
    }
    let labels: Vec<&str> = host.split('.').collect();
    let take = if SHARED_SUFFIXES.iter().any(|s| host == *s || host.ends_with(&format!(".{s}"))) {
        3
    } else {
        2
    };
    let start = labels.len().saturating_sub(take);
    labels.get(start..).map(|l| l.join(".")).unwrap_or(host)
}

/// Whether an address may be reached by a connection: never the cloud
/// metadata service, link-local, private, shared (CGNAT), multicast or
/// unspecified ranges. Loopback is allowed (a local server). Checked on the
/// URL's literal and again on every address its name resolves to (DNS
/// rebinding).
pub fn check_ip(ip: IpAddr) -> Result<(), Refusal> {
    let refused = match ip {
        IpAddr::V4(v4) => v4_refused(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => v4_refused(v4),
            None => v6_refused(v6),
        },
    };
    match refused {
        Some(why) => Err(Refusal::new(format!("{ip} is {why}; cmux does not connect there"))),
        None => Ok(()),
    }
}

fn v4_refused(ip: Ipv4Addr) -> Option<&'static str> {
    let [a, b, ..] = ip.octets();
    if ip.is_loopback() {
        None
    } else if a == 169 && b == 254 {
        Some("a link-local or cloud metadata address")
    } else if ip.is_private() {
        Some("a private network address")
    } else if a == 100 && (64..=127).contains(&b) {
        Some("a shared (CGNAT or tailnet) address")
    } else if ip.is_unspecified() || ip.is_broadcast() || ip.is_multicast() || a == 0 {
        Some("not a server address")
    } else {
        None
    }
}

fn v6_refused(ip: Ipv6Addr) -> Option<&'static str> {
    let first = ip.segments().first().copied().unwrap_or(0);
    if ip.is_loopback() {
        None
    } else if ip.is_unspecified() || ip.is_multicast() {
        Some("not a server address")
    } else if first & 0xfe00 == 0xfc00 {
        Some("a private network address")
    } else if first & 0xffc0 == 0xfe80 {
        Some("a link-local address")
    } else {
        None
    }
}

/// Checks a remote server URL (threat model T3, T4).
pub fn check_url(text: &str) -> Result<RemoteTarget, Refusal> {
    let url = Url::parse(text.trim()).map_err(|e| Refusal::new(format!("not a URL: {e}")))?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err(Refusal::new(
            "a URL with a user name or password before the host is refused (it hides the real host)",
        ));
    }
    if url.fragment().is_some() {
        return Err(Refusal::new("a server URL has no #fragment"));
    }
    let host = url.host().ok_or_else(|| Refusal::new("the URL has no host"))?;
    let (host_text, loopback) = match &host {
        Host::Domain(d) => {
            let d = d.trim_end_matches('.').to_ascii_lowercase();
            let lo = d == "localhost" || d.ends_with(".localhost");
            (d, lo)
        }
        Host::Ipv4(ip) => {
            check_ip(IpAddr::V4(*ip))?;
            (ip.to_string(), ip.is_loopback())
        }
        Host::Ipv6(ip) => {
            check_ip(IpAddr::V6(*ip))?;
            (ip.to_string(), ip.is_loopback())
        }
    };
    match url.scheme() {
        "https" => {}
        "http" if loopback => {}
        "http" => {
            return Err(Refusal::new(
                "http:// is only for a server on this Mac (127.0.0.1, localhost); use https://",
            ));
        }
        other => return Err(Refusal::new(format!("{other}:// is not an MCP server URL"))),
    }
    let idn = host_text.split('.').any(|l| l.starts_with("xn--"));
    Ok(RemoteTarget {
        url: url.to_string(),
        publisher: if loopback { "this Mac".to_owned() } else { publisher_of(&host_text) },
        host: host_text,
        idn,
        loopback,
    })
}
