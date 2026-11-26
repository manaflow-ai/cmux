//! The real host's readings. The parsers of Linux's
//! `/proc` files, the perf-level fold and the macOS tick, thermal and HID folds are
//! plain functions, so every platform tests them (`probe_tests.rs`).
//!
//! RFD 0072's signals beyond the budget's: CPU busy (two readings, the delta since
//! the last sample), thermal pressure, HID idle and timer lateness. Power (AC,
//! battery, lid) is not read here: acpmux's `host_power` already reads it, so
//! [`Sample::on_ac`] and [`Sample::battery_percent`] are for its caller to fill.
//!
//! Core count, settled from code: `performance_cores` sums every perf level not
//! named `Efficiency`. RFD 0072's run A read `hw.perflevel0.physicalcpu` alone, which
//! is 5 on a 15-CPU M5 Pro (level 0 is its 5 Super cores; level 1, Performance, has
//! 10). The budget's 15 is the sum, so the two readings agree.

use super::{Probe, Sample};

/// The real host's readings. Blocking: run it on a blocking thread (off the async runtime).
pub struct HostProbe;

impl Probe for HostProbe {
    fn sample(&self) -> Sample {
        let logical_cpus = std::thread::available_parallelism()
            .map_or(1, |n| u32::try_from(n.get()).unwrap_or(u32::MAX));
        let mut sample = platform::sample(logical_cpus);
        if let Some(l) = crate::lateness::global_stats() {
            sample.lateness_p50_ms = Some(l.p50_ms);
            sample.lateness_p95_ms = Some(l.p95_ms);
            sample.lateness_over_5ms_share = Some(l.share_over_5ms);
        }
        sample
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

/// macOS `host_cpu_load_info` ticks as `[user, system, idle, nice]`: the share busy
/// between two readings (0..1). The counters are 32-bit and wrap, so the
/// differences wrap too. None when no tick passed.
#[cfg(any(target_os = "macos", test))]
pub fn cpu_busy_ticks(before: [u32; 4], after: [u32; 4]) -> Option<f64> {
    let d: Vec<u64> =
        before.iter().zip(&after).map(|(b, a)| u64::from(a.wrapping_sub(*b))).collect();
    let total: u64 = d.iter().sum();
    let idle = *d.get(2)?;
    (total > 0).then(|| (total - idle) as f64 / total as f64)
}

/// The word for macOS's `com.apple.system.thermalpressurelevel` state
/// (`OSThermalNotification.h`): 0 nominal, 1 moderate, 2 heavy, 3 trapping,
/// 4 sleeping, else unknown.
pub fn thermal_pressure_word(level: u32) -> &'static str {
    match level {
        0 => "nominal",
        1 => "moderate",
        2 => "heavy",
        3 => "trapping",
        4 => "sleeping",
        _ => "unknown",
    }
}

/// `/sys/class/thermal/thermal_zone*/temp` files' text (millidegrees C): the
/// hottest zone in degrees. A zone reading 0 or under, or over 200 C, is a sensor
/// that says nothing and is left out.
pub fn parse_thermal_millic_max<'a>(temps: impl IntoIterator<Item = &'a str>) -> Option<f64> {
    temps
        .into_iter()
        .filter_map(|t| t.trim().parse::<i64>().ok())
        .filter(|m| (1..=200_000).contains(m))
        .max()
        .map(|m| m as f64 / 1000.0)
}

/// IORegistry's `HIDIdleTime` (nanoseconds) as seconds; a negative one is none.
#[cfg(any(target_os = "macos", test))]
pub fn hid_idle_seconds(nanos: i64) -> Option<f64> {
    (nanos >= 0).then(|| nanos as f64 / 1e9)
}

#[cfg(test)]
#[path = "probe_tests.rs"]
mod tests;

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
            cpu_busy: cpu_busy_since_last(),
            thermal_pressure_level: thermal_level(),
            hid_idle_seconds: hid_idle(),
            ..Sample::default()
        }
    }

    /// The host's mach port, one send right for the daemon's life.
    fn host_port() -> libc::mach_port_t {
        static HOST: std::sync::OnceLock<libc::mach_port_t> = std::sync::OnceLock::new();
        // SAFETY: no arguments; returns this host's name port.
        #[allow(deprecated)]
        *HOST.get_or_init(|| unsafe { libc::mach_host_self() })
    }

    /// The CPUs' busy share since the last call (`host_statistics64` HOST_CPU_LOAD_INFO,
    /// two readings); none on the first.
    fn cpu_busy_since_last() -> Option<f64> {
        static LAST: std::sync::Mutex<Option<[u32; 4]>> = std::sync::Mutex::new(None);
        // SAFETY: an all-zero host_cpu_load_info is a valid value of this plain C struct.
        let mut info: libc::host_cpu_load_info = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        // SAFETY: `info` is HOST_CPU_LOAD_INFO_COUNT integers of writable storage, as `count` says.
        let rc = unsafe {
            libc::host_statistics64(
                host_port(),
                libc::HOST_CPU_LOAD_INFO,
                (&raw mut info).cast(),
                &raw mut count,
            )
        };
        if rc != libc::KERN_SUCCESS {
            return None;
        }
        let now = info.cpu_ticks;
        let mut last = LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let busy = last.and_then(|before| super::cpu_busy_ticks(before, now));
        *last = Some(now);
        busy
    }

    unsafe extern "C" {
        fn notify_register_check(name: *const libc::c_char, token: *mut libc::c_int) -> u32;
        fn notify_get_state(token: libc::c_int, state: *mut u64) -> u32;
    }

    /// `com.apple.system.thermalpressurelevel`'s state ([`super::thermal_pressure_word`]).
    fn thermal_level() -> Option<u32> {
        static TOKEN: std::sync::OnceLock<Option<libc::c_int>> = std::sync::OnceLock::new();
        let token = (*TOKEN.get_or_init(|| {
            let mut token: libc::c_int = 0;
            // SAFETY: a NUL-terminated name and a valid out pointer.
            let rc = unsafe {
                notify_register_check(
                    c"com.apple.system.thermalpressurelevel".as_ptr(),
                    &raw mut token,
                )
            };
            (rc == 0).then_some(token)
        }))?;
        let mut state: u64 = 0;
        // SAFETY: a token from notify_register_check and a valid out pointer.
        let rc = unsafe { notify_get_state(token, &raw mut state) };
        (rc == 0).then(|| u32::try_from(state).ok()).flatten()
    }

    mod iokit {
        use std::ffi::c_void;
        #[link(name = "IOKit", kind = "framework")]
        unsafe extern "C" {
            pub fn IOServiceMatching(name: *const libc::c_char) -> *mut c_void;
            pub fn IOServiceGetMatchingService(main_port: u32, matching: *mut c_void) -> u32;
            pub fn IORegistryEntryCreateCFProperty(
                entry: u32,
                key: *const c_void,
                allocator: *const c_void,
                options: u32,
            ) -> *const c_void;
            pub fn IOObjectRelease(object: u32) -> i32;
        }
        #[link(name = "CoreFoundation", kind = "framework")]
        unsafe extern "C" {
            pub fn CFStringCreateWithCString(
                allocator: *const c_void,
                c_str: *const libc::c_char,
                encoding: u32,
            ) -> *const c_void;
            pub fn CFGetTypeID(cf: *const c_void) -> usize;
            pub fn CFNumberGetTypeID() -> usize;
            pub fn CFNumberGetValue(number: *const c_void, kind: i32, out: *mut c_void) -> u8;
            pub fn CFRelease(cf: *const c_void);
        }
    }

    /// Seconds since the last keyboard or pointer input: `HIDIdleTime` (nanoseconds) of
    /// the IORegistry's `IOHIDSystem`.
    fn hid_idle() -> Option<f64> {
        const UTF8: u32 = 0x0800_0100;
        const SINT64: i32 = 4;
        // SAFETY: IOKit and CoreFoundation calls with NUL-terminated names and valid out
        // pointers; every object created is released, and the matching dictionary is
        // consumed by IOServiceGetMatchingService.
        unsafe {
            let matching = iokit::IOServiceMatching(c"IOHIDSystem".as_ptr());
            if matching.is_null() {
                return None;
            }
            let entry = iokit::IOServiceGetMatchingService(0, matching);
            if entry == 0 {
                return None;
            }
            let key =
                iokit::CFStringCreateWithCString(std::ptr::null(), c"HIDIdleTime".as_ptr(), UTF8);
            let mut nanos: i64 = -1;
            if !key.is_null() {
                let value = iokit::IORegistryEntryCreateCFProperty(entry, key, std::ptr::null(), 0);
                if !value.is_null() {
                    if iokit::CFGetTypeID(value) == iokit::CFNumberGetTypeID() {
                        let ok = iokit::CFNumberGetValue(value, SINT64, (&raw mut nanos).cast());
                        if ok == 0 {
                            nanos = -1;
                        }
                    }
                    iokit::CFRelease(value);
                }
                iokit::CFRelease(key);
            }
            iokit::IOObjectRelease(entry);
            super::hid_idle_seconds(nanos)
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
            cpu_busy: read("/proc/stat")
                .and_then(|s| super::parse_proc_stat_cpu(&s))
                .and_then(busy_since_last),
            thermal_max_c: thermal_max_c(),
            ..Sample::default()
        }
    }

    /// The busy share since the last call (two `/proc/stat` readings); none on the first.
    fn busy_since_last(now: (u64, u64)) -> Option<f64> {
        static LAST: std::sync::Mutex<Option<(u64, u64)>> = std::sync::Mutex::new(None);
        let mut last = LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let busy = last.and_then(|before| super::cpu_busy(before, now));
        *last = Some(now);
        busy
    }

    /// The hottest `/sys/class/thermal` zone, in degrees C.
    fn thermal_max_c() -> Option<f64> {
        let zones = std::fs::read_dir("/sys/class/thermal").ok()?;
        let texts: Vec<String> = zones
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().starts_with("thermal_zone"))
            .filter_map(|e| std::fs::read_to_string(e.path().join("temp")).ok())
            .collect();
        super::parse_thermal_millic_max(texts.iter().map(String::as_str))
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use super::Sample;

    pub(super) fn sample(logical_cpus: u32) -> Sample {
        Sample { logical_cpus, ..Sample::default() }
    }
}
