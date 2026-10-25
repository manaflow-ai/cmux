//! Ring v1 behaviour: exact-once decoding under contention, black-box overwrite, torn records,
//! heap-to-file adoption, the golden bytes shared with Swift and C, allocation-free writes, and
//! the process-wide lifecycle (in child processes, so each run starts with fresh globals).

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use cmux_trace::{
    DecodedRecord, FLAG_ASYNC_ID, Phase, Record, Ring, RingConfig, Role, ThreadInfo, Writer,
    category, decode,
};

/// Counts the allocations of the calling thread only (libtest's own threads allocate freely).
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

const ARG1_KEY: u64 = 0x5A5A_5A5A_5A5A_5A5A;

/// A record whose fields all derive from (thread, index), so a torn mix of two records shows.
fn checked(thread: u32, index: u64) -> Record {
    let arg0 = u64::from(thread) << 32 | index;
    Record {
        t_ns: index + 1,
        name: thread as u16,
        phase: Phase::Instant,
        flags: 0,
        arg0,
        arg1: arg0 ^ ARG1_KEY,
    }
}

fn assert_whole(record: &DecodedRecord) {
    assert_eq!(record.arg1, record.arg0 ^ ARG1_KEY, "torn record {record:?}");
    assert_eq!(u64::from(record.name), record.arg0 >> 32, "torn record {record:?}");
    assert_eq!(record.t_ns, (record.arg0 & 0xFFFF_FFFF) + 1, "torn record {record:?}");
    assert_eq!(
        record.thread_generation,
        u32::from(record.name),
        "record credited to the wrong thread"
    );
    assert_eq!(record.phase, Phase::Instant as u8);
}

/// Per thread, the indices in write order ((position, slot) order), checking each record is whole.
fn indices_by_thread(records: &[DecodedRecord]) -> HashMap<u32, Vec<u64>> {
    let mut sorted = records.to_vec();
    sorted.sort_by_key(|record| (record.position, record.slot));
    let mut out: HashMap<u32, Vec<u64>> = HashMap::new();
    for record in &sorted {
        assert_whole(record);
        out.entry(record.thread_generation).or_default().push(record.arg0 & 0xFFFF_FFFF);
    }
    out
}

fn config(records: usize) -> RingConfig {
    RingConfig { threads: 64, name_bytes: 1024, ..RingConfig::for_process(Role::Daemon, records) }
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-trace-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn write_threads(ring: &Ring, threads: u32, per_thread: u64) {
    std::thread::scope(|scope| {
        for thread in 1..=threads {
            scope.spawn(move || {
                let mut writer = Writer::new(ring, ThreadInfo::current(thread));
                for index in 0..per_thread {
                    writer.write(checked(thread, index));
                }
            });
        }
    });
}

#[test]
fn eight_threads_of_a_hundred_thousand_records_decode_exactly_once_in_order() {
    const THREADS: u32 = 8;
    const PER_THREAD: u64 = 100_000;
    let ring = Ring::new(config(THREADS as usize * PER_THREAD as usize + 31 * THREADS as usize));
    write_threads(&ring, THREADS, PER_THREAD);
    let decoded = decode(&ring.snapshot()).expect("decodes");
    assert_eq!(decoded.records.len(), (THREADS as u64 * PER_THREAD) as usize);
    assert_eq!(decoded.header.overwrites, 0);
    let by_thread = indices_by_thread(&decoded.records);
    assert_eq!(by_thread.len(), THREADS as usize);
    for indices in by_thread.values() {
        assert!(
            indices.iter().copied().eq(0..PER_THREAD),
            "a thread's records are missing, doubled or out of order"
        );
    }
    assert!(
        decoded.records.windows(2).all(|pair| pair[0].t_ns <= pair[1].t_ns),
        "the merge is not by time"
    );
    let generations: Vec<u32> = decoded.threads.iter().map(|thread| thread.generation).collect();
    assert_eq!(generations.len(), THREADS as usize);
    assert!((1..=THREADS).all(|thread| generations.contains(&thread)));
}

#[test]
fn a_black_box_written_ten_times_over_keeps_the_newest_whole_records() {
    let ring = Ring::new(config(31 * 8));
    let capacity = ring.capacity() as u64;
    let mut writer = Writer::new(&ring, ThreadInfo::new(9, 1, 0, "solo"));
    for index in 0..capacity * 10 {
        writer.write(checked(1, index));
    }
    let decoded = decode(&ring.snapshot()).expect("decodes");
    assert!(decoded.header.overwrites >= 8 * 9);
    let indices = &indices_by_thread(&decoded.records)[&1];
    assert_eq!(indices.len() as u64, capacity, "a single writer's wrapped ring is not full");
    assert!(
        indices.iter().copied().eq(capacity * 9..capacity * 10),
        "the ring did not keep the newest records"
    );
}

#[test]
fn eight_threads_wrapping_a_small_ring_leave_only_whole_records() {
    let ring = Ring::new(config(31 * 64));
    write_threads(&ring, 8, 50_000);
    let decoded = decode(&ring.snapshot()).expect("decodes");
    assert!(decoded.header.overwrites > 0);
    assert!(!decoded.records.is_empty());
    for indices in indices_by_thread(&decoded.records).values() {
        assert!(
            indices.windows(2).all(|pair| pair[0] < pair[1]),
            "a thread's records repeat or run backwards"
        );
    }
}

#[test]
fn a_torn_record_is_skipped() {
    let ring = Ring::new(config(64));
    let mut writer = Writer::new(&ring, ThreadInfo::new(9, 1, 0, "solo"));
    for index in 0..3 {
        writer.write(checked(1, index));
    }
    let mut bytes = ring.snapshot();
    let layout = ring.layout();
    // The second record of the first chunk: its writer died between the odd and the even store.
    let seq_at = layout.chunk_offset + 2 * 32 + 8;
    let published = u32::from_le_bytes(bytes[seq_at..seq_at + 4].try_into().unwrap());
    assert_eq!(published, 2, "lap 0 publishes sequence 2");
    bytes[seq_at..seq_at + 4].copy_from_slice(&(published - 1).to_le_bytes());
    let indices = &indices_by_thread(&decode(&bytes).expect("decodes").records)[&1];
    assert_eq!(indices, &[0, 2]);
}

#[cfg(unix)]
#[test]
fn heap_records_move_into_the_file_and_later_writes_land_there() {
    let dir = scratch_dir("adopt");
    let path = dir.join("ring.cmxtrace");
    std::fs::write(&path, vec![0xEE; 100_000]).expect("stale file");
    let ring = Ring::new(config(31 * 16));
    assert!(ring.register_name(4, "daemon.request"));
    let mut writer = Writer::new(&ring, ThreadInfo::new(9, 1, 0, "solo"));
    for index in 0..100 {
        writer.write(checked(1, index));
    }
    ring.adopt_file(&path).expect("adopts");
    assert!(ring.is_file_backed());
    for index in 100..200 {
        writer.write(checked(1, index));
    }
    let decoded = decode(&std::fs::read(&path).expect("reads")).expect("decodes");
    assert!(indices_by_thread(&decoded.records)[&1].iter().copied().eq(0..200));
    assert_eq!(decoded.names, vec![(4, "daemon.request".to_owned())]);
    assert_eq!(decoded.threads.len(), 1);
    assert_eq!(decoded.threads[0].name, "solo");
    assert_eq!(decoded.header.pid, std::process::id());
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn adoption_while_eight_threads_write_loses_at_most_one_record_each() {
    const PER_THREAD: u64 = 50_000;
    let dir = scratch_dir("adopt-live");
    let path = dir.join("ring.cmxtrace");
    let ring = Ring::new(config(8 * PER_THREAD as usize + 31 * 8));
    std::thread::scope(|scope| {
        for thread in 1..=8u32 {
            let ring = &ring;
            scope.spawn(move || {
                let mut writer = Writer::new(ring, ThreadInfo::current(thread));
                for index in 0..PER_THREAD {
                    writer.write(checked(thread, index));
                }
            });
        }
        ring.adopt_file(&path).expect("adopts");
    });
    let decoded = decode(&std::fs::read(&path).expect("reads")).expect("decodes");
    let by_thread = indices_by_thread(&decoded.records);
    assert_eq!(by_thread.len(), 8);
    for (thread, indices) in &by_thread {
        assert!(
            indices.windows(2).all(|pair| pair[0] < pair[1]),
            "thread {thread} doubled a record"
        );
        let lost = PER_THREAD - indices.len() as u64;
        assert!(lost <= 1, "thread {thread} lost {lost} records across the swap");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// The ring every implementation writes for the golden file: fixed header values, two threads,
/// two names, every phase family.
fn golden_ring() -> Ring {
    let ring = Ring::new(RingConfig {
        records: 31 * 4,
        threads: 4,
        name_bytes: 64,
        pid: 4242,
        role: Role::Daemon,
        clock: cmux_trace::clock::ClockDomain::UptimeRaw,
        start_ns: 1_000_000_000,
        boot_session: std::array::from_fn(|index| 0x10 + index as u8),
        build_id: std::array::from_fn(|index| 0x20 + index as u8),
    });
    assert!(ring.register_name(1, "key.frame"));
    assert!(ring.register_name(2, "daemon.request"));
    let mut main = Writer::new(&ring, ThreadInfo::new(101, 1, 0x21, "main"));
    let mut io = Writer::new(&ring, ThreadInfo::new(202, 2, 0x19, "cmux-io"));
    let record =
        |t_ns, name, phase, flags, arg0, arg1| Record { t_ns, name, phase, flags, arg0, arg1 };
    main.write(record(1_000, 1, Phase::Begin, 0, 7, 0));
    io.write(record(1_050, 2, Phase::AsyncBegin, FLAG_ASYNC_ID, 0, 5));
    main.write(record(1_100, 1, Phase::FlowOut, 0, 99, 0));
    io.write(record(1_150, 2, Phase::FlowIn, 0, 99, 0));
    main.write(record(1_200, 1, Phase::End, 0, 0, 0));
    io.write(record(1_300, 2, Phase::AsyncEnd, FLAG_ASYNC_ID, 0, 5));
    io.write(record(1_350, 2, Phase::Counter, cmux_trace::FLAG_ESTIMATED, 42, 0));
    main.write(record(1_400, 1, Phase::Instant, 0, 3, 4));
    ring
}

#[test]
fn the_golden_ring_is_byte_identical_to_the_fixture() {
    let fixture =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ring-v1-golden.cmxtrace");
    let bytes = golden_ring().snapshot();
    if std::env::var_os("CMUX_TRACE_UPDATE_GOLDEN").is_some() {
        std::fs::write(&fixture, &bytes).expect("writes the golden file");
    }
    let golden =
        std::fs::read(&fixture).expect("the golden file (CMUX_TRACE_UPDATE_GOLDEN=1 writes it)");
    assert!(
        bytes == golden,
        "ring v1 bytes changed: the Swift (003) and C (094) writers must change with them"
    );
    // The Swift ring's fixture (task 003) is the same file, byte for byte, once it exists.
    let swift = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Tests/CmuxNextTraceTests/Fixtures/ring-v1-golden.cmxtrace");
    if let Ok(swift_bytes) = std::fs::read(&swift) {
        assert!(swift_bytes == golden, "the Swift fixture differs from the Rust golden file");
    }

    let decoded = decode(&golden).expect("the golden file decodes");
    assert_eq!(decoded.header.pid, 4242);
    assert_eq!(decoded.header.role, Role::Daemon as u8);
    assert_eq!(decoded.header.clock, 1);
    assert_eq!(decoded.header.boot_session[0], 0x10);
    assert_eq!(decoded.header.build_id[15], 0x2F);
    assert_eq!(decoded.names, vec![(1, "key.frame".to_owned()), (2, "daemon.request".to_owned())]);
    let threads: Vec<(u64, u32, u32, &str)> = decoded
        .threads
        .iter()
        .map(|thread| (thread.tid, thread.generation, thread.qos, thread.name.as_str()))
        .collect();
    assert_eq!(threads, vec![(101, 1, 0x21, "main"), (202, 2, 0x19, "cmux-io")]);
    let phases: Vec<(u64, u8, u8)> =
        decoded.records.iter().map(|record| (record.t_ns, record.phase, record.flags)).collect();
    assert_eq!(
        phases,
        vec![
            (1_000, 1, 0),
            (1_050, 4, 1),
            (1_100, 6, 0),
            (1_150, 7, 0),
            (1_200, 2, 0),
            (1_300, 5, 1),
            (1_350, 8, 2),
            (1_400, 3, 0)
        ]
    );
}

#[test]
fn a_trace_point_that_is_off_allocates_nothing() {
    // This test binary never calls init_blackbox in-process, so every category is off.
    assert!(!cmux_trace::enabled(category::ALL));
    let before = allocations();
    for index in 0..10_000 {
        cmux_trace::write(category::KEY, 1, Phase::Instant, 0, index, 0);
        cmux_trace::write_at(category::FRAME, index, 2, Phase::Begin, 0, 0, 0);
    }
    assert_eq!(allocations() - before, 0, "a trace point that is off allocated");
}

#[test]
fn a_ring_write_allocates_nothing_even_on_the_first_write() {
    let ring = Ring::new(config(31 * 8));
    let mut writer = Writer::new(&ring, ThreadInfo::current(1));
    let before = allocations();
    for index in 0..10_000 {
        writer.write(checked(1, index));
    }
    assert_eq!(allocations() - before, 0, "a ring write allocated");
}

/// Runs `mode` of [`child_process`] in a child of this test binary and returns its exit status.
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
        other => panic!("unknown child mode {other:?}"),
    }
}

fn child_abort(dir: &Path) {
    let open = cmux_trace::init_blackbox(dir, Role::Daemon, 4096).expect("first init");
    for index in 0..1_000 {
        cmux_trace::write(category::ACTION, 1, Phase::Instant, 0, index, 0);
    }
    open.wait().expect("the black box moved into its file");
    for index in 1_000..2_000 {
        cmux_trace::write(category::ACTION, 1, Phase::Instant, 0, index, 0);
    }
    cmux_trace::start_recording(0, category::ALL).expect("starts");
    for index in 0..5_000 {
        cmux_trace::write(category::MOTION, 2, Phase::Instant, 0, index, 0);
    }
    std::process::abort();
}

#[cfg(unix)]
#[test]
fn a_child_that_aborts_leaves_rings_that_decode() {
    let dir = scratch_dir("abort");
    let status = run_child("abort", &dir);
    assert!(!status.success(), "the child was meant to abort");
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(&dir).expect("lists").map(|entry| entry.unwrap().path()).collect();
    files.sort();
    assert_eq!(files.len(), 2, "expected a black box and a recording, got {files:?}");
    let blackbox = files
        .iter()
        .find(|path| path.to_string_lossy().ends_with(".blackbox.cmxtrace"))
        .expect("black box");
    let recording = files
        .iter()
        .find(|path| path.to_string_lossy().ends_with(".recording.cmxtrace"))
        .expect("recording");

    let decoded = decode(&std::fs::read(blackbox).unwrap()).expect("the black box decodes");
    assert_eq!(decoded.header.role, Role::Daemon as u8);
    assert_ne!(decoded.header.pid, std::process::id());
    assert!(blackbox.to_string_lossy().contains(&format!("daemon-{}.", decoded.header.pid)));
    let mut indices: Vec<u64> = decoded.records.iter().map(|record| record.arg0).collect();
    indices.sort_unstable();
    let before = indices.len();
    indices.dedup();
    assert_eq!(indices.len(), before, "a black-box record decoded twice");
    assert!(
        indices.iter().filter(|&&index| index >= 1_000).copied().eq(1_000..2_000),
        "records after adoption are missing"
    );
    assert!(
        indices.len() >= 1_999,
        "more than one record was lost while the ring moved into its file"
    );

    let decoded = decode(&std::fs::read(recording).unwrap()).expect("the recording decodes");
    let indices: Vec<u64> = decoded.records.iter().map(|record| record.arg0).collect();
    assert!(indices.iter().copied().eq(0..5_000), "the recording lost or reordered records");
    assert!(decoded.records.iter().all(|record| record.name == 2));
    let _ = std::fs::remove_dir_all(&dir);
}

fn names(path: &Path) -> Vec<(u16, u64)> {
    let decoded = decode(&std::fs::read(path).expect("reads")).expect("decodes");
    decoded.records.iter().map(|record| (record.name, record.arg0)).collect()
}

fn child_lifecycle(dir: &Path) {
    assert_eq!(cmux_trace::start_recording(0, 0), Err(cmux_trace::TraceError::NotInitialized));
    assert!(cmux_trace::status().is_none());
    let open = cmux_trace::init_blackbox(dir, Role::Daemon, 4096).expect("first init");
    assert!(
        cmux_trace::init_blackbox(dir, Role::App, 64).is_none(),
        "a second init replaced the black box"
    );
    let blackbox = open.wait().expect("adopts");
    assert!(cmux_trace::register_name(1, "action.dispatch"));
    assert!(cmux_trace::enabled(category::ACTION) && !cmux_trace::enabled(category::MOTION));

    cmux_trace::write(category::ACTION, 1, Phase::Instant, 0, 1, 0);
    cmux_trace::write(category::MOTION, 2, Phase::Instant, 0, 2, 0);

    let status = cmux_trace::start_recording(1_000, category::MOTION).expect("starts");
    assert!(status.recording && status.recording_file_backed);
    assert_eq!(status.recording_records, 1_000usize.div_ceil(31) * 31);
    assert_eq!(status.categories, category::BLACKBOX | category::MOTION);
    assert_eq!(cmux_trace::start_recording(0, 0), Err(cmux_trace::TraceError::AlreadyRecording));
    let recording = status.recording_path.expect("recording path");
    assert!(cmux_trace::register_name(2, "motion.frame"));
    cmux_trace::write(category::ACTION, 1, Phase::Instant, 0, 3, 0);
    cmux_trace::write(category::MOTION, 2, Phase::Instant, 0, 4, 0);

    let status = cmux_trace::stop().expect("stops");
    assert!(!status.recording);
    assert_eq!(status.categories, category::BLACKBOX, "stop left recording categories on");
    assert!(!cmux_trace::enabled(category::MOTION));
    assert_eq!(cmux_trace::stop(), Err(cmux_trace::TraceError::NotRecording));
    cmux_trace::write(category::ACTION, 1, Phase::Instant, 0, 5, 0);
    cmux_trace::write(category::MOTION, 2, Phase::Instant, 0, 6, 0);

    assert_eq!(
        names(&blackbox),
        vec![(1, 1), (1, 5)],
        "the black box holds a recording-time record or lost one"
    );
    assert_eq!(names(&recording), vec![(1, 3), (2, 4)], "the recording holds the wrong records");
    let decoded = decode(&std::fs::read(&recording).unwrap()).unwrap();
    assert_eq!(decoded.names, vec![(2, "motion.frame".to_owned())]);
    assert_eq!(decode(&std::fs::read(&blackbox).unwrap()).unwrap().names.len(), 2);
    assert_eq!(decoded.threads.len(), 1, "one writer thread, one entry");

    let status = cmux_trace::start_recording(0, category::RECORDING).expect("starts again");
    assert_eq!(
        status.recording_path.as_deref(),
        Some(recording.as_path()),
        "a second start mapped a new file"
    );
    assert_eq!(status.recording_records, Role::Daemon.recording_records().div_ceil(31) * 31);
    assert!(names(&recording).is_empty(), "a new recording kept the last one's records");
    cmux_trace::write(category::FRAME, 3, Phase::Instant, 0, 7, 0);
    assert_eq!(names(&recording), vec![(3, 7)]);
    cmux_trace::stop().expect("stops");

    // Moving between the rings registers this thread once in each.
    let decoded = decode(&std::fs::read(&blackbox).unwrap()).unwrap();
    assert_eq!(decoded.threads.len(), 1);
}

#[test]
fn start_record_stop_and_restart_move_writes_between_the_rings() {
    let dir = scratch_dir("lifecycle");
    assert!(
        run_child("lifecycle", &dir).success(),
        "the lifecycle child failed (see its output above)"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

fn child_alloc(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Holder, 4096).expect("first init").wait().ok();
    cmux_trace::write(category::KEY, 1, Phase::Instant, 0, 0, 0);
    let before = allocations();
    for index in 0..10_000 {
        cmux_trace::write(category::KEY, 1, Phase::Instant, 0, index, 0);
        cmux_trace::write(category::FRAME, 2, Phase::Instant, 0, index, 0);
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
