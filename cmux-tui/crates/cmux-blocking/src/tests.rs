use std::cell::Cell;
use std::sync::mpsc;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

use cmux_threads::blocking::{
    AllowReason, BlockingCheck, BlockingMode, allow_blocking, is_blocking_disallowed, with_mode,
};

use cmux_threads::ThreadQos;

use super::*;
use crate::runtime::ThreadHooks;

/// The thread name of the runtimes these tests build.
const TEST_RUNTIME: &str = "cmux-blocking-test";

thread_local! {
    /// `Some(false)` lets one test thread exercise the counting path; the
    /// crate's tests are strict otherwise.
    pub(crate) static STRICT_OVERRIDE: Cell<Option<bool>> = const { Cell::new(None) };
}

/// Runs `f` on this thread in the record path of both layers: this crate's
/// stall is counted and recorded instead of its strict test panic, and the
/// `cmux_threads` check records the site instead of its Debug panic
/// (`BlockingMode::Record`, what Release and `CMUX_DAEMON_BLOCKING=record`
/// do). In a Debug build `cmux_threads` panics at a stall's policy check
/// (b6e8b3cba04, Chrome's DCHECK), before this crate's route runs, so a test
/// of this crate's own stall handling needs that layer to record.
fn recording<R>(f: impl FnOnce() -> R) -> R {
    struct Restore;
    impl Drop for Restore {
        fn drop(&mut self) {
            STRICT_OVERRIDE.with(|cell| cell.set(None));
        }
    }
    STRICT_OVERRIDE.with(|cell| cell.set(Some(false)));
    let _restore = Restore;
    with_mode(BlockingMode::Record, f)
}

struct Collector(Mutex<Vec<BlockingRecord>>);

impl RecordSink for Collector {
    fn record(&self, record: &BlockingRecord) {
        self.0
            .lock()
            .expect("INVARIANT: the collector never panics while holding its lock")
            .push(record.clone());
    }
}

/// The process's sink in this test binary: one collector shared by every test.
fn collector() -> &'static Collector {
    static SHARED: OnceLock<&'static Collector> = OnceLock::new();
    SHARED.get_or_init(|| {
        let collector: &'static Collector = Box::leak(Box::new(Collector(Mutex::new(Vec::new()))));
        struct Forward(&'static Collector);
        impl RecordSink for Forward {
            fn record(&self, record: &BlockingRecord) {
                self.0.record(record);
            }
        }
        install_sink(Box::new(Forward(collector)))
            .expect("INVARIANT: only collector() installs a sink in this test binary");
        collector
    })
}

fn records_at(line: u32) -> Vec<BlockingRecord> {
    collector()
        .0
        .lock()
        .expect("INVARIANT: the collector never panics while holding its lock")
        .iter()
        .filter(|record| record.location.file() == file!() && record.location.line() == line)
        .cloned()
        .collect()
}

/// Violations `cmux_threads` recorded at `line` of this file: the shared
/// site table `server.blocking` reports.
fn policy_count_at(line: u32) -> u64 {
    cmux_threads::blocking::snapshot().site(file!(), line).map_or(0, |site| site.count)
}

fn scratch_file(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "cmux-blocking-{}-{name}-{:?}",
        std::process::id(),
        std::time::SystemTime::now()
    ));
    std::fs::write(&path, b"cmux").expect("write scratch file");
    path
}

/// A one-worker `runtime::multi_thread` runtime whose worker has parked once,
/// so the next task it runs follows an unpark (and the user hook ran).
fn one_parked_worker() -> tokio::runtime::Runtime {
    let (parked_tx, parked_rx) = mpsc::sync_channel::<()>(1);
    let hooks = ThreadHooks::new().on_thread_park(move || {
        let _ = parked_tx.try_send(());
    });
    let runtime = runtime::multi_thread_with(TEST_RUNTIME, ThreadQos::Utility, hooks)
        .worker_threads(1)
        .build()
        .expect("build runtime");
    parked_rx.recv_timeout(Duration::from_secs(10)).expect("the worker parks and the hook runs");
    runtime
}

#[test]
fn route_follows_role_flavor_and_policy() {
    let allowed = BlockingCheck::Allowed;
    let first = BlockingCheck::Violation { first_at_site: true };
    assert_eq!(route(Role::Worker, true, allowed), Route::Compensated);
    assert_eq!(route(Role::Worker, true, first), Route::Compensated, "allowance or not");
    assert_eq!(route(Role::RuntimeThread, true, allowed), Route::Unconfirmed);
    assert_eq!(route(Role::Worker, false, allowed), Route::Unknown, "never block_in_place");
    assert_eq!(route(Role::RuntimeThread, false, allowed), Route::Unknown);
    assert_eq!(route(Role::Driver, true, first), Route::Stalled { first_at_site: true });
    assert_eq!(route(Role::Driver, false, first), Route::Stalled { first_at_site: true });
    assert_eq!(route(Role::Driver, true, allowed), Route::Allowed);
    assert_eq!(route(Role::MayBlock, true, allowed), Route::Allowed);
    assert_eq!(route(Role::Unknown, true, allowed), Route::Unknown);
    assert_eq!(route(Role::Unknown, true, first), Route::Unknown);
}

#[test]
fn worker_is_compensated_so_other_tasks_keep_running() {
    // One worker: without block_in_place the receiver would hold the only
    // worker and the sender task could never run.
    let runtime = one_parked_worker();
    let before = counts();
    let (tx, rx) = mpsc::channel::<u32>();
    // Ends a deadlocked run with a wrong value instead of a hang.
    let watchdog_tx = tx.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(10));
        let _ = watchdog_tx.send(0);
    });
    let (role, received) = runtime.block_on(async {
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let waiter = tokio::spawn(async move {
            let role = current_role();
            started_tx.send(()).expect("test awaits the start");
            (role, sync::recv(&rx))
        });
        started_rx.await.expect("waiter started");
        let sender = tokio::spawn(async move { tx.send(7) });
        sender.await.expect("sender task").expect("send");
        waiter.await.expect("waiter task")
    });
    assert_eq!(role, Role::Worker);
    assert_eq!(received, Ok(7));
    assert!(counts().compensated > before.compensated);
}

#[test]
fn compensated_call_marks_nested_wrappers_may_block_then_unconfirms_the_worker() {
    let runtime = one_parked_worker();
    let roles = runtime.block_on(async {
        tokio::spawn(async {
            let outer = current_role();
            let inner = scoped_blocking_call("test::nested", BlockingKind::Fs, current_role);
            (outer, inner, current_role())
        })
        .await
        .expect("task")
    });
    assert_eq!(roles, (Role::Worker, Role::MayBlock, Role::RuntimeThread));
}

#[test]
fn raw_spawn_blocking_is_not_a_worker_and_is_not_counted_compensated() {
    let runtime = runtime::multi_thread(TEST_RUNTIME, ThreadQos::Utility)
        .worker_threads(1)
        .build()
        .expect("build runtime");
    let (role, routed) = runtime.block_on(async {
        tokio::task::spawn_blocking(|| {
            let role = current_role();
            let routed = route(role, on_multi_thread_runtime(), BlockingCheck::Allowed);
            thread::sleep(Duration::from_millis(1));
            (role, routed)
        })
        .await
        .expect("blocking task")
    });
    assert_eq!(role, Role::RuntimeThread);
    assert_eq!(routed, Route::Unconfirmed);
}

#[test]
fn multi_thread_driver_stalls_instead_of_compensating() {
    collector();
    let runtime = runtime::multi_thread(TEST_RUNTIME, ThreadQos::Utility)
        .worker_threads(1)
        .build()
        .expect("build runtime");
    let before = counts();
    let (sleep_line, role, disallowed) = recording(|| {
        runtime::block_on(&runtime, async {
            let sleep_line = line!() + 1;
            thread::sleep(Duration::from_millis(1));
            (sleep_line, current_role(), is_blocking_disallowed())
        })
    });
    assert_eq!((role, disallowed), (Role::Driver, true));
    assert_eq!((current_role(), is_blocking_disallowed()), (Role::Unknown, false));
    let records = records_at(sleep_line);
    assert_eq!(records.len(), 1, "a stall, not a compensation");
    assert_eq!(records[0].op, "thread::sleep");
    assert_eq!(records[0].kind, BlockingKind::Sleep);
    assert_eq!(policy_count_at(sleep_line), 1);
    assert!(counts().stalled > before.stalled);
}

#[test]
fn local_set_on_a_multi_thread_driver_records_stalls_and_never_panics() {
    collector();
    let runtime = runtime::multi_thread(TEST_RUNTIME, ThreadQos::Utility)
        .worker_threads(1)
        .build()
        .expect("build runtime");
    let local = tokio::task::LocalSet::new();
    let (direct_line, local_task_line) = recording(|| {
        runtime::block_on(
            &runtime,
            local.run_until(async {
                let direct_line = line!() + 1;
                thread::sleep(Duration::from_millis(1));
                let local_task_line = tokio::task::spawn_local(async {
                    let line = line!() + 1;
                    thread::sleep(Duration::from_millis(1));
                    line
                })
                .await
                .expect("local task");
                (direct_line, local_task_line)
            }),
        )
    });
    assert_eq!(records_at(direct_line).len(), 1);
    assert_eq!(records_at(local_task_line).len(), 1);
}

#[test]
fn current_thread_stall_panics_in_strict_mode_and_restores_the_thread() {
    let runtime =
        runtime::current_thread(TEST_RUNTIME, ThreadQos::Utility).build().expect("build runtime");
    // This crate's strict panic, not the `cmux_threads` Debug panic before it.
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        with_mode(BlockingMode::Record, || {
            runtime::block_on(&runtime, async { thread::sleep(Duration::from_millis(1)) });
        });
    }));
    let payload = caught.expect_err("strict mode panics on a stall");
    let message = payload.downcast_ref::<String>().expect("panic! with arguments yields a String");
    assert!(message.contains("thread::sleep"), "{message}");
    assert!(message.contains(file!()), "names the caller: {message}");
    assert_eq!((current_role(), is_blocking_disallowed()), (Role::Unknown, false));
}

#[test]
fn current_thread_stall_is_counted_and_recorded_once_per_site() {
    collector();
    let path = scratch_file("stall");
    let before = counts();
    let runtime =
        runtime::current_thread(TEST_RUNTIME, ThreadQos::Utility).build().expect("build runtime");
    let (read_line, metadata_line, reads) = recording(|| {
        runtime::block_on(&runtime, async {
            assert_eq!(current_role(), Role::Driver);
            let mut reads = Vec::new();
            // Each marker names the line below it, the wrapper's call site.
            let read_line = line!() + 2;
            for _ in 0..3 {
                reads.push(fs::read(&path).expect("read"));
            }
            let metadata_line = line!() + 1;
            let len = fs::metadata(&path).expect("metadata").len();
            assert_eq!(len, 4);
            (read_line, metadata_line, reads)
        })
    });
    assert_eq!(reads, vec![b"cmux".to_vec(); 3]);
    let after = counts();
    assert!(after.stalled >= before.stalled + 4);

    let read_records = records_at(read_line);
    assert_eq!(read_records.len(), 1, "one record for three stalls at one site");
    assert_eq!(read_records[0].op, "fs::read");
    assert_eq!(read_records[0].kind, BlockingKind::Fs);
    assert_eq!(policy_count_at(read_line), 3, "every stall is in the shared site table");
    let metadata_records = records_at(metadata_line);
    assert_eq!(metadata_records.len(), 1);
    assert_eq!(metadata_records[0].op, "fs::metadata");
    std::fs::remove_file(path).expect("remove scratch file");
}

#[test]
fn shutdown_allowance_lets_a_driver_block_without_a_stall() {
    collector();
    let runtime =
        runtime::current_thread(TEST_RUNTIME, ThreadQos::Utility).build().expect("build runtime");
    let before = counts();
    // Strict: a stall here would panic.
    let line = runtime::block_on(&runtime, async {
        allow_blocking(AllowReason::Shutdown, || {
            let line = line!() + 1;
            thread::sleep(Duration::from_millis(1));
            line
        })
    });
    assert!(records_at(line).is_empty());
    assert_eq!(policy_count_at(line), 0);
    assert!(counts().allowed > before.allowed);
}

#[test]
fn spawn_blocking_may_block_inside_a_current_thread_runtime() {
    let runtime =
        runtime::current_thread(TEST_RUNTIME, ThreadQos::Utility).build().expect("build runtime");
    let before = counts();
    let role = runtime::block_on(&runtime, async {
        spawn_blocking(|| {
            thread::sleep(Duration::from_millis(1));
            current_role()
        })
        .await
        .expect("blocking task")
    });
    assert_eq!(role, Role::MayBlock);
    assert!(counts().allowed > before.allowed);
}

#[test]
fn a_disallowed_std_thread_reports_a_wrapper_in_the_shared_table() {
    // Record mode: the site is the finding, not the Debug panic.
    let line = std::thread::spawn(|| {
        cmux_threads::disallow_blocking();
        with_mode(BlockingMode::Record, || {
            let line = line!() + 1;
            thread::sleep(Duration::from_millis(1));
            line
        })
    })
    .join()
    .expect("test thread");
    let snapshot = cmux_threads::blocking::snapshot();
    let site = snapshot.site(file!(), line).expect("cmux_threads recorded the site");
    assert_eq!(site.count, 1);
    assert_eq!(site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::Sleep]);
}

#[tokio::test]
async fn unmarked_test_runtime_counts_unknown_and_never_panics() {
    assert_eq!(current_role(), Role::Unknown);
    let before = counts();
    thread::sleep(Duration::from_millis(1));
    let pair = (Mutex::new(false), Condvar::new());
    let guard = pair.0.lock().expect("fresh mutex");
    let (_guard, timeout) =
        sync::wait_timeout(&pair.1, guard, Duration::from_millis(1)).expect("fresh mutex");
    assert!(timeout.timed_out());
    assert!(counts().unknown >= before.unknown + 2);
}

#[test]
fn plain_multi_thread_runtime_is_unknown_even_with_a_local_set_on_its_driver() {
    // A raw block_on driver running a LocalSet: tokio's block_in_place panics
    // here, which is why an unmarked runtime is never compensated.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .expect("build runtime");
    let (driver_route, worker_route) =
        runtime.block_on(tokio::task::LocalSet::new().run_until(async {
            thread::sleep(Duration::from_millis(1));
            let driver_route =
                route(current_role(), on_multi_thread_runtime(), BlockingCheck::Allowed);
            let worker_route = tokio::spawn(async {
                thread::sleep(Duration::from_millis(1));
                route(current_role(), on_multi_thread_runtime(), BlockingCheck::Allowed)
            })
            .await
            .expect("worker task");
            (driver_route, worker_route)
        }));
    assert_eq!((driver_route, worker_route), (Route::Unknown, Route::Unknown));
}

#[test]
fn strict_only_for_exactly_one() {
    use std::ffi::OsStr;
    assert!(strict_from_env_value(Some(OsStr::new("1"))));
    assert!(!strict_from_env_value(None));
    assert!(!strict_from_env_value(Some(OsStr::new("0"))));
    assert!(!strict_from_env_value(Some(OsStr::new("true"))));
}

#[test]
fn jsonl_sink_appends_one_line_with_the_callers_location() {
    let path = scratch_file("jsonl");
    std::fs::remove_file(&path).expect("start empty");
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "test".into());
    let sink = JsonlSink::new(path.clone(), fields);
    let location = Location::caller();
    sink.record(&BlockingRecord {
        op: "fs::read",
        kind: BlockingKind::Fs,
        location,
        thread: Some("worker".into()),
        blocked: Duration::from_millis(12),
    });
    let text = std::fs::read_to_string(&path).expect("read log");
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1);
    let line: serde_json::Value = serde_json::from_str(lines[0]).expect("json line");
    assert_eq!(line["process"], "test");
    assert_eq!(line["kind"], "blocking");
    assert_eq!(line["op"], "fs::read");
    assert_eq!(line["outcome"], "stalled");
    assert_eq!(line["blocking_kind"], "fs");
    assert_eq!(line["blocking_type"], "may_block");
    assert_eq!(line["thread"], "worker");
    assert_eq!(line["blocked_ms"], 12);
    assert_eq!(line["location"], format!("{}:{}:{}", file!(), location.line(), location.column()));
    assert!(line["at_ms"].as_u64().is_some_and(|at| at > 0));
    std::fs::remove_file(path).expect("remove log");
}

#[test]
fn a_second_sink_is_refused() {
    collector();
    struct Nothing;
    impl RecordSink for Nothing {
        fn record(&self, _: &BlockingRecord) {}
    }
    assert_eq!(install_sink(Box::new(Nothing)), Err(SinkAlreadyInstalled));
}
