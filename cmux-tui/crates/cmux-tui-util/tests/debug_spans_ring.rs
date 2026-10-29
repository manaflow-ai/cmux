//! `debug_spans` in the trace ring and the marks file: a trace is an async
//! slice with its marks as thread instants, and each JSON line (a followed
//! terminal's too) carries the arrival on the trace clock and the writing
//! thread. Each case runs in a child of this
//! test binary, so each starts with fresh process globals (the tracer, the
//! marks file).

use std::borrow::Cow;
use std::path::{Path, PathBuf};
use std::time::Instant;

use cmux_trace::{DecodedRecord, FLAG_ID, Phase, Role, decode};
use cmux_tui_util::debug_spans;
use serde_json::Value;

fn scratch_dir(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-debug-spans-ring-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Runs `mode` of [`child_process`] in a child of this test binary, with the
/// marks file `spans` when given; panics unless the child passed.
fn run_child(mode: &str, dir: &Path, spans: Option<&Path>) {
    let mut command = std::process::Command::new(std::env::current_exe().expect("test binary"));
    command
        .args(["--exact", "child_process", "--nocapture", "--test-threads=1"])
        .env("CMUX_DEBUG_SPANS_TEST_CHILD", mode)
        .env("CMUX_DEBUG_SPANS_TEST_DIR", dir)
        .env_remove("CMUX_TUI_DEBUG_SPANS");
    if let Some(spans) = spans {
        command.env("CMUX_TUI_DEBUG_SPANS", spans);
    }
    let status = command.status().expect("runs the child");
    assert!(status.success(), "child {mode} failed: {status}");
}

/// The child half of the tests (does nothing in a normal run).
#[test]
fn child_process() {
    let (Some(mode), Some(dir)) = (
        std::env::var_os("CMUX_DEBUG_SPANS_TEST_CHILD"),
        std::env::var_os("CMUX_DEBUG_SPANS_TEST_DIR"),
    ) else {
        return;
    };
    let dir = PathBuf::from(dir);
    match mode.to_str() {
        Some("ring") => child_ring(&dir),
        Some("ring_only") => child_ring_only(&dir),
        Some("category_toggle") => child_category_toggle(&dir),
        Some("off") => child_off(),
        other => panic!("unknown child mode {other:?}"),
    }
}

/// Starts this process's black box in `dir` and waits until its ring file is
/// the active ring. Until then the heap ring is active, and the
/// `cmux-trace-open` thread copies it into the file and swaps: a record a
/// thread adds to a heap chunk after that chunk was copied and before the
/// swap is not in the file (trace.md "Heap, then file"), so a test that
/// writes during the copy would read a ring without it.
fn black_box_in_file(dir: &Path) {
    let open =
        cmux_trace::init_blackbox(dir.join("rings"), Role::Daemon).expect("a fresh black box");
    open.wait().expect("the black box moved into its file");
}

/// The records of the active ring named `name`.
fn records_named<'a>(decoded: &'a cmux_trace::Decoded, name: &str) -> Vec<&'a DecodedRecord> {
    decoded.records.iter().filter(|record| decoded.name(record.name) == Some(name)).collect()
}

fn ring() -> cmux_trace::Decoded {
    decode(&cmux_trace::snapshot_active().expect("tracing started")).expect("the ring decodes")
}

/// The terminal the followed create names.
const TERMINAL: &str = "00000000000040008000000000000058";

/// A create that hops threads and follows its terminal, then one dropped
/// unfinished, with both sinks on.
fn child_ring(dir: &Path) {
    black_box_in_file(dir);
    let trace = debug_spans::Trace::start("new-tab", Instant::now()).expect("marks are on");
    debug_spans::install(Some(trace));
    debug_spans::mark("job.start");
    let trace = debug_spans::take();
    let job_tid = std::thread::spawn(move || {
        debug_spans::install(trace);
        debug_spans::mark("commit.start");
        debug_spans::mark_with(|| Cow::Borrowed("lock.wait computed"));
        debug_spans::follow(TERMINAL);
        debug_spans::mark("reply.queued");
        debug_spans::finish(debug_spans::take());
        cmux_trace::ThreadIdentity::current().tid
    })
    .join()
    .expect("the commit thread");
    assert!(debug_spans::following(), "the create follows its terminal");
    let [first, rest @ ..] = debug_spans::FOLLOW_MARKS;
    debug_spans::terminal_mark(TERMINAL, first);
    let main_tid = cmux_trace::ThreadIdentity::current().tid;
    let output_tid = std::thread::spawn(move || {
        for name in rest {
            debug_spans::terminal_mark(TERMINAL, name);
        }
        cmux_trace::ThreadIdentity::current().tid
    })
    .join()
    .expect("the output thread");
    assert!(!debug_spans::following(), "every follow mark was paid");

    debug_spans::install(debug_spans::Trace::start("pane-create", Instant::now()));
    debug_spans::mark("prelaunch.done");
    drop(debug_spans::take());

    let decoded = ring();
    let begins = records_named(&decoded, "new-tab");
    assert_eq!(begins.len(), 2, "one begin and one end: {begins:?}");
    let (begin, end) = (begins[0], begins[1]);
    assert_eq!(begin.phase, Phase::AsyncBegin as u8);
    assert_eq!(end.phase, Phase::AsyncEnd as u8);
    assert_eq!(begin.arg1, end.arg1, "the pair shares its id");
    assert!(begin.flags & FLAG_ID != 0 && end.flags & FLAG_ID != 0);
    let id = begin.arg1;
    let mut since_arrival = 0;
    for name in ["job.start", "commit.start", "reply.queued"] {
        let marks = records_named(&decoded, name);
        assert_eq!(marks.len(), 1, "{name}: {marks:?}");
        let mark = marks[0];
        assert_eq!(mark.phase, Phase::Instant as u8, "{name}");
        assert_eq!((mark.flags, mark.arg1), (0, 0), "{name} is a plain thread instant");
        assert!(mark.arg0 >= since_arrival, "{name}: arg0 is the time since arrival");
        since_arrival = mark.arg0;
        assert!(begin.t_ns <= mark.t_ns && mark.t_ns <= end.t_ns, "{name} is in the slice");
    }
    let commit = records_named(&decoded, "commit.start")[0];
    assert_eq!(decoded.thread_of(commit).map(|thread| thread.tid), Some(job_tid));
    assert!(
        decoded.names.iter().all(|entry| !entry.text.contains("computed")),
        "a computed name reached the ring"
    );

    let dropped = records_named(&decoded, "pane-create");
    let phases: Vec<u8> = dropped.iter().map(|record| record.phase).collect();
    assert_eq!(phases, [Phase::AsyncBegin as u8, Phase::AsyncEnd as u8], "dropping ends it");
    assert_ne!(dropped[0].arg1, id, "each trace has its own id");

    let spans = std::fs::read_to_string(dir.join("spans.jsonl")).expect("the marks file");
    let lines: Vec<Value> =
        spans.lines().map(|line| serde_json::from_str(line).expect("a JSON line")).collect();
    assert_eq!(lines.len(), 5, "the finished trace and its follow marks: {spans}");
    let line = &lines[0];
    assert_eq!(line["label"], "new-tab");
    assert_eq!(line["terminal"], TERMINAL);
    assert_eq!(line["tid"].as_u64(), Some(job_tid));
    assert!(
        line["total_us"].as_u64().is_some_and(|total| total >= since_arrival),
        "the ring marks fall inside the trace"
    );
    let start_uptime_ns = line["start_uptime_ns"].as_u64().expect("start_uptime_ns");
    assert!(
        start_uptime_ns <= begin.t_ns && begin.t_ns - start_uptime_ns < 1_000_000_000,
        "the arrival {start_uptime_ns} and the ring begin {} are on one clock",
        begin.t_ns
    );
    let names: Vec<&str> =
        line["marks"].as_array().unwrap().iter().filter_map(|mark| mark[0].as_str()).collect();
    assert_eq!(names, ["job.start", "commit.start", "lock.wait computed", "reply.queued"]);

    let writers = [main_tid, output_tid, output_tid, output_tid];
    for ((follow, name), tid) in lines[1..].iter().zip(debug_spans::FOLLOW_MARKS).zip(writers) {
        assert_eq!(follow["label"], "new-tab.follow", "{follow}");
        assert_eq!(follow["terminal"], TERMINAL, "{follow}");
        assert_eq!(follow["marks"][0][0], name, "{follow}");
        assert_eq!(
            follow["start_uptime_ns"].as_u64(),
            Some(start_uptime_ns),
            "one arrival: {follow}"
        );
        assert_eq!(follow["tid"].as_u64(), Some(tid), "the writing thread: {follow}");
    }
    assert_ne!(main_tid, output_tid);
}

/// The ring alone: a trace starts, writes no file and runs no computed name.
fn child_ring_only(dir: &Path) {
    black_box_in_file(dir);
    debug_spans::install(debug_spans::Trace::start("create", Instant::now()));
    debug_spans::mark("job.start");
    debug_spans::mark_with(|| panic!("a computed name ran with no marks file"));
    debug_spans::label_terminal(|| panic!("a terminal name ran with no marks file"));
    debug_spans::follow("00000000000040008000000000000058");
    assert!(!debug_spans::following(), "the ring follows no terminal");
    debug_spans::finish(debug_spans::take());

    let decoded = ring();
    let phases: Vec<u8> =
        records_named(&decoded, "create").iter().map(|record| record.phase).collect();
    assert_eq!(phases, [Phase::AsyncBegin as u8, Phase::AsyncEnd as u8]);
    assert_eq!(records_named(&decoded, "job.start").len(), 1);
}

/// The daemon category goes off while a trace is installed (a recording
/// stops, with a black box that leaves it off): the trace still moves, and a
/// registry connection opened before the tracer marks its commits once the
/// ring records.
fn child_category_toggle(dir: &Path) {
    let connection =
        debug_spans::traced(rusqlite::Connection::open_in_memory().expect("an in-memory database"));
    let mut config = cmux_trace::TracerConfig::for_process(dir.join("rings"), Role::Daemon);
    config.blackbox_categories &= !cmux_trace::category::DAEMON;
    let _open = cmux_trace::init_process(config);
    assert!(debug_spans::Trace::start("new-tab", Instant::now()).is_none(), "both sinks are off");

    cmux_trace::start_recording(cmux_trace::category::DAEMON).expect("a recording starts");
    debug_spans::install(debug_spans::Trace::start("new-tab", Instant::now()));
    connection.execute_batch("CREATE TABLE t (x); INSERT INTO t VALUES (1);").expect("a commit");
    let decoded = ring();
    let commits = records_named(&decoded, "sqlite.commit");
    assert!(!commits.is_empty(), "a hook installed before the tracer marks the commit");
    assert!(commits.iter().all(|record| record.phase == Phase::Instant as u8));

    cmux_trace::stop().expect("the recording stops");
    assert!(!cmux_trace::enabled(cmux_trace::category::DAEMON));
    assert!(debug_spans::take().is_some(), "the trace moves after the ring stops");
    assert!(debug_spans::take().is_none(), "the thread holds no trace");
}

/// Neither sink: no trace starts.
fn child_off() {
    assert!(debug_spans::Trace::start("new-tab", Instant::now()).is_none());
    debug_spans::mark("job.start");
    assert!(debug_spans::take().is_none());
}

#[test]
fn a_trace_is_an_async_slice_in_the_ring_and_a_line_on_the_uptime_clock() {
    let dir = scratch_dir("ring");
    run_child("ring", &dir, Some(&dir.join("spans.jsonl")));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_ring_alone_records_a_trace_without_the_marks_file() {
    let dir = scratch_dir("ring-only");
    run_child("ring_only", &dir, None);
    assert!(!dir.join("spans.jsonl").exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_trace_outlives_its_category_and_late_tracing_marks_commits() {
    let dir = scratch_dir("category-toggle");
    run_child("category_toggle", &dir, None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn with_both_sinks_off_no_trace_starts() {
    let dir = scratch_dir("off");
    run_child("off", &dir, None);
    let _ = std::fs::remove_dir_all(&dir);
}
