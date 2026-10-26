//! The trace macros (`trace_scope!` and the others) over the process ring, the thread's scope stack
//! and the shared catalog. Cases that start tracing run in a child of this test binary, so each
//! starts with fresh globals; this binary itself never starts tracing, so every category is off here.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use cmux_trace::names::{CATALOG, catalog_id};
use cmux_trace::{
    Decoded, DecodedRecord, FLAG_ID, NameKind, Phase, Role, SCOPE_SLOTS, SCOPE_STACK_DEPTH,
    TracerConfig, category, decode, scope_stack, trace_async_begin, trace_async_end, trace_counter,
    trace_flow_in, trace_flow_out, trace_instant, trace_scope,
};

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

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-trace-macros-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Runs `mode` of [`child_process`] in a child of this test binary and asserts it succeeded.
fn run_child(mode: &str) {
    let dir = scratch_dir(mode);
    let status = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args(["--exact", "child_process", "--nocapture", "--test-threads=1"])
        .env("CMUX_TRACE_TEST_CHILD", mode)
        .env("CMUX_TRACE_TEST_DIR", &dir)
        .status()
        .expect("runs the child");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "the {mode} child failed (see its output above)");
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
        Some("nested") => child_nested(&dir),
        Some("async") => child_async(&dir),
        Some("points") => child_points(&dir),
        Some("stack") => child_stack(&dir),
        Some("alloc") => child_alloc(&dir),
        Some("rings") => child_rings(&dir),
        Some("catalog") => child_catalog(&dir),
        other => panic!("unknown child mode {other:?}"),
    }
}

/// Starts the black box as the daemon and waits for its file.
fn start(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
}

fn snapshot() -> Decoded {
    decode(&cmux_trace::snapshot_active().expect("initialised")).expect("decodes")
}

/// The records of the thread that wrote `first`, in the order it wrote them.
fn thread_records(decoded: &Decoded, first: &DecodedRecord) -> Vec<DecodedRecord> {
    let mut records: Vec<DecodedRecord> = decoded
        .records
        .iter()
        .filter(|record| {
            (record.thread_index, record.thread_generation)
                == (first.thread_index, first.thread_generation)
        })
        .copied()
        .collect();
    records.sort_by_key(|record| (record.position, record.slot));
    records
}

fn text(decoded: &Decoded, record: &DecodedRecord) -> String {
    decoded.name(record.name).unwrap_or("<no name>").to_owned()
}

// MARK: off

#[test]
fn a_trace_point_that_is_off_records_nothing_and_evaluates_no_argument() {
    assert!(!cmux_trace::enabled(category::ALL), "this test binary never starts tracing");
    let evaluated = Cell::new(0u32);
    let arg = || {
        evaluated.set(evaluated.get() + 1);
        7u64
    };
    let before = allocations();
    for _ in 0..1_000 {
        let mut scope = trace_scope!(daemon, "daemon.request", arg(), arg());
        scope.set_end_args(1u64, 2u64);
        let _inner = trace_scope!(daemon, "daemon.request.parse", arg());
        trace_instant!(daemon, "daemon.request.parsed", arg(), arg());
        trace_async_begin!(daemon, "daemon.url_open", arg(), arg());
        trace_async_end!(daemon, "daemon.url_open", arg(), arg());
        trace_flow_out!(key, "key.flow", arg(), arg());
        trace_flow_in!(key, "key.flow", arg());
        trace_counter!(frame, "frame.sequence", arg(), arg());
    }
    assert_eq!(allocations() - before, 0, "a trace point that is off allocated");
    assert_eq!(evaluated.get(), 0, "a trace point that is off evaluated its arguments");
    assert_eq!(scope_stack().depth(), 0, "a scope that is off went on the stack");
}

// MARK: scopes

fn child_nested(dir: &Path) {
    start(dir);
    {
        let mut outer = trace_scope!(daemon, "daemon.request", 3u16, 0xfeed_u64);
        {
            let _inner = trace_scope!(daemon, "daemon.request.parse", 1u8);
            trace_instant!(daemon, "daemon.request.parsed", 9u32);
            let _innermost = trace_scope!(daemon, "daemon.request.validate");
        }
        let _second = trace_scope!(daemon, "daemon.request.dispatch", -1i32);
        outer.set_end_args(200u64, true);
    }
    let decoded = snapshot();
    let first = decoded.records.first().expect("records");
    let records = thread_records(&decoded, first);
    let shape: Vec<(char, String)> =
        records.iter().map(|record| (record.phase as char, text(&decoded, record))).collect();
    let expected = [
        ('B', "daemon.request"),
        ('B', "daemon.request.parse"),
        ('I', "daemon.request.parsed"),
        ('B', "daemon.request.validate"),
        ('E', "daemon.request.validate"),
        ('E', "daemon.request.parse"),
        ('B', "daemon.request.dispatch"),
        ('E', "daemon.request.dispatch"),
        ('E', "daemon.request"),
    ];
    let expected: Vec<(char, String)> =
        expected.iter().map(|(phase, name)| (*phase, (*name).to_owned())).collect();
    assert_eq!(shape, expected, "the scopes did not decode as nested B/E pairs");

    // Every E closes the innermost open B of the same name, no earlier than it began.
    let mut open: Vec<&DecodedRecord> = Vec::new();
    for record in &records {
        match Phase::from_raw(record.phase) {
            Some(Phase::Begin) => open.push(record),
            Some(Phase::End) => {
                let begin = open.pop().expect("an E with no open B");
                assert_eq!(begin.name, record.name);
                assert!(record.t_ns >= begin.t_ns, "a scope ended before it began");
            }
            _ => {}
        }
    }
    assert!(open.is_empty(), "a scope never ended");

    let outer_begin = &records[0];
    assert_eq!(outer_begin.name, catalog_id("daemon.request"), "a catalog name keeps its id");
    assert_eq!((outer_begin.arg0, outer_begin.arg1), (3, 0xfeed));
    assert_eq!(records[6].arg0, u64::MAX, "a signed argument is stored as two's complement");
    let outer_end = records.last().expect("the outer end");
    assert_eq!((outer_end.arg0, outer_end.arg1), (200, 1), "set_end_args reaches the E record");
    assert!(
        decoded.names.iter().any(|entry| entry.text == "daemon.request.parse"
            && entry.kind == NameKind::Interned as u8
            && entry.category == 6),
        "a name outside the catalog is interned under its category"
    );
}

#[test]
fn nested_scopes_decode_as_nested_begin_end_pairs() {
    run_child("nested");
}

// MARK: scopes across trace.start and trace.stop

/// The B/E records of `decoded`, paired per thread: (tags of whole pairs, tags of open begins). A
/// begin's tag is its `arg0`, and its end carries the same tag (`set_end_args`). Panics on an end
/// with no open begin, or one that closes another scope's begin.
fn pairs(decoded: &Decoded) -> (Vec<u64>, Vec<u64>) {
    let mut by_thread: HashMap<(u32, u32), Vec<DecodedRecord>> = HashMap::new();
    for record in &decoded.records {
        by_thread.entry((record.thread_index, record.thread_generation)).or_default().push(*record);
    }
    let (mut whole, mut open_tags) = (Vec::new(), Vec::new());
    for records in by_thread.values_mut() {
        records.sort_by_key(|record| (record.position, record.slot));
        let mut open: Vec<DecodedRecord> = Vec::new();
        for record in records.iter() {
            match Phase::from_raw(record.phase) {
                Some(Phase::Begin) => open.push(*record),
                Some(Phase::End) => {
                    let begin = open.pop().unwrap_or_else(|| {
                        panic!("an E with no B: {} tag {}", text(decoded, record), record.arg0)
                    });
                    assert_eq!(
                        (begin.name, begin.arg0),
                        (record.name, record.arg0),
                        "an E closed another B"
                    );
                    whole.push(begin.arg0);
                }
                _ => {}
            }
        }
        open_tags.extend(open.iter().map(|record| record.arg0));
    }
    whole.sort_unstable();
    open_tags.sort_unstable();
    (whole, open_tags)
}

fn tagged_scope(tag: u64) -> cmux_trace::ScopeGuard {
    let mut scope = trace_scope!(daemon, "daemon.request", tag);
    scope.set_end_args(tag, 0u64);
    scope
}

fn child_rings(dir: &Path) {
    start(dir);
    let read = |path: &Path| decode(&std::fs::read(path).expect("reads")).expect("decodes");
    let open_across_start = tagged_scope(1);
    cmux_trace::start_recording(0).expect("starts the first recording");
    drop(open_across_start);
    drop(tagged_scope(2));
    let open_across_restart = tagged_scope(3);
    let first = cmux_trace::stop().expect("stops the first recording");
    let recording = first.recording_path.expect("a recording file");
    assert_eq!(pairs(&read(&recording)), (vec![2], vec![3]), "the first recording");

    // The second recording reuses the ring slot; a scope of the first ends in neither.
    cmux_trace::start_recording(0).expect("starts the second recording");
    drop(open_across_restart);
    drop(tagged_scope(4));
    let open_across_stop = tagged_scope(5);
    cmux_trace::stop().expect("stops the second recording");
    drop(open_across_stop);
    assert_eq!(pairs(&read(&recording)), (vec![4], vec![5]), "the second recording");

    drop(tagged_scope(6));
    let blackbox = cmux_trace::status().and_then(|status| status.blackbox_path).expect("a file");
    assert_eq!(pairs(&read(&blackbox)), (vec![6], vec![1]), "the black box");
}

#[test]
fn a_scope_open_across_start_or_stop_leaves_no_end_without_its_begin() {
    run_child("rings");
}

// MARK: async

fn child_async(dir: &Path) {
    start(dir);
    for id in [10u64, 20, 30] {
        trace_async_begin!(daemon, "daemon.url_open", id, id + 1);
    }
    // The slices end on other threads, in another order, and overlap.
    std::thread::scope(|threads| {
        for id in [30u64, 10, 20] {
            threads.spawn(move || trace_async_end!(daemon, "daemon.url_open", id, id * 2));
        }
    });
    trace_async_begin!(cef, "cef.create_browser", 10u64);
    trace_async_end!(cef, "cef.create_browser", 10u64);

    let decoded = snapshot();
    // Keyed by name id, as an exporter keys its async tracks: the begin and the end sites of one
    // text share its id.
    let mut slices: HashMap<(u16, u64), (Option<DecodedRecord>, Option<DecodedRecord>)> =
        HashMap::new();
    for record in &decoded.records {
        let slot = slices.entry((record.name, record.arg1)).or_default();
        assert_eq!(record.flags & FLAG_ID, FLAG_ID, "an async record carries its id flag");
        match Phase::from_raw(record.phase) {
            Some(Phase::AsyncBegin) => assert!(slot.0.replace(*record).is_none(), "two begins"),
            Some(Phase::AsyncEnd) => assert!(slot.1.replace(*record).is_none(), "two ends"),
            other => panic!("unexpected phase {other:?}"),
        }
    }
    assert_eq!(slices.len(), 4, "every (name, id) is one slice");
    for ((name, id), (begin, end)) in &slices {
        let name = decoded.name(*name).expect("a named slice");
        let (begin, end) = (begin.expect("a begin"), end.expect("an end"));
        assert!(end.t_ns >= begin.t_ns, "{name} {id} ended before it began");
        if name == "daemon.url_open" {
            assert_eq!((begin.arg0, end.arg0), (id + 1, id * 2), "{name} {id}: wrong arguments");
            assert_ne!(begin.thread_index, end.thread_index, "{name} {id} ended on its own thread");
        }
    }
}

#[test]
fn async_slices_pair_by_name_and_id_across_threads() {
    run_child("async");
}

// MARK: instants, flows, counters

fn child_points(dir: &Path) {
    start(dir);
    cmux_trace::start_recording(category::FRAME | category::KEY).expect("starts");
    trace_instant!(launch, "launch.daemon_ready");
    trace_flow_out!(key, "key.flow", 77u64, 5u64);
    std::thread::scope(|threads| {
        threads.spawn(|| trace_flow_in!(key, "key.flow", 77u64));
    });
    trace_counter!(frame, "frame.sequence", 12u64);
    trace_counter!(frame, "frame.sequence", 13u64, 4u64);
    // A recording that stops inside a scope leaves its begin open, not an end with no begin.
    let scope = trace_scope!(frame, "frame.tick");
    let status = cmux_trace::stop().expect("stops");
    drop(scope);
    trace_instant!(frame, "frame.commit");

    let path = status.recording_path.expect("a recording file");
    let decoded = decode(&std::fs::read(path).expect("reads")).expect("decodes");
    let mut records = decoded.records.clone();
    records.sort_by_key(|record| record.t_ns);
    let seen: Vec<(char, String, u64, u64, u8)> = records
        .iter()
        .map(|record| {
            let flags = record.flags;
            (record.phase as char, text(&decoded, record), record.arg0, record.arg1, flags)
        })
        .collect();
    let expected = [
        ('I', "launch.daemon_ready", 0, 0, 0),
        ('s', "key.flow", 5, 77, 0),
        ('f', "key.flow", 0, 77, 0),
        ('C', "frame.sequence", 12, 0, 0),
        ('C', "frame.sequence", 13, 4, FLAG_ID),
        ('B', "frame.tick", 0, 0, 0),
    ];
    let expected: Vec<(char, String, u64, u64, u8)> = expected
        .iter()
        .map(|(phase, name, arg0, arg1, flags)| (*phase, (*name).to_owned(), *arg0, *arg1, *flags))
        .collect();
    assert_eq!(seen, expected);
}

#[test]
fn instants_flows_and_counters_record_their_phase_and_numbers() {
    run_child("points");
}

// MARK: scope stack

fn nest(level: u32, deepest: &mut Option<cmux_trace::ScopeStack>) {
    if level == 0 {
        let _innermost = trace_scope!(action, "action.perform");
        *deepest = Some(scope_stack());
        return;
    }
    let _scope = trace_scope!(daemon, "daemon.request.nested", level);
    nest(level - 1, deepest);
}

fn child_stack(dir: &Path) {
    start(dir);
    {
        let _outer = trace_scope!(daemon, "daemon.request");
        let _inner = trace_scope!(action, "action.perform");
        let stack = scope_stack();
        assert_eq!(stack.depth(), 2);
        assert_eq!(stack.names().collect::<Vec<_>>(), ["action.perform", "daemon.request"]);
        // Another thread has its own stack.
        std::thread::scope(|threads| {
            threads.spawn(|| assert_eq!(scope_stack().depth(), 0));
        });
    }
    assert_eq!(scope_stack().depth(), 0, "the guards popped their scopes");

    // Deeper than the stack keeps: the depth counts every scope, the innermost 16 are named.
    let mut deepest = None;
    nest(SCOPE_STACK_DEPTH as u32 + 4, &mut deepest);
    let deepest = deepest.expect("reached the bottom");
    assert_eq!(deepest.depth(), SCOPE_STACK_DEPTH as u32 + 5);
    let names: Vec<&str> = deepest.names().collect();
    assert_eq!(names.len(), SCOPE_STACK_DEPTH);
    assert_eq!(names[0], "action.perform", "the innermost scope is named first");
    assert!(names[1..].iter().all(|name| *name == "daemon.request.nested"));
    assert_eq!(scope_stack().depth(), 0, "the deep scopes popped");

    // Deeper than the stack has slots: it holds the scopes up to its last slot.
    let mut deepest = None;
    nest(SCOPE_SLOTS as u32 + 4, &mut deepest);
    let deepest = deepest.expect("reached the bottom");
    assert_eq!(deepest.depth(), SCOPE_SLOTS as u32);
    let names: Vec<&str> = deepest.names().collect();
    assert_eq!(names.len(), SCOPE_STACK_DEPTH);
    assert!(names.iter().all(|name| *name == "daemon.request.nested"));
    assert_eq!(scope_stack().depth(), 0, "the deeper scopes popped");

    // A guard dropped out of order takes the scopes above it off the stack.
    let outer = trace_scope!(daemon, "daemon.request");
    let inner = trace_scope!(daemon, "daemon.request.parse");
    drop(outer);
    assert_eq!(scope_stack().depth(), 0);
    drop(inner);
    assert_eq!(scope_stack().depth(), 0);
    let again = trace_scope!(daemon, "daemon.request");
    assert_eq!(scope_stack().names().collect::<Vec<_>>(), ["daemon.request"]);
    drop(again);

    // A guard taken off the stack out of order leaves alone the scopes opened at its depth since.
    let outer = trace_scope!(daemon, "daemon.request");
    let inner = trace_scope!(daemon, "daemon.request.parse");
    drop(outer);
    let x = trace_scope!(action, "action.perform");
    let y = trace_scope!(action, "action.commit");
    drop(inner);
    assert_eq!(scope_stack().names().collect::<Vec<_>>(), ["action.commit", "action.perform"]);
    drop(y);
    assert_eq!(scope_stack().names().collect::<Vec<_>>(), ["action.perform"]);
    drop(x);
    assert_eq!(scope_stack().depth(), 0);

    child_stack_deep_out_of_order();
}

fn open_scopes(count: usize) -> Vec<cmux_trace::ScopeGuard> {
    (0..count).map(|_| trace_scope!(daemon, "daemon.request.nested")).collect()
}

/// Out-of-order drops past 32 open scopes: a guard whose scope was already taken off the stack
/// leaves alone the scopes opened at its depth since, at every depth the stack holds.
fn child_stack_deep_out_of_order() {
    let outer = open_scopes(31);
    let w = trace_scope!(daemon, "daemon.w");
    let y = trace_scope!(daemon, "daemon.y");
    drop(w);
    assert_eq!(scope_stack().depth(), 31, "w took y off the stack with it");
    let z = trace_scope!(daemon, "daemon.z");
    let z2 = trace_scope!(daemon, "daemon.z2");
    let z3 = trace_scope!(daemon, "daemon.z3");
    drop(y);
    let stack = scope_stack();
    assert_eq!(stack.depth(), 34, "y, already off the stack, cut the scopes opened since");
    assert_eq!(
        stack.names().take(4).collect::<Vec<_>>(),
        ["daemon.z3", "daemon.z2", "daemon.z", "daemon.request.nested"]
    );
    drop(z3);
    drop(z2);
    drop(z);
    assert_eq!(scope_stack().depth(), 31);
    assert_eq!(scope_stack().names().next(), Some("daemon.request.nested"));
    drop(outer);
    assert_eq!(scope_stack().depth(), 0);

    let mut first = open_scopes(32);
    let x = trace_scope!(daemon, "daemon.x");
    let mut above = open_scopes(1);
    drop(first.remove(5));
    assert_eq!(scope_stack().depth(), 5, "the out-of-order drop took the scopes above it off");
    let refill = open_scopes(29);
    assert_eq!(scope_stack().depth(), 34);
    drop(x);
    assert_eq!(scope_stack().depth(), 34, "x, already off the stack, cut the scopes opened since");
    above.clear();
    assert_eq!(scope_stack().depth(), 34);
    drop(refill);
    drop(first);
    assert_eq!(scope_stack().depth(), 0);
}

#[test]
fn the_scope_stack_names_the_open_scopes_innermost_first() {
    run_child("stack");
}

// MARK: allocation

fn child_alloc(dir: &Path) {
    start(dir);
    // The first record of a thread registers it and the first of an interned name interns it.
    let warm = || {
        let _scope = trace_scope!(daemon, "daemon.request", 1u64);
        let _inner = trace_scope!(daemon, "daemon.request.parse");
        trace_async_begin!(daemon, "daemon.url_open", 1u64);
        trace_async_end!(daemon, "daemon.url_open", 1u64);
        trace_instant!(daemon, "daemon.request.parsed");
    };
    warm();
    let before = allocations();
    for _ in 0..10_000 {
        warm();
    }
    assert_eq!(allocations() - before, 0, "a recorded trace point allocated");
}

#[test]
fn a_recorded_trace_point_allocates_nothing() {
    run_child("alloc");
}

// MARK: catalog

fn child_catalog(dir: &Path) {
    cmux_trace::init_process(TracerConfig::for_process(dir, Role::Daemon))
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    trace_instant!(action, "action.perform");
    let decoded = snapshot();
    let record = decoded.records.first().expect("the instant");
    assert_eq!(record.name, catalog_id("action.perform"), "a catalog name keeps its id");
    assert_eq!(text(&decoded, record), "action.perform", "the process ring took another catalog");
}

#[test]
fn the_process_ring_names_the_shared_catalog() {
    run_child("catalog");
}

// MARK: catalog

/// `SignpostName.swift` (`case name = id` and `case .name: "text"`) as (id, text) pairs.
fn swift_catalog() -> Vec<(u16, String)> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Sources/CmuxNextSignposts/SignpostName.swift");
    let source = std::fs::read_to_string(&path).expect("reads SignpostName.swift");
    let mut ids = HashMap::new();
    let mut texts = HashMap::new();
    for line in source.lines().map(str::trim) {
        let Some(rest) = line.strip_prefix("case ") else { continue };
        if let Some((case, id)) = rest.split_once(" = ") {
            if let Ok(id) = id.trim().parse::<u16>() {
                ids.insert(case.trim().to_owned(), id);
            }
        } else if let Some((case, text)) = rest.strip_prefix('.').and_then(|r| r.split_once(": \""))
            && let Some(text) = text.strip_suffix('"')
        {
            texts.insert(case.trim().to_owned(), text.to_owned());
        }
    }
    assert!(!ids.is_empty(), "found no SignpostName cases in {}", path.display());
    let mut pairs: Vec<(u16, String)> = ids
        .iter()
        .map(|(case, id)| {
            (*id, texts.get(case).unwrap_or_else(|| panic!("{case} has no staticName")).clone())
        })
        .collect();
    pairs.sort();
    pairs
}

#[test]
fn the_catalog_is_swifts_signpost_name_table() {
    let rust: Vec<(u16, String)> =
        CATALOG.iter().map(|name| (name.id, name.text.to_owned())).collect();
    assert_eq!(rust, swift_catalog(), "names.rs differs from SignpostName.swift");
    let categories: [(&str, u64); 22] = [
        ("action", category::ACTION),
        ("key", category::KEY),
        ("switch", category::SWITCH),
        ("create", category::CREATE),
        ("cef", category::CEF),
        ("launch", category::LAUNCH),
        ("daemon", category::DAEMON),
        ("hang", category::HANG),
        ("crash", category::CRASH),
        ("motion", category::MOTION),
        ("frame", category::FRAME),
        ("stall", category::STALL),
        ("task", category::TASK),
        ("burst", category::BURST),
        ("input", category::INPUT),
        ("webview", category::WEBVIEW),
        ("remote", category::REMOTE),
        ("control", category::CONTROL),
        ("ghostty", category::GHOSTTY),
        ("resize", category::RESIZE),
        ("webui", category::WEBUI),
        ("log", category::LOG),
    ];
    assert_eq!(category::NAMES.len(), categories.len());
    for (text, mask) in categories {
        assert_eq!(category::NAMES[mask.trailing_zeros() as usize], text, "category::NAMES");
    }
    for name in CATALOG {
        assert_eq!(name.kind, NameKind::Catalog);
        let prefix = name.text.split('.').next().expect("a prefix");
        let (_, mask) = categories
            .iter()
            .find(|(category, _)| *category == prefix)
            .unwrap_or_else(|| panic!("{} has no category", name.text));
        assert_eq!(1u64 << name.category, *mask, "{} is in the wrong category", name.text);
        assert_eq!(catalog_id(name.text), name.id);
    }
    assert_eq!(catalog_id("daemon.request.parse"), 0, "an unknown name has no catalog id");
}

// MARK: off path

/// The newest `lib<name>-*.rlib` in `deps`: the one cargo built for this test binary.
fn newest_rlib(deps: &Path, name: &str) -> PathBuf {
    let prefix = format!("lib{name}-");
    std::fs::read_dir(deps)
        .expect("reads the deps dir")
        .filter_map(Result::ok)
        .filter(|entry| {
            let file = entry.file_name();
            let file = file.to_string_lossy();
            file.starts_with(&prefix) && file.ends_with(".rlib")
        })
        .max_by_key(|entry| entry.metadata().and_then(|meta| meta.modified()).ok())
        .map(|entry| entry.path())
        .unwrap_or_else(|| panic!("no {prefix}*.rlib in {}", deps.display()))
}

/// The lines of the LLVM IR function `name` in `ir`, from its `define` to its closing `}`.
fn ir_function<'a>(ir: &'a str, name: &str) -> Vec<&'a str> {
    let header = format!("@{name}(");
    let lines: Vec<&str> = ir.lines().collect();
    let start = lines
        .iter()
        .position(|line| line.starts_with("define") && line.contains(&header))
        .unwrap_or_else(|| panic!("no {name} in the IR"));
    let end = start + lines[start..].iter().position(|line| *line == "}").expect("its end");
    lines[start..=end].to_vec()
}

/// Chrome's `TRACE_EVENT*` off path is the `category_group_enabled` load and a branch. Each macro
/// call site of `tests/fixtures/off_path.rs`, compiled with `-C opt-level=3` against this build of
/// the crate, enters with one relaxed (LLVM `monotonic`) load and a conditional branch: no call, no
/// other load and no argument work before it, and no other atomic load anywhere in it.
#[test]
fn a_trace_point_that_is_off_is_one_relaxed_load_and_a_branch() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let exe = std::env::current_exe().expect("test binary");
    let deps = exe.parent().expect("the deps dir");
    let rustc =
        Path::new(env!("CARGO")).with_file_name(format!("rustc{}", std::env::consts::EXE_SUFFIX));
    let out = scratch_dir("off-path").join("off_path.ll");
    let output = std::process::Command::new(&rustc)
        .args(["--edition", "2024", "--crate-type", "lib", "-C", "opt-level=3"])
        .args(["-C", "debuginfo=0", "--emit=llvm-ir", "-o"])
        .arg(&out)
        .arg("-L")
        .arg(format!("dependency={}", deps.display()))
        .arg("--extern")
        .arg(format!("cmux_trace={}", newest_rlib(deps, "cmux_trace").display()))
        .arg(root.join("tests/fixtures/off_path.rs"))
        .output()
        .unwrap_or_else(|error| panic!("runs {}: {error}", rustc.display()));
    assert!(
        output.status.success(),
        "rustc failed on the fixture: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let ir = std::fs::read_to_string(&out).expect("reads the IR");
    let _ = std::fs::remove_dir_all(out.parent().expect("its dir"));
    let functions = [
        "off_instant",
        "off_async_begin",
        "off_async_end",
        "off_flow_out",
        "off_counter",
        "off_scope",
    ];
    for name in functions {
        let body = ir_function(&ir, name);
        let shown = body.join("\n");
        let instructions: Vec<&str> = body[1..]
            .iter()
            .map(|line| line.trim())
            .filter(|line| !line.is_empty() && !line.ends_with(':') && !line.starts_with(';'))
            .collect();
        let branch = instructions
            .iter()
            .position(|line| line.starts_with("br "))
            .unwrap_or_else(|| panic!("{name} has no branch:\n{shown}"));
        let entry = &instructions[..branch];
        let loads: Vec<&&str> = entry.iter().filter(|line| line.contains(" load ")).collect();
        assert_eq!(loads.len(), 1, "{name} loads more than the category word first:\n{shown}");
        assert!(
            loads[0].contains("load atomic") && loads[0].contains("monotonic"),
            "{name}'s first load is not one relaxed atomic load:\n{shown}"
        );
        assert!(
            // The lifetime markers of a scope's guard are intrinsics, not code.
            !entry.iter().any(|line| (line.contains("call ") || line.contains("invoke "))
                && !line.contains("@llvm.lifetime.")),
            "{name} calls before its branch:\n{shown}"
        );
        assert!(
            instructions[branch].starts_with("br i1 "),
            "{name}'s entry does not end in a conditional branch:\n{shown}"
        );
        let atomic_loads = instructions.iter().filter(|line| line.contains("load atomic")).count();
        assert_eq!(atomic_loads, 1, "{name} reads the category word again:\n{shown}");
    }
}
