//! The host side of a profile: CPU, memory, disk and GPU of the app process, sampled once a
//! second.
//!
//! cmux-next never scans processes (plans/cmux-next/pty-holder.md), so this reads only the
//! one pid the app's socket names, from the kernel: on macOS `proc_pid_rusage` gives its CPU
//! time, resident size, physical footprint (what Activity Monitor shows) and disk bytes; on
//! Linux `/proc/PID/io` gives the disk bytes. The app's helpers (web renderers) and the
//! terminal daemon are not counted. GPU busy is host-wide (macOS `ioreg`'s IOAccelerator
//! "Device Utilization %"): no per-process GPU number exists without a tracer.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{Scope, ScopedJoinHandle};
use std::time::{Duration, Instant};

/// One sample of the app process.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct Sample {
    /// Seconds since the first sample.
    pub at: f64,
    pub cpu_s: HashMap<i32, f64>,
    pub rss_kb: u64,
    /// Physical footprint in bytes (macOS).
    pub footprint: Option<u64>,
    /// Cumulative disk bytes read and written per pid.
    pub disk: HashMap<i32, (u64, u64)>,
    /// Host-wide GPU busy percent (macOS).
    pub gpu_pct: Option<f64>,
    pub processes: usize,
}

/// What a counter grew by between two readings: per pid the growth, and a pid new in `now`
/// counts in full (it started in the window); a pid that ended counts nothing.
pub(super) fn growth(before: &HashMap<i32, f64>, now: &HashMap<i32, f64>) -> f64 {
    now.iter().map(|(pid, value)| (value - before.get(pid).copied().unwrap_or(0.0)).max(0.0)).sum()
}

/// The host metrics over `samples`, oldest first.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct HostSummary {
    pub cpu_avg_pct: Option<f64>,
    pub cpu_peak_pct: Option<f64>,
    pub rss_peak_mb: Option<f64>,
    pub footprint_peak_mb: Option<f64>,
    pub disk_read_mb: Option<f64>,
    pub disk_write_mb: Option<f64>,
    pub gpu_avg_pct: Option<f64>,
    pub gpu_peak_pct: Option<f64>,
    pub processes_peak: Option<f64>,
}

pub(super) fn summarize(samples: &[Sample]) -> HostSummary {
    let mut summary = HostSummary::default();
    let (Some(first), Some(last)) = (samples.first(), samples.last()) else { return summary };
    let mb = |bytes: u64| bytes as f64 / (1024.0 * 1024.0);
    summary.rss_peak_mb = samples.iter().map(|s| s.rss_kb).max().map(|kb| kb as f64 / 1024.0);
    summary.footprint_peak_mb = samples.iter().filter_map(|s| s.footprint).max().map(mb);
    summary.processes_peak = samples.iter().map(|s| s.processes as f64).reduce(f64::max);
    let gpu: Vec<f64> = samples.iter().filter_map(|s| s.gpu_pct).collect();
    if !gpu.is_empty() {
        summary.gpu_avg_pct = Some(gpu.iter().sum::<f64>() / gpu.len() as f64);
        summary.gpu_peak_pct = gpu.iter().copied().reduce(f64::max);
    }
    let span = last.at - first.at;
    if samples.len() >= 2 && span > 0.0 {
        let mut total = 0.0;
        let mut peak: f64 = 0.0;
        for pair in samples.windows(2) {
            let used = growth(&pair[0].cpu_s, &pair[1].cpu_s);
            let dt = pair[1].at - pair[0].at;
            if dt > 0.0 {
                peak = peak.max(used * 100.0 / dt);
            }
            total += used;
        }
        summary.cpu_avg_pct = Some(total * 100.0 / span);
        summary.cpu_peak_pct = Some(peak);
        if !first.disk.is_empty() || !last.disk.is_empty() {
            let column = |sample: &Sample, pick: fn(&(u64, u64)) -> u64| -> HashMap<i32, f64> {
                sample.disk.iter().map(|(pid, io)| (*pid, pick(io) as f64)).collect()
            };
            let (mut read, mut written) = (0.0, 0.0);
            for pair in samples.windows(2) {
                read += growth(&column(&pair[0], |io| io.0), &column(&pair[1], |io| io.0));
                written += growth(&column(&pair[0], |io| io.1), &column(&pair[1], |io| io.1));
            }
            summary.disk_read_mb = Some(read / (1024.0 * 1024.0));
            summary.disk_write_mb = Some(written / (1024.0 * 1024.0));
        }
    }
    summary
}

/// `"Device Utilization %"=N` in `ioreg -r -d 1 -w 0 -c IOAccelerator`; the busiest GPU.
pub(super) fn parse_gpu(text: &str) -> Option<f64> {
    const KEY: &str = "\"Device Utilization %\"=";
    text.match_indices(KEY)
        .filter_map(|(at, _)| {
            let rest = &text[at + KEY.len()..];
            let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
            rest[..end].parse::<f64>().ok()
        })
        .reduce(f64::max)
}

fn gpu() -> Option<f64> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = cmux_process::Command::new("ioreg")
        .args(["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        .output()
        .ok()?;
    parse_gpu(&String::from_utf8_lossy(&output.stdout))
}

/// What the kernel counts for one process.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct Usage {
    cpu_s: Option<f64>,
    rss_kb: u64,
    footprint: u64,
    disk: (u64, u64),
}

/// `mach_timebase_info_data_t` (`<mach/mach_time.h>`), declared here because libc deprecates
/// its copy in favour of the `mach2` crate.
#[cfg(target_vendor = "apple")]
#[repr(C)]
struct Timebase {
    numer: u32,
    denom: u32,
}

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    /// `mach_timebase_info(3)`: the ratio of Mach absolute time units to nanoseconds.
    fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
}

/// The app's counters from macOS `proc_pid_rusage`.
#[cfg(target_vendor = "apple")]
fn usage(pid: i32) -> Option<Usage> {
    // SAFETY: rusage_info_v2 is plain old data; all-zero is a valid value.
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is a live rusage_info_v2 that RUSAGE_INFO_V2 fills.
    let status = unsafe {
        libc::proc_pid_rusage(
            pid,
            libc::RUSAGE_INFO_V2,
            (&raw mut info).cast::<libc::rusage_info_t>(),
        )
    };
    if status != 0 {
        return None;
    }
    // The times are Mach absolute time units, not nanoseconds on Apple silicon.
    let mut timebase = Timebase { numer: 0, denom: 0 };
    // SAFETY: the out-pointer is a valid `mach_timebase_info_data_t`.
    let cpu_s = (unsafe { mach_timebase_info(&raw mut timebase) } == 0 && timebase.denom != 0)
        .then(|| {
            let ticks = u128::from(info.ri_user_time) + u128::from(info.ri_system_time);
            let nanos = ticks * u128::from(timebase.numer) / u128::from(timebase.denom);
            nanos as f64 / 1e9
        });
    Some(Usage {
        cpu_s,
        rss_kb: info.ri_resident_size / 1024,
        footprint: info.ri_phys_footprint,
        disk: (info.ri_diskio_bytesread, info.ri_diskio_byteswritten),
    })
}

/// Disk bytes of `pid` from `/proc/PID/io` (no CPU, RSS or footprint off macOS).
#[cfg(not(target_vendor = "apple"))]
fn usage(pid: i32) -> Option<Usage> {
    let text = std::fs::read_to_string(format!("/proc/{pid}/io")).ok()?;
    let field = |name: &str| {
        text.lines()
            .find_map(|line| line.strip_prefix(name))
            .and_then(|value| value.trim().parse::<u64>().ok())
    };
    Some(Usage { disk: (field("read_bytes:")?, field("write_bytes:")?), ..Usage::default() })
}

fn sample(pid: i32, start: Instant) -> Sample {
    let mut sample = Sample { at: start.elapsed().as_secs_f64(), ..Sample::default() };
    if let Some(usage) = usage(pid) {
        if let Some(cpu_s) = usage.cpu_s {
            sample.cpu_s.insert(pid, cpu_s);
        }
        sample.rss_kb = usage.rss_kb;
        sample.disk.insert(pid, usage.disk);
        sample.footprint = (usage.footprint > 0).then_some(usage.footprint);
        sample.processes = 1;
    }
    sample.gpu_pct = gpu();
    sample
}

/// Samples the app process every second on its own thread until [`Sampler::finish`].
pub(super) struct Sampler<'scope> {
    stop: Arc<AtomicBool>,
    thread: ScopedJoinHandle<'scope, Vec<Sample>>,
}

impl<'scope> Sampler<'scope> {
    /// The thread belongs to `scope`, which joins it.
    pub fn start<'env>(scope: &'scope Scope<'scope, 'env>, pid: i32) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let thread = scope.spawn(move || {
            let start = Instant::now();
            let mut samples = vec![sample(pid, start)];
            while !flag.load(Ordering::Acquire) {
                let next = Duration::from_secs(samples.len() as u64);
                while start.elapsed() < next && !flag.load(Ordering::Acquire) {
                    std::thread::sleep(Duration::from_millis(50));
                }
                samples.push(sample(pid, start));
            }
            samples
        });
        Self { stop, thread }
    }

    pub fn finish(self) -> Vec<Sample> {
        self.stop.store(true, Ordering::Release);
        self.thread.join().unwrap_or_default()
    }
}
