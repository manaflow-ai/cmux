//! Memory pressure and OOM kills, read once a second, so the Cloud grows a starved machine within
//! seconds (cmuxterm-hq RFD 0133, "What to build next" item 3, the guest-side pressure push).
//!
//! cmux-platform's automatic sizing (`AutoSize.ts`) measures a machine through the provider's
//! exec once a minute, so a machine that ran out of memory waited up to a minute for its grow.
//! This probe reads two small files a second (`/proc/meminfo`, `/proc/vmstat`; no process walk,
//! unlike the workload probe), and when the machine crosses a line the agent's next status
//! report says so at once in `activity.pressure`:
//!
//! - `memory`: `low` while available memory is under [`MEM_LOW`] of the total (the platform's
//!   own grow line, `AutoSizePolicy.ts` `memAvailableUnder`), `ok` again only
//!   [`MEM_MARGIN`] above it, so a value that sits on the line does not report every second;
//! - `oom_rise_at`: when the kernel's OOM-kill count last rose (Unix ms). The first reading is
//!   the baseline; a count that went down (a new boot) is a new baseline.
//!
//! The report only wakes the machine's sizer: the platform then measures the machine itself, as
//! it does every minute, and decides from its own sample. So the block carries no number the
//! decision trusts, and a machine that sends nothing (an older agent, no `/proc`) is sized as
//! before.

use serde_json::{Value, json};

/// How often the agent reads the two files.
pub const PROBE_INTERVAL_MS: u64 = 1_000;
/// Available memory under this share of the total is `low` (cmux-platform's grow line).
pub const MEM_LOW: f64 = 0.10;
/// `low` clears this far above [`MEM_LOW`].
pub const MEM_MARGIN: f64 = 0.05;

/// What the report says about pressure.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Pressure {
    pub memory_low: bool,
    pub oom_rise_at: Option<u64>,
}

impl Pressure {
    pub fn to_json(&self) -> Value {
        let mut out = json!({ "memory": if self.memory_low { "low" } else { "ok" } });
        if let Some(at) = self.oom_rise_at {
            out["oom_rise_at"] = json!(at);
        }
        out
    }
}

/// The lines' state between readings.
#[derive(Debug, Default)]
pub struct Tracker {
    oom_kills: Option<u64>,
    now: Pressure,
    /// Something was read at least once: until then the block is unknown and not sent.
    read: bool,
}

impl Tracker {
    /// One reading. Some(block) when what the report says changed (the first reading that reads
    /// anything included), None when it did not.
    pub fn observe(
        &mut self,
        mem_available_fraction: Option<f64>,
        oom_kills: Option<u64>,
        wall_ms: u64,
    ) -> Option<Pressure> {
        if mem_available_fraction.is_none() && oom_kills.is_none() {
            return None;
        }
        let mut next = self.now;
        if let Some(v) = mem_available_fraction {
            next.memory_low =
                if self.now.memory_low { v < MEM_LOW + MEM_MARGIN } else { v < MEM_LOW };
        }
        if let Some(count) = oom_kills {
            if self.oom_kills.is_some_and(|before| count > before) {
                next.oom_rise_at = Some(wall_ms);
            }
            self.oom_kills = Some(count);
        }
        let first = !self.read;
        self.read = true;
        if first || next != self.now {
            self.now = next;
            return Some(next);
        }
        None
    }
}

/// `MemAvailable / MemTotal` from `/proc/meminfo`'s text.
pub fn mem_available_fraction(meminfo: &str) -> Option<f64> {
    let field = |name: &str| {
        meminfo.lines().find_map(|line| {
            let rest = line.strip_prefix(name)?.strip_prefix(':')?;
            rest.split_whitespace().next()?.parse::<u64>().ok()
        })
    };
    let total = field("MemTotal")?;
    let available = field("MemAvailable")?;
    (total > 0).then(|| (available as f64 / total as f64).clamp(0.0, 1.0))
}

/// The `oom_kill` count from `/proc/vmstat`'s text.
pub fn oom_kills(vmstat: &str) -> Option<u64> {
    vmstat.lines().find_map(|line| line.strip_prefix("oom_kill ")?.trim().parse().ok())
}

/// One reading of the machine under `root` (`/` in production).
pub fn read(root: &std::path::Path) -> (Option<f64>, Option<u64>) {
    let text = |name: &str| std::fs::read_to_string(root.join("proc").join(name)).ok();
    (
        text("meminfo").as_deref().and_then(mem_available_fraction),
        text("vmstat").as_deref().and_then(oom_kills),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_reading_reports_and_a_steady_one_does_not() {
        let mut t = Tracker::default();
        assert_eq!(t.observe(Some(0.5), Some(3), 1), Some(Pressure::default()));
        assert_eq!(t.observe(Some(0.4), Some(3), 2), None);
        assert_eq!(t.observe(None, None, 3), None, "nothing read changes nothing");
    }

    #[test]
    fn memory_goes_low_under_the_line_and_clears_only_past_the_margin() {
        let mut t = Tracker::default();
        t.observe(Some(0.5), None, 1);
        let low = t.observe(Some(0.08), None, 2).expect("crossed");
        assert!(low.memory_low);
        assert_eq!(t.observe(Some(0.12), None, 3), None, "inside the margin it stays low");
        let ok = t.observe(Some(0.16), None, 4).expect("cleared");
        assert!(!ok.memory_low);
    }

    #[test]
    fn an_oom_rise_reports_its_time_and_the_baseline_does_not() {
        let mut t = Tracker::default();
        assert_eq!(t.observe(None, Some(4), 1).unwrap().oom_rise_at, None, "the count at start");
        assert_eq!(t.observe(None, Some(5), 2).unwrap().oom_rise_at, Some(2));
        assert_eq!(t.observe(None, Some(5), 3), None);
        // A new boot: the lower count is the new baseline, never a rise.
        assert_eq!(t.observe(None, Some(0), 4), None);
        assert_eq!(t.observe(None, Some(1), 5).unwrap().oom_rise_at, Some(5));
    }

    #[test]
    fn the_files_parse() {
        let meminfo = "MemTotal:        4000000 kB\nMemFree:  10 kB\nMemAvailable:     400000 kB\n";
        assert_eq!(mem_available_fraction(meminfo), Some(0.1));
        assert_eq!(mem_available_fraction("MemTotal: 0 kB\nMemAvailable: 0 kB\n"), None);
        assert_eq!(oom_kills("pgfault 9\noom_kill 7\n"), Some(7));
        assert_eq!(oom_kills("pgfault 9\n"), None);
    }

    #[test]
    fn the_block_names_memory_and_the_rise() {
        let p = Pressure { memory_low: true, oom_rise_at: Some(9) };
        assert_eq!(p.to_json(), json!({"memory": "low", "oom_rise_at": 9}));
        assert_eq!(Pressure::default().to_json(), json!({"memory": "ok"}));
    }
}
