//! DIAGNOSTIC ONLY (lane acpmux-duress-p99): per-phase wall and thread-CPU times of the list and
//! status reads, appended to /tmp/acpmux-diag/timing-PID.log. Reverted before the PR is ready.

use std::io::Write;
use std::sync::Mutex;
use std::time::Instant;

static FILE: Mutex<Option<std::fs::File>> = Mutex::new(None);

pub fn thread_cpu_us() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes into the timespec we pass.
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    (ts.tv_sec as u64) * 1_000_000 + (ts.tv_nsec as u64) / 1000
}

pub struct Span {
    pub name: &'static str,
    wall: Instant,
    cpu: u64,
}

impl Span {
    pub fn new(name: &'static str) -> Self {
        Self { name, wall: Instant::now(), cpu: thread_cpu_us() }
    }
    pub fn end(self, extra: u64) {
        let wall = self.wall.elapsed().as_micros() as u64;
        let cpu = thread_cpu_us().saturating_sub(self.cpu);
        line(self.name, wall, cpu, extra);
    }
    /// Wall only (spans across awaits: the thread may change).
    pub fn end_wall(self, extra: u64) {
        line(self.name, self.wall.elapsed().as_micros() as u64, u64::MAX, extra);
    }
}

pub fn line(name: &str, wall_us: u64, cpu_us: u64, extra: u64) {
    let mut f = FILE.lock().unwrap_or_else(|e| e.into_inner());
    if f.is_none() {
        let _ = std::fs::create_dir_all("/tmp/acpmux-diag");
        *f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("/tmp/acpmux-diag/timing-{}.log", std::process::id()))
            .ok();
    }
    if let Some(f) = f.as_mut() {
        let cpu = if cpu_us == u64::MAX { -1 } else { cpu_us as i64 };
        let _ = writeln!(f, "{name} {wall_us} {cpu} {extra}");
    }
}

/// Times `$e`; logs `row.NAME wall cpu` when its wall is over 5 ms.
#[macro_export]
macro_rules! dt {
    ($name:literal, $e:expr) => {{
        let __w = std::time::Instant::now();
        let __c = $crate::diag_timing::thread_cpu_us();
        let __r = $e;
        let __us = __w.elapsed().as_micros() as u64;
        if __us > 5_000 {
            $crate::diag_timing::line(
                concat!("slow.", $name),
                __us,
                $crate::diag_timing::thread_cpu_us().saturating_sub(__c),
                0,
            );
        }
        __r
    }};
}
