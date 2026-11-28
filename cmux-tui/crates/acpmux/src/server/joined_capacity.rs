//! A joined machine's free capacity, as its team's placement reads it (RFD 0004 step 3). The
//! joined mesh relay sends it every [`EVERY`] (`mesh_relay.rs` `capacity_reports`) to cmux-platform
//! `POST /v1/machines/joined/heartbeat` with the machine's own `cmm_` credential; the hub keys it by
//! that machine's id and drops it two minutes after the last one, so a box that stops sending
//! stops being offered.
//!
//! What it says: the machine's cores and installed memory as the most one session there can have,
//! the cores the 1-minute load leaves free, the memory the pressure meter reads as available (none
//! before its first sample: an unknown is not free), the free disk of acpmux's home and the live
//! sessions. Only Linux and macOS on arm64 or x86_64 report: the contract names no other.

use super::peer_status;
use crate::mesh::{Capacity, CapacityLimits};
use crate::server::Hub;
use std::time::Duration;

/// The time between two reports: a third of the two minutes the hub keeps one, so one lost
/// report never drops the machine from placement.
pub(crate) const EVERY: Duration = Duration::from_secs(40);

/// The wait after the hub refused a report (an older hub with no such route, a registry that is
/// off, a credential it does not take): a refusal repeats, so it is asked again rarely.
pub(crate) const REFUSED_RETRY: Duration = Duration::from_secs(10 * 60);

const GIB: f64 = (1u64 << 30) as f64;

/// One reading of this machine.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Reading {
    pub os: &'static str,
    pub arch: &'static str,
    pub cpus: usize,
    pub ram_total: u64,
    /// The share of RAM available (the pressure meter's), if it has a sample.
    pub ram_free_fraction: Option<f64>,
    pub disk_free: Option<u64>,
    pub load1: Option<f64>,
    pub sessions: usize,
}

/// The report a reading makes, or none on a platform the contract does not name.
pub(crate) fn capacity_from(host: &str, r: &Reading) -> Option<Capacity> {
    let os = match r.os {
        "linux" | "macos" => r.os,
        _ => return None,
    };
    let arch = match r.arch {
        "aarch64" | "arm64" => "arm64",
        "x86_64" => "x86_64",
        _ => return None,
    };
    let cpus = r.cpus.max(1) as f64;
    let load = r.load1.filter(|l| l.is_finite() && *l >= 0.0).unwrap_or(0.0);
    let mem = r.ram_total as f64 / GIB;
    let fraction = r.ram_free_fraction.filter(|f| f.is_finite()).unwrap_or(0.0).clamp(0.0, 1.0);
    // The hub takes 1 to 128 characters; a longer name is cut on a character boundary.
    let host_id: String = host.chars().take(128).collect();
    Some(Capacity {
        host_id: if host_id.is_empty() { "joined".into() } else { host_id },
        region: "joined".into(),
        capabilities: CapacityLimits {
            memory_pause: false,
            fork: false,
            gpu: false,
            arch: arch.into(),
            os: os.into(),
            max_vcpu: cpus,
            max_mem_gib: mem,
        },
        free_vcpu: (cpus - load).clamp(0.0, cpus),
        free_mem_gib: mem * fraction,
        free_disk_gib: r.disk_free.unwrap_or(0) as f64 / GIB,
        sessions_running: r.sessions as u64,
        load,
        state: "ready".into(),
    })
}

/// This machine now, as `host` names it; none where it cannot say (another platform, no RAM size).
pub(crate) async fn capacity_now(hub: &Hub, host: &str) -> Option<Capacity> {
    let pressure = hub.host_pressure_status().await;
    let reading = Reading {
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        cpus: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        ram_total: peer_status::ram_total()?,
        ram_free_fraction: pressure
            .get("available_ram_fraction")
            .and_then(serde_json::Value::as_f64),
        disk_free: crate::config::home()
            .ancestors()
            .find_map(peer_status::disk)
            .map(|(free, _)| free),
        load1: peer_status::load().map(|l| l[0]),
        sessions: hub.live_session_count(),
    };
    capacity_from(host, &reading)
}

#[cfg(test)]
#[path = "joined_capacity_tests.rs"]
mod tests;
