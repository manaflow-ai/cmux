//! The remote view tab's record and policy (was `RemoteViewTabRecord.swift`,
//! `RemoteViewTabPolicy.swift`, `RemoteViewTabDecision.swift`): the
//! `cmux://remote-view?...` address a tab persists, and whether a tab may
//! connect to it.

use serde::{Deserialize, Serialize};

use super::pane::ControlMode;

pub const SCHEME: &str = "cmux";
pub const URL_HOST: &str = "remote-view";
pub const MAXIMUM_HOST_LENGTH: usize = 128;
pub const DEFAULT_VNC_PORT: u16 = 5900;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum Target {
    Display(u32),
    Window(u64),
    Virtual,
}

impl Default for Target {
    fn default() -> Self {
        Self::Display(1)
    }
}

impl Target {
    pub fn raw_value(&self) -> String {
        match self {
            Self::Display(id) => format!("display:{id}"),
            Self::Window(id) => format!("window:{id}"),
            Self::Virtual => "virtual".to_owned(),
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        if raw == "virtual" {
            return Some(Self::Virtual);
        }
        let (kind, digits) = raw.split_once(':')?;
        if digits.is_empty() || digits.len() > 20 || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        match kind {
            "display" => digits.parse().ok().map(Self::Display),
            "window" => digits.parse().ok().map(Self::Window),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabRecord {
    pub host: String,
    #[serde(default)]
    pub target: Target,
    #[serde(default = "view_mode")]
    pub mode: ControlMode,
    #[serde(default)]
    pub vnc_port: Option<u16>,
    #[serde(default)]
    pub cloud_desktop: bool,
    #[serde(default)]
    pub cloud_rd: bool,
}

fn view_mode() -> ControlMode {
    ControlMode::View
}

impl TabRecord {
    /// The record, or None: a host outside [`is_valid_host`], port 0, a
    /// Cloud desktop with a VNC port, or Cloud rd without a Cloud desktop.
    pub fn new(
        host: &str,
        target: Target,
        mode: ControlMode,
        vnc_port: Option<u16>,
        cloud_desktop: bool,
        cloud_rd: bool,
    ) -> Option<Self> {
        if !is_valid_host(host)
            || vnc_port == Some(0)
            || (cloud_desktop && vnc_port.is_some())
            || (cloud_rd && !cloud_desktop)
        {
            return None;
        }
        Some(Self { host: host.to_owned(), target, mode, vnc_port, cloud_desktop, cloud_rd })
    }

    /// Validates a record that came in as data.
    pub fn validated(self) -> Option<Self> {
        Self::new(
            &self.host,
            self.target,
            self.mode,
            self.vnc_port,
            self.cloud_desktop,
            self.cloud_rd,
        )
    }

    pub fn url(&self) -> String {
        let mode = match self.mode {
            ControlMode::View => "view",
            ControlMode::Control => "control",
        };
        let mut url = format!(
            "{SCHEME}://{URL_HOST}?host={}&target={}&mode={mode}",
            encode_query(&self.host),
            encode_query(&self.target.raw_value())
        );
        if let Some(port) = self.vnc_port {
            url.push_str(&format!("&via=vnc&port={port}"));
        } else if self.cloud_desktop {
            url.push_str(if self.cloud_rd { "&via=cloud-rd" } else { "&via=cloud" });
        }
        url
    }

    /// Parses a tab address (`URLComponents` rules: no user, password, port,
    /// path or fragment; each known field once, with a value).
    pub fn parse(url: &str) -> Option<Self> {
        let parts = UrlParts::parse(url)?;
        if !parts.scheme.eq_ignore_ascii_case(SCHEME) || !parts.host.eq_ignore_ascii_case(URL_HOST)
        {
            return None;
        }
        if parts.has_user || parts.has_port || !parts.path.is_empty() || parts.has_fragment {
            return None;
        }
        const NAMES: [&str; 5] = ["host", "target", "mode", "via", "port"];
        let mut fields: [Option<String>; 5] = Default::default();
        for (name, value) in parts.query_items() {
            let Some(index) = NAMES.iter().position(|n| *n == name) else { continue };
            let value = value?;
            if fields[index].is_some() {
                return None;
            }
            fields[index] = Some(value);
        }
        let [host, target, mode, via, port] = fields;
        let host = host?;
        let target = match target {
            Some(raw) => Target::parse(&raw)?,
            None => Target::default(),
        };
        let mode = match mode.as_deref() {
            None => ControlMode::View,
            Some("view") => ControlMode::View,
            Some("control") => ControlMode::Control,
            Some(_) => return None,
        };
        let (mut vnc_port, mut cloud_desktop, mut cloud_rd) = (None, false, false);
        match via.as_deref() {
            None | Some("rd") => {
                if port.is_some() {
                    return None;
                }
            }
            Some(v @ ("cloud" | "cloud-rd")) => {
                if port.is_some() {
                    return None;
                }
                cloud_desktop = true;
                cloud_rd = v == "cloud-rd";
            }
            Some("vnc") => {
                vnc_port = Some(match port {
                    Some(raw) => {
                        if !(1..=5).contains(&raw.len()) || !raw.bytes().all(|b| b.is_ascii_digit())
                        {
                            return None;
                        }
                        let port: u16 = raw.parse().ok()?;
                        if port == 0 {
                            return None;
                        }
                        port
                    }
                    None => DEFAULT_VNC_PORT,
                });
            }
            Some(_) => return None,
        }
        Self::new(&host, target, mode, vnc_port, cloud_desktop, cloud_rd)
    }
}

/// 1...128 bytes of `[A-Za-z0-9._-]`, the first alphanumeric.
pub fn is_valid_host(host: &str) -> bool {
    let bytes = host.as_bytes();
    let Some(first) = bytes.first() else { return false };
    bytes.len() <= MAXIMUM_HOST_LENGTH
        && first.is_ascii_alphanumeric()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Percent-encodes what `URLComponents` encodes in a query value.
fn encode_query(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"-._~!$'()*+,;=:@/?".contains(&b);
        if keep {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn decode_percent(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The pieces of an absolute URL a tab address reads.
struct UrlParts<'a> {
    scheme: &'a str,
    host: String,
    has_user: bool,
    has_port: bool,
    path: &'a str,
    query: Option<&'a str>,
    has_fragment: bool,
}

impl<'a> UrlParts<'a> {
    fn parse(url: &'a str) -> Option<Self> {
        if url.bytes().any(|b| b <= b' ' || b >= 0x7F) {
            return None;
        }
        let (scheme, rest) = url.split_once(':')?;
        let mut chars = scheme.chars();
        if !chars.next()?.is_ascii_alphabetic()
            || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        {
            return None;
        }
        let rest = rest.strip_prefix("//")?;
        let (rest, has_fragment) = match rest.split_once('#') {
            Some((before, _)) => (before, true),
            None => (rest, false),
        };
        let (rest, query) = match rest.split_once('?') {
            Some((before, query)) => (before, Some(query)),
            None => (rest, None),
        };
        let (authority, path) = match rest.find('/') {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, ""),
        };
        let (has_user, host_port) = match authority.rsplit_once('@') {
            Some((_, hp)) => (true, hp),
            None => (false, authority),
        };
        let (host, has_port) = match host_port.rsplit_once(':') {
            Some((host, port)) => {
                if !port.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                // An empty port (`host:`) is no port to URLComponents.
                (host, !port.is_empty())
            }
            None => (host_port, false),
        };
        Some(Self {
            scheme,
            host: decode_percent(host)?,
            has_user,
            has_port,
            path,
            query,
            has_fragment,
        })
    }

    /// `URLComponents.queryItems`: `&`-separated, value None without `=`,
    /// both percent-decoded (`+` stays `+`). An undecodable item is dropped
    /// whole, as is the query of an undecodable URL.
    fn query_items(&self) -> Vec<(String, Option<String>)> {
        let Some(query) = self.query else { return vec![] };
        query
            .split('&')
            .filter_map(|item| match item.split_once('=') {
                Some((name, value)) => Some((decode_percent(name)?, Some(decode_percent(value)?))),
                None => Some((decode_percent(item)?, None)),
            })
            .collect()
    }
}

/// Where a tab's open request came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabSource {
    /// A record restored from a remote tree (another machine's layout).
    RemoteTree,
    /// Opened by something other than the person (a link, a restore).
    Unconfirmed,
    /// The person opened it here.
    Person,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum UnavailableReason {
    NotInThisBuild,
    NoTransport { host: String },
    NotLoopback { host: String },
    NotPrivateNetwork { host: String },
    RemoteRecord,
    InvalidAddress,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TabDecision {
    Connect { record: TabRecord },
    Confirm { record: TabRecord },
    Unavailable { reason: UnavailableReason },
}

pub const LOOPBACK_NAMES: [&str; 3] = ["mock", "local", "localhost"];

pub fn decide(
    record: Option<&TabRecord>,
    source: TabSource,
    pane_available: bool,
    cloud_rd_available: bool,
) -> TabDecision {
    let unavailable = |reason| TabDecision::Unavailable { reason };
    if source == TabSource::RemoteTree {
        return unavailable(UnavailableReason::RemoteRecord);
    }
    let Some(record) = record else { return unavailable(UnavailableReason::InvalidAddress) };
    if !(pane_available || (record.cloud_desktop && record.cloud_rd && cloud_rd_available)) {
        return unavailable(UnavailableReason::NotInThisBuild);
    }
    if record.cloud_desktop {
        // Only over the app's own Cloud tunnel: no network address to check.
    } else if record.vnc_port.is_some() {
        if !is_private_network(&record.host) {
            return unavailable(UnavailableReason::NotPrivateNetwork { host: record.host.clone() });
        }
    } else if !is_loopback(&record.host) {
        return unavailable(UnavailableReason::NotLoopback { host: record.host.clone() });
    }
    if source != TabSource::Person {
        let mut view = record.clone();
        view.mode = ControlMode::View;
        return TabDecision::Confirm { record: view };
    }
    TabDecision::Connect { record: record.clone() }
}

fn ipv4_octets(host: &str) -> Option<[u8; 4]> {
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() != 4 {
        return None;
    }
    let mut octets = [0u8; 4];
    for (slot, part) in octets.iter_mut().zip(parts) {
        if !(1..=3).contains(&part.len())
            || !part.bytes().all(|b| b.is_ascii_digit())
            || (part.len() > 1 && part.starts_with('0'))
        {
            return None;
        }
        *slot = part.parse().ok()?;
    }
    Some(octets)
}

pub fn is_loopback(host: &str) -> bool {
    let lower = host.to_lowercase();
    if LOOPBACK_NAMES.contains(&lower.as_str()) {
        return true;
    }
    ipv4_octets(host).is_some_and(|o| o[0] == 127)
}

pub fn is_private_network(host: &str) -> bool {
    if is_loopback(host) {
        return true;
    }
    let lower = host.to_lowercase();
    if let Some(o) = ipv4_octets(&lower) {
        return matches!((o[0], o[1]), (10, _) | (192, 168) | (172, 16..=31) | (100, 64..=127));
    }
    if lower.ends_with(".ts.net") || lower.ends_with(".local") {
        return true;
    }
    if lower.bytes().all(|b| b.is_ascii_digit()) || lower.starts_with("0x") {
        return false;
    }
    !lower.contains('.')
}
