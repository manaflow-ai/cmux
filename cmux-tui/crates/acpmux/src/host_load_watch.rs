//! `acpmux machine load --watch` (`host load --watch`): the guest-side pressure push of
//! cmuxterm-hq RFD 0133 ("What to build next" 3). It samples this machine once a second
//! (a few file reads and one `statvfs`, about 150 µs) and prints one JSON line when a
//! line is crossed, instead of the server asking once a minute:
//!
//! - memory available under 25% (`warn`) and under 10% (`grow`) (`/proc/meminfo`);
//! - any rise of the OOM-kill count (`/proc/vmstat` `oom_kill`);
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
/// A memory level clears this far above its line.
pub const MEM_MARGIN: f64 = 0.05;
/// Low disk clears this far above both of its lines.
pub const DISK_MARGIN_FRACTION: f64 = 0.02;
pub const DISK_MARGIN_BYTES: u64 = 512 << 20;
/// Saturated CPU clears after this long below its line.
pub const CPU_CLEAR_SECS: u64 = 60;

impl Default for Lines {
    fn default() -> Self {
        Self {
            mem_warn: MEM_WARN,
            mem_grow: MEM_GROW,
            cpu_busy: CPU_BUSY,
            cpu_hold_secs: CPU_HOLD_SECS,
            disk_fraction: DISK_FRACTION,
            disk_bytes: DISK_BYTES,
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

    /// The events this sample crosses, in a fixed order: OOM, memory, CPU, disk.
    pub fn step(&mut self, s: &Sample) -> Vec<Event> {
        let mut out = Vec::new();
        self.oom(s, &mut out);
        self.memory(s, &mut out);
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
            let cleared = if v >= warn + MEM_MARGIN {
                MemLevel::Ok
            } else if v >= grow + MEM_MARGIN {
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
            && fraction.is_none_or(|f| f >= self.lines.disk_fraction + DISK_MARGIN_FRACTION);
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
        sample.oom_kills = read("/proc/vmstat").and_then(|s| p::parse_vmstat_oom_kill(&s));
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
mod tests {
    use super::*;
    use serde_json::json;

    fn at(secs: u64) -> Sample {
        Sample { at: secs * 1000, ..Sample::default() }
    }
    fn mem(secs: u64, v: f64) -> Sample {
        Sample { mem_available_fraction: Some(v), ..at(secs) }
    }
    fn states(events: &[Event]) -> Vec<String> {
        events
            .iter()
            .map(|e| {
                let v = serde_json::to_value(e).unwrap();
                format!("{}:{}", v["signal"].as_str().unwrap(), v["state"].as_str().unwrap())
            })
            .collect()
    }

    #[test]
    fn memory_prints_once_per_line_crossed() {
        let mut w = Watch::default();
        assert!(w.step(&mem(0, 0.60)).is_empty());
        assert_eq!(states(&w.step(&mem(1, 0.24))), ["memory:warn"]);
        assert!(w.step(&mem(2, 0.20)).is_empty(), "no repeat while it holds");
        assert_eq!(states(&w.step(&mem(3, 0.09))), ["memory:grow"]);
        assert!(w.step(&mem(4, 0.05)).is_empty());
        // A jump straight from ok to under 10% is one grow line, not warn then grow.
        let mut w = Watch::default();
        assert_eq!(states(&w.step(&mem(0, 0.02))), ["memory:grow"]);
        let v = serde_json::to_value(&w.step(&mem(1, 0.40))[0]).unwrap();
        assert_eq!(
            v,
            json!({"signal": "memory", "at": 1000, "state": "ok", "from": "grow",
                   "memAvailableFraction": 0.40})
        );
    }

    #[test]
    fn memory_on_a_line_does_not_flap() {
        let mut w = Watch::default();
        assert_eq!(states(&w.step(&mem(0, 0.249))), ["memory:warn"]);
        for (i, v) in [0.251, 0.249, 0.26, 0.24, 0.29].into_iter().enumerate() {
            assert!(w.step(&mem(i as u64 + 1, v)).is_empty(), "{v} stays warn");
        }
        assert_eq!(states(&w.step(&mem(9, 0.30))), ["memory:ok"]);
        // Grow clears to warn only at 15%.
        let mut w = Watch::default();
        w.step(&mem(0, 0.099));
        assert!(w.step(&mem(1, 0.101)).is_empty());
        assert!(w.step(&mem(2, 0.149)).is_empty());
        assert_eq!(states(&w.step(&mem(3, 0.15))), ["memory:warn"]);
    }

    #[test]
    fn an_oom_kill_rise_prints_and_the_baseline_does_not() {
        let mut w = Watch::default();
        let oom = |secs, n| Sample { oom_kills: Some(n), ..at(secs) };
        assert!(w.step(&oom(0, 4)).is_empty(), "the count at start is the baseline");
        assert!(w.step(&oom(1, 4)).is_empty());
        let e = w.step(&oom(2, 6));
        assert_eq!(e, [Event::OomKill { at: 2000, state: "rise", oom_kills: 6, rise: 2 }]);
        assert!(w.step(&oom(3, 6)).is_empty());
        assert!(w.step(&Sample { oom_kills: None, ..at(4) }).is_empty());
        assert_eq!(states(&w.step(&oom(5, 7))), ["oomKill:rise"]);
    }

    fn cpu(secs: u64, busy: f64, queue: u64) -> Sample {
        Sample { cpu_busy: Some(busy), run_queue: Some(queue), vcpus: Some(2), ..at(secs) }
    }

    #[test]
    fn cpu_prints_after_five_minutes_saturated_not_four() {
        let mut w = Watch::default();
        for t in 0..=240 {
            assert!(w.step(&cpu(t, 0.97, 5)).is_empty(), "{t}s is not 5 minutes");
        }
        // A break resets the hold: four minutes, a calm second, four more is not five.
        assert!(w.step(&cpu(241, 0.30, 1)).is_empty());
        for t in 242..=482 {
            assert!(w.step(&cpu(t, 0.97, 5)).is_empty());
        }
        let mut fired = Vec::new();
        for t in 483..=600 {
            fired.extend(w.step(&cpu(t, 0.97, 5)));
        }
        assert_eq!(
            fired,
            [Event::Cpu {
                at: 542_000,
                state: "saturated",
                cpu_busy: 0.97,
                run_queue: 5,
                vcpus: 2,
                held_secs: 300
            }]
        );
    }

    #[test]
    fn cpu_needs_both_busy_and_a_queue_over_the_vcpus() {
        let mut w = Watch::default();
        for t in 0..=400 {
            // Busy but the queue fits the vCPUs, then queued but not busy enough.
            let s = if t % 2 == 0 { cpu(t, 0.99, 2) } else { cpu(t, 0.89, 9) };
            assert!(w.step(&s).is_empty());
        }
    }

    #[test]
    fn saturated_cpu_clears_after_a_calm_minute_only() {
        let mut w = Watch::default();
        for t in 0..=300 {
            w.step(&cpu(t, 0.95, 4));
        }
        for t in 301..=330 {
            assert!(w.step(&cpu(t, 0.20, 1)).is_empty());
        }
        // Back to saturated before the minute: still the same burst, no new line.
        for t in 331..=340 {
            assert!(w.step(&cpu(t, 0.95, 4)).is_empty());
        }
        let mut out = Vec::new();
        for t in 341..=401 {
            out.extend(w.step(&cpu(t, 0.20, 1)));
        }
        assert_eq!(states(&out), ["cpu:ok"]);
    }

    #[test]
    fn disk_low_on_either_line_and_clears_past_the_margin() {
        let gib = 1u64 << 30;
        let disk = |secs, bytes, f| Sample {
            disk_free_bytes: Some(bytes),
            disk_free_fraction: Some(f),
            ..at(secs)
        };
        let mut w = Watch::default();
        assert!(w.step(&disk(0, 50 * gib, 0.5)).is_empty());
        assert_eq!(states(&w.step(&disk(1, 3 * gib, 0.09))), ["disk:low"], "under 10%");
        assert!(w.step(&disk(2, 3 * gib, 0.11)).is_empty(), "11% is inside the margin");
        assert_eq!(states(&w.step(&disk(3, 3 * gib, 0.12))), ["disk:ok"]);
        assert_eq!(states(&w.step(&disk(4, gib, 0.5))), ["disk:low"], "under 2 GiB");
        assert!(w.step(&disk(5, 2 * gib + 1, 0.5)).is_empty());
        assert_eq!(states(&w.step(&disk(6, 3 * gib, 0.5))), ["disk:ok"]);
    }

    #[test]
    fn a_guest_with_no_psi_no_swap_and_unread_fields_still_judges_what_it_read() {
        // Freestyle: no /proc/pressure, no swap; the sample has no PSI field at all, and
        // an unread field leaves its signal alone.
        let mut w = Watch::default();
        assert!(w.step(&at(0)).is_empty());
        assert_eq!(states(&w.step(&mem(1, 0.05))), ["memory:grow"]);
        assert!(w.step(&at(2)).is_empty(), "an unread sample does not clear it");
        assert!(w.step(&mem(3, 0.05)).is_empty());
    }

    #[test]
    fn flags_move_the_lines() {
        let mut w = Watch::new(Lines { mem_warn: 0.40, cpu_hold_secs: 10, ..Lines::default() });
        assert_eq!(states(&w.step(&mem(0, 0.35))), ["memory:warn"]);
        let mut out = Vec::new();
        for t in 0..=10 {
            out.extend(w.step(&cpu(t, 0.95, 3)));
        }
        assert_eq!(states(&out), ["cpu:saturated"]);
    }

    #[test]
    fn run_queue_and_vcpus_come_from_proc_stat() {
        let stat = "cpu  1 2 3 4 5 6 7 8 0 0\ncpu0 1 1 1 1 1 1 1 1 0 0\ncpu1 1 1 1 1 1 1 1 1 0 0\n\
                    intr 9\nctxt 9\nprocs_running 3\nprocs_blocked 0\n";
        assert_eq!(parse_run_queue_and_vcpus(stat), (Some(3), Some(2)));
        assert_eq!(parse_run_queue_and_vcpus("cpu 1 2 3\n"), (None, None));
    }
}
