//! Observations to findings. Every threshold is here, with why.

use crate::{Band, Finding, Medium, Observations, Severity};

/// Below this the radio drops to low rates and retries; Apple's own guidance
/// for roaming and voice is about -67 dBm.
const RSSI_FAIR_DBM: i32 = -67;
const RSSI_BAD_DBM: i32 = -75;
/// Signal over noise below this means retransmits and jitter.
const SNR_BAD_DB: i32 = 20;
/// A negotiated rate this low is a weak or legacy link.
const RATE_LOW_MBPS: f64 = 100.0;
/// Extra p95 round trip under load: up to 30 ms is a well-queued link, past
/// 100 ms every keystroke behind a download waits that long.
const BLOAT_WARN_MS: f64 = 30.0;
const BLOAT_BAD_MS: f64 = 100.0;
/// The gateway is one hop away: a p95 past this on an idle link is the radio.
const GATEWAY_SLOW_P95_MS: f64 = 20.0;
const LOSS_WARN_PCT: f64 = 1.0;

fn finding(severity: Severity, code: &str, line: String) -> Finding {
    Finding { severity, code: code.to_owned(), line, fixed: None }
}

/// Findings for `obs`, worst first. A link with nothing wrong gets one `ok`
/// finding.
pub fn diagnose(obs: &Observations) -> Vec<Finding> {
    let mut out = Vec::new();
    wired(obs, &mut out);
    wifi(obs, &mut out);
    awdl(obs, &mut out);
    tailscale(obs, &mut out);
    gateway(obs, &mut out);
    phone(obs, &mut out);
    if out.is_empty() {
        out.push(finding(Severity::Ok, "ok", good_summary(obs)));
    }
    // Stable: equal severities keep rule order (the physical layer first).
    out.sort_by_key(|f| std::cmp::Reverse(f.severity));
    out
}

fn wired(obs: &Observations, out: &mut Vec<Finding>) {
    if obs.route.medium == Some(Medium::Wifi) && !obs.route.idle_wired_with_link.is_empty() {
        let port = obs.route.idle_wired_with_link.join(", ");
        out.push(finding(
            Severity::Warn,
            "wired_unused",
            format!(
                "A cable is plugged in ({port}) but traffic goes over Wi-Fi: move the wired service above Wi-Fi in System Settings > Network > ... > Set Service Order"
            ),
        ));
    }
}

fn wifi(obs: &Observations, out: &mut Vec<Finding>) {
    let Some(w) = &obs.wifi else { return };
    if obs.route.medium.is_some_and(|m| m != Medium::Wifi) {
        // Wi-Fi is associated but not carrying traffic: its radio does not matter.
        return;
    }
    if w.band == Some(Band::Ghz2_4) {
        out.push(finding(
            Severity::Warn,
            "wifi_2_4ghz",
            format!(
                "Wi-Fi is on 2.4 GHz{}: join the 5 or 6 GHz network (or split the bands on the router); 2.4 GHz is crowded and slow",
                w.channel.map(|c| format!(" (channel {c})")).unwrap_or_default()
            ),
        ));
    }
    if let Some(rssi) = w.rssi_dbm {
        if rssi < RSSI_BAD_DBM {
            out.push(finding(
                Severity::Bad,
                "wifi_weak",
                format!("Wi-Fi signal is weak ({rssi} dBm): move closer to the router or add an access point or a cable"),
            ));
        } else if rssi < RSSI_FAIR_DBM {
            out.push(finding(
                Severity::Warn,
                "wifi_fair",
                format!("Wi-Fi signal is fair ({rssi} dBm): closer to the router, or a mesh node nearby, cuts retries"),
            ));
        }
        if let Some(noise) = w.noise_dbm {
            let snr = rssi - noise;
            if snr < SNR_BAD_DB {
                out.push(finding(
                    Severity::Warn,
                    "wifi_noisy",
                    format!("Wi-Fi is noisy (signal {rssi} dBm, noise {noise} dBm, {snr} dB apart): change the router's channel or band"),
                ));
            }
        }
    }
    if let Some(rate) = w.tx_rate_mbps
        && rate < RATE_LOW_MBPS
    {
        out.push(finding(
            Severity::Warn,
            "wifi_slow_rate",
            format!(
                "Wi-Fi link rate is only {rate:.0} Mbit/s: a weak signal or an old access point"
            ),
        ));
    }
}

fn awdl(obs: &Observations, out: &mut Vec<Finding>) {
    if obs.awdl_active == Some(true) && obs.route.medium == Some(Medium::Wifi) {
        out.push(finding(
            Severity::Info,
            "awdl_active",
            "AWDL is up (AirDrop, Sidecar or Universal Control): it pulls the Wi-Fi radio off channel and adds latency spikes; turn AirDrop to Receiving Off while you work remotely".to_owned(),
        ));
    }
}

/// Past this many relayed peers, one finding names the count and the closest
/// few instead of a line each.
const RELAYED_LISTED: usize = 3;

fn tailscale(obs: &Observations, out: &mut Vec<Finding>) {
    let mut relayed: Vec<_> =
        obs.tailscale_peers.iter().filter(|p| p.online && !p.is_direct()).collect();
    if relayed.len() > RELAYED_LISTED {
        // Measured peers first, fastest first: those are the ones in reach.
        relayed.sort_by(|a, b| {
            let key = |p: &crate::TailscalePeer| p.ping_ms.unwrap_or(f64::INFINITY);
            key(a).total_cmp(&key(b))
        });
        let online = obs.tailscale_peers.iter().filter(|p| p.online).count();
        let named: Vec<String> = relayed
            .iter()
            .take(RELAYED_LISTED)
            .map(|p| match (&p.derp_region, p.ping_ms) {
                (Some(r), Some(ms)) => format!("{} (via {r}, {ms:.0} ms)", p.name),
                (Some(r), None) => format!("{} (via {r})", p.name),
                _ => p.name.clone(),
            })
            .collect();
        out.push(finding(
            Severity::Warn,
            "tailscale_derp",
            format!(
                "Tailscale reaches {} of {online} online peers through a relay, not direct, e.g. {}: allow UDP out (and UPnP/NAT-PMP) on the router",
                relayed.len(),
                named.join(", ")
            ),
        ));
        return;
    }
    for peer in relayed {
        let via = peer.derp_region.as_deref().unwrap_or("a DERP relay");
        let ms = peer.ping_ms.map(|m| format!(", {m:.0} ms")).unwrap_or_default();
        out.push(finding(
            Severity::Warn,
            "tailscale_derp",
            format!(
                "Tailscale to {} goes through relay {via}{ms}, not direct: allow UDP out (and UPnP/NAT-PMP) on the router, or put both on the same network",
                peer.name
            ),
        ));
    }
}

fn gateway(obs: &Observations, out: &mut Vec<Finding>) {
    let idle_p50 = obs.gateway_idle.as_ref().and_then(|s| s.quantile(0.5));
    if let Some(idle) = &obs.gateway_idle {
        let loss = idle.loss_pct();
        if idle.sent > 0 && loss >= LOSS_WARN_PCT {
            out.push(finding(
                Severity::Bad,
                "gateway_loss",
                format!("{loss:.0}% of pings to the router are lost: the local link drops packets (signal, interference or a bad cable)"),
            ));
        }
        if let Some(p95) = idle.quantile(0.95)
            && p95 > GATEWAY_SLOW_P95_MS
            && obs.route.medium == Some(Medium::Wifi)
        {
            out.push(finding(
                Severity::Warn,
                "gateway_jitter",
                format!("Round trips to the router reach {p95:.0} ms (p95) with the link idle: the Wi-Fi is congested or the signal is weak"),
            ));
        }
    }
    if let (Some(idle_p50), Some(loaded_p95)) =
        (idle_p50, obs.gateway_loaded.as_ref().and_then(|s| s.quantile(0.95)))
    {
        let extra = loaded_p95 - idle_p50;
        if extra > BLOAT_WARN_MS {
            let severity = if extra > BLOAT_BAD_MS { Severity::Bad } else { Severity::Warn };
            out.push(finding(
                severity,
                "bufferbloat",
                format!(
                    "The router buffers under load (+{extra:.0} ms when something downloads): turn on Smart Queue / SQM (fq_codel or cake) on the router"
                ),
            ));
        }
    }
}

fn phone(obs: &Observations, out: &mut Vec<Finding>) {
    let Some(p) = &obs.phone else { return };
    if p.constrained {
        out.push(finding(
            Severity::Warn,
            "low_data_mode",
            "Low Data Mode is on for this network: iOS defers background traffic and can stall the link; turn it off in Settings > Wi-Fi > (i)".to_owned(),
        ));
    }
    if p.same_lan_as_mac == Some(false) && p.medium == Some(Medium::Wifi) {
        out.push(finding(
            Severity::Info,
            "phone_other_network",
            "The phone and the Mac are on different networks: join the Mac's Wi-Fi for a direct link".to_owned(),
        ));
    }
}

/// One line describing a link the rules found nothing wrong with.
pub(crate) fn good_summary(obs: &Observations) -> String {
    let mut parts: Vec<String> = Vec::new();
    match obs.route.medium {
        Some(Medium::Wired) => parts.push("wired".to_owned()),
        Some(Medium::Cellular) => parts.push("cellular".to_owned()),
        _ => {}
    }
    if obs.route.medium != Some(Medium::Wired)
        && let Some(w) = &obs.wifi
    {
        if let Some(b) = w.band {
            parts.push(b.label().to_owned());
        }
        if let Some(r) = w.rssi_dbm {
            parts.push(format!("{r} dBm"));
        }
        if let Some(rate) = w.tx_rate_mbps {
            parts.push(format!("{rate:.0} Mbit/s"));
        }
    }
    let direct = obs.tailscale_peers.iter().filter(|p| p.online && p.is_direct()).count();
    let online = obs.tailscale_peers.iter().filter(|p| p.online).count();
    if online > 0 {
        parts.push(format!("Tailscale direct to {direct}/{online} peers"));
    }
    if let (Some(i), Some(l)) = (
        obs.gateway_idle.as_ref().and_then(|s| s.quantile(0.5)),
        obs.gateway_loaded.as_ref().and_then(|s| s.quantile(0.95)),
    ) {
        parts.push(format!("+{:.0} ms under load", (l - i).max(0.0)));
    } else if let Some(p) = obs.gateway_idle.as_ref().and_then(|s| s.quantile(0.95)) {
        parts.push(format!("router p95 {p:.1} ms"));
    }
    if parts.is_empty() {
        "Link looks fine".to_owned()
    } else {
        format!("Link looks good: {}", parts.join(", "))
    }
}

#[cfg(test)]
#[path = "rules_tests.rs"]
mod tests;
