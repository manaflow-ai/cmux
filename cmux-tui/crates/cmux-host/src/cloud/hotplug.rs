//! Hot-added memory and vCPUs online at once, not when udev gets to them (RFD 0133, "grows a
//! starved machine within 5 s").
//!
//! The Cloud grows a machine in place (Freestyle `resize`): the hypervisor hot-adds memory and
//! vCPUs, and the kernel leaves them offline. On the Ubuntu image the udev rule
//! `40-vm-hotadd.rules` onlines them, one 128 MiB memory block and one vCPU per event, from
//! userspace. On a machine that grows because its CPU is pegged, udev's workers queue behind the
//! very load the grow is for: production read-back 46176958820 (cmux-platform, 2026-11-28) saw a
//! 2 -> 8 vCPU grow come online one 0.1-0.2 GiB block at a time over 55 s, with the vCPUs, queued
//! behind the memory events, arriving only after the last block (runs 7, 8, 19; 89-91 s to fit). An
//! idle-enough machine took the same grow in under 2 s.
//!
//! So on every pressure probe the role:
//! - sets `memory/auto_online_blocks` to `online` when it reads `offline`: the kernel then onlines a
//!   new block inside the hot-add itself, with no udev event to wait for;
//! - onlines each present vCPU still offline (the kernel has no such switch for CPUs).
//!
//! Both are a read of one small sysfs file while nothing is offline. A write that fails (not root,
//! a kernel without the file) is logged once and changes nothing.

use std::path::Path;

/// What one pass did, for the role's log line.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Onlined {
    /// `auto_online_blocks` was `offline` and is now `online`.
    pub memory_auto_online: bool,
    /// vCPUs this pass brought online.
    pub cpus: Vec<u32>,
    /// Writes that failed (path and error), so the caller logs them once.
    pub failed: Vec<String>,
}

const AUTO_ONLINE: &str = "sys/devices/system/memory/auto_online_blocks";
const CPU_OFFLINE: &str = "sys/devices/system/cpu/offline";

/// The kernel's CPU list syntax (`2-7,9`, or empty) into CPU numbers; a part that does not parse
/// is skipped.
pub fn parse_cpu_list(list: &str) -> Vec<u32> {
    let mut out = Vec::new();
    for part in list.trim().split(',').map(str::trim).filter(|p| !p.is_empty()) {
        match part.split_once('-') {
            Some((a, b)) => {
                if let (Ok(a), Ok(b)) = (a.trim().parse::<u32>(), b.trim().parse::<u32>()) {
                    // Bounded: a machine has at most a few hundred CPUs.
                    out.extend((a..=b.min(a.saturating_add(4096))).take(4097));
                }
            }
            None => {
                if let Ok(n) = part.parse() {
                    out.push(n);
                }
            }
        }
    }
    out
}

/// One pass under `root` (`/` in production).
pub fn online_hot_added(root: &Path) -> Onlined {
    let mut done = Onlined::default();
    let auto = root.join(AUTO_ONLINE);
    if let Ok(state) = std::fs::read_to_string(&auto)
        && state.trim() == "offline"
    {
        match std::fs::write(&auto, "online") {
            Ok(()) => done.memory_auto_online = true,
            Err(e) => done.failed.push(format!("{}: {e}", auto.display())),
        }
    }
    // `offline` lists every possible CPU not online, the ones not present (no `cpuN` directory, or
    // no `online` file) included: only those that can be onlined are tried.
    let offline = std::fs::read_to_string(root.join(CPU_OFFLINE)).unwrap_or_default();
    for cpu in parse_cpu_list(&offline) {
        let file = root.join(format!("sys/devices/system/cpu/cpu{cpu}/online"));
        match std::fs::read_to_string(&file) {
            Ok(v) if v.trim() == "0" => match std::fs::write(&file, "1") {
                Ok(()) => done.cpus.push(cpu),
                Err(e) => done.failed.push(format!("{}: {e}", file.display())),
            },
            _ => {}
        }
    }
    done
}
