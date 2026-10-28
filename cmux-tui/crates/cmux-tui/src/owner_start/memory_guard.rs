//! The owner's memory guard (plans/cmux-next/tui-tester-rollout.md #9).
//!
//! Classic cmux had reports of 30-70+ GB and one of 190 GB: memory that grows
//! without bound, seen only when a user noticed. The owner samples its own
//! memory (macOS physical footprint, Linux resident set) every few minutes.
//! Past a threshold (4 GiB, then each doubling: 8, 16, 32 GiB...) it appends
//! one line to `owner-memory-<session>.jsonl` beside the panic log and, when
//! crash reports are allowed (`crash_forward`), sends it to Sentry at once.
//! Doubling keeps a runaway process to a handful of events.

use crate::json_fields::JsonFields;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_panic_log::{Restart, ShutdownBehavior, StopToken, Supervisor};

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

/// Starts the sampling thread for the owner whose panic log is `panic_log`,
/// under `supervisor`: its only state is its [`MemoryGuard`], so a failed
/// run is restarted with a fresh one, and owner shutdown stops it.
pub(super) fn spawn(
    supervisor: &Supervisor,
    panic_log: Option<PathBuf>,
    forwarder: Option<Forwarder>,
) {
    let Some(log) = panic_log.map(|path| memory_log_path(&path)) else { return };
    let (threshold, interval) = limits();
    let started = Instant::now();
    let pid = std::process::id();
    let sample = move || {
        cmux_tui_core::process_resources::Sampler::new()
            .sample(pid)
            .map(|sample| sample.memory_bytes)
    };
    let alert = move |memory: u64, crossed: u64| {
        let at_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis())
            .unwrap_or_default();
        let line = record(memory, crossed, started.elapsed(), at_ms);
        crate::client_log::warn(LOG_AREA, line.field("message").as_str().unwrap_or_default());
        append(&log, &line);
        if let Some(forwarder) = &forwarder
            && let Err(error) = forwarder.forward(&log)
        {
            crate::client_log::warn(LOG_AREA, &format!("send failed: {error}"));
        }
    };
    let watch = Watch { threshold, interval, sample, alert };
    if let Err(error) = start(supervisor, Restart::state_private(), watch) {
        crate::client_log::warn(LOG_AREA, &format!("not started: {error}"));
    }
}

/// One memory watch: `sample` reads the owner's memory, `alert` records a
/// crossed threshold.
struct Watch<S, A> {
    threshold: u64,
    interval: Duration,
    sample: S,
    alert: A,
}

/// Run `watch` on the "memory-guard" thread under `policy`. Each run starts
/// from `MemoryGuard::new`, samples at once, then every interval until the
/// owner stops it (seen after the current interval; Skip, so shutdown does
/// not wait for it).
fn start<S, A>(
    supervisor: &Supervisor,
    policy: Restart,
    mut watch: Watch<S, A>,
) -> Result<cmux_panic_log::WorkerHandle, cmux_panic_log::SuperviseError>
where
    S: FnMut() -> Option<u64> + Send + 'static,
    A: FnMut(u64, u64) + Send + 'static,
{
    supervisor.supervise_thread_restarting(
        "memory-guard",
        policy,
        ShutdownBehavior::Skip,
        move |stop: &StopToken| {
            let mut guard = MemoryGuard::new(watch.threshold);
            loop {
                if let Some(memory) = (watch.sample)()
                    && let Some(crossed) = guard.observe(memory)
                {
                    (watch.alert)(memory, crossed);
                }
                // A periodic sample is this thread's intended behavior, not a wait on a condition.
                cmux_blocking::thread::sleep(watch.interval);
                if stop.is_stopped() {
                    return;
                }
            }
        },
    )
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
    if let Ok(mut file) = crate::blocking::fs::open_with(&options, path) {
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

    /// The guard's state is private: a run that panics is restarted with a
    /// fresh `MemoryGuard`, so the restarted run alerts for 4 bytes again
    /// (the failed run's doubling is gone with it).
    #[test]
    fn a_restarted_guard_rebuilds_its_state() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::{Arc, Mutex, mpsc};

        #[derive(Default)]
        struct Recorded {
            restarts: Mutex<Vec<String>>,
            fatal: Mutex<Vec<String>>,
        }
        struct Sink(Arc<Recorded>);
        impl cmux_panic_log::FailureSink for Sink {
            fn restarting(
                &self,
                worker: &str,
                _failure: &cmux_panic_log::Failure,
                _backoff: Duration,
            ) {
                self.0.restarts.lock().unwrap().push(worker.to_owned());
            }
            fn fatal(&self, report: &cmux_panic_log::FatalReport) {
                self.0.fatal.lock().unwrap().push(report.to_string());
            }
        }

        let recorded = Arc::new(Recorded::default());
        let supervisor = Supervisor::new(Arc::new(Sink(recorded.clone())));
        let samples = Arc::new(AtomicUsize::new(0));
        let counted = samples.clone();
        let (alerts, alerted) = mpsc::channel();
        let watch = Watch {
            threshold: 4,
            interval: Duration::from_millis(1),
            // The first run alerts for 4 bytes, then its sampler fails.
            sample: move || match counted.fetch_add(1, Ordering::SeqCst) {
                1 => panic!("sampler failed"),
                _ => Some(4),
            },
            alert: move |memory, crossed| {
                let _ = alerts.send((memory, crossed));
            },
        };
        let policy =
            Restart::state_private().backoff(Duration::from_millis(1), Duration::from_millis(1));
        let handle = start(&supervisor, policy, watch).unwrap();
        let wait = Duration::from_secs(10);
        assert_eq!(alerted.recv_timeout(wait), Ok((4, 4)), "the first run");
        assert_eq!(alerted.recv_timeout(wait), Ok((4, 4)), "the restarted run's fresh guard");
        handle.stop();
        assert!(supervisor.shutdown().late.is_empty());
        assert_eq!(*recorded.restarts.lock().unwrap(), vec!["memory-guard".to_owned()]);
        assert!(recorded.fatal.lock().unwrap().is_empty());
        assert!(samples.load(Ordering::SeqCst) >= 3);
    }

    struct NoFatal;
    impl cmux_panic_log::FailureSink for NoFatal {
        fn fatal(&self, report: &cmux_panic_log::FatalReport) {
            panic!("unexpected fatal: {report}");
        }
    }

    /// Owner shutdown never waits for the guard (Skip), even one in the
    /// middle of a long interval.
    #[test]
    fn shutdown_does_not_wait_for_the_guards_interval() {
        use std::sync::{Arc, mpsc};

        let supervisor = Supervisor::new(Arc::new(NoFatal));
        let (sampled, first_sample) = mpsc::channel();
        let watch = Watch {
            threshold: u64::MAX,
            interval: Duration::from_secs(3600),
            sample: move || {
                let _ = sampled.send(());
                None
            },
            alert: |_, _| {},
        };
        let _handle = start(&supervisor, Restart::state_private(), watch).unwrap();
        first_sample.recv_timeout(Duration::from_secs(10)).unwrap();
        let started = Instant::now();
        assert!(supervisor.shutdown().late.is_empty());
        assert!(started.elapsed() < Duration::from_secs(5), "shutdown waited for the guard");
    }

    /// A stopped guard takes no sample after its current interval: its
    /// thread ends instead.
    #[test]
    fn a_stopped_guard_ends_after_its_current_interval() {
        use std::sync::{Arc, mpsc};

        let supervisor = Supervisor::new(Arc::new(NoFatal));
        let (sampled, samples) = mpsc::channel();
        // Dropped with the worker's body, when its thread ends.
        let (alive, ended) = mpsc::channel::<()>();
        let watch = Watch {
            threshold: u64::MAX,
            interval: Duration::from_millis(50),
            sample: move || {
                let _alive = &alive;
                let _ = sampled.send(());
                None
            },
            alert: |_, _| {},
        };
        let _handle = start(&supervisor, Restart::state_private(), watch).unwrap();
        let wait = Duration::from_secs(10);
        samples.recv_timeout(wait).unwrap();
        assert!(supervisor.shutdown().late.is_empty());
        assert_eq!(ended.recv_timeout(wait), Err(mpsc::RecvTimeoutError::Disconnected));
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
