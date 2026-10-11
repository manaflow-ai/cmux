//! Host identity and CPU accounting (/proc on Linux).

use crate::clock::now_ns;

pub fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname").map(|s| s.trim().to_string()).unwrap_or_default()
}

pub fn cpu_model() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("model name")).map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string()))
        .unwrap_or_default()
}

pub fn cores() -> u32 {
    std::thread::available_parallelism().map(|n| n.get() as u32).unwrap_or(1)
}

/// User + system CPU seconds consumed by this process (all threads).
pub fn process_cpu_s() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: getrusage fills a valid rusage struct.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

/// (busy, total) jiffies from the aggregate line of /proc/stat.
fn system_jiffies() -> Option<(u64, u64)> {
    let s = std::fs::read_to_string("/proc/stat").ok()?;
    let nums: Vec<u64> = s.lines().next()?.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
    let total: u64 = nums.iter().take(8).sum();
    let idle = nums.get(3)? + nums.get(4).copied().unwrap_or(0);
    Some((total - idle, total))
}

/// Measures CPU between successive `sample()` calls.
/// Process % is of one core (400 = four cores busy); system % is of all cores (0..100).
pub struct CpuMeter {
    wall_ns: u64,
    proc_s: f64,
    sys: Option<(u64, u64)>,
}

impl CpuMeter {
    pub fn new() -> Self {
        Self { wall_ns: now_ns(), proc_s: process_cpu_s(), sys: system_jiffies() }
    }

    pub fn sample(&mut self) -> (Option<f64>, Option<f64>) {
        let (wall, proc_s, sys) = (now_ns(), process_cpu_s(), system_jiffies());
        let dt = (wall - self.wall_ns) as f64 / 1e9;
        let proc_pct = (dt > 0.0).then(|| (proc_s - self.proc_s) / dt * 100.0);
        let sys_pct = match (self.sys, sys) {
            (Some((b0, t0)), Some((b1, t1))) if t1 > t0 => Some((b1 - b0) as f64 / (t1 - t0) as f64 * 100.0),
            _ => None,
        };
        *self = Self { wall_ns: wall, proc_s, sys };
        let r = |x: f64| (x * 10.0).round() / 10.0;
        (proc_pct.map(r), sys_pct.map(r))
    }
}
