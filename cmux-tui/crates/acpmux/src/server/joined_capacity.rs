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
        ram_free_fraction: pressure["available_ram_fraction"].as_f64(),
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
mod tests {
    use super::*;

    fn studio() -> Reading {
        Reading {
            os: "macos",
            arch: "aarch64",
            cpus: 12,
            ram_total: 64 << 30,
            ram_free_fraction: Some(0.5),
            disk_free: Some(300 << 30),
            load1: Some(2.5),
            sessions: 3,
        }
    }

    #[test]
    fn a_reading_reports_what_is_left_free() {
        let c = capacity_from("studio", &studio()).unwrap();
        assert_eq!(c.host_id, "studio");
        assert_eq!(c.region, "joined");
        assert_eq!(c.state, "ready");
        assert_eq!(c.capabilities.arch, "arm64");
        assert_eq!(c.capabilities.os, "macos");
        assert_eq!(c.capabilities.max_vcpu, 12.0);
        assert_eq!(c.capabilities.max_mem_gib, 64.0);
        assert_eq!(c.free_vcpu, 9.5);
        assert_eq!(c.free_mem_gib, 32.0);
        assert_eq!(c.free_disk_gib, 300.0);
        assert_eq!(c.sessions_running, 3);
        assert_eq!(c.load, 2.5);
    }

    #[test]
    fn an_unknown_or_overloaded_reading_is_never_more_free_than_the_box() {
        let busy = Reading { load1: Some(40.0), ram_free_fraction: Some(1.7), ..studio() };
        let c = capacity_from("studio", &busy).unwrap();
        assert_eq!(c.free_vcpu, 0.0);
        assert_eq!(c.free_mem_gib, 64.0);
        let unknown = Reading { load1: None, ram_free_fraction: None, disk_free: None, ..studio() };
        let c = capacity_from("studio", &unknown).unwrap();
        assert_eq!(c.free_vcpu, 12.0);
        assert_eq!(c.free_mem_gib, 0.0, "no meter sample is no free memory");
        assert_eq!(c.free_disk_gib, 0.0);
    }

    #[test]
    fn only_the_platforms_the_contract_names_report() {
        assert!(capacity_from("pc", &Reading { os: "windows", ..studio() }).is_none());
        assert!(capacity_from("pi", &Reading { arch: "arm", ..studio() }).is_none());
        let linux = Reading { os: "linux", arch: "x86_64", ..studio() };
        assert_eq!(capacity_from("box", &linux).unwrap().capabilities.arch, "x86_64");
        let long = "m".repeat(300);
        assert_eq!(capacity_from(&long, &studio()).unwrap().host_id.len(), 128);
        assert_eq!(capacity_from("", &studio()).unwrap().host_id, "joined");
    }
}
