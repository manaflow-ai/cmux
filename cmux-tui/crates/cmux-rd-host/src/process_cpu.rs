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
mod tests {
    use super::*;
    fn sample() -> Sample {
        Sample { pid: 10, start_abstime: 42, cpu_ns: 100, sampled_ns: 100 }
    }
    #[test]
    fn process_cpu_interval_units_and_multicore() {
        let before = sample();
        assert_eq!(
            interval(Ok(before), Ok(Sample { cpu_ns: 350, sampled_ns: 200, ..before })).cpu_pct,
            Some(250.0)
        );
        assert_eq!(
            interval(Ok(before), Ok(Sample { sampled_ns: 200, ..before })).cpu_pct,
            Some(0.0)
        );
    }
    #[test]
    fn process_cpu_interval_rejects_reuse_regression_and_unavailable() {
        let before = sample();
        for after in [
            Sample { pid: 11, ..before },
            Sample { start_abstime: 43, ..before },
            Sample { cpu_ns: 99, ..before },
            before,
        ] {
            assert!(interval(Ok(before), Ok(after)).cpu_pct.is_none());
        }
        assert_eq!(
            interval(Err("permission_denied"), Ok(before)).reason,
            Some("permission_denied")
        );
        assert_eq!(interval(Ok(before), Err("process_gone")).reason, Some("process_gone"));
    }
}
