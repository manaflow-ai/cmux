//! The process-wide API ([`cmux_trace::init_blackbox`], [`cmux_trace::write`], the thread-local
//! writer and its TLS destructor). Each case runs in a child of this test binary, so each starts
//! with fresh globals.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::path::{Path, PathBuf};

use cmux_trace::names::catalog_id;
use cmux_trace::{InternedName, Phase, Role, category, decode};

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn allocations() -> usize {
    ALLOCATIONS.with(Cell::get)
}

/// Two names of the shared catalog every process ring starts with.
const ACTION: u16 = catalog_id("action.perform");
const MOTION: u16 = catalog_id("motion.frame");

static READ: InternedName = InternedName::new("cmux.io.read", 6);

fn scratch_dir(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-trace-process-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Runs `mode` of [`child_process`] in a child of this test binary; true when it succeeded.
fn run_child(mode: &str, dir: &Path) -> std::process::ExitStatus {
    std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args(["--exact", "child_process", "--nocapture", "--test-threads=1"])
        .env("CMUX_TRACE_TEST_CHILD", mode)
        .env("CMUX_TRACE_TEST_DIR", dir)
        .status()
        .expect("runs the child")
}

/// The child half of the process-wide tests (does nothing in a normal run).
#[test]
fn child_process() {
    let (Some(mode), Some(dir)) =
        (std::env::var_os("CMUX_TRACE_TEST_CHILD"), std::env::var_os("CMUX_TRACE_TEST_DIR"))
    else {
        return;
    };
    let dir = PathBuf::from(dir);
    match mode.to_str() {
        Some("abort") => child_abort(&dir),
        Some("lifecycle") => child_lifecycle(&dir),
        Some("alloc") => child_alloc(&dir),
        Some("threads") => child_threads(&dir),
        other => panic!("unknown child mode {other:?}"),
    }
}

fn read(path: &Path) -> cmux_trace::Decoded {
    decode(&std::fs::read(path).expect("reads")).expect("decodes")
}

#[cfg(unix)]
fn ring_files(dir: &Path) -> (PathBuf, PathBuf) {
    let files: Vec<PathBuf> =
        std::fs::read_dir(dir).expect("lists").map(|entry| entry.expect("entry").path()).collect();
    assert_eq!(files.len(), 2, "expected a black box and a recording, got {files:?}");
    let find = |suffix: &str| {
        files.iter().find(|path| path.to_string_lossy().ends_with(suffix)).cloned().expect(suffix)
    };
    (find(".blackbox.cmxtrace"), find(".recording.cmxtrace"))
}

#[test]
fn a_trace_point_that_is_off_allocates_nothing() {
    // This test binary never starts tracing in-process, so every category is off.
    assert!(!cmux_trace::enabled(category::ALL));
    let before = allocations();
    for index in 0..10_000 {
        cmux_trace::write(category::KEY, ACTION, Phase::Instant, 0, index, 0);
        cmux_trace::write_at(category::FRAME, index, 2, Phase::Begin, 0, 0, 0);
        cmux_trace::write_interned(category::DAEMON, &READ, Phase::Instant, 0, index, 0);
    }
    assert_eq!(allocations() - before, 0, "a trace point that is off allocated");
}

fn child_abort(dir: &Path) {
    let open = cmux_trace::init_blackbox(dir, Role::Daemon).expect("first init");
    for index in 0..1_000 {
        cmux_trace::write(category::ACTION, ACTION, Phase::Instant, 0, index, 0);
    }
    open.wait().expect("the black box moved into its file");
    for index in 1_000..2_000 {
        cmux_trace::write(category::ACTION, ACTION, Phase::Instant, 0, index, 0);
    }
    cmux_trace::start_recording(category::ALL).expect("starts");
    for index in 0..5_000 {
        cmux_trace::write(category::MOTION, MOTION, Phase::Instant, 0, index, 0);
    }
    std::process::abort();
}

/// A crash leaves both rings decodable: the owned chunk is odd and its published slots whole.
#[cfg(unix)]
#[test]
fn a_child_that_aborts_leaves_rings_that_decode() {
    let dir = scratch_dir("abort");
    assert!(!run_child("abort", &dir).success(), "the child was meant to abort");
    let (blackbox, recording) = ring_files(&dir);
    let decoded = read(&blackbox);
    assert_eq!(decoded.header.role, Role::Daemon as u16);
    assert_ne!(decoded.header.pid, std::process::id());
    assert!(blackbox.to_string_lossy().contains(&format!("daemon-{}.", decoded.header.pid)));
    assert_ne!(decoded.header.boot_session_uuid, [0; 16], "the file has no boot session");
    let mut indices: Vec<u64> = decoded.records.iter().map(|record| record.arg0).collect();
    indices.sort_unstable();
    let before = indices.len();
    indices.dedup();
    assert_eq!(indices.len(), before, "a black-box record decoded twice");
    // The ring was quiet while it moved into its file, so nothing was lost.
    assert!(indices.iter().copied().eq(0..2_000), "black-box records are missing");
    assert_eq!(decoded.header.heap_chunks_lost, 0);

    let decoded = read(&recording);
    let indices: Vec<u64> = decoded.records.iter().map(|record| record.arg0).collect();
    assert!(indices.iter().copied().eq(0..5_000), "the recording lost or reordered records");
    assert!(decoded.records.iter().all(|record| record.name == MOTION));
    let _ = std::fs::remove_dir_all(&dir);
}

fn child_lifecycle(dir: &Path) {
    assert_eq!(cmux_trace::start_recording(0), Err(cmux_trace::TraceError::NotInitialized));
    assert!(cmux_trace::status().is_none());
    let open = cmux_trace::init_blackbox(dir, Role::Daemon).expect("first init");
    assert!(
        cmux_trace::init_blackbox(dir, Role::App).is_none(),
        "a second init replaced the black box"
    );
    let blackbox = open.wait().expect("adopts");
    assert!(cmux_trace::enabled(category::ACTION) && !cmux_trace::enabled(category::MOTION));
    cmux_trace::write(category::ACTION, ACTION, Phase::Instant, 0, 1, 0);
    cmux_trace::write(category::MOTION, MOTION, Phase::Instant, 0, 2, 0);

    let status = cmux_trace::start_recording(category::MOTION).expect("starts");
    assert!(status.recording && status.recording_file_backed);
    let recording = status.recording_path.expect("recording path");
    cmux_trace::write(category::ACTION, ACTION, Phase::Instant, 0, 3, 0);
    cmux_trace::write(category::MOTION, MOTION, Phase::Instant, 0, 4, 0);
    cmux_trace::write_interned(category::DAEMON, &READ, Phase::Instant, 0, 5, 0);
    cmux_trace::stop().expect("stops");
    assert!(!cmux_trace::enabled(category::MOTION));
    cmux_trace::write(category::ACTION, ACTION, Phase::Instant, 0, 6, 0);
    cmux_trace::write(category::MOTION, MOTION, Phase::Instant, 0, 7, 0);

    let pairs = |decoded: &cmux_trace::Decoded| -> Vec<(Option<String>, u64)> {
        decoded.records.iter().map(|r| (decoded.name(r.name).map(str::to_owned), r.arg0)).collect()
    };
    let named = |text: &str, arg0| (Some(text.to_owned()), arg0);
    let decoded = read(&blackbox);
    assert_eq!(pairs(&decoded), [named("action.perform", 1), named("action.perform", 6)]);
    let decoded = read(&recording);
    assert_eq!(
        pairs(&decoded),
        [named("action.perform", 3), named("motion.frame", 4), named("cmux.io.read", 5)],
        "the recording's own table must name every record"
    );
    assert_eq!(decoded.threads.len(), 1, "one writer thread, one entry");
    assert!(cmux_trace::snapshot_active().is_some_and(|bytes| decode(&bytes).is_ok()));
}

#[test]
fn start_record_stop_through_the_process_api() {
    let dir = scratch_dir("lifecycle");
    assert!(
        run_child("lifecycle", &dir).success(),
        "the lifecycle child failed (see its output above)"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

fn child_alloc(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Holder).expect("first init").wait().ok();
    cmux_trace::write(category::KEY, ACTION, Phase::Instant, 0, 0, 0);
    cmux_trace::write_interned(category::DAEMON, &READ, Phase::Instant, 0, 0, 0);
    let before = allocations();
    for index in 0..10_000 {
        cmux_trace::write(category::KEY, ACTION, Phase::Instant, 0, index, 0);
        cmux_trace::write(category::FRAME, MOTION, Phase::Instant, 0, index, 0);
        cmux_trace::write_interned(category::DAEMON, &READ, Phase::Instant, 0, index, 0);
    }
    assert_eq!(allocations() - before, 0, "a recorded trace point allocated");
}

#[test]
fn a_recorded_trace_point_allocates_nothing() {
    let dir = scratch_dir("alloc");
    assert!(
        run_child("alloc", &dir).success(),
        "the allocation child failed (see its output above)"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// 1000 threads write once each and exit in a terminal host (256 thread entries): the TLS
/// destructor frees each entry, so none is unknown and the last thread is attributed.
fn child_threads(dir: &Path) {
    let blackbox = cmux_trace::init_blackbox(dir, Role::TerminalHost)
        .expect("first init")
        .wait()
        .expect("adopts");
    for index in 0..1_000u64 {
        std::thread::Builder::new()
            .name(format!("short-{index}"))
            .spawn(move || cmux_trace::write(category::ACTION, ACTION, Phase::Instant, 0, index, 0))
            .expect("spawns")
            .join()
            .expect("joins");
    }
    let decoded = read(&blackbox);
    assert_eq!(decoded.header.thread_overflow, 0, "a thread found the table full");
    let last = decoded.records.iter().find(|record| record.arg0 == 999).expect("the last record");
    let thread = decoded.thread_of(last).expect("the last thread is attributed");
    assert_eq!((thread.name.as_str(), thread.state), ("short-999", 3));
}

#[cfg(unix)]
#[test]
fn short_lived_threads_free_their_entries_at_exit() {
    let dir = scratch_dir("threads");
    assert!(
        run_child("threads", &dir).success(),
        "the threads child failed (see its output above)"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
