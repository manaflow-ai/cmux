//! The owner's memory guard (plans/cmux-next/tui-tester-rollout.md #9).
//!
//! Classic cmux had reports of 30-70+ GB and one of 190 GB: memory that grows
//! without bound, seen only when a user noticed. The owner samples its own
//! memory (macOS physical footprint, Linux resident set) every 5 minutes, a
//! maintenance job (p14-energy-077d).
//! Past a threshold (4 GiB, then each doubling: 8, 16, 32 GiB...) it appends
//! one line to `owner-memory-<session>.jsonl` beside the panic log and, when
//! crash reports are allowed (`crash_forward`), sends it to Sentry at once.
//! Doubling keeps a runaway process to a handful of events.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_tui_core::Mux;
use cmux_tui_core::wake::JobSpec;

use super::crash_forward::Forwarder;
use crate::version_report::DISTRIBUTION_VERSION;

/// The first alert threshold.
const DEFAULT_THRESHOLD_BYTES: u64 = 4 << 30;
/// How often the owner samples its memory.
const DEFAULT_INTERVAL: Duration = Duration::from_secs(300);
const LOG_AREA: &str = "memory-guard";
/// The thread that appends and sends the alerts.
const REPORT_THREAD: &str = "memory-guard-report";
#[cfg(debug_assertions)]
const TEST_THRESHOLD_ENV: &str = "CMUX_TUI_TEST_MEMORY_THRESHOLD_BYTES";
#[cfg(debug_assertions)]
const TEST_INTERVAL_ENV: &str = "CMUX_TUI_TEST_MEMORY_INTERVAL_MS";
#[cfg(debug_assertions)]
const TEST_THREAD: &str = "memory-guard-test";

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

/// The memory guard's maintenance job: one sample per period.
const SAMPLE_JOB: JobSpec =
    JobSpec { name: "memory_guard.sample", period: DEFAULT_INTERVAL, skippable_in_saver: true };

/// The memory guard of the owner whose panic log is `panic_log`, ready to
/// start once the owner's mux exists ([`MemoryGuardStart::start`]).
pub(super) fn prepare(
    panic_log: Option<PathBuf>,
    forwarder: Option<Forwarder>,
) -> Option<MemoryGuardStart> {
    let log = panic_log.map(|path| memory_log_path(&path))?;
    Some(MemoryGuardStart { log, forwarder })
}

/// What the memory guard needs to start.
pub(crate) struct MemoryGuardStart {
    log: PathBuf,
    forwarder: Option<Forwarder>,
}

/// A maintenance job: the clock calls it once per period.
type Job = Box<dyn FnMut() + Send>;

impl MemoryGuardStart {
    /// Samples the owner's memory every [`DEFAULT_INTERVAL`] as a job on
    /// `mux`'s maintenance clock (its 5-minute wall-clock grid, which the
    /// kernel coalesces with every other maintenance wake); it used to sleep
    /// 300 s on a thread of its own.
    pub(crate) fn start(self, mux: &Mux) {
        #[cfg(debug_assertions)]
        if let Some((threshold, interval)) = test_limits() {
            let started = Reporter::start(self.log, self.forwarder)
                .map(|(reporter, _)| Sampler::new(reporter, threshold))
                .and_then(|mut sample| {
                    cmux_threads::spawn(TEST_THREAD, cmux_threads::ThreadQos::Utility, move || {
                        loop {
                            sample.run();
                            // wakeup-allow: debug the tests' sampling interval (CMUX_TUI_TEST_MEMORY_INTERVAL_MS), debug builds only
                            std::thread::sleep(interval);
                        }
                    })
                });
            if let Err(error) = started {
                crate::client_log::warn(LOG_AREA, &format!("cannot start: {error}"));
            }
            return;
        }
        let started = self.start_on(DEFAULT_THRESHOLD_BYTES, |spec, job| {
            mux.maintenance_clock()?.register(spec, job).map_err(std::io::Error::other)
        });
        if let Err(error) = started {
            crate::client_log::warn(LOG_AREA, &format!("cannot start: {error}"));
        }
    }

    /// Registers the sample job through `register` (the mux's maintenance
    /// clock in production) and starts the reporter that writes and sends
    /// its alerts. Returns the reporter's thread, which ends once the job is
    /// dropped.
    fn start_on(
        self,
        threshold: u64,
        register: impl FnOnce(JobSpec, Job) -> std::io::Result<()>,
    ) -> std::io::Result<JoinHandle<()>> {
        let (reporter, thread) = Reporter::start(self.log, self.forwarder)?;
        let mut sample = Sampler::new(reporter, threshold);
        register(SAMPLE_JOB, Box::new(move || sample.run()))?;
        Ok(thread)
    }
}

/// The memory guard's alert writer. The sample job runs on the maintenance
/// clock's one thread, so it only hands each alert line here; this thread
/// appends the line and sends it to Sentry (a blocking upload), and blocks
/// on its channel with no timeout between alerts.
struct Reporter {
    lines: mpsc::Sender<serde_json::Value>,
}

impl Reporter {
    fn start(
        log: PathBuf,
        forwarder: Option<Forwarder>,
    ) -> std::io::Result<(Self, JoinHandle<()>)> {
        let (lines, received) = mpsc::channel::<serde_json::Value>();
        let thread =
            cmux_threads::spawn(REPORT_THREAD, cmux_threads::ThreadQos::Utility, move || {
                for line in received {
                    append(&log, &line);
                    if let Some(forwarder) = &forwarder
                        && let Err(error) = forwarder.forward(&log)
                    {
                        crate::client_log::warn(LOG_AREA, &format!("send failed: {error}"));
                    }
                }
            })?;
        Ok((Self { lines }, thread))
    }
}

/// One sample: the owner's memory, and the alert line when it crossed the
/// next threshold.
struct Sampler {
    reporter: Reporter,
    guard: MemoryGuard,
    started: Instant,
}

impl Sampler {
    fn new(reporter: Reporter, threshold: u64) -> Self {
        Self { reporter, guard: MemoryGuard::new(threshold), started: Instant::now() }
    }

    /// Never blocks: it runs on the maintenance clock's thread.
    fn run(&mut self) {
        let sample = cmux_tui_core::process_resources::Sampler::new().sample(std::process::id());
        let Some(crossed) = sample
            .map(|sample| sample.memory_bytes)
            .and_then(|memory| self.guard.observe(memory).map(|crossed| (memory, crossed)))
        else {
            return;
        };
        let (memory, crossed) = crossed;
        let at_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis())
            .unwrap_or_default();
        let line = record(memory, crossed, self.started.elapsed(), at_ms);
        crate::client_log::warn(LOG_AREA, line["message"].as_str().unwrap_or_default());
        let _ = self.reporter.lines.send(line);
    }
}

/// Debug builds: the tests' threshold and sampling interval, when a test
/// sets the interval.
#[cfg(debug_assertions)]
fn test_limits() -> Option<(u64, Duration)> {
    let read = |name: &str| std::env::var(name).ok().and_then(|value| value.parse::<u64>().ok());
    let interval = Duration::from_millis(read(TEST_INTERVAL_ENV)?);
    Some((read(TEST_THRESHOLD_ENV).unwrap_or(DEFAULT_THRESHOLD_BYTES), interval))
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

    /// p14-energy-077d: the sample is a maintenance job (one 5-minute grid
    /// wake shared with the rest), not a thread that sleeps 300 s.
    #[test]
    fn the_sample_is_a_maintenance_job_on_the_grid() {
        use cmux_tui_core::wake::{EnergyMode, MaintenanceClock};
        assert_eq!(SAMPLE_JOB.period.as_secs() % 300, 0);
        let clock = MaintenanceClock::start(&EnergyMode::new(false)).unwrap();
        clock.register(SAMPLE_JOB, || {}).expect("not a durability job");
    }

    /// The production start: the guard registers its sample as the clock's
    /// `memory_guard.sample` job, and each run the clock makes past the
    /// threshold appends one alert line, written off the clock's thread.
    #[test]
    fn the_clock_job_appends_the_alert_off_the_clock_thread() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("owner-memory-main.jsonl");
        let guard = MemoryGuardStart { log: log.clone(), forwarder: None };
        let mut registered = None;
        let reporter = guard
            .start_on(1, |spec, job| {
                registered = Some((spec, job));
                Ok(())
            })
            .unwrap();
        let (spec, mut job) = registered.expect("the guard registers its sample job");
        assert_eq!(spec.name, SAMPLE_JOB.name);
        assert_eq!(spec.period, DEFAULT_INTERVAL);

        // The clock runs the job: past 1 byte, then not past the doubling.
        job();
        job();
        // The clock drops its jobs when it stops; the reporter then ends.
        drop(job);
        reporter.join().unwrap();

        let lines = std::fs::read_to_string(&log).unwrap();
        let lines: Vec<serde_json::Value> =
            lines.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert_eq!(lines[0]["kind"], "memory");
        assert_eq!(lines[0]["threshold_bytes"], 1u64);
    }

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
