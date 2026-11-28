//! `acpmux machine load --watch` (`host load --watch`): the guest-side pressure push of
//! cmuxterm-hq RFD 0133 ("What to build next" 3). It samples this machine once a second
//! (a few file reads and one `statvfs`, about 150 µs) and prints one JSON line when a
//! line is crossed, instead of the server asking once a minute:
//!
//! - memory available under 25% (`warn`) and under 10% (`grow`) (`/proc/meminfo`);
//! - any rise of the OOM-kill count (`/proc/vmstat` `oom_kill`);
//! - memory stall: direct reclaim (an `allocstall_*` rise) or refaults of at least
//!   10 MiB/s in 3 of the last 10 samples (`stall`), clear after 30 calm samples (`ok`).
//!   This is PSI memory `some avg10 >= 30%` read from the counters every kernel keeps
//!   (cmuxterm-hq RFD 0182 B1): the guest is short of memory before MemAvailable says so,
//!   and with no swap the thrash shows as refaults, then the freeze;
//! - CPU at least 90% busy with a run queue over the vCPU count, held 5 minutes
//!   (`/proc/stat`: the aggregate `cpu` line between two samples, `procs_running`);
//! - disk under 10% or 2 GiB free (`statvfs` of `$HOME`).
//!
//! Edge-triggered: a line prints when its state changes, never while it holds. Each
//! line clears only past a margin (memory 5 points above it, disk 2 points and
//! 512 MiB above it, CPU after a minute below it), so a value that sits on a line does
//! not print every second. It reads no `/proc/pressure` (Freestyle guests run with PSI
//! off, and memory PSI read 0 until the kill in a guest with no swap) and needs no swap.
//!
//! [`Watch::step`] is the whole decision and is pure; [`run`] only reads and prints.

use serde::Serialize;
use std::time::Duration;

/// The lines, as `acpmux machine load --watch` flags. Defaults are the RFD's table.
#[derive(Debug, Clone, Copy, PartialEq, clap::Args)]
pub struct Lines {
    /// Memory available under this share of the total: a `warn` event.
    #[arg(long, default_value_t = MEM_WARN)]
    pub mem_warn: f64,
    /// Memory available under this share of the total: a `grow` event.
    #[arg(long, default_value_t = MEM_GROW)]
    pub mem_grow: f64,
    /// CPU busy share at or over which, with a run queue over the vCPU count, CPU is saturated.
    #[arg(long, default_value_t = CPU_BUSY)]
    pub cpu_busy: f64,
    /// Seconds CPU must stay saturated before the `saturated` event.
    #[arg(long, default_value_t = CPU_HOLD_SECS)]
    pub cpu_hold_secs: u64,
    /// Free disk under this share of the disk: a `low` event.
    #[arg(long, default_value_t = DISK_FRACTION)]
    pub disk_fraction: f64,
    /// Free disk under this many bytes: a `low` event.
    #[arg(long, default_value_t = DISK_BYTES)]
    pub disk_bytes: u64,
    /// Stalled samples, of the last [`STALL_WINDOW`], that make a memory `stall`.
    #[arg(long, default_value_t = STALL_SAMPLES)]
    pub stall_samples: u32,
    /// Refaulted pages per sample that count as a stalled sample.
    #[arg(long, default_value_t = REFAULT_PAGES)]
    pub refault_pages: u64,
    /// Milliseconds between samples.
    #[arg(long, default_value_t = INTERVAL_MS)]
    pub interval_ms: u64,
}

pub const MEM_WARN: f64 = 0.25;
pub const MEM_GROW: f64 = 0.10;
pub const CPU_BUSY: f64 = 0.90;
pub const CPU_HOLD_SECS: u64 = 300;
pub const DISK_FRACTION: f64 = 0.10;
pub const DISK_BYTES: u64 = 2 << 30;
pub const INTERVAL_MS: u64 = 1000;
/// The memory-stall window, in samples (PSI's avg10 at one sample a second).
pub const STALL_WINDOW: u32 = 10;
pub const STALL_SAMPLES: u32 = 3;
/// 10 MiB of 4 KiB pages read back in one sample.
pub const REFAULT_PAGES: u64 = 2560;
/// A memory stall clears after this many calm samples in a row.
pub const STALL_CLEAR_SAMPLES: u32 = 30;
/// A memory level clears this far above its line.
pub const MEM_MARGIN: f64 = 0.05;
/// Low disk clears this far above both of its lines.
pub const DISK_MARGIN_FRACTION: f64 = 0.02;
pub const DISK_MARGIN_BYTES: u64 = 512 << 20;
/// Saturated CPU clears after this long below its line.
pub const CPU_CLEAR_SECS: u64 = 60;
/// A fraction on a clear line counts as past it: `0.25 + 0.05` is `0.30000000000000004` in f64.
const AT_LINE: f64 = 1e-9;

impl Default for Lines {
    fn default() -> Self {
        Self {
            mem_warn: MEM_WARN,
            mem_grow: MEM_GROW,
            cpu_busy: CPU_BUSY,
            cpu_hold_secs: CPU_HOLD_SECS,
            disk_fraction: DISK_FRACTION,
            disk_bytes: DISK_BYTES,
            stall_samples: STALL_SAMPLES,
            refault_pages: REFAULT_PAGES,
            interval_ms: INTERVAL_MS,
        }
    }
}

/// One sample. A field that could not be read is `None` and leaves its signal as it was.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Sample {
    /// Milliseconds since the epoch.
    pub at: u64,
    pub mem_available_fraction: Option<f64>,
    pub oom_kills: Option<u64>,
    /// `/proc/vmstat`'s reclaim counters since boot.
    pub reclaim: Option<crate::host_pressure::Reclaim>,
    /// Busy share since the previous sample.
    pub cpu_busy: Option<f64>,
    /// Runnable tasks now (`procs_running`).
    pub run_queue: Option<u64>,
    pub vcpus: Option<u32>,
    pub disk_free_bytes: Option<u64>,
    pub disk_free_fraction: Option<f64>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MemLevel {
    #[default]
    Ok,
    Warn,
    Grow,
}

/// One printed line.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "signal", rename_all = "camelCase")]
pub enum Event {
    #[serde(rename_all = "camelCase")]
    Memory { at: u64, state: MemLevel, from: MemLevel, mem_available_fraction: f64 },
    #[serde(rename_all = "camelCase")]
    OomKill { at: u64, state: &'static str, oom_kills: u64, rise: u64 },
    #[serde(rename_all = "camelCase")]
    Reclaim {
        at: u64,
        /// `stall` or `ok`.
        state: &'static str,
        /// Stalled samples among the last `windowSamples`.
        stalled_samples: u32,
        window_samples: u32,
        /// Allocation stalls and refaulted pages in this sample.
        alloc_stalls: u64,
        refaults: u64,
    },
    #[serde(rename_all = "camelCase")]
    Cpu {
        at: u64,
        /// `saturated` or `ok`.
        state: &'static str,
        cpu_busy: f64,
        run_queue: u64,
        vcpus: u32,
        /// How long the state before this one held, in seconds.
        held_secs: u64,
    },
    #[serde(rename_all = "camelCase")]
    Disk {
        at: u64,
        /// `low` or `ok`.
        state: &'static str,
        disk_free_bytes: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        disk_free_fraction: Option<f64>,
    },
}

/// The edge state between samples.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Watch {
    pub lines: Lines,
    mem: MemLevel,
    oom_kills: Option<u64>,
    reclaim: Option<crate::host_pressure::Reclaim>,
    /// One bit per recent sample with reclaim read, newest lowest: set when it stalled.
    stall_bits: u32,
    stalled: bool,
    calm_samples: u32,
    /// When the current saturated run began (ms), saturated or not yet held long enough.
    cpu_since: Option<u64>,
    cpu_fired: bool,
    /// When CPU last fell below its line after `saturated` printed (ms).
    cpu_calm_since: Option<u64>,
    disk_low: bool,
}

impl Watch {
    pub fn new(lines: Lines) -> Self {
        Self { lines, ..Self::default() }
    }

    /// The events this sample crosses, in a fixed order: OOM, memory, reclaim, CPU, disk.
    pub fn step(&mut self, s: &Sample) -> Vec<Event> {
        let mut out = Vec::new();
        self.oom(s, &mut out);
        self.memory(s, &mut out);
        self.reclaim(s, &mut out);
        self.cpu(s, &mut out);
        self.disk(s, &mut out);
        out
    }

    fn oom(&mut self, s: &Sample, out: &mut Vec<Event>) {
        let Some(now) = s.oom_kills else { return };
        // The first reading is the baseline; a count that went down (a new boot) is one too.
        if let Some(before) = self.oom_kills
            && now > before
        {
            out.push(Event::OomKill {
                at: s.at,
                state: "rise",
                oom_kills: now,
                rise: now - before,
            });
        }
        self.oom_kills = Some(now);
    }

    fn memory(&mut self, s: &Sample, out: &mut Vec<Event>) {
        let Some(v) = s.mem_available_fraction else { return };
        let (warn, grow) = (self.lines.mem_warn, self.lines.mem_grow);
        let raw = if v < grow {
            MemLevel::Grow
        } else if v < warn {
            MemLevel::Warn
        } else {
            MemLevel::Ok
        };
        let next = if raw >= self.mem {
            raw
        } else {
            // Down only past the margin: grow clears to warn at grow + margin, warn to ok
            // at warn + margin.
            let cleared = if v + AT_LINE >= warn + MEM_MARGIN {
                MemLevel::Ok
            } else if v + AT_LINE >= grow + MEM_MARGIN {
                MemLevel::Warn
            } else {
                MemLevel::Grow
            };
            cleared.min(self.mem)
        };
        if next != self.mem {
            out.push(Event::Memory {
                at: s.at,
                state: next,
                from: self.mem,
                mem_available_fraction: v,
            });
            self.mem = next;
        }
    }

    fn reclaim(&mut self, s: &Sample, out: &mut Vec<Event>) {
        let Some(now) = s.reclaim else { return };
        let before = self.reclaim.replace(now);
        // The first reading is the baseline; a counter that went down (a new boot) is one too.
        let Some(before) =
            before.filter(|b| now.alloc_stalls >= b.alloc_stalls && now.refaults >= b.refaults)
        else {
            return;
        };
        let stalls = now.alloc_stalls - before.alloc_stalls;
        let refaults = now.refaults - before.refaults;
        let stalled_now = stalls > 0 || refaults >= self.lines.refault_pages;
        let window = (1u32 << STALL_WINDOW) - 1;
        self.stall_bits = ((self.stall_bits << 1) | u32::from(stalled_now)) & window;
        let stalled = self.stall_bits.count_ones();
        self.calm_samples = if stalled_now { 0 } else { self.calm_samples.saturating_add(1) };
        let next = if self.stalled {
            self.calm_samples < STALL_CLEAR_SAMPLES
        } else {
            stalled >= self.lines.stall_samples.max(1)
        };
        if next != self.stalled {
            self.stalled = next;
            out.push(Event::Reclaim {
                at: s.at,
                state: if next { "stall" } else { "ok" },
                stalled_samples: stalled,
                window_samples: STALL_WINDOW,
                alloc_stalls: stalls,
                refaults,
            });
        }
    }

    fn cpu(&mut self, s: &Sample, out: &mut Vec<Event>) {
        let (Some(busy), Some(queue), Some(vcpus)) = (s.cpu_busy, s.run_queue, s.vcpus) else {
            return;
        };
        let hot = busy >= self.lines.cpu_busy && queue > u64::from(vcpus);
        let hold_ms = self.lines.cpu_hold_secs.saturating_mul(1000);
        if hot {
            self.cpu_calm_since = None;
            let since = *self.cpu_since.get_or_insert(s.at);
            if !self.cpu_fired && s.at.saturating_sub(since) >= hold_ms {
                self.cpu_fired = true;
                out.push(Event::Cpu {
                    at: s.at,
                    state: "saturated",
                    cpu_busy: busy,
                    run_queue: queue,
                    vcpus,
                    held_secs: s.at.saturating_sub(since) / 1000,
                });
            }
            return;
        }
        if !self.cpu_fired {
            self.cpu_since = None;
            return;
        }
        let calm = *self.cpu_calm_since.get_or_insert(s.at);
        if s.at.saturating_sub(calm) >= CPU_CLEAR_SECS * 1000 {
            let held = calm.saturating_sub(self.cpu_since.unwrap_or(calm)) / 1000;
            out.push(Event::Cpu {
                at: s.at,
                state: "ok",
                cpu_busy: busy,
                run_queue: queue,
                vcpus,
                held_secs: held,
            });
            self.cpu_fired = false;
            self.cpu_since = None;
            self.cpu_calm_since = None;
        }
    }

    fn disk(&mut self, s: &Sample, out: &mut Vec<Event>) {
        let Some(bytes) = s.disk_free_bytes else { return };
        let fraction = s.disk_free_fraction;
        let low =
            bytes < self.lines.disk_bytes || fraction.is_some_and(|f| f < self.lines.disk_fraction);
        let clear = bytes >= self.lines.disk_bytes.saturating_add(DISK_MARGIN_BYTES)
            && fraction
                .is_none_or(|f| f + AT_LINE >= self.lines.disk_fraction + DISK_MARGIN_FRACTION);
        let next = if self.disk_low { !clear } else { low };
        if next != self.disk_low {
            self.disk_low = next;
            let state = if next { "low" } else { "ok" };
            out.push(Event::Disk {
                at: s.at,
                state,
                disk_free_bytes: bytes,
                disk_free_fraction: fraction,
            });
        }
    }
}

/// `/proc/stat`: `procs_running`, and the vCPU count (its `cpuN` lines).
pub fn parse_run_queue_and_vcpus(text: &str) -> (Option<u64>, Option<u32>) {
    let queue = text.lines().find_map(|l| l.strip_prefix("procs_running ")?.trim().parse().ok());
    let vcpus = text
        .lines()
        .filter(|l| {
            l.split_whitespace()
                .next()
                .and_then(|w| w.strip_prefix("cpu"))
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        })
        .count();
    (queue, u32::try_from(vcpus).ok().filter(|n| *n > 0))
}

/// Samples every `lines.interval_ms` and prints each event as one JSON line on stdout,
/// until stdout closes.
pub async fn run(lines: Lines) -> anyhow::Result<()> {
    use std::io::Write;
    let mut watch = Watch::new(lines);
    let mut ticks = tokio::time::interval(Duration::from_millis(lines.interval_ms.max(100)));
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut cpu_before = None;
    loop {
        ticks.tick().await;
        let (sample, cpu_now) = read(cpu_before);
        cpu_before = cpu_now;
        let events = watch.step(&sample);
        if events.is_empty() {
            continue;
        }
        let mut stdout = std::io::stdout().lock();
        for event in events {
            let line = serde_json::to_string(&event)?;
            if writeln!(stdout, "{line}").and_then(|()| stdout.flush()).is_err() {
                // The reader went away: nothing left to tell.
                return Ok(());
            }
        }
    }
}

/// One sample, and this sample's `/proc/stat` CPU reading for the next one's busy share.
fn read(cpu_before: Option<(u64, u64)>) -> (Sample, Option<(u64, u64)>) {
    let mut sample = Sample { at: crate::store::now_ms(), ..Sample::default() };
    let mut load = crate::host_load::Load::default();
    crate::host_load::disk(&mut load);
    sample.disk_free_bytes = load.disk_free_bytes;
    sample.disk_free_fraction = load.disk_free_fraction;
    #[cfg(target_os = "linux")]
    {
        use crate::host_pressure as p;
        let read = |path: &str| std::fs::read_to_string(path).ok();
        sample.mem_available_fraction =
            read("/proc/meminfo").and_then(|s| p::parse_meminfo_available(&s));
        if let Some(vmstat) = read("/proc/vmstat") {
            sample.oom_kills = p::parse_vmstat_oom_kill(&vmstat);
            sample.reclaim = p::parse_vmstat_reclaim(&vmstat);
        }
        if let Some(stat) = read("/proc/stat") {
            let now = p::parse_proc_stat_cpu(&stat);
            sample.cpu_busy = cpu_before.zip(now).and_then(|(a, b)| p::cpu_busy(a, b));
            (sample.run_queue, sample.vcpus) = parse_run_queue_and_vcpus(&stat);
            return (sample, now);
        }
    }
    let _ = cpu_before;
    (sample, None)
}

#[cfg(test)]
#[path = "host_load_watch_tests.rs"]
mod tests;
