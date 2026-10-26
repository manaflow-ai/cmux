use std::cell::Cell;
use std::sync::atomic::AtomicU64;
use std::sync::mpsc;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

use super::*;

thread_local! {
    /// `Some(false)` lets one test thread exercise the counting path; the
    /// crate's tests are strict otherwise.
    pub(crate) static STRICT_OVERRIDE: Cell<Option<bool>> = const { Cell::new(None) };
}

struct Lenient;

impl Lenient {
    fn enter() -> Self {
        STRICT_OVERRIDE.with(|cell| cell.set(Some(false)));
        Self
    }
}

impl Drop for Lenient {
    fn drop(&mut self) {
        STRICT_OVERRIDE.with(|cell| cell.set(None));
    }
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

fn scratch_file(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "cmux-blocking-{}-{name}-{:?}",
        std::process::id(),
        std::time::SystemTime::now()
    ));
    std::fs::write(&path, b"cmux").expect("write scratch file");
    path
}

#[test]
fn multi_thread_worker_is_compensated_so_other_tasks_keep_running() {
    // One worker: without block_in_place the receiver would hold the only
    // worker and the sender task could never run.
    let runtime = runtime::multi_thread().worker_threads(1).build().expect("build runtime");
    let before = counts();
    let (tx, rx) = mpsc::channel::<u32>();
    // Ends a deadlocked run with a wrong value instead of a hang.
    let watchdog_tx = tx.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(10));
        let _ = watchdog_tx.send(0);
    });
    let received = runtime.block_on(async {
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let waiter = tokio::spawn(async move {
            assert_eq!(current_thread_kind(), ThreadKind::NoBlock);
            started_tx.send(()).expect("test awaits the start");
            sync::recv(&rx)
        });
        started_rx.await.expect("waiter started");
        let sender = tokio::spawn(async move { tx.send(7) });
        sender.await.expect("sender task").expect("send");
        waiter.await.expect("waiter task")
    });
    assert_eq!(received, Ok(7));
    assert!(counts().compensated > before.compensated);
}

#[test]
fn raw_spawn_blocking_on_a_marked_runtime_runs_the_call() {
    let runtime = runtime::multi_thread().worker_threads(1).build().expect("build runtime");
    let kind = runtime.block_on(async {
        tokio::task::spawn_blocking(|| {
            let kind = current_thread_kind();
            thread::sleep(Duration::from_millis(1));
            kind
        })
        .await
        .expect("blocking task")
    });
    assert_eq!(kind, ThreadKind::NoBlock);
}

#[test]
fn current_thread_stall_panics_in_strict_mode_and_restores_the_kind() {
    let runtime = runtime::current_thread().build().expect("build runtime");
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime::block_on(&runtime, async { thread::sleep(Duration::from_millis(1)) });
    }));
    let payload = caught.expect_err("strict mode panics on a stall");
    let message = payload.downcast_ref::<String>().expect("panic! with arguments yields a String");
    assert!(message.contains("thread::sleep"), "{message}");
    assert!(message.contains(file!()), "names the caller: {message}");
    assert_eq!(current_thread_kind(), ThreadKind::Unknown);
}

#[test]
fn current_thread_stall_is_counted_and_recorded_once_per_site() {
    collector();
    let _lenient = Lenient::enter();
    let path = scratch_file("stall");
    let before = counts();
    let runtime = runtime::current_thread().build().expect("build runtime");
    let (read_line, metadata_line, reads) = runtime::block_on(&runtime, async {
        assert_eq!(current_thread_kind(), ThreadKind::NoBlock);
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
    });
    assert_eq!(reads, vec![b"cmux".to_vec(); 3]);
    let after = counts();
    assert!(after.stalled >= before.stalled + 4);

    let read_records = records_at(read_line);
    assert_eq!(read_records.len(), 1, "one record for three stalls at one site");
    assert_eq!(read_records[0].op, "fs::read");
    assert_eq!(read_records[0].outcome, Outcome::Stalled);
    assert_eq!(read_records[0].blocking_type, BlockingType::MayBlock);
    let metadata_records = records_at(metadata_line);
    assert_eq!(metadata_records.len(), 1);
    assert_eq!(metadata_records[0].op, "fs::metadata");
    std::fs::remove_file(path).expect("remove scratch file");
}

#[test]
fn spawn_blocking_may_block_inside_a_current_thread_runtime() {
    let runtime = runtime::current_thread().build().expect("build runtime");
    let before = counts();
    let kind = runtime::block_on(&runtime, async {
        spawn_blocking(|| {
            thread::sleep(Duration::from_millis(1));
            current_thread_kind()
        })
        .await
        .expect("blocking task")
    });
    assert_eq!(kind, ThreadKind::MayBlock);
    assert!(counts().allowed > before.allowed);
}

#[tokio::test]
async fn unmarked_test_runtime_counts_unknown_and_never_panics() {
    assert_eq!(current_thread_kind(), ThreadKind::Unknown);
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
fn thread_kind_scopes_nest_and_restore() {
    assert_eq!(current_thread_kind(), ThreadKind::Unknown);
    {
        let _outer = ThreadKindScope::enter(ThreadKind::NoBlock);
        {
            let _inner = ThreadKindScope::enter(ThreadKind::MayBlock);
            assert_eq!(current_thread_kind(), ThreadKind::MayBlock);
        }
        assert_eq!(current_thread_kind(), ThreadKind::NoBlock);
    }
    assert_eq!(current_thread_kind(), ThreadKind::Unknown);
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
fn site_table_dedupes_and_reports_full() {
    let table = [const { AtomicU64::new(0) }; 2];
    assert_eq!(sites::insert(&table, 5), sites::Seen::First);
    assert_eq!(sites::insert(&table, 6), sites::Seen::First);
    assert_eq!(sites::insert(&table, 5), sites::Seen::Before);
    assert_eq!(sites::insert(&table, 7), sites::Seen::TableFull);
}

#[test]
fn site_keys_differ_by_line_and_are_never_zero() {
    let first = Location::caller();
    let second = Location::caller();
    assert_ne!(sites::site_key(first), sites::site_key(second));
    assert_eq!(sites::site_key(first), sites::site_key(first));
    assert_ne!(sites::site_key(first), 0);
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
        blocking_type: BlockingType::MayBlock,
        outcome: Outcome::Stalled,
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

#[test]
fn compensated_call_marks_nested_wrappers_may_block() {
    let runtime = runtime::multi_thread().worker_threads(2).build().expect("build runtime");
    let kinds = runtime.block_on(async {
        tokio::spawn(async {
            let outer = current_thread_kind();
            let inner =
                scoped_blocking_call("test::nested", BlockingType::MayBlock, current_thread_kind);
            (outer, inner, current_thread_kind())
        })
        .await
        .expect("task")
    });
    assert_eq!(kinds, (ThreadKind::NoBlock, ThreadKind::MayBlock, ThreadKind::NoBlock));
}
