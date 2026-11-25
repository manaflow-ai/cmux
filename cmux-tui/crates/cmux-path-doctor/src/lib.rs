//! The path doctor: reads the real link a phone and a Mac talk over, says in
//! one line what is wrong with it, and fixes what software can.
//!
//! The split is facts, then rules:
//!
//! - [`Observations`] is everything read about the link: the Wi-Fi radio
//!   (band, channel width, RSSI, noise, link rate), the route out (Wi-Fi or
//!   wired, and whether a wired port has link while Wi-Fi carries the
//!   traffic), AWDL, Tailscale peers (direct or through a DERP relay), RTT to
//!   the gateway idle and under load (bufferbloat), and the phone's own path
//!   flags (Low Data Mode, expensive). The Mac fills it with [`probe`]; the
//!   phone can fill the same struct from `NWPath` and its own pings and hand
//!   it over as JSON.
//! - [`diagnose`] turns observations into [`Finding`]s, worst first, each
//!   with a one-line action for the person. [`Report::headline`] is the line
//!   to show.
//!
//! The rules are pure, so the phone, the Mac and a test all give the same
//! advice for the same link.

pub mod parse;
pub mod probe;
mod rules;

use serde::{Deserialize, Serialize};

pub use rules::diagnose;

/// The Wi-Fi band a radio is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Band {
    #[serde(rename = "2.4ghz")]
    Ghz2_4,
    #[serde(rename = "5ghz")]
    Ghz5,
    #[serde(rename = "6ghz")]
    Ghz6,
}

impl Band {
    pub fn label(self) -> &'static str {
        match self {
            Band::Ghz2_4 => "2.4 GHz",
            Band::Ghz5 => "5 GHz",
            Band::Ghz6 => "6 GHz",
        }
    }

    /// The band of a Wi-Fi channel number when nothing else says it. 1-14 is
    /// 2.4 GHz; 36-177 is 5 GHz. 6 GHz channel numbers overlap both, so a
    /// caller that knows the frequency should use [`Band::from_mhz`].
    pub fn from_channel(channel: u32) -> Option<Band> {
        match channel {
            1..=14 => Some(Band::Ghz2_4),
            32..=177 => Some(Band::Ghz5),
            _ => None,
        }
    }

    pub fn from_mhz(mhz: u32) -> Option<Band> {
        match mhz {
            2400..=2500 => Some(Band::Ghz2_4),
            5150..=5895 => Some(Band::Ghz5),
            5925..=7125 => Some(Band::Ghz6),
            _ => None,
        }
    }
}

/// The Wi-Fi association of one interface.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct WifiLink {
    pub interface: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub band: Option<Band>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width_mhz: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rssi_dbm: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub noise_dbm: Option<i32>,
    /// The negotiated transmit rate, Mbit/s.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx_rate_mbps: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phy_mode: Option<String>,
}

/// How this device reaches the network.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Medium {
    Wifi,
    Wired,
    Cellular,
    Other,
}

/// The default route and what else could carry it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RouteInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interface: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gateway: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub medium: Option<Medium>,
    /// Wired interfaces that have link (cable in, carrier up) but do not
    /// carry the default route.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub idle_wired_with_link: Vec<String>,
}

/// One Tailscale peer as this device's node sees it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TailscalePeer {
    pub name: String,
    /// Its first tailnet address: what `tailscale ping` is given, since a
    /// host name can hold spaces or be ambiguous.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    pub online: bool,
    /// The direct endpoint (`ip:port`) when the path is direct.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub direct_addr: Option<String>,
    /// The DERP region the traffic goes through when it is not direct.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub derp_region: Option<String>,
    /// A `tailscale ping` round trip, ms.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ping_ms: Option<f64>,
}

impl TailscalePeer {
    pub fn is_direct(&self) -> bool {
        self.direct_addr.is_some()
    }
}

/// Round trips of one ping run, ms, with the loss.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RttSample {
    pub sent: u32,
    pub received: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rtts_ms: Vec<f64>,
}

impl RttSample {
    pub fn loss_pct(&self) -> f64 {
        if self.sent == 0 {
            return 0.0;
        }
        100.0 * f64::from(self.sent.saturating_sub(self.received)) / f64::from(self.sent)
    }

    /// The `q` quantile (0..=1) of the round trips, nearest rank.
    pub fn quantile(&self, q: f64) -> Option<f64> {
        quantile(&self.rtts_ms, q)
    }
}

/// The nearest-rank quantile of `values`.
pub fn quantile(values: &[f64], q: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = (q.clamp(0.0, 1.0) * sorted.len() as f64).ceil() as usize;
    Some(sorted[rank.saturating_sub(1).min(sorted.len() - 1)])
}

/// The phone's own path flags (`NWPath`), when the phone reports.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PhonePath {
    /// Low Data Mode (`NWPath.isConstrained`).
    #[serde(default)]
    pub constrained: bool,
    /// Cellular or a personal hotspot (`NWPath.isExpensive`).
    #[serde(default)]
    pub expensive: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub medium: Option<Medium>,
    /// The phone and the Mac are on the same network (the phone saw the
    /// Mac's LAN address answer).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub same_lan_as_mac: Option<bool>,
}

/// Everything read about the link. Every field is optional: a probe that
/// could not run leaves its field empty and the rules skip it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Observations {
    /// Which device this was read on ("mac", "phone", a host name).
    #[serde(default)]
    pub host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wifi: Option<WifiLink>,
    #[serde(default)]
    pub route: RouteInfo,
    /// AWDL (AirDrop, Sidecar, Universal Control) is up and hopping channels.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub awdl_active: Option<bool>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tailscale_peers: Vec<TailscalePeer>,
    /// Pings to the default gateway with the link idle.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gateway_idle: Option<RttSample>,
    /// Pings to the default gateway while a bulk download and upload run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gateway_loaded: Option<RttSample>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phone: Option<PhonePath>,
    /// Probes that could not run, and why (no Wi-Fi, no tailscale CLI).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Ok,
    Info,
    Warn,
    Bad,
}

/// One thing the doctor found, with what to do about it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Finding {
    pub severity: Severity,
    /// A stable id (`wifi_2_4ghz`, `tailscale_derp`, `bufferbloat`).
    pub code: String,
    /// The one line for the person: what is wrong and what to change.
    pub line: String,
    /// What the doctor already did about it, if anything.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fixed: Option<String>,
}

/// A whole reading: the facts and the findings, worst first.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub observations: Observations,
    pub findings: Vec<Finding>,
}

impl Report {
    pub fn new(observations: Observations) -> Self {
        let findings = diagnose(&observations);
        Self { observations, findings }
    }

    /// The one line to show: the worst finding, or a summary of a good link.
    pub fn headline(&self) -> String {
        match self.findings.first() {
            Some(f) if f.severity >= Severity::Warn => f.line.clone(),
            _ => rules::good_summary(&self.observations),
        }
    }
}
