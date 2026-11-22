//! Parsers for what the system tools print. Pure: each takes the tool's
//! output as text, so tests run on recorded output from real machines.

use serde_json::Value;

use crate::{Band, RttSample, TailscalePeer, WifiLink};

/// `system_profiler SPAirPortDataType -json` (macOS 13+): the associated
/// network of the first Wi-Fi interface that has one.
pub fn macos_system_profiler_wifi(json: &str) -> Option<WifiLink> {
    let v: Value = serde_json::from_str(json).ok()?;
    let ifaces = v
        .get("SPAirPortDataType")?
        .as_array()?
        .iter()
        .filter_map(|e| e.get("spairport_airport_interfaces").and_then(Value::as_array));
    for iface in ifaces.flatten() {
        let Some(net) = iface.get("spairport_current_network_information") else { continue };
        let mut link = WifiLink {
            interface: iface.get("_name").and_then(Value::as_str).unwrap_or("en0").to_owned(),
            ..WifiLink::default()
        };
        if let Some(ch) = net.get("spairport_network_channel") {
            let text = match ch {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            let (channel, band, width) = channel_text(&text);
            link.channel = channel;
            link.band = band.or_else(|| channel.and_then(Band::from_channel));
            link.width_mhz = width;
        }
        if let Some(sn) = net.get("spairport_signal_noise").and_then(Value::as_str) {
            let (signal, noise) = signal_noise(sn);
            link.rssi_dbm = signal;
            link.noise_dbm = noise;
        }
        link.tx_rate_mbps = net.get("spairport_network_rate").and_then(|r| match r {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.trim().parse().ok(),
            _ => None,
        });
        link.phy_mode =
            net.get("spairport_network_phymode").and_then(Value::as_str).map(str::to_owned);
        return Some(link);
    }
    None
}

/// `149 (5GHz, 80MHz)`, `6 (2GHz, 20MHz)`, `37 (6GHz, 160MHz)`.
fn channel_text(text: &str) -> (Option<u32>, Option<Band>, Option<u32>) {
    let channel = leading_number(text).map(|n| n as u32);
    let lower = text.to_ascii_lowercase();
    let band = if lower.contains("6ghz") {
        Some(Band::Ghz6)
    } else if lower.contains("5ghz") {
        Some(Band::Ghz5)
    } else if lower.contains("2ghz") || lower.contains("2.4ghz") {
        Some(Band::Ghz2_4)
    } else {
        None
    };
    let width = lower
        .split([',', '(', ')'])
        .map(str::trim)
        .find_map(|part| part.strip_suffix("mhz").and_then(|n| n.trim().parse().ok()));
    (channel, band, width)
}

/// `-55 dBm / -94 dBm`.
fn signal_noise(text: &str) -> (Option<i32>, Option<i32>) {
    let mut parts = text.split('/');
    let a = parts.next().and_then(|p| leading_number(p.trim())).map(|n| n as i32);
    let b = parts.next().and_then(|p| leading_number(p.trim())).map(|n| n as i32);
    (a, b)
}

/// The number a string starts with (sign and decimals allowed).
fn leading_number(text: &str) -> Option<f64> {
    let t = text.trim_start();
    let end = t
        .char_indices()
        .find(|(i, c)| !(c.is_ascii_digit() || *c == '.' || (*i == 0 && (*c == '-' || *c == '+'))))
        .map_or(t.len(), |(i, _)| i);
    t[..end].parse().ok()
}

/// `iw dev IFACE link` (Linux).
pub fn linux_iw_link(interface: &str, text: &str) -> Option<WifiLink> {
    if !text.contains("Connected to") {
        return None;
    }
    let mut link = WifiLink { interface: interface.to_owned(), ..WifiLink::default() };
    for line in text.lines().map(str::trim) {
        if let Some(v) = line.strip_prefix("freq:") {
            let mhz = leading_number(v).map(|n| n as u32);
            link.band = mhz.and_then(Band::from_mhz);
        } else if let Some(v) = line.strip_prefix("signal:") {
            link.rssi_dbm = leading_number(v).map(|n| n as i32);
        } else if let Some(v) = line.strip_prefix("tx bitrate:") {
            link.tx_rate_mbps = leading_number(v);
            if let Some(w) = v.split_whitespace().find_map(|w| w.strip_suffix("MHz")) {
                link.width_mhz = w.parse().ok();
            }
        }
    }
    Some(link)
}

/// `route -n get default` (macOS): `(interface, gateway)`.
pub fn macos_route_default(text: &str) -> (Option<String>, Option<String>) {
    let field = |name: &str| {
        text.lines().find_map(|l| {
            l.trim().strip_prefix(name).map(|v| v.trim_start_matches(':').trim().to_owned())
        })
    };
    (field("interface:"), field("gateway:"))
}

/// `ip route show default` (Linux): `(interface, gateway)`.
pub fn linux_route_default(text: &str) -> (Option<String>, Option<String>) {
    let line = text.lines().find(|l| l.starts_with("default")).unwrap_or("");
    let words: Vec<&str> = line.split_whitespace().collect();
    let after = |key: &str| {
        words.iter().position(|w| *w == key).and_then(|i| words.get(i + 1)).map(|s| (*s).to_owned())
    };
    (after("dev"), after("via"))
}

/// `networksetup -listallhardwareports` (macOS): `(port name, device)`.
pub fn macos_hardware_ports(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut port: Option<String> = None;
    for line in text.lines().map(str::trim) {
        if let Some(p) = line.strip_prefix("Hardware Port:") {
            port = Some(p.trim().to_owned());
        } else if let Some(d) = line.strip_prefix("Device:")
            && let Some(p) = port.take()
        {
            out.push((p, d.trim().to_owned()));
        }
    }
    out
}

/// Whether `ifconfig IFACE` (macOS) says the interface has link.
pub fn ifconfig_active(text: &str) -> Option<bool> {
    text.lines().find_map(|l| l.trim().strip_prefix("status:").map(|s| s.trim() == "active"))
}

/// Whether `ifconfig IFACE` (macOS) shows an Ethernet medium
/// (`media: autoselect (1000baseT <full-duplex>)`): a USB or Thunderbolt
/// adapter `networksetup` may not list.
pub fn ifconfig_is_ethernet(text: &str) -> bool {
    text.lines()
        .find_map(|l| l.trim().strip_prefix("media:"))
        .is_some_and(|m| m.contains("baseT") || m.contains("baseSR") || m.contains("baseLR"))
}

/// `tailscale status --json`: every peer, direct or through DERP.
pub fn tailscale_status(json: &str) -> Vec<TailscalePeer> {
    let Ok(v) = serde_json::from_str::<Value>(json) else { return Vec::new() };
    let Some(peers) = v.get("Peer").and_then(Value::as_object) else { return Vec::new() };
    let mut out: Vec<TailscalePeer> = peers
        .values()
        .map(|p| {
            let s = |k: &str| p.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
            TailscalePeer {
                name: s("HostName")
                    .or_else(|| s("DNSName").and_then(|d| d.split('.').next()))
                    .unwrap_or("?")
                    .to_owned(),
                address: p
                    .get("TailscaleIPs")
                    .and_then(Value::as_array)
                    .and_then(|ips| ips.first())
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                online: p.get("Online").and_then(Value::as_bool).unwrap_or(false),
                direct_addr: s("CurAddr").map(str::to_owned),
                derp_region: if s("CurAddr").is_none() {
                    s("Relay").map(str::to_owned)
                } else {
                    None
                },
                ping_ms: None,
            }
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// The last pong of `tailscale ping`: `(direct addr or None, DERP region or
/// None, ms)`. `pong from air-blue (100.x) via 192.168.1.5:41641 in 3ms` or
/// `... via DERP(sfo) in 48ms`.
pub fn tailscale_ping(text: &str) -> Option<(Option<String>, Option<String>, f64)> {
    let line = text.lines().rev().find(|l| l.starts_with("pong from"))?;
    let via = line.split(" via ").nth(1)?;
    let (path, rest) = via.split_once(" in ")?;
    let ms = leading_number(rest)?;
    let ms = if rest.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.').starts_with("µs")
    {
        ms / 1000.0
    } else {
        ms
    };
    if let Some(region) = path.strip_prefix("DERP(").and_then(|r| r.strip_suffix(')')) {
        Some((None, Some(region.to_owned()), ms))
    } else {
        Some((Some(path.to_owned()), None, ms))
    }
}

/// `ping -c N HOST` on macOS or Linux: each reply's `time=` and the
/// transmitted and received counts.
pub fn ping_output(text: &str) -> RttSample {
    let mut sample = RttSample::default();
    for line in text.lines() {
        if let Some(i) = line.find("time=")
            && let Some(ms) = leading_number(&line[i + 5..])
        {
            sample.rtts_ms.push(ms);
        }
        if line.contains("packets transmitted") {
            let nums: Vec<u32> = line
                .split(',')
                .filter_map(|p| leading_number(p.trim()).map(|n| n as u32))
                .collect();
            if let [sent, received, ..] = nums[..] {
                sample.sent = sent;
                sample.received = received;
            }
        }
    }
    if sample.sent == 0 {
        sample.sent = sample.rtts_ms.len() as u32;
        sample.received = sample.rtts_ms.len() as u32;
    }
    sample
}

#[cfg(test)]
#[path = "parse_tests.rs"]
mod tests;
