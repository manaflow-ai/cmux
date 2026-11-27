//! Process CPU interval arithmetic for benchmark tools; no process discovery.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Clone, Copy, Debug)]
pub struct Sample {
    pub pid: i32,
    pub start_abstime: u64,
    pub cpu_ns: u64,
    pub sampled_ns: u64,
}

/// A percentage of one CPU core, so a multithreaded process can exceed 100%.
#[derive(Debug, serde::Serialize)]
pub struct Interval {
    pub cpu_pct: Option<f64>,
    pub reason: Option<&'static str>,
}

/// Mach absolute-time ticks to nanoseconds with the host timebase (`numer / denom`). On
/// Apple Silicon a tick is 125/3 ns, so the raw counters are never nanoseconds there.
pub fn ticks_to_ns(ticks: u64, numer: u32, denom: u32) -> Option<u64> {
    let ns = u128::from(ticks) * u128::from(numer) / u128::from(denom.max(1));
    u64::try_from(ns).ok()
}

pub fn interval(
    before: Result<Sample, &'static str>,
    after: Result<Sample, &'static str>,
) -> Interval {
    let calculate = || {
        let before = before?;
        let after = after?;
        if before.pid != after.pid {
            return Err("pid_mismatch");
        }
        if before.start_abstime == 0 || before.start_abstime != after.start_abstime {
            return Err("pid_reused_or_unknown_start");
        }
        let used = after.cpu_ns.checked_sub(before.cpu_ns).ok_or("cpu_counter_regressed")?;
        let elapsed = after
            .sampled_ns
            .checked_sub(before.sampled_ns)
            .filter(|elapsed| *elapsed > 0)
            .ok_or("invalid_elapsed_time")?;
        Ok(used as f64 / elapsed as f64 * 100.0)
    };
    match calculate() {
        Ok(pct) => Interval { cpu_pct: Some(pct), reason: None },
        Err(reason) => Interval { cpu_pct: None, reason: Some(reason) },
    }
}

#[cfg(test)]
#[path = "process_cpu_tests.rs"]
mod tests;
