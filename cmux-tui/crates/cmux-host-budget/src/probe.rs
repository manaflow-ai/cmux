//! The real host's readings. The parsers of Linux's
//! `/proc` files and the perf-level fold are plain functions, so every platform
//! tests them.

use super::{Probe, Sample};

/// The real host's readings. Blocking: run it on a blocking thread (off the async runtime).
pub struct HostProbe;

impl Probe for HostProbe {
    fn sample(&self) -> Sample {
        let logical_cpus = std::thread::available_parallelism().map_or(1, |n| n.get() as u32);
        platform::sample(logical_cpus)
    }
}

/// The performance cores from macOS's perf levels (`hw.perflevelN.name`,
/// `hw.perflevelN.physicalcpu`): every level not named `Efficiency`. M1 to M4
/// name theirs Performance and Efficiency; the M5 names its fastest Super, and
/// an M5 Pro's second level is Performance (full cores, not efficiency ones).
pub fn performance_cores(levels: &[(String, u32)]) -> Option<u32> {
    let n: u32 = levels.iter().filter(|(name, _)| name != "Efficiency").map(|(_, n)| n).sum();
    (n > 0).then_some(n)
}

/// `/proc/loadavg`: the first field.
pub fn parse_loadavg(text: &str) -> Option<f64> {
    text.split_whitespace().next()?.parse().ok()
}

/// `/proc/pressure/memory`: `some avg10=1.23 avg60=... total=...` → 1.23.
pub fn parse_psi_some_avg10(text: &str) -> Option<f64> {
    let line = text.lines().find(|l| l.starts_with("some "))?;
    line.split_whitespace().find_map(|w| w.strip_prefix("avg10=")?.parse().ok())
}

/// `/proc/meminfo`: MemAvailable / MemTotal.
pub fn parse_meminfo_available(text: &str) -> Option<f64> {
    let kb = |key: &str| {
        text.lines().find_map(|l| {
            l.strip_prefix(key)?.trim().trim_end_matches("kB").trim().parse::<f64>().ok()
        })
    };
    let total = kb("MemTotal:").filter(|t| *t > 0.0)?;
    Some(kb("MemAvailable:")? / total)
}

/// `/proc/vmstat`: pages swapped out since boot (`pswpout`).
pub fn parse_vmstat_pswpout(text: &str) -> Option<u64> {
    text.lines().find_map(|l| l.strip_prefix("pswpout ")?.trim().parse().ok())
}

/// Any `/proc/pressure/*` file: the `avg60` of its `some` or `full` line.
pub fn parse_psi_avg60(text: &str, line: &str) -> Option<f64> {
    let found = text.lines().find(|l| l.split_whitespace().next() == Some(line))?;
    found.split_whitespace().find_map(|w| w.strip_prefix("avg60=")?.parse().ok())
}

/// `/proc/vmstat`: processes the OOM killer killed since boot (`oom_kill`).
pub fn parse_vmstat_oom_kill(text: &str) -> Option<u64> {
    text.lines().find_map(|l| l.strip_prefix("oom_kill ")?.trim().parse().ok())
}

/// `/proc/meminfo`: (SwapTotal - SwapFree) / SwapTotal; none without swap.
pub fn parse_meminfo_swap_used(text: &str) -> Option<f64> {
    let kb = |key: &str| {
        text.lines().find_map(|l| {
            l.strip_prefix(key)?.trim().trim_end_matches("kB").trim().parse::<f64>().ok()
        })
    };
    let total = kb("SwapTotal:").filter(|t| *t > 0.0)?;
    Some(((total - kb("SwapFree:")?) / total).clamp(0.0, 1.0))
}

/// `/proc/stat`'s aggregate `cpu` line as (all jiffies, idle jiffies). Idle counts
/// `idle` and `iowait`; `guest` and `guest_nice` are already inside `user` and `nice`.
pub fn parse_proc_stat_cpu(text: &str) -> Option<(u64, u64)> {
    let line = text.lines().find(|l| l.split_whitespace().next() == Some("cpu"))?;
    let n: Vec<u64> = line.split_whitespace().skip(1).map_while(|w| w.parse().ok()).collect();
    let idle = n.get(3)?.saturating_add(n.get(4).copied().unwrap_or(0));
    let total = n.iter().take(8).fold(0u64, |sum, j| sum.saturating_add(*j));
    Some((total, idle))
}

/// The share of all CPUs busy between two [`parse_proc_stat_cpu`] readings (0..1).
pub fn cpu_busy(before: (u64, u64), after: (u64, u64)) -> Option<f64> {
    let total = after.0.checked_sub(before.0).filter(|t| *t > 0)?;
    let idle = after.1.saturating_sub(before.1).min(total);
    Some(total.saturating_sub(idle) as f64 / total as f64)
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Sample;
    use std::ffi::{CStr, CString};

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        let mut load = [0f64; 3];
        // SAFETY: `load` has room for the 3 values asked for.
        let load1 = (unsafe { libc::getloadavg(load.as_mut_ptr(), 3) } >= 1).then_some(load[0]);
        // The core counts never change while the daemon runs.
        static CORES: std::sync::OnceLock<(Option<u32>, Option<u32>)> = std::sync::OnceLock::new();
        let (performance_cores, physical_cores) =
            *CORES.get_or_init(|| (perf_level_cores(), count(c"hw.physicalcpu")));
        Sample {
            load1,
            performance_cores,
            physical_cores,
            logical_cpus,
            vm_pressure_level: count(c"kern.memorystatus_vm_pressure_level"),
            psi_some_avg10: None,
            // The "System-wide memory free percentage" memory_pressure prints.
            available_ram_fraction: sysctl_i32(c"kern.memorystatus_level")
                .map(|p| f64::from(p) / 100.0),
            swapout_bytes: swapout_bytes(),
        }
    }

    fn count(name: &CStr) -> Option<u32> {
        sysctl_i32(name).and_then(|n| u32::try_from(n).ok()).filter(|n| *n > 0)
    }

    /// [`super::performance_cores`] of this Mac's perf levels.
    fn perf_level_cores() -> Option<u32> {
        let levels = count(c"hw.nperflevels")?;
        let mut found = Vec::new();
        for i in 0..levels.min(8) {
            let name = CString::new(format!("hw.perflevel{i}.name")).ok()?;
            let cores = CString::new(format!("hw.perflevel{i}.physicalcpu")).ok()?;
            found.push((sysctl_string(&name)?, count(&cores)?));
        }
        super::performance_cores(&found)
    }

    fn sysctl_i32(name: &CStr) -> Option<i32> {
        let mut value: libc::c_int = 0;
        let mut size = size_of::<libc::c_int>();
        // SAFETY: the name is NUL-terminated and `value`/`size` describe valid storage.
        let ok = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                (&raw mut value).cast(),
                &raw mut size,
                std::ptr::null_mut(),
                0,
            )
        } == 0;
        ok.then_some(value)
    }

    fn sysctl_string(name: &CStr) -> Option<String> {
        let mut buf = [0u8; 64];
        let mut size = buf.len();
        // SAFETY: the name is NUL-terminated and `buf`/`size` describe valid storage; the
        // kernel writes at most `size` bytes and sets `size` to what it wrote.
        let ok = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                buf.as_mut_ptr().cast(),
                &raw mut size,
                std::ptr::null_mut(),
                0,
            )
        } == 0;
        let bytes = buf.get(..size.min(buf.len())).filter(|_| ok)?;
        let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
        Some(String::from_utf8_lossy(bytes.get(..end).unwrap_or(bytes)).into_owned())
    }

    /// `vm_stat`'s Swapouts (pages) in bytes.
    fn swapout_bytes() -> Option<u64> {
        // One send right for the daemon's life, not one per sample.
        static HOST: std::sync::OnceLock<libc::mach_port_t> = std::sync::OnceLock::new();
        // SAFETY: no arguments; returns this host's name port.
        #[allow(deprecated)]
        let host = *HOST.get_or_init(|| unsafe { libc::mach_host_self() });
        // SAFETY: an all-zero vm_statistics64 is a valid value of this plain C struct.
        let mut stats: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        // SAFETY: `stats` is HOST_VM_INFO64_COUNT integers of writable storage, as `count` says.
        let rc = unsafe {
            libc::host_statistics64(
                host,
                libc::HOST_VM_INFO64,
                (&raw mut stats).cast(),
                &raw mut count,
            )
        };
        // SAFETY: sysconf has no preconditions.
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        (rc == libc::KERN_SUCCESS && page > 0).then(|| stats.swapouts.saturating_mul(page as u64))
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::Sample;

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        let read = |path: &str| std::fs::read_to_string(path).ok();
        // SAFETY: sysconf has no preconditions.
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        let swapout_bytes = read("/proc/vmstat")
            .and_then(|s| super::parse_vmstat_pswpout(&s))
            .filter(|_| page > 0)
            .map(|pages| pages.saturating_mul(page as u64));
        Sample {
            load1: read("/proc/loadavg").and_then(|s| super::parse_loadavg(&s)),
            performance_cores: None,
            physical_cores: None,
            logical_cpus,
            vm_pressure_level: None,
            psi_some_avg10: read("/proc/pressure/memory")
                .and_then(|s| super::parse_psi_some_avg10(&s)),
            available_ram_fraction: read("/proc/meminfo")
                .and_then(|s| super::parse_meminfo_available(&s)),
            swapout_bytes,
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use super::Sample;

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        Sample { logical_cpus, ..Sample::default() }
    }
}
