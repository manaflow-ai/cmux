//! The test binary's one process hang watch, on a clock the tests move
//! (cmux-hang-watch `init_process` runs once per process, so every test of
//! the daemon's hang-watch scopes shares it). A test registers its own
//! thread name, or reads only the hangs of the daemon thread it drives:
//! other tests' threads register too once the watch runs, and their scopes
//! may be reported when the clock moves.

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use cmux_hang_watch::{Clock, Config, Hang, HangSink, ThreadKind};

/// How long a test waits in real time for the watcher to report.
const REPORT_TIMEOUT: Duration = Duration::from_secs(20);

struct TestClock(AtomicU64);

impl Clock for TestClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Default)]
struct Recorded {
    hangs: Mutex<Vec<Hang>>,
    changed: Condvar,
}

struct TestSink(Arc<Recorded>);

impl HangSink for TestSink {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        self.0.hangs.lock().unwrap_or_else(PoisonError::into_inner).push(hang.clone());
        self.0.changed.notify_all();
        Ok(())
    }
}

pub(crate) struct Harness {
    clock: Arc<TestClock>,
    recorded: Arc<Recorded>,
    /// The tests that move the clock run one at a time.
    serial: Mutex<()>,
}

impl Harness {
    pub(crate) fn get() -> &'static Harness {
        static HARNESS: OnceLock<Harness> = OnceLock::new();
        HARNESS.get_or_init(|| {
            let clock = Arc::new(TestClock(AtomicU64::new(0)));
            let recorded = Arc::<Recorded>::default();
            // A 1 ms watcher period, and no pass is ever late: the clock
            // jumps while the watcher sleeps in real time.
            let config =
                Config { min_deadline: Duration::from_millis(1), drift_tolerance: Duration::MAX };
            cmux_hang_watch::init_process(
                config,
                clock.clone(),
                Box::new(TestSink(recorded.clone())),
            )
            .expect("the test binary's one process hang watch");
            Harness { clock, recorded, serial: Mutex::new(()) }
        })
    }

    pub(crate) fn serial(&self) -> MutexGuard<'_, ()> {
        self.serial.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn advance(&self, by: Duration) {
        let ns = u64::try_from(by.as_nanos()).expect("a test step fits in u64 ns");
        self.clock.0.fetch_add(ns, Ordering::SeqCst);
    }

    pub(crate) fn hangs_of(&self, thread: &str) -> Vec<Hang> {
        let hangs = self.recorded.hangs.lock().unwrap_or_else(PoisonError::into_inner);
        hangs.iter().filter(|hang| hang.thread == thread).cloned().collect()
    }

    /// Waits until `thread` has `count` hangs and returns them.
    pub(crate) fn wait_for(&self, thread: &str, count: usize) -> Vec<Hang> {
        let deadline = Instant::now() + REPORT_TIMEOUT;
        let mut hangs = self.recorded.hangs.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            let found: Vec<Hang> =
                hangs.iter().filter(|hang| hang.thread == thread).cloned().collect();
            if found.len() >= count {
                return found;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "{thread}: {count} hangs not reported in {REPORT_TIMEOUT:?}");
            hangs = self
                .recorded
                .changed
                .wait_timeout(hangs, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// Returns after at least one whole watcher pass ran on the clock as it
    /// is now: a control thread hangs twice in a row, and its second hang
    /// comes from a pass after the one that saw its first.
    pub(crate) fn full_pass(&self, control: &'static str) {
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let _registered = cmux_hang_watch::register_thread(ThreadKind::Io, control);
                for count in 1..=2 {
                    let watched = cmux_hang_watch::watch(Duration::from_millis(1));
                    self.advance(Duration::from_millis(10));
                    self.wait_for(control, count);
                    drop(watched);
                }
            });
        });
    }
}
