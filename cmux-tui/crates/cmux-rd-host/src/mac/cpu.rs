//! Bounded process CPU sampling for benchmark receipts.
//!
//! This is deliberately separate from product telemetry. The observer samples the
//! selected viewer PID only when a bench asks for it; inaccessible, dead, or
//! reused PIDs return an explicit unknown result.

use std::ffi::c_void;
use std::os::raw::c_int;

const RUSAGE_INFO_V4: c_int = 4;

unsafe extern "C" {
    fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *mut c_void) -> c_int;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sample {
    pub pid: i32,
    /// The kernel process UUID is stable for the lifetime of a process and changes on PID reuse.
    pub start: String,
    pub cpu_us: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeltaError {
    PidMismatch,
    PidReused,
    CounterWentBackwards,
    Unavailable(String),
}

/// Compute a process CPU delta only when both samples identify the same live
/// process. CPU is process time, not wall time or a lifetime-average percent.
pub fn delta(before: &Sample, after: &Sample) -> Result<u64, DeltaError> {
    if before.pid != after.pid {
        return Err(DeltaError::PidMismatch);
    }
    if before.start != after.start {
        return Err(DeltaError::PidReused);
    }
    after.cpu_us.checked_sub(before.cpu_us).ok_or(DeltaError::CounterWentBackwards)
}

/// Sample one PID using macOS `proc_pid_rusage`. The first 16 bytes are the
/// kernel process UUID; the next two words are user and system CPU nanoseconds
/// in `rusage_info_v4`.
pub fn sample(pid: i32) -> Result<Sample, DeltaError> {
    if pid <= 0 {
        return Err(DeltaError::Unavailable("invalid pid".to_string()));
    }
    let mut raw = [0u8; 512];
    // SAFETY: the kernel writes into the fixed rusage buffer; this is a
    // read-only accounting request and does not signal or mutate the process.
    let result = unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V4, raw.as_mut_ptr().cast()) };
    if result != 0 {
        return Err(DeltaError::Unavailable(format!("proc_pid_rusage failed: {result}")));
    }
    let mut start = String::with_capacity(32);
    for byte in &raw[..16] {
        use std::fmt::Write;
        let _ = write!(start, "{byte:02x}");
    }
    let Ok(user_bytes) = <[u8; 8]>::try_from(&raw[16..24]) else {
        return Err(DeltaError::Unavailable("short user CPU field".to_string()));
    };
    let Ok(system_bytes) = <[u8; 8]>::try_from(&raw[24..32]) else {
        return Err(DeltaError::Unavailable("short system CPU field".to_string()));
    };
    let user_ns = u64::from_ne_bytes(user_bytes);
    let system_ns = u64::from_ne_bytes(system_bytes);
    Ok(Sample { pid, start, cpu_us: user_ns.saturating_add(system_ns) / 1000 })
}

/// A separate observer self-CPU sample can use `getrusage(RUSAGE_SELF)`;
/// callers must label it `observer_cpu_us`, never viewer or host CPU.
pub fn observer_cpu_us() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage initializes the plain-old-data struct we own.
    let result = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    // SAFETY: getrusage returned success and initialized `usage`.
    let usage = unsafe { usage.assume_init() };
    Some(
        (usage.ru_utime.tv_sec as u64)
            .saturating_mul(1_000_000)
            .saturating_add(usage.ru_utime.tv_usec as u64)
            .saturating_add((usage.ru_stime.tv_sec as u64).saturating_mul(1_000_000))
            .saturating_add(usage.ru_stime.tv_usec as u64),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(pid: i32, start: &str, cpu_us: u64) -> Sample {
        Sample { pid, start: start.to_string(), cpu_us }
    }

    #[test]
    fn delta_accepts_same_process_and_preserves_microseconds() {
        assert_eq!(delta(&sample(7, "start", 1_000), &sample(7, "start", 2_500)), Ok(1_500));
    }

    #[test]
    fn delta_rejects_pid_reuse_and_counter_regression() {
        assert_eq!(delta(&sample(7, "old", 1), &sample(7, "new", 2)), Err(DeltaError::PidReused));
        assert_eq!(
            delta(&sample(7, "same", 2), &sample(7, "same", 1)),
            Err(DeltaError::CounterWentBackwards)
        );
        assert_eq!(
            delta(&sample(7, "same", 1), &sample(8, "same", 2)),
            Err(DeltaError::PidMismatch)
        );
    }
}
