//! Ring v1 behaviour on a [`Tracer`] (no process globals): exact-once decoding under contention,
//! overwrite, chunks never shared, torn records, heap-to-file adoption, thread-entry reuse, a
//! full disk, recordings, the byte offsets of plans/cmux-next/trace.md and the golden file shared
//! with Swift (003) and C (094).

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Barrier;

use cmux_trace::clock::ClockDomain;
use cmux_trace::{
    CatalogName, Decoded, DecodedRecord, FLAG_ESTIMATE, FLAG_ID, InternedName, NameKind, Phase,
    ProcessIdentity, Record, RingSizes, Role, StartClocks, ThreadIdentity, Tracer, TracerConfig,
    Writer, category, decode,
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

static CATALOG: [CatalogName; 3] = [
    CatalogName { id: 1, kind: NameKind::Catalog, category: 1, text: "key.frame" },
    CatalogName { id: 2, kind: NameKind::Catalog, category: 6, text: "daemon.request" },
    CatalogName { id: 3, kind: NameKind::Category, category: 1, text: "key" },
];

const ARG1_KEY: u64 = 0x5A5A_5A5A_5A5A_5A5A;

fn zero() -> u64 {
    0
}

fn sizes(chunks: u32) -> RingSizes {
    RingSizes { name_capacity: 64, thread_capacity: 256, chunk_count: chunks }
}

fn config(chunks: u32, dir: &Path) -> TracerConfig {
    TracerConfig {
        blackbox: sizes(chunks),
        recording: sizes(chunks),
        // Records stamp small times; a ring that starts at 0 keeps them.
        clocks: StartClocks { uptime_ns: zero, ..StartClocks::SYSTEM },
        ..TracerConfig::for_process(dir, Role::Daemon)
    }
}

fn tracer(chunks: u32) -> Tracer {
    Tracer::with_catalog(config(chunks, &std::env::temp_dir()), &CATALOG)
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-trace-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

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

fn identity(thread: u32) -> ThreadIdentity {
    ThreadIdentity::new(u64::from(thread), 0, &format!("writer-{thread}"))
}

/// Checks a record is whole and credited to the thread that wrote it.
fn assert_whole(decoded: &Decoded, record: &DecodedRecord) {
    assert_eq!(record.arg1, record.arg0 ^ ARG1_KEY, "torn record {record:?}");
    assert_eq!(u64::from(record.name), record.arg0 >> 32, "torn record {record:?}");
    assert_eq!(record.t_ns, (record.arg0 & 0xFFFF_FFFF) + 1, "torn record {record:?}");
    assert_eq!(record.phase, Phase::Instant as u8);
    let writer = decoded.thread_of(record).map(|thread| thread.tid);
    assert_eq!(writer, Some(u64::from(record.name)), "record credited to the wrong thread");
}

/// Per thread, the indices in write order ((position, slot) order), checking each record.
fn indices_by_thread(decoded: &Decoded) -> HashMap<u16, Vec<u64>> {
    let mut sorted = decoded.records.clone();
    sorted.sort_by_key(|record| (record.position, record.slot));
    let mut out: HashMap<u16, Vec<u64>> = HashMap::new();
    for record in &sorted {
        assert_whole(decoded, record);
        out.entry(record.name).or_default().push(record.arg0 & 0xFFFF_FFFF);
    }
    out
}

fn write_threads(tracer: &Tracer, threads: u32, per_thread: u64) {
    std::thread::scope(|scope| {
        for thread in 1..=threads {
            scope.spawn(move || {
                let mut writer = Writer::new(tracer, identity(thread));
                for index in 0..per_thread {
                    writer.write(checked(thread, index));
                }
            });
        }
    });
}

fn snapshot(tracer: &Tracer) -> Decoded {
    decode(&tracer.snapshot_active()).expect("decodes")
}

#[test]
fn eight_threads_of_a_hundred_thousand_records_decode_exactly_once_in_order() {
    const THREADS: u32 = 8;
    const PER_THREAD: u64 = 100_000;
    let tracer = tracer(32768);
    write_threads(&tracer, THREADS, PER_THREAD);
    let decoded = snapshot(&tracer);
    assert_eq!(decoded.records.len(), (u64::from(THREADS) * PER_THREAD) as usize);
    assert_eq!(decoded.header.chunks_overwritten, 0);
    assert_eq!(decoded.header.records_dropped, 0);
    let by_thread = indices_by_thread(&decoded);
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
    assert_eq!(decoded.threads.len(), THREADS as usize);
}

#[test]
fn a_black_box_written_ten_times_over_keeps_the_newest_whole_records() {
    let tracer = tracer(8);
    let capacity = sizes(8).records() as u64;
    let mut writer = Writer::new(&tracer, identity(1));
    for index in 0..capacity * 10 {
        writer.write(checked(1, index));
    }
    let decoded = snapshot(&tracer);
    assert!(decoded.header.chunks_overwritten >= 8 * 9);
    let indices = &indices_by_thread(&decoded)[&1];
    assert!(
        indices.iter().copied().eq(capacity * 9..capacity * 10),
        "the ring did not keep exactly the newest {capacity} records"
    );
}

#[test]
fn eight_threads_wrapping_a_small_ring_leave_only_whole_attributed_records() {
    let tracer = tracer(64);
    write_threads(&tracer, 8, 50_000);
    let decoded = snapshot(&tracer);
    assert!(decoded.header.chunks_overwritten > 0);
    assert!(!decoded.records.is_empty());
    for indices in indices_by_thread(&decoded).values() {
        assert!(
            indices.windows(2).all(|pair| pair[0] < pair[1]),
            "a thread's records repeat or run backwards"
        );
    }
}

/// More writers than chunks: claims skip owned chunks and drop rather than share one, so every
/// record that decodes is whole and credited to its own writer. Each writer's first record is
/// written before any writer goes on, so 12 of the 16 first claims find all four chunks owned.
#[test]
fn sixteen_writers_on_four_chunks_never_share_a_chunk() {
    const WRITERS: u32 = 16;
    let tracer = tracer(4);
    let first_written = Barrier::new(WRITERS as usize);
    std::thread::scope(|scope| {
        for thread in 1..=WRITERS {
            let (tracer, first_written) = (&tracer, &first_written);
            scope.spawn(move || {
                let mut writer = Writer::new(tracer, identity(thread));
                writer.write(checked(thread, 0));
                first_written.wait();
                for index in 1..20_000 {
                    writer.write(checked(thread, index));
                }
            });
        }
    });
    let decoded = snapshot(&tracer);
    let status = tracer.status();
    assert!(status.records_dropped >= 12, "a first record shared an owned chunk");
    assert!(status.chunks_skipped >= 48);
    assert_eq!(status.chunks_skipped, decoded.header.chunks_skipped);
    for indices in indices_by_thread(&decoded).values() {
        assert!(indices.windows(2).all(|pair| pair[0] < pair[1]));
    }
}

#[test]
fn a_record_finds_no_free_chunk_and_is_dropped_not_shared() {
    let tracer = tracer(4);
    let mut holders: Vec<Writer<'_>> =
        (1..=4).map(|thread| Writer::new(&tracer, identity(thread))).collect();
    for (thread, writer) in (1..).zip(holders.iter_mut()) {
        writer.write(checked(thread, 0));
    }
    let mut late = Writer::new(&tracer, identity(5));
    late.write(checked(5, 0));
    let status = tracer.status();
    assert_eq!((status.records_dropped, status.chunks_skipped), (1, 4));
    let decoded = snapshot(&tracer);
    assert_eq!(decoded.records.len(), 4);
    assert!(decoded.records.iter().all(|record| record.name != 5));
}

#[test]
fn a_torn_record_is_skipped() {
    let tracer = tracer(4);
    let mut writer = Writer::new(&tracer, identity(1));
    for index in 0..3 {
        writer.write(checked(1, index));
    }
    let mut bytes = tracer.snapshot_active();
    let chunks_offset = decode(&bytes).expect("decodes").header.chunks_offset as usize;
    // The second record of chunk 0: its writer died between the odd and the even store.
    let seq_at = chunks_offset + 2 * 32 + 8;
    assert_eq!(bytes[seq_at..seq_at + 4], 2u32.to_le_bytes(), "lap 0 publishes seq 2");
    bytes[seq_at..seq_at + 4].copy_from_slice(&1u32.to_le_bytes());
    assert_eq!(&indices_by_thread(&decode(&bytes).expect("decodes"))[&1], &[0, 2]);
}

/// 1000 threads, each writing once and exiting, on a 256-entry table: exited entries are taken
/// again with the next generation, so no thread is unknown and the last one is attributed.
#[test]
fn a_thousand_short_lived_threads_reuse_the_thread_table() {
    let tracer = tracer(64);
    for thread in 1..=1000u32 {
        std::thread::scope(|scope| {
            scope.spawn(|| Writer::new(&tracer, identity(thread)).write(checked(thread, 0)));
        });
    }
    let decoded = snapshot(&tracer);
    assert_eq!(decoded.header.thread_overflow, 0, "a thread found the table full");
    assert!(decoded.header.thread_cursor as usize <= 256 + 1);
    let last = decoded.records.iter().find(|record| record.name == 1000).expect("the last record");
    assert_eq!(decoded.thread_of(last).map(|thread| (thread.tid, thread.state)), Some((1000, 3)));
    let owners: HashSet<(u32, u32)> = decoded
        .records
        .iter()
        .map(|record| (record.thread_index, record.thread_generation))
        .collect();
    assert_eq!(owners.len(), decoded.records.len(), "two threads shared an (index, generation)");
}

#[cfg(unix)]
#[test]
fn heap_records_move_into_the_file_and_later_writes_land_there() {
    let dir = scratch_dir("adopt");
    let tracer = Tracer::with_catalog(config(16, &dir), &CATALOG);
    let read = InternedName::new("cmux.io.read", 6);
    let mut writer = Writer::new(&tracer, identity(1));
    for index in 0..100 {
        writer.write(checked(1, index));
    }
    writer.write_interned(&read, checked(1, 100));
    let heap = snapshot(&tracer);
    let path = tracer.adopt_file().expect("adopts");
    assert_eq!(path, dir.join(cmux_trace::blackbox_file_name(Role::Daemon, std::process::id())));
    assert!(tracer.adopt_file().is_err(), "a second adoption replaced the file");
    for index in 101..200 {
        writer.write(checked(1, index));
    }
    writer.write_interned(&read, checked(1, 200));
    let decoded = decode(&std::fs::read(&path).expect("reads")).expect("decodes");
    let indices: Vec<u64> =
        decoded.records.iter().map(|record| record.arg0 & 0xFFFF_FFFF).collect();
    assert!(indices.iter().copied().eq(0..=200), "records were lost or doubled across the swap");
    // The heap's id (copied with its entry) and a new id the file interned after the swap.
    let interned: Vec<Option<&str>> = decoded
        .records
        .iter()
        .filter(|record| record.name != 1)
        .map(|record| decoded.name(record.name))
        .collect();
    let interned: Vec<&str> = interned.into_iter().flatten().collect();
    assert_eq!(
        interned,
        ["cmux.io.read", "cmux.io.read"],
        "an interned record names no entry of its ring"
    );
    assert_eq!(decoded.name(1), Some("key.frame"));
    assert_eq!(decoded.header.pid, std::process::id());
    assert_eq!(
        decoded.header.start_unix_ns, heap.header.start_unix_ns,
        "the file has its own start"
    );
    assert_eq!(decoded.header.heap_cursor, heap.header.chunk_cursor);
    assert!(decoded.header.chunk_cursor >= heap.header.chunk_cursor + 16);
    assert_eq!(decoded.header.heap_chunks_lost, 0);
    // The thread registered in the heap (copied) and again in the file.
    assert_eq!(decoded.threads.len(), 2);
    assert!(decoded.records.iter().all(|record| decoded.thread_of(record).is_some()));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Copy first, swap last: records written while the copy runs may be lost (counted by chunk in
/// `heap_chunks_lost`), but none doubles, and every record after the swap lands in the file.
#[cfg(unix)]
#[test]
fn adoption_while_eight_threads_write_doubles_nothing_and_keeps_every_later_record() {
    const BEFORE: u64 = 50_000;
    const AFTER: u64 = 1_000;
    let dir = scratch_dir("adopt-live");
    let tracer = Tracer::with_catalog(config(32768, &dir), &CATALOG);
    let adopted = Barrier::new(9);
    std::thread::scope(|scope| {
        for thread in 1..=8u32 {
            let (tracer, adopted) = (&tracer, &adopted);
            scope.spawn(move || {
                let mut writer = Writer::new(tracer, identity(thread));
                for index in 0..BEFORE {
                    writer.write(checked(thread, index));
                }
                adopted.wait();
                for index in BEFORE..BEFORE + AFTER {
                    writer.write(checked(thread, index));
                }
            });
        }
        tracer.adopt_file().expect("adopts");
        adopted.wait();
    });
    let path = tracer.status().blackbox_path.expect("a black-box file");
    let decoded = decode(&std::fs::read(path).expect("reads")).expect("decodes");
    let by_thread = indices_by_thread(&decoded);
    assert_eq!(by_thread.len(), 8);
    for (thread, indices) in &by_thread {
        assert!(
            indices.windows(2).all(|pair| pair[0] < pair[1]),
            "thread {thread} doubled a record"
        );
        let after = indices.iter().filter(|&&index| index >= BEFORE).count() as u64;
        assert_eq!(after, AFTER, "thread {thread} lost records written after the swap");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A disk that cannot hold the ring file leaves the black box on the heap: no SIGBUS, no file,
/// a counted failure, and writes go on.
#[test]
fn a_full_disk_keeps_the_black_box_on_the_heap() {
    fn full(_: &std::fs::File, _: u64) -> std::io::Result<()> {
        Err(std::io::Error::other("no space left on device"))
    }
    let dir = scratch_dir("full");
    let tracer = Tracer::with_catalog(TracerConfig { reserve: full, ..config(16, &dir) }, &CATALOG);
    let mut writer = Writer::new(&tracer, identity(1));
    writer.write(checked(1, 0));
    assert!(tracer.adopt_file().is_err());
    writer.write(checked(1, 1));
    let status = tracer.status();
    assert_eq!((status.map_failures, status.blackbox_path), (1, None));
    assert_eq!(std::fs::read_dir(&dir).expect("lists").count(), 0, "a ring file was left behind");
    assert!(indices_by_thread(&snapshot(&tracer))[&1].iter().copied().eq(0..2));
    let status = tracer.start_recording(category::MOTION).expect("a recording on the heap");
    assert!(!status.recording_file_backed && status.recording_path.is_none());
    assert_eq!(status.map_failures, 2);
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn start_record_stop_and_restart_move_writes_between_the_rings() {
    let dir = scratch_dir("recording");
    let tracer = Tracer::with_catalog(config(16, &dir), &CATALOG);
    tracer.adopt_file().expect("adopts");
    let read = InternedName::new("cmux.io.read", 6);
    let mut writer = Writer::new(&tracer, identity(1));
    writer.write(checked(1, 1));
    assert!(!tracer.enabled(category::MOTION));
    let status = tracer.start_recording(category::MOTION).expect("starts");
    assert!(status.recording && status.recording_file_backed);
    assert_eq!(status.categories, category::BLACKBOX | category::MOTION);
    assert!(tracer.enabled(category::MOTION));
    assert_eq!(tracer.start_recording(0), Err(cmux_trace::TraceError::AlreadyRecording));
    writer.write(checked(1, 2));
    writer.write_interned(&read, checked(1, 3));
    let status = tracer.stop().expect("stops");
    assert_eq!(status.categories, category::BLACKBOX, "stop left recording categories on");
    assert_eq!(tracer.stop(), Err(cmux_trace::TraceError::NotRecording));
    writer.write(checked(1, 4));

    let recording_path = status.recording_path.expect("a recording file");
    let read_ring = |path: &Path| decode(&std::fs::read(path).expect("reads")).expect("decodes");
    let arg = |decoded: &Decoded| -> Vec<u64> {
        decoded.records.iter().map(|r| r.arg0 & 0xFFFF_FFFF).collect()
    };
    let blackbox = read_ring(&status.blackbox_path.expect("a black-box file"));
    assert_eq!(arg(&blackbox), [1, 4], "the black box holds a recording record or lost one");
    let recording = read_ring(&recording_path);
    assert_eq!(arg(&recording), [2, 3], "the recording holds the wrong records");
    assert_eq!(recording.header.ring_kind, 2);
    // The whole catalog is in the recording's own table, and the interned name after it.
    assert_eq!(recording.name(1), Some("key.frame"));
    assert_eq!(recording.name(2), Some("daemon.request"));
    assert_eq!(recording.name(recording.records[1].name), Some("cmux.io.read"));
    assert_eq!(recording.threads.len(), 1);

    let status = tracer.start_recording(category::FRAME).expect("starts again");
    assert_eq!(
        status.recording_path.as_deref(),
        Some(recording_path.as_path()),
        "a second start mapped a new file"
    );
    assert!(
        read_ring(&recording_path).records.is_empty(),
        "a new recording kept the last one's records"
    );
    writer.write(checked(1, 5));
    let recording = read_ring(&recording_path);
    assert_eq!(arg(&recording), [5]);
    assert_eq!(recording.threads.len(), 1, "the tables carry over between recordings");
    assert!(recording.header.start_lap() >= 2);
    tracer.stop().expect("stops");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_ring_write_allocates_nothing_even_on_the_first_write() {
    let tracer = tracer(8);
    let read = InternedName::new("cmux.io.read", 6);
    let mut writer = Writer::new(&tracer, ThreadIdentity::current());
    let before = allocations();
    for index in 0..10_000 {
        writer.write(checked(1, index));
        writer.write_interned(&read, checked(1, index));
    }
    assert_eq!(allocations() - before, 0, "a ring write allocated");
}

#[test]
fn bad_bytes_decode_to_errors_not_panics() {
    use cmux_trace::DecodeError;
    let good = tracer(4).snapshot_active();
    assert_eq!(decode(b"short"), Err(DecodeError::Truncated));
    assert_eq!(decode(&[0u8; 300]), Err(DecodeError::BadMagic));
    assert_eq!(decode(&good[..good.len() - 1]), Err(DecodeError::Truncated));
    let patched = |at: usize, bytes: &[u8]| {
        let mut copy = good.clone();
        copy[at..at + bytes.len()].copy_from_slice(bytes);
        decode(&copy)
    };
    assert_eq!(patched(8, &9u32.to_le_bytes()), Err(DecodeError::UnsupportedVersion(9)));
    assert!(matches!(patched(116, &3u32.to_le_bytes()), Err(DecodeError::BadLayout(_))));
    assert!(matches!(patched(120, &1024u64.to_le_bytes()), Err(DecodeError::BadLayout(_))));
    assert!(patched(116, &(1u32 << 31).to_le_bytes()).is_err());
    assert!(patched(144, &u32::MAX.to_le_bytes()).is_err());
    assert!(patched(152, &u64::MAX.to_le_bytes()).is_err());
}

// The golden ring: every writer (Rust, Swift 003, C 094) builds this ring and must produce the
// same bytes. Recipe:
// - Header: pid 4242, role 2 (daemon), ring_kind 1, clock_domain 1, start_uptime_ns 1000,
//   start_unix_ns 1_700_000_000_000_000_000, start_continuous_ns 2000, process_start_unix_us
//   1_699_999_999_000_000, boot_session_uuid 0x10..0x1f, build_uuid 0x20..0x2f, build_version
//   "1.2.3 (45) abcdef0", categories `category::BLACKBOX` (0x1ff).
// - Sizes: name_capacity 64, thread_capacity 256, chunk_count 4; the name table at 16384, the
//   thread table at 32768, the chunks at 49152 (each region on a 16 KiB page).
// - Catalog: 1 "key.frame" (catalog, category 1), 2 "daemon.request" (catalog, category 6),
//   3 "key" (category, bit 1).
// - Thread "main" (tid 101, QoS 0x21) writes 33 records, thread "cmux-io" (tid 202, QoS 0x19)
//   writes 5 (one under the interned name "cmux.io.read", category 6), in the order below; then
//   both exit.
// - The bytes are the ring's memory after that (a snapshot of it is the same bytes).
fn golden_bytes() -> Vec<u8> {
    fn uptime() -> u64 {
        1_000
    }
    fn unix() -> u64 {
        1_700_000_000_000_000_000
    }
    fn continuous() -> u64 {
        2_000
    }
    let mut build_version = [0u8; 32];
    build_version[..18].copy_from_slice(b"1.2.3 (45) abcdef0");
    let tracer = Tracer::with_catalog(
        TracerConfig {
            blackbox: sizes(4),
            recording: sizes(4),
            clocks: StartClocks {
                uptime_ns: uptime,
                unix_ns: unix,
                continuous_ns: continuous,
                domain: ClockDomain::UptimeRaw,
            },
            identity: ProcessIdentity {
                pid: 4242,
                process_start_unix_us: 1_699_999_999_000_000,
                boot_session_uuid: std::array::from_fn(|index| 0x10 + index as u8),
                build_uuid: std::array::from_fn(|index| 0x20 + index as u8),
                build_version,
            },
            read_slow_identity: |_| {},
            ..TracerConfig::for_process("/nonexistent", Role::Daemon)
        },
        &CATALOG,
    );
    let read = InternedName::new("cmux.io.read", 6);
    let record =
        |t_ns, name, phase, flags, arg0, arg1| Record { t_ns, name, phase, flags, arg0, arg1 };
    let mut main = Writer::new(&tracer, ThreadIdentity::new(101, 0x21, "main"));
    let mut io = Writer::new(&tracer, ThreadIdentity::new(202, 0x19, "cmux-io"));
    main.write(record(1_000, 1, Phase::Begin, 0, 7, 0));
    io.write(record(1_050, 2, Phase::AsyncBegin, FLAG_ID, 0, 5));
    main.write(record(1_100, 1, Phase::FlowOut, 0, 0, 99));
    io.write(record(1_150, 2, Phase::FlowIn, 0, 0, 99));
    main.write(record(1_200, 1, Phase::End, 0, 0, 0));
    io.write(record(1_300, 2, Phase::AsyncEnd, FLAG_ID, 0, 5));
    io.write(record(1_350, 2, Phase::Counter, FLAG_ID | FLAG_ESTIMATE, 42, 3));
    io.write_interned(&read, record(1_375, 0, Phase::Instant, 0, 8, 0));
    for index in 0..30 {
        main.write(record(1_400 + index, 1, Phase::Instant, 0, index, 4));
    }
    drop(main);
    drop(io);
    tracer.snapshot_active()
}

fn golden_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Tests/CmuxNextTraceTests/Fixtures/ring-v1-golden.cmxtrace")
}

/// One fixture for every writer: the Swift test (003) reads the same file, so the two cannot
/// drift. It is missing only if someone deletes it, and then this test fails.
#[test]
fn the_golden_ring_is_byte_identical_to_the_shared_fixture() {
    let bytes = golden_bytes();
    if std::env::var_os("CMUX_TRACE_UPDATE_GOLDEN").is_some() {
        std::fs::write(golden_path(), &bytes).expect("writes the golden file");
    }
    let golden = std::fs::read(golden_path())
        .expect("the shared golden file (CMUX_TRACE_UPDATE_GOLDEN=1 writes it)");
    assert!(
        bytes == golden,
        "ring v1 bytes changed: the Swift (003) and C (094) writers must change with them"
    );
    let decoded = decode(&golden).expect("the golden file decodes");
    assert_eq!(decoded.name(4), Some("cmux.io.read"));
    let threads: Vec<(u64, u8, &str, u32)> = decoded
        .threads
        .iter()
        .map(|thread| (thread.tid, thread.qos, thread.name.as_str(), thread.state))
        .collect();
    assert_eq!(threads, [(101, 0x21, "main", 3), (202, 0x19, "cmux-io", 3)]);
    let phases: Vec<(u64, u8, u8)> =
        decoded.records.iter().take(8).map(|r| (r.t_ns, r.phase, r.flags)).collect();
    assert_eq!(
        phases,
        [
            (1_000, b'B', 0),
            (1_050, b'b', 1),
            (1_100, b's', 0),
            (1_150, b'f', 0),
            (1_200, b'E', 0),
            (1_300, b'e', 1),
            (1_350, b'C', 3),
            (1_375, b'I', 0)
        ]
    );
    assert_eq!(decoded.records.len(), 38);
}

fn u16_at(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().expect("4 bytes"))
}

fn u64_at(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().expect("8 bytes"))
}

/// Every field at the offset the trace.md tables give, read as raw bytes (not through the decoder).
#[test]
fn every_field_sits_at_its_trace_md_offset() {
    let b = golden_bytes();
    assert_eq!(&b[0..8], b"CMXTRACE");
    assert_eq!((u32_at(&b, 8), u32_at(&b, 12), u32_at(&b, 16)), (1, 256, 4242));
    assert_eq!(
        (u16_at(&b, 20), b[22], b[23]),
        (2, 1, 1),
        "role u16 at 20, ring_kind at 22, clock_domain at 23"
    );
    assert_eq!(
        (u64_at(&b, 24), u64_at(&b, 32), u64_at(&b, 40)),
        (1_000, 1_700_000_000_000_000_000, 1_699_999_999_000_000)
    );
    assert_eq!((b[48], b[63], b[64], b[79]), (0x10, 0x1f, 0x20, 0x2f));
    assert_eq!(&b[80..99], b"1.2.3 (45) abcdef0\0");
    assert_eq!((u32_at(&b, 112), u32_at(&b, 116)), (1024, 4));
    let chunks = u64_at(&b, 120) as usize;
    assert_eq!(chunks % 16384, 0, "chunks_offset is a multiple of 16384");
    assert_eq!(u64_at(&b, 128), 3, "chunk_cursor: main claimed twice, cmux-io once");
    let names = u64_at(&b, 136) as usize;
    assert_eq!((u32_at(&b, 144), u32_at(&b, 148)), (64, 5), "name_capacity, name_cursor");
    let threads = u64_at(&b, 152) as usize;
    assert_eq!((u32_at(&b, 160), u32_at(&b, 164)), (256, 2), "thread_capacity, thread_cursor");
    assert_eq!(u64_at(&b, 168), category::BLACKBOX);
    assert_eq!((u64_at(&b, 176), u64_at(&b, 184), u32_at(&b, 192), u32_at(&b, 196)), (0, 0, 0, 0));
    assert_eq!(
        (u64_at(&b, 200), u64_at(&b, 208), u64_at(&b, 216), u64_at(&b, 224), u32_at(&b, 232)),
        (0, 2_000, 0, 0, 0)
    );
    assert!(b[236..256].iter().all(|&byte| byte == 0), "reserved bytes are zero");

    assert!(b[names..names + 64].iter().all(|&byte| byte == 0), "name entry 0 stays zero");
    let key = names + 3 * 64;
    assert_eq!(
        (u32_at(&b, key), u16_at(&b, key + 4), b[key + 6], b[key + 7], b[key + 8]),
        (2, 3, 3, 1, 3)
    );
    assert_eq!(&b[key + 9..key + 13], b"key\0");
    let interned = names + 4 * 64;
    assert_eq!((b[interned + 6], b[interned + 7], b[interned + 8]), (2, 6, 12));
    assert_eq!(&b[interned + 9..interned + 21], b"cmux.io.read");

    let io = threads + 64;
    assert_eq!(
        (u32_at(&b, io), u32_at(&b, io + 4), u64_at(&b, io + 8)),
        (3, 0, 202),
        "exited, generation 0, tid"
    );
    assert_eq!((b[io + 16], b[io + 17]), (0x19, 7), "qos at 16, name_len at 17");
    assert_eq!(&b[io + 18..io + 26], b"cmux-io\0");

    // Chunk 0: main's first, full chunk of lap 0 (complete: 2*0+2).
    assert_eq!(
        (
            u32_at(&b, chunks),
            u32_at(&b, chunks + 4),
            u64_at(&b, chunks + 8),
            u32_at(&b, chunks + 16)
        ),
        (0, 0, 2, 31)
    );
    let first = chunks + 32;
    assert_eq!(
        (
            u64_at(&b, first),
            u32_at(&b, first + 8),
            u16_at(&b, first + 12),
            b[first + 14],
            b[first + 15]
        ),
        (1_000, 2, 1, b'B', 0)
    );
    assert_eq!((u64_at(&b, first + 16), u64_at(&b, first + 24)), (7, 0));
    // Chunk 1: cmux-io's, closed at its exit.
    let io_chunk = chunks + 1024;
    assert_eq!(
        (u32_at(&b, io_chunk), u64_at(&b, io_chunk + 8), u32_at(&b, io_chunk + 16)),
        (1, 2, 5)
    );
    assert_eq!((b[io_chunk + 32 + 14], b[io_chunk + 32 + 15]), (b'b', FLAG_ID));
}
