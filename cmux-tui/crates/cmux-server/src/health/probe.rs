//! Probe facts for the health reducer (server.md 9.2). Each probe reads
//! once when called; the caller decides when (a probe event or the one-shot
//! deadline from [`super::HealthRole::wake_at_ms`]). Nothing here loops.
//!
//! The file-reading probes take their root directory, so tests run them
//! against a fixture tree.

use std::fs;
use std::path::Path;

use cmux_server_core::health::{DiskFacts, PowerFacts, PowerSource};

use crate::sys;

/// Free and total bytes of the filesystem holding `path` (or its nearest
/// existing ancestor).
pub fn disk(path: &Path) -> Option<DiskFacts> {
    let existing = path.ancestors().find(|p| p.exists())?;
    let (free_bytes, total_bytes) = sys::statvfs(existing).ok()?;
    Some(DiskFacts { free_bytes, total_bytes })
}

fn read_trim(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_owned())
}

/// Power source from `/sys/class/power_supply` (Linux). A machine with no
/// supply entries (a VM, most servers) is on AC without a battery. `None`
/// when the directory does not exist.
pub fn power(supply_dir: &Path) -> Option<PowerFacts> {
    let entries = fs::read_dir(supply_dir).ok()?;
    let mut mains_online = false;
    let mut discharging = false;
    let mut battery_percent: Option<u8> = None;
    for entry in entries.flatten() {
        let dir = entry.path();
        match read_trim(&dir.join("type")).as_deref() {
            Some("Mains" | "USB") => {
                mains_online |= read_trim(&dir.join("online")).as_deref() == Some("1");
            }
            Some("Battery") => {
                if read_trim(&dir.join("scope")).as_deref() == Some("Device") {
                    continue; // a mouse or keyboard battery
                }
                discharging |= read_trim(&dir.join("status")).as_deref() == Some("Discharging");
                if let Some(pct) =
                    read_trim(&dir.join("capacity")).and_then(|c| c.parse::<u8>().ok())
                {
                    let pct = pct.min(100);
                    battery_percent = Some(battery_percent.map_or(pct, |p: u8| p.min(pct)));
                }
            }
            _ => {}
        }
    }
    let source = if discharging && !mains_online { PowerSource::Battery } else { PowerSource::Ac };
    Some(PowerFacts { source, battery_percent })
}

/// Whether the kernel has a default route, from `<proc>/net/route` and
/// `<proc>/net/ipv6_route` (Linux). `None` when neither file is readable.
pub fn has_default_route(proc_dir: &Path) -> Option<bool> {
    let v4 = fs::read_to_string(proc_dir.join("net/route")).ok();
    let v6 = fs::read_to_string(proc_dir.join("net/ipv6_route")).ok();
    if v4.is_none() && v6.is_none() {
        return None;
    }
    let v4_default = v4.iter().flat_map(|t| t.lines().skip(1)).any(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        // Iface Destination Gateway Flags …; RTF_UP is 0x1.
        fields.len() > 3
            && fields[1] == "00000000"
            && u32::from_str_radix(fields[3], 16).is_ok_and(|f| f & 1 == 1)
    });
    let v6_default = v6.iter().flat_map(|t| t.lines()).any(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        // dest dest_len src src_len next_hop metric refcnt use flags iface
        fields.len() >= 10
            && fields[0] == "00000000000000000000000000000000"
            && fields[1] == "00"
            && fields[9] != "lo"
            && u32::from_str_radix(fields[8], 16).is_ok_and(|f| f & 1 == 1)
    });
    Some(v4_default || v6_default)
}
