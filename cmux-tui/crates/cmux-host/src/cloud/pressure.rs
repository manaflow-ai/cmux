//! The machine's pressure, as the Cloud's sizer reads it (`activity.pressure`; cmux-platform
//! `AutoSize.ts` `readReportedPressure`, docs/machine-autosize.md, RFD 0133).
//!
//! Every [`PROBE_INTERVAL_MS`] the role reads three small kernel files: `/proc/meminfo`
//! (MemAvailable against MemTotal), `/proc/vmstat` (`oom_kill`) and `/proc/stat` (`procs_running`
//! and the CPU count). The block it reports names only what is short:
//! - `"memory": "low"` while less than [`MEMORY_LOW_SHARE`] of memory is available;
//! - `"cpu": "pegged"` while more tasks are runnable than the machine has vCPUs, on
//!   [`CPU_PROBES`] probes in a row (held 2 s; clear again after as many below);
//! - `"oom_rise_at"` (Unix ms) when the kernel's OOM kill count rose.
//!
//! A report goes only when the block changes, so a machine under steady pressure sends one; a
//! block that names something newly short goes at once, past the report's 10 s floor
//! (`Reporter::trigger_now`). It only wakes the sizer: the sizer then samples the machine itself
//! and decides, so the block carries no numbers. Before this, the sizer looked once a minute
//! however starved the machine was.
//!
//! Timing (RFD 0133, "grows a starved machine within 5 s"): memory under its line is seen within
//! one probe (1 s) and a pegged CPU within 2 s, and the report leaves on that probe. At the old
//! 5 s probe with two CPU probes and the 10 s floor, the report alone took up to 15 s (memory) and
//! 20 s (CPU) before the Cloud heard of it (development read-back, 2026-11-26: first grow 17-46 s
//! after the load started).

use std::path::Path;

use serde_json::{Map, Value, json};

/// How often the role reads the files: three small `/proc` files a second, and a report only
/// when the block changes, so the cost stays flat.
pub const PROBE_INTERVAL_MS: u64 = 1_000;
/// Memory counts as low under this share available (the platform's memory line, 10%).
pub const MEMORY_LOW_SHARE: f64 = 0.10;
/// Probes in a row a CPU reading must hold to change state (2 s at [`PROBE_INTERVAL_MS`]), so one
/// burst does not wake the sizer.
pub const CPU_PROBES: u8 = 3;

/// One read of the three files.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Reading {
    pub mem_total_kib: u64,
    pub mem_available_kib: u64,
    /// The kernel's OOM kill count since boot.
    pub oom_kills: u64,
    /// Runnable tasks, the probe's own thread excluded.
    pub run_queue: u64,
    pub cpus: u64,
}

fn kib(meminfo: &str, key: &str) -> Option<u64> {
    meminfo
        .lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix(':'))
        .and_then(|rest| rest.split_whitespace().next()?.parse().ok())
}

/// The three files' text into a reading, or None when one does not parse.
pub fn parse(meminfo: &str, vmstat: &str, stat: &str) -> Option<Reading> {
    let mem_total_kib = kib(meminfo, "MemTotal").filter(|t| *t > 0)?;
    let mem_available_kib = kib(meminfo, "MemAvailable")?;
    // An older kernel without the counter: no OOM rise is ever read.
    let oom_kills =
        vmstat.lines().find_map(|l| l.strip_prefix("oom_kill ")?.trim().parse().ok()).unwrap_or(0);
    let running: u64 =
        stat.lines().find_map(|l| l.strip_prefix("procs_running ")?.trim().parse().ok())?;
    let cpus = stat
        .lines()
        .filter(|l| l.starts_with("cpu") && l.as_bytes().get(3).is_some_and(u8::is_ascii_digit))
        .count() as u64;
    if cpus == 0 {
        return None;
    }
    Some(Reading {
        mem_total_kib,
        mem_available_kib,
        oom_kills,
        run_queue: running.saturating_sub(1),
        cpus,
    })
}

/// One read under `root` (`/` in production), or None when a file does not read.
pub fn read(root: &Path) -> Option<Reading> {
    let file = |p: &str| std::fs::read_to_string(root.join(p)).ok();
    parse(&file("proc/meminfo")?, &file("proc/vmstat").unwrap_or_default(), &file("proc/stat")?)
}

/// The pressure as reported: what is short, and when the OOM count last rose.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Pressure {
    pub memory_low: bool,
    pub cpu_pegged: bool,
    pub oom_rise_at: Option<u64>,
}

impl Pressure {
    /// `activity.pressure`, or None while nothing is short and no OOM kill was seen.
    pub fn to_json(&self) -> Option<Value> {
        let mut out = Map::new();
        if self.memory_low {
            out.insert("memory".to_owned(), json!("low"));
        }
        if self.cpu_pegged {
            out.insert("cpu".to_owned(), json!("pegged"));
        }
        if let Some(at) = self.oom_rise_at {
            out.insert("oom_rise_at".to_owned(), json!(at));
        }
        (!out.is_empty()).then_some(Value::Object(out))
    }
}

/// Whether `now` names something `before` did not (a key newly short, or a newer OOM rise): such
/// a block goes at once; a block that only clears waits for the report's floor.
pub fn rose(before: Option<&Value>, now: Option<&Value>) -> bool {
    let Some(Value::Object(now)) = now else { return false };
    let before = before.and_then(Value::as_object);
    now.iter().any(|(k, v)| before.and_then(|b| b.get(k)) != Some(v))
}

/// The probe's memory between reads: the OOM count and the CPU streak.
#[derive(Clone, Debug, Default)]
pub struct Tracker {
    oom_kills: Option<u64>,
    /// Probes in a row whose CPU reading disagreed with the reported state.
    cpu_streak: u8,
    pressure: Pressure,
}

impl Tracker {
    /// One reading at `wall_ms`: the pressure as it now stands. The first reading sets the OOM
    /// baseline (kills before the probe started are not a rise).
    pub fn observe(&mut self, r: &Reading, wall_ms: u64) -> &Pressure {
        let share = r.mem_available_kib as f64 / r.mem_total_kib as f64;
        self.pressure.memory_low = share < MEMORY_LOW_SHARE;
        if self.oom_kills.is_some_and(|before| r.oom_kills > before) {
            self.pressure.oom_rise_at = Some(wall_ms);
        }
        self.oom_kills = Some(r.oom_kills);
        let pegged = r.run_queue > r.cpus;
        if pegged == self.pressure.cpu_pegged {
            self.cpu_streak = 0;
        } else {
            self.cpu_streak = self.cpu_streak.saturating_add(1);
            if self.cpu_streak >= CPU_PROBES {
                self.pressure.cpu_pegged = pegged;
                self.cpu_streak = 0;
            }
        }
        &self.pressure
    }
}
