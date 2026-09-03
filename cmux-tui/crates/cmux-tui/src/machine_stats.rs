//! Host resource sampler for the served mux.
//!
//! Every [`SAMPLE_INTERVAL`] the daemon reads its own host's CPU, memory, load,
//! and home-disk usage and publishes a [`MachineStats`] on the mux. The mux fans
//! it out as `machine-stats-changed` and answers `machine-stats` from the same
//! value, so every client that already reaches the daemon (the macOS app over
//! its cmux-remote link, an SDK over the socket) sees one set of numbers with
//! no second channel into the machine and no new authority.
//!
//! Only Linux hosts sample today. Everywhere else [`start_sampler`] returns
//! `None` and the daemon reports `stats: null`; the parsers below still compile
//! there so the same unit tests cover every platform.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::time::Duration;

/// How often the host is sampled. Also the interval `cpu_percent` averages over.
pub(crate) const SAMPLE_INTERVAL: Duration = Duration::from_secs(10);

/// CPU jiffies from the aggregate `cpu` line of `/proc/stat`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CpuTicks {
    pub(crate) idle: u64,
    pub(crate) total: u64,
}

/// Parses the aggregate `cpu` line of `/proc/stat`. `idle` counts idle plus
/// iowait; `total` sums the eight kernel-reported states (guest time is already
/// folded into user/nice by the kernel, so it is not added again).
pub(crate) fn parse_cpu_ticks(proc_stat: &str) -> Option<CpuTicks> {
    let line = proc_stat.lines().find(|line| line.starts_with("cpu "))?;
    let fields = line
        .split_whitespace()
        .skip(1)
        .map(str::parse::<u64>)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    if fields.len() < 4 {
        return None;
    }
    let idle = fields[3].saturating_add(fields.get(4).copied().unwrap_or(0));
    let total = fields.iter().take(8).fold(0u64, |sum, value| sum.saturating_add(*value));
    Some(CpuTicks { idle, total })
}

/// Busy CPU between two readings as a percentage with one decimal, or `None`
/// when the counters did not advance (or went backwards after a host reset).
pub(crate) fn cpu_percent(previous: CpuTicks, current: CpuTicks) -> Option<f64> {
    let total = current.total.checked_sub(previous.total)?;
    if total == 0 {
        return None;
    }
    let idle = current.idle.checked_sub(previous.idle)?;
    let busy = total.saturating_sub(idle) as f64 / total as f64 * 100.0;
    Some((busy * 10.0).round() / 10.0)
}

/// `(total_kb, available_kb)` from `/proc/meminfo`. `MemAvailable` is the
/// kernel's estimate of memory that new work can claim without swapping;
/// kernels too old to report it get `MemFree + Buffers + Cached`.
pub(crate) fn parse_meminfo(meminfo: &str) -> Option<(u64, u64)> {
    let mut total = None;
    let mut available = None;
    let mut free = None;
    let mut buffers = None;
    let mut cached = None;
    for line in meminfo.lines() {
        let Some((key, rest)) = line.split_once(':') else { continue };
        let value = rest.split_whitespace().next().and_then(|value| value.parse::<u64>().ok());
        match key {
            "MemTotal" => total = value,
            "MemAvailable" => available = value,
            "MemFree" => free = value,
            "Buffers" => buffers = value,
            "Cached" => cached = value,
            _ => {}
        }
    }
    let total = total?;
    let available =
        available.or_else(|| Some(free?.saturating_add(buffers?).saturating_add(cached?)))?;
    Some((total, available.min(total)))
}

/// The one-minute load average, the first field of `/proc/loadavg`.
pub(crate) fn parse_loadavg(loadavg: &str) -> Option<f64> {
    loadavg.split_whitespace().next()?.parse::<f64>().ok().filter(|value| value.is_finite())
}

/// The directory whose filesystem the sample describes: the daemon's home,
/// where a cloud machine keeps its persistent volume, or `/` without one.
pub(crate) fn disk_path() -> String {
    std::env::var("HOME").ok().filter(|home| !home.is_empty()).unwrap_or_else(|| "/".into())
}

pub(crate) const fn kib_to_mib(kib: u64) -> u64 {
    kib / 1024
}

#[cfg(unix)]
pub(crate) fn disk_usage_mb(path: &str) -> Option<(u64, u64)> {
    use std::ffi::CString;
    let c_path = CString::new(path).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c_path` is a valid NUL-terminated string and `stat` is a
    // writable, correctly sized struct for the duration of the call.
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    let fragment = u64::from(stat.f_frsize);
    let total = u64::from(stat.f_blocks).saturating_mul(fragment);
    let free = u64::from(stat.f_bfree).saturating_mul(fragment);
    if total == 0 {
        return None;
    }
    Some((total / (1024 * 1024), total.saturating_sub(free) / (1024 * 1024)))
}

#[cfg(target_os = "linux")]
mod linux {
    use std::sync::{Arc, Condvar, Mutex, Weak};
    use std::thread::JoinHandle;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use cmux_tui_core::{MachineStats, Mux};

    use super::{
        CpuTicks, SAMPLE_INTERVAL, cpu_percent, disk_path, disk_usage_mb, kib_to_mib,
        parse_cpu_ticks, parse_loadavg, parse_meminfo,
    };

    const LOG_AREA: &str = "machine-stats";
    const STARTUP_DELAY: Duration = Duration::from_secs(2);

    /// Handle to the sampler thread. `stop` wakes any sleep and joins.
    pub(crate) struct StatsSampler {
        stop: Arc<(Mutex<bool>, Condvar)>,
        thread: Option<JoinHandle<()>>,
    }

    impl StatsSampler {
        pub(crate) fn stop(mut self) {
            Self::signal(&self.stop);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }

        fn signal(stop: &(Mutex<bool>, Condvar)) {
            *stop.0.lock().unwrap() = true;
            stop.1.notify_all();
        }
    }

    impl Drop for StatsSampler {
        fn drop(&mut self) {
            Self::signal(&self.stop);
        }
    }

    /// Sleeps `delay` unless stopped first; returns `true` when stopped.
    fn wait_or_stop(stop: &(Mutex<bool>, Condvar), delay: Duration) -> bool {
        let guard = stop.0.lock().unwrap();
        let (guard, _) = stop.1.wait_timeout_while(guard, delay, |stopped| !*stopped).unwrap();
        *guard
    }

    fn read_sample(previous: Option<CpuTicks>) -> Option<(MachineStats, CpuTicks)> {
        let ticks = parse_cpu_ticks(&std::fs::read_to_string("/proc/stat").ok()?)?;
        let (memory_total_kb, memory_available_kb) =
            parse_meminfo(&std::fs::read_to_string("/proc/meminfo").ok()?)?;
        let load_average_1m = parse_loadavg(&std::fs::read_to_string("/proc/loadavg").ok()?)?;
        let disk_path = disk_path();
        let disk = disk_usage_mb(&disk_path);
        let sampled_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|elapsed| u64::try_from(elapsed.as_millis()).ok())?;
        let cpus = std::thread::available_parallelism()
            .map(|count| u32::try_from(count.get()).unwrap_or(u32::MAX))
            .unwrap_or(1);
        let stats = MachineStats {
            sampled_at_ms,
            cpus,
            cpu_percent: previous.and_then(|previous| cpu_percent(previous, ticks)),
            load_average_1m,
            memory_total_mb: kib_to_mib(memory_total_kb),
            memory_used_mb: kib_to_mib(memory_total_kb.saturating_sub(memory_available_kb)),
            disk_total_mb: disk.map(|(total, _)| total),
            disk_used_mb: disk.map(|(_, used)| used),
            disk_path,
        };
        Some((stats, ticks))
    }

    pub(crate) fn start_sampler(mux: Weak<Mux>) -> Option<StatsSampler> {
        let stop = Arc::new((Mutex::new(false), Condvar::new()));
        let stop_for_thread = stop.clone();
        let spawn =
            std::thread::Builder::new().name("machine-stats-sample".into()).spawn(move || {
                let mut previous: Option<CpuTicks> = None;
                let mut delay = STARTUP_DELAY;
                let mut reported_failure = false;
                loop {
                    if wait_or_stop(&stop_for_thread, delay) {
                        return;
                    }
                    delay = SAMPLE_INTERVAL;
                    let Some(mux) = mux.upgrade() else { return };
                    match read_sample(previous) {
                        Some((stats, ticks)) => {
                            previous = Some(ticks);
                            mux.set_machine_stats(Some(stats));
                        }
                        None => {
                            if !reported_failure {
                                reported_failure = true;
                                crate::client_log::log(
                                    "DEBUG",
                                    LOG_AREA,
                                    "host sample unavailable",
                                );
                            }
                            previous = None;
                            mux.set_machine_stats(None);
                        }
                    }
                }
            });
        match spawn {
            Ok(thread) => Some(StatsSampler { stop, thread: Some(thread) }),
            Err(error) => {
                crate::client_log::log(
                    "DEBUG",
                    LOG_AREA,
                    &format!("sampler start failed: {error}"),
                );
                None
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub(crate) use linux::start_sampler;

#[cfg(not(target_os = "linux"))]
mod other {
    use std::sync::Weak;

    use cmux_tui_core::Mux;

    /// No sampler runs on this host; the daemon reports `stats: null`. Never
    /// constructed here, so the type exists only to keep `main` uniform.
    #[allow(dead_code)]
    pub(crate) struct StatsSampler;

    impl StatsSampler {
        pub(crate) fn stop(self) {}
    }

    pub(crate) fn start_sampler(_mux: Weak<Mux>) -> Option<StatsSampler> {
        None
    }
}

#[cfg(not(target_os = "linux"))]
pub(crate) use other::start_sampler;

#[cfg(test)]
mod tests {
    use super::*;

    const PROC_STAT: &str = "cpu  4705 150 1120 16250 520 0 30 0 0 0\ncpu0 2000 70 600 8000 260 0 15 0 0 0\nintr 12345\n";

    #[test]
    fn cpu_ticks_fold_idle_and_iowait() {
        let ticks = parse_cpu_ticks(PROC_STAT).unwrap();
        assert_eq!(ticks.idle, 16250 + 520);
        assert_eq!(ticks.total, 4705 + 150 + 1120 + 16250 + 520 + 30);
    }

    #[test]
    fn cpu_ticks_reject_short_or_missing_lines() {
        assert_eq!(parse_cpu_ticks("cpu 1 2 3\n"), None);
        assert_eq!(parse_cpu_ticks("cpu0 1 2 3 4\n"), None);
        assert_eq!(parse_cpu_ticks("cpu a b c d\n"), None);
    }

    #[test]
    fn cpu_percent_is_busy_share_of_the_interval() {
        let previous = CpuTicks { idle: 1000, total: 2000 };
        let current = CpuTicks { idle: 1300, total: 3000 };
        assert_eq!(cpu_percent(previous, current), Some(70.0));
        assert_eq!(cpu_percent(current, current), None);
        assert_eq!(cpu_percent(current, previous), None);
    }

    #[test]
    fn meminfo_prefers_mem_available() {
        let text = "MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    9000000 kB\nBuffers:          200000 kB\nCached:          3000000 kB\n";
        assert_eq!(parse_meminfo(text), Some((16_000_000, 9_000_000)));
    }

    #[test]
    fn meminfo_falls_back_without_mem_available() {
        let text = "MemTotal:       16000000 kB\nMemFree:         1000000 kB\nBuffers:          200000 kB\nCached:          3000000 kB\n";
        assert_eq!(parse_meminfo(text), Some((16_000_000, 4_200_000)));
        assert_eq!(parse_meminfo("MemFree: 5 kB\n"), None);
    }

    #[test]
    fn loadavg_reads_the_first_field() {
        assert_eq!(parse_loadavg("0.52 0.58 0.59 1/389 12345\n"), Some(0.52));
        assert_eq!(parse_loadavg(""), None);
        assert_eq!(parse_loadavg("nan 0 0"), None);
    }

    #[cfg(unix)]
    #[test]
    fn disk_usage_reads_a_real_filesystem() {
        let (total, used) = disk_usage_mb("/").expect("root filesystem readable");
        assert!(total > 0);
        assert!(used <= total);
        assert_eq!(disk_usage_mb("/definitely/not/a/path"), None);
    }
}
