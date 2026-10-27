//! Tokio runtimes under the process hang watch (p09-observability task 118): a task that blocks
//! its worker for 3 s gives one hang record naming that worker; parked workers, short tasks,
//! blocking-pool threads and `block_in_place` waits give none.
//!
//! Every test shares this binary's process watch, so each names its runtime and reads only the
//! records of its own threads.

use std::collections::HashSet;
use std::io;
use std::sync::{Arc, Condvar, Mutex, Once};
use std::thread;
use std::time::Duration;

use cmux_hang_watch::tokio::{WORKER_DEADLINE, WorkerHooks};
use cmux_hang_watch::{Config, Hang, HangSink, ThreadKind};

const BLOCK: Duration = Duration::from_secs(3);

static HANGS: Mutex<Vec<Hang>> = Mutex::new(Vec::new());

struct Collect;

impl HangSink for Collect {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        HANGS.lock().unwrap().push(hang.clone());
        Ok(())
    }
}

fn start_process_watch() {
    static START: Once = Once::new();
    START.call_once(|| {
        // A loaded test machine may wake the watcher late; this suite checks blame, not drift.
        let config = Config {
            min_deadline: Duration::from_millis(200),
            drift_tolerance: Duration::from_secs(2),
        };
        cmux_hang_watch::init_process(
            config,
            Arc::new(cmux_hang_watch::TraceClock),
            Box::new(Collect),
        )
        .unwrap();
    });
}

fn hangs_of(runtime: &str) -> Vec<Hang> {
    let prefix = format!("{runtime}-");
    HANGS.lock().unwrap().iter().filter(|hang| hang.thread.starts_with(&prefix)).cloned().collect()
}

/// Threads of one runtime that parked at least once, chained after the watch's park hook.
#[derive(Default)]
struct Parked {
    threads: Mutex<HashSet<thread::ThreadId>>,
    changed: Condvar,
}

impl Parked {
    fn note(&self) {
        if self.threads.lock().unwrap().insert(thread::current().id()) {
            self.changed.notify_all();
        }
    }

    /// Until `count` workers parked. A worker's run before its first park opens no scope (it never
    /// unparked), so a test that wants its task watched spawns it after this.
    fn wait_for(&self, count: usize) {
        let threads = self.threads.lock().unwrap();
        let (_threads, timeout) = self
            .changed
            .wait_timeout_while(threads, Duration::from_secs(10), |threads| threads.len() < count)
            .unwrap();
        assert!(!timeout.timed_out(), "the workers did not park");
    }
}

const WORKERS: usize = 2;

/// A multi-thread runtime with the hooks chained the way [`cmux_hang_watch::tokio::instrument`]
/// sets them, its park hook also noting parked workers.
fn runtime(name: &str) -> (tokio::runtime::Runtime, Arc<Parked>) {
    start_process_watch();
    let hooks = WorkerHooks::new(name);
    let parked = Arc::new(Parked::default());
    let watch_parked = hooks.on_thread_park();
    let note_parked = Arc::clone(&parked);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(WORKERS)
        .enable_all()
        .on_thread_start(hooks.on_thread_start())
        .on_thread_unpark(hooks.on_thread_unpark())
        .on_thread_park(move || {
            watch_parked();
            note_parked.note();
        })
        .on_thread_stop(hooks.on_thread_stop())
        .build()
        .unwrap();
    (runtime, parked)
}

#[cfg(target_vendor = "apple")]
fn native_thread_id() -> u64 {
    // SAFETY: pthread_self has no preconditions and its result is the calling thread's handle.
    u64::from(unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) })
}

#[cfg(target_os = "linux")]
fn native_thread_id() -> u64 {
    // SAFETY: gettid has no arguments and no preconditions.
    u64::try_from(unsafe { libc::syscall(libc::SYS_gettid) }).unwrap()
}

#[cfg(any(target_vendor = "apple", target_os = "linux"))]
#[test]
fn tokio_task_that_sleeps_3s_gives_one_hang_naming_its_worker() {
    let (runtime, parked) = runtime("sleep-rt");
    parked.wait_for(WORKERS);
    let busy_before = cmux_hang_watch::stats().unwrap().runtime_busy_ms;
    let worker = runtime
        .block_on(runtime.spawn(async {
            thread::sleep(BLOCK);
            native_thread_id()
        }))
        .unwrap();
    // Dropping the runtime joins its threads, so every busy period is counted.
    drop(runtime);

    let hangs = hangs_of("sleep-rt");
    assert_eq!(hangs.len(), 1, "{hangs:?}");
    let hang = &hangs[0];
    assert_eq!(hang.kind, ThreadKind::Pool);
    assert_eq!(hang.native_thread_id, worker, "{hang:?}");
    assert_eq!(hang.deadline_ms, u64::try_from(WORKER_DEADLINE.as_millis()).unwrap());
    let busy = cmux_hang_watch::stats().unwrap().runtime_busy_ms - busy_before;
    assert!(busy >= 2_900, "runtime.busy_ms grew by {busy}");
}

#[test]
fn tokio_parked_workers_short_tasks_and_blocking_threads_give_no_hang() {
    let (runtime, _parked) = runtime("quiet-rt");
    runtime.block_on(async {
        let mut tasks = Vec::new();
        for _ in 0..20 {
            tasks.push(tokio::spawn(async { thread::sleep(Duration::from_millis(20)) }));
        }
        // A worker waiting on a timer is parked, not hung.
        tasks.push(tokio::spawn(tokio::time::sleep(BLOCK)));
        // Blocking-pool threads are registered (their work opens scopes on that registration)
        // but run no worker scope, so a long blocking call is not a worker hang.
        let blocking = tokio::task::spawn_blocking(|| {
            let registered = cmux_hang_watch::watch(Duration::from_secs(60)).is_watching();
            thread::sleep(BLOCK);
            registered
        });
        for task in tasks {
            task.await.unwrap();
        }
        assert!(blocking.await.unwrap(), "a blocking-pool thread is registered");
    });
    drop(runtime);
    assert_eq!(hangs_of("quiet-rt"), Vec::new());
}

#[cfg(feature = "tokio")]
#[test]
fn tokio_block_in_place_wait_is_not_a_hang_and_the_worker_is_watched_after() {
    start_process_watch();
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.worker_threads(2).enable_all();
    let runtime = cmux_hang_watch::tokio::instrument(&mut builder, "bip-rt").build().unwrap();
    runtime
        .block_on(runtime.spawn(async {
            cmux_hang_watch::tokio::block_in_place(|| thread::sleep(BLOCK));
        }))
        .unwrap();
    assert_eq!(hangs_of("bip-rt"), Vec::new());
    runtime.block_on(runtime.spawn(async { thread::sleep(BLOCK) })).unwrap();
    drop(runtime);
    assert_eq!(hangs_of("bip-rt").len(), 1);
}
