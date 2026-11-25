//! The owner's memory guard (plans/cmux-next/tui-tester-rollout.md #9).
//!
//! Classic cmux had reports of 30-70+ GB and one of 190 GB: memory that grows
//! without bound, seen only when a user noticed. The owner samples its own
//! memory (macOS physical footprint, Linux resident set) every few minutes.
//! Past a threshold (4 GiB, then each doubling: 8, 16, 32 GiB...) it appends
//! one line to `owner-memory-<session>.jsonl` beside the panic log and, when
//! crash reports are allowed (`crash_forward`), sends it to Sentry at once.
//! Doubling keeps a runaway process to a handful of events.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::crash_forward::Forwarder;
use crate::version_report::DISTRIBUTION_VERSION;

/// The first alert threshold.
const DEFAULT_THRESHOLD_BYTES: u64 = 4 << 30;
/// How often the owner samples its memory.
const DEFAULT_INTERVAL: Duration = Duration::from_secs(300);
const LOG_AREA: &str = "memory-guard";
#[cfg(debug_assertions)]
const TEST_THRESHOLD_ENV: &str = "CMUX_TUI_TEST_MEMORY_THRESHOLD_BYTES";
#[cfg(debug_assertions)]
const TEST_INTERVAL_ENV: &str = "CMUX_TUI_TEST_MEMORY_INTERVAL_MS";

/// When the next alert is due: past `next_alert` bytes, which then doubles
/// past the sample, so one growth spurt is one alert.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct MemoryGuard {
    next_alert: u64,
}

impl MemoryGuard {
    pub(super) fn new(threshold: u64) -> Self {
        Self { next_alert: threshold.max(1) }
    }

    /// The threshold `memory_bytes` crossed, if any.
    pub(super) fn observe(&mut self, memory_bytes: u64) -> Option<u64> {
        if memory_bytes < self.next_alert {
            return None;
        }
        let crossed = self.next_alert;
        while self.next_alert <= memory_bytes {
            self.next_alert = self.next_alert.saturating_mul(2);
            if self.next_alert == u64::MAX {
                break;
            }
        }
        Some(crossed)
    }
}

/// `owner-memory-<session>.jsonl` beside `owner-panics-<session>.jsonl`.
pub(super) fn memory_log_path(panic_log: &Path) -> PathBuf {
    let name = panic_log.file_name().unwrap_or_default().to_string_lossy();
    let session_part = name.strip_prefix("owner-panics-").unwrap_or(&name);
    panic_log.with_file_name(format!("owner-memory-{session_part}"))
}

/// One memory line.
pub(super) fn record(
    memory_bytes: u64,
    threshold: u64,
    uptime: Duration,
    at_ms: u128,
) -> serde_json::Value {
    let gib = |bytes: u64| bytes as f64 / f64::from(1u32 << 30);
    serde_json::json!({
        "kind": "memory",
        "message": format!(
            "cmux-tui owner memory passed {:.1} GiB ({:.1} GiB after {} min)",
            gib(threshold),
            gib(memory_bytes),
            uptime.as_secs() / 60
        ),
        "location": "memory_guard",
        "memory_bytes": memory_bytes,
        "threshold_bytes": threshold,
        "uptime_seconds": uptime.as_secs(),
        "version": DISTRIBUTION_VERSION,
        "build_identity": build_identity(),
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "owner_pid": std::process::id(),
        "at_ms": at_ms,
        "test": false,
    })
}

/// Starts the sampling thread for the owner whose panic log is `panic_log`.
pub(super) fn spawn(panic_log: Option<PathBuf>, forwarder: Option<Forwarder>) {
    let Some(log) = panic_log.map(|path| memory_log_path(&path)) else { return };
    let (threshold, interval) = limits();
    let _ = std::thread::Builder::new().name("memory-guard".into()).spawn(move || {
        let started = Instant::now();
        let mut guard = MemoryGuard::new(threshold);
        let pid = std::process::id();
        loop {
            let sample = cmux_tui_core::process_resources::sample_process(pid);
            if let Some(memory) = sample.map(|sample| sample.memory_bytes)
                && let Some(crossed) = guard.observe(memory)
            {
                let at_ms = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|elapsed| elapsed.as_millis())
                    .unwrap_or_default();
                let line = record(memory, crossed, started.elapsed(), at_ms);
                crate::client_log::warn(LOG_AREA, line["message"].as_str().unwrap_or_default());
                append(&log, &line);
                if let Some(forwarder) = &forwarder
                    && let Err(error) = forwarder.forward(&log)
                {
                    crate::client_log::warn(LOG_AREA, &format!("send failed: {error}"));
                }
            }
            // A periodic sample is this thread's intended behavior, not a wait on a condition.
            std::thread::sleep(interval);
        }
    });
}

fn limits() -> (u64, Duration) {
    #[cfg(debug_assertions)]
    {
        let read =
            |name: &str| std::env::var(name).ok().and_then(|value| value.parse::<u64>().ok());
        (
            read(TEST_THRESHOLD_ENV).unwrap_or(DEFAULT_THRESHOLD_BYTES),
            read(TEST_INTERVAL_ENV).map_or(DEFAULT_INTERVAL, Duration::from_millis),
        )
    }
    #[cfg(not(debug_assertions))]
    {
        (DEFAULT_THRESHOLD_BYTES, DEFAULT_INTERVAL)
    }
}

fn append(path: &Path, line: &serde_json::Value) {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    if let Ok(mut file) = options.open(path) {
        let _ = file.write_all(format!("{line}\n").as_bytes());
    }
}

#[cfg(unix)]
fn build_identity() -> Option<&'static str> {
    Some(cmux_build_identity::BUILD_IDENTITY)
}

#[cfg(not(unix))]
fn build_identity() -> Option<&'static str> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_doubling_alerts_once() {
        let gib = 1u64 << 30;
        let mut guard = MemoryGuard::new(4 * gib);
        assert_eq!(guard.observe(3 * gib), None);
        assert_eq!(guard.observe(4 * gib), Some(4 * gib));
        assert_eq!(guard.observe(5 * gib), None);
        assert_eq!(guard.observe(7 * gib), None);
        assert_eq!(guard.observe(8 * gib), Some(8 * gib));
        // A jump past several doublings is one alert, and the next waits above it.
        assert_eq!(guard.observe(190 * gib), Some(16 * gib));
        assert_eq!(guard.observe(200 * gib), None);
        assert_eq!(guard.observe(256 * gib), Some(256 * gib));
    }

    #[test]
    fn the_memory_log_sits_beside_the_panic_log() {
        let path = memory_log_path(Path::new("/state/owner-panics-main.jsonl"));
        assert_eq!(path, Path::new("/state/owner-memory-main.jsonl"));
    }

    #[test]
    fn a_record_is_a_memory_event_line() {
        let line = record(5 << 30, 4 << 30, Duration::from_secs(600), 1);
        assert_eq!(line["kind"], "memory");
        assert_eq!(line["threshold_bytes"], 4u64 << 30);
        assert!(line["message"].as_str().unwrap().contains("passed 4.0 GiB"));
        assert_eq!(line["test"], false);
    }
}
