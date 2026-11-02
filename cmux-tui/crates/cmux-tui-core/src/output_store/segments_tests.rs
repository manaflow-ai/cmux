//! Segment file reads and appends: gaps, overlaps, cut tails, resume ends.

use super::*;

/// A fresh store directory for one test.
fn store_directory(name: &str) -> PathBuf {
    let directory =
        std::env::temp_dir().join(format!("cmux-output-segments-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir_all(&directory).unwrap();
    directory
}

fn terminal() -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{:032x}", 7)).unwrap()
}

/// Append one frame of `bytes` at `start` the way a flush does.
fn append(segments: &Segments, directory: &Path, start: u64, bytes: &[u8]) {
    let terminal_directory = terminal_directory(directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    append_frame(segments, &terminal_directory, "g1", start, bytes).unwrap();
}

fn only_file(directory: &Path) -> PathBuf {
    let files = generation_files(&terminal_directory(directory, &terminal()), "g1");
    assert_eq!(files.len(), 1, "{files:?}");
    files.into_iter().next().unwrap().1
}

#[test]
fn a_read_stops_at_a_gap_and_says_it_was_truncated() {
    let directory = store_directory("gap");
    let segments = Segments::default();
    append(&segments, &directory, 0, b"abc");
    // Bytes 3..5 were lost in a crash.
    append(&segments, &directory, 5, b"fgh");
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abc");
    assert_eq!((window.start_offset, window.next_offset), (0, 3));
    assert!(window.truncated, "a gap ends the window as truncated");
    let after_gap = read_after(&directory, &terminal(), "g1", 5, 1024).unwrap();
    assert_eq!(after_gap.bytes, b"fgh");
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn an_overlapping_older_frame_adds_no_byte_twice() {
    let directory = store_directory("overlap");
    let segments = Segments::default();
    append(&segments, &directory, 0, b"abcd");
    // A re-adopted terminal wrote 2..6 again before its resume was fixed.
    append(&segments, &directory, 2, b"cdef");
    append(&segments, &directory, 1, b"bc");
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcdef");
    assert_eq!(window.next_offset, 6);
    assert!(!window.truncated);
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_cut_tail_is_cut_off_before_the_next_append() {
    let directory = store_directory("cut");
    append(&Segments::default(), &directory, 0, b"abc");
    let file = only_file(&directory);
    let whole = fs::metadata(&file).unwrap().len();
    // A crash cut a second frame after its header.
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(&[9_u8; FRAME_HEADER_BYTES + 2]).unwrap();
    drop(handle);
    // A new daemon (nothing verified) appends to the same file.
    append(&Segments::default(), &directory, 3, b"def");
    assert_eq!(only_file(&directory), file, "the small file is reused");
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcdef", "the frame after the cut tail stays readable");
    assert!(fs::metadata(&file).unwrap().len() > whole);
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn the_stored_stream_end_is_read_from_frame_headers() {
    let directory = store_directory("ends");
    let segments = Segments::default();
    append(&segments, &directory, 0, b"abc");
    append(&segments, &directory, 3, b"defg");
    let ends = all_stream_ends(&directory);
    assert_eq!(ends.get(&(terminal(), generation_key("g1"))), Some(&7));
    assert_eq!(ends.len(), 1);
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_generation_key_is_a_stable_digest() {
    // File names outlive a daemon upgrade: the key may never change.
    assert_eq!(generation_key("g1"), generation_key("g1"));
    assert_eq!(generation_key("g1").len(), 16);
    assert_ne!(generation_key("g1"), generation_key("g2"));
    assert_eq!(generation_key(""), "e3b0c44298fc1c14", "the first 8 bytes of SHA-256(\"\")");
}

#[test]
fn files_named_with_the_legacy_key_are_still_read_and_resumed() {
    let directory = store_directory("legacy");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    append_frame(&Segments::default(), &terminal_directory, "g1", 0, b"abc").unwrap();
    // The file as an older daemon named it (std's hasher).
    let current = only_file(&directory);
    let legacy =
        terminal_directory.join(format!("{}-{:020}.{SUFFIX}", legacy_generation_key("g1"), 0));
    fs::rename(&current, &legacy).unwrap();
    // A new frame after an upgrade goes on in the same stream.
    append(&Segments::default(), &directory, 3, b"def");
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcdef");
    let ends = all_stream_ends(&directory);
    let resumed = keys_of("g1").into_iter().filter_map(|key| ends.get(&(terminal(), key))).max();
    assert_eq!(resumed, Some(&6));
    fs::remove_dir_all(&directory).unwrap();
}

/// A log of one generation with `bytes` unflushed from offset 0.
fn pending_log(bytes: &[u8]) -> Arc<TerminalLog> {
    Arc::new(TerminalLog {
        terminal_id: terminal(),
        state: std::sync::Mutex::new(super::super::LogState {
            generation: Arc::from("g1"),
            tail_start: 0,
            tail: std::collections::VecDeque::from(bytes.to_vec()),
            dirty: false,
            snapshot_digest: None,
            snapshot_at: None,
            segment_digest: None,
            last_output: std::time::Instant::now(),
            pending: bytes.to_vec(),
            pending_start: 0,
            resident: 0,
            measured_rows: None,
            measure_due: false,
            forgotten: false,
        }),
    })
}

#[test]
fn a_flush_keeps_its_bytes_in_memory_until_the_frame_is_written() {
    let directory = store_directory("flush");
    let log = pending_log(b"abcd");
    let policy = PersistencePolicy::resolve(Some("full"), None, None);
    flush_logs(&Segments::default(), &directory, &[(log.clone(), Some(1))], policy, false);
    {
        let state = log.state.lock().unwrap();
        assert!(state.pending.is_empty(), "the written bytes leave memory");
        assert_eq!(state.pending_start, 4);
    }
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcd");
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_failed_write_keeps_the_bytes_for_the_next_flush() {
    let directory = store_directory("failed");
    // The terminal's folder cannot be made: a file is in the way.
    fs::write(terminal_directory(&directory, &terminal()), b"").unwrap();
    let log = pending_log(b"abcd");
    let policy = PersistencePolicy::resolve(Some("full"), None, None);
    let failed =
        flush_logs(&Segments::default(), &directory, &[(log.clone(), Some(1))], policy, false);
    assert!(failed, "the caller schedules another pass");
    {
        let state = log.state.lock().unwrap();
        assert!(state.dirty, "the next pass takes the log again, output or not");
        assert_eq!(state.pending, b"abcd", "unwritten bytes stay in memory");
        assert_eq!(state.pending_start, 0);
        assert_eq!(state.segment_digest, None, "the next pass writes them, changed or not");
    }
    fs::remove_file(terminal_directory(&directory, &terminal())).unwrap();
    // Same content digest as before: still written.
    flush_logs(&Segments::default(), &directory, &[(log.clone(), Some(1))], policy, false);
    assert!(log.state.lock().unwrap().pending.is_empty());
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcd");
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn the_stream_end_is_the_largest_frame_end_of_any_file() {
    let directory = store_directory("ends-any");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    // A file that starts at 10 and ends at 12, and one that starts lower
    // but ends later (an older daemon resumed behind).
    append_frame(&Segments::default(), &terminal_directory, "g1", 10, b"kl").unwrap();
    let early = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 5));
    let mut frame = Vec::new();
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(b"fghijklmnop").unwrap();
    let compressed = encoder.finish().unwrap();
    frame.extend_from_slice(&5_u64.to_le_bytes());
    frame.extend_from_slice(&u32::try_from(compressed.len()).unwrap().to_le_bytes());
    frame.extend_from_slice(&11_u32.to_le_bytes());
    frame.extend_from_slice(&compressed);
    fs::write(&early, frame).unwrap();
    let ends = all_stream_ends(&directory);
    assert_eq!(ends.get(&(terminal(), generation_key("g1"))), Some(&16));
    fs::remove_dir_all(&directory).unwrap();
}

/// A file at `start` in `terminal_directory` holding one frame of `bytes`
/// (written by hand: an older daemon's layout, not `append_frame`'s).
fn write_frame_file(terminal_directory: &Path, start: u64, bytes: &[u8]) {
    let path = terminal_directory.join(format!("{}-{start:020}.{SUFFIX}", generation_key("g1")));
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(bytes).unwrap();
    let compressed = encoder.finish().unwrap();
    let mut frame = Vec::new();
    frame.extend_from_slice(&start.to_le_bytes());
    frame.extend_from_slice(&u32::try_from(compressed.len()).unwrap().to_le_bytes());
    frame.extend_from_slice(&u32::try_from(bytes.len()).unwrap().to_le_bytes());
    frame.extend_from_slice(&compressed);
    fs::write(path, frame).unwrap();
}

#[test]
fn a_read_finds_bytes_in_an_older_file_that_reaches_past_the_cursor() {
    let directory = store_directory("older-file");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    // The file named 5 holds 5..16; the file named 10 holds only 10..12
    // (an older daemon resumed behind). Bytes 12..16 are only in the first.
    write_frame_file(&terminal_directory, 5, b"fghijklmnop");
    write_frame_file(&terminal_directory, 10, b"kl");
    let window = read_after(&directory, &terminal(), "g1", 12, 1024)
        .expect("bytes 12..16 are stored, in the file named 5");
    assert_eq!(window.bytes, b"mnop");
    assert_eq!((window.start_offset, window.next_offset), (12, 16));
    assert!(!window.truncated);
    let from_start = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(from_start.bytes, b"fghijklmnop");
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_read_after_a_gap_in_one_file_still_takes_the_bytes_another_file_holds() {
    let directory = store_directory("gap-other-file");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    // The file named 0 holds 0..3 and then 20..23; the file named 3 holds
    // 3..20. Reading past 3 must not jump to 20.
    write_frame_file(&terminal_directory, 0, b"abc");
    append_frame(&Segments::default(), &terminal_directory, "g1", 20, b"uvw").unwrap();
    let late = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 20));
    assert!(!late.exists(), "the frame at 20 went into the file named 0");
    write_frame_file(&terminal_directory, 3, b"defghijklmnopqrst");
    let window = read_after(&directory, &terminal(), "g1", 3, 1024).unwrap();
    assert_eq!(window.bytes, b"defghijklmnopqrstuvw");
    assert_eq!((window.start_offset, window.next_offset), (3, 23));
    assert!(!window.truncated);
    fs::remove_dir_all(&directory).unwrap();
}

#[cfg(unix)]
#[test]
fn a_newest_file_that_cannot_be_stated_is_left_and_the_frame_goes_to_a_new_file() {
    let directory = store_directory("unstatable");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    append_frame(&Segments::default(), &terminal_directory, "g1", 0, b"abc").unwrap();
    // The newest file is listed but cannot be stated (a dangling link).
    let broken = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 3));
    std::os::unix::fs::symlink(directory.join("missing"), &broken).unwrap();
    append_frame(&Segments::default(), &terminal_directory, "g1", 6, b"ghi")
        .expect("the frame goes to a new file");
    assert!(fs::symlink_metadata(&broken).unwrap().file_type().is_symlink(), "left as it is");
    let fresh = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 6));
    assert!(fresh.is_file(), "the frame is in a file of its own");
    let window = read_after(&directory, &terminal(), "g1", 6, 1024).unwrap();
    assert_eq!(window.bytes, b"ghi");
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn one_read_returns_the_stored_bytes_and_the_unflushed_ones_after_them() {
    let registry = store_directory("store-read");
    let store = super::super::OutputStore::new(Some(&registry));
    store.full.set_enabled(true);
    let generation: Arc<str> = Arc::from("g1");
    store.append(&terminal(), &generation, b"abcd", None);
    let log = store.logs.lock().unwrap().get(&terminal()).unwrap().clone();
    let policy = PersistencePolicy::resolve(Some("full"), None, None);
    let directory = store.directory().unwrap().to_path_buf();
    assert!(!flush_logs(&store.full, &directory, &[(log, Some(1))], policy, false));
    // New output after the flush: in memory only.
    store.append(&terminal(), &generation, b"efgh", None);
    let window = store.read_after(&terminal(), 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcdefgh", "the stored bytes, then the unflushed ones");
    assert_eq!((window.start_offset, window.next_offset), (0, 8));
    assert!(!window.truncated, "nothing after the stream end");
    fs::remove_dir_all(&registry).unwrap();
}

#[cfg(unix)]
#[test]
fn an_unusable_newest_file_at_the_frame_start_is_left_and_the_frame_goes_beside_it() {
    let directory = store_directory("unusable-same-start");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    // The newest file is named with the very offset the next frame starts at.
    let broken = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 3));
    std::os::unix::fs::symlink(directory.join("missing"), &broken).unwrap();
    append_frame(&Segments::default(), &terminal_directory, "g1", 3, b"def")
        .expect("the frame goes to a new file");
    assert!(fs::symlink_metadata(&broken).unwrap().file_type().is_symlink(), "left as it is");
    assert!(!directory.join("missing").exists(), "nothing written through the broken link");
    // The next frame goes on in the new file, not in yet another one.
    append_frame(&Segments::default(), &terminal_directory, "g1", 6, b"ghi").unwrap();
    assert_eq!(generation_files(&terminal_directory, "g1").len(), 2);
    let window = read_after(&directory, &terminal(), "g1", 3, 1024).unwrap();
    assert_eq!(window.bytes, b"defghi");
    assert!(!window.truncated);
    let ends = all_stream_ends(&directory);
    assert_eq!(ends.get(&(terminal(), generation_key("g1"))), Some(&9));
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_frame_that_does_not_decode_ends_the_window_as_truncated() {
    let directory = store_directory("corrupt-body");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    write_frame_file(&terminal_directory, 0, b"abc");
    // A whole frame header for 3..6 whose body is not gzip.
    let path = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 0));
    let mut handle = fs::OpenOptions::new().append(true).open(&path).unwrap();
    handle.write_all(&3_u64.to_le_bytes()).unwrap();
    handle.write_all(&4_u32.to_le_bytes()).unwrap();
    handle.write_all(&3_u32.to_le_bytes()).unwrap();
    handle.write_all(&[0xde, 0xad, 0xbe, 0xef]).unwrap();
    drop(handle);
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abc");
    assert!(window.truncated, "bytes 3..6 are stored but unreadable: the read is not complete");
    // Another file that holds 3..6 fills the hole.
    write_frame_file(&terminal_directory, 3, b"def");
    let window = read_after(&directory, &terminal(), "g1", 0, 1024).unwrap();
    assert_eq!(window.bytes, b"abcdef");
    assert!(!window.truncated);
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_newest_file_with_a_frame_that_does_not_decode_is_left_and_new_frames_stay_readable() {
    let directory = store_directory("corrupt-newest");
    let terminal_directory = terminal_directory(&directory, &terminal());
    fs::create_dir_all(&terminal_directory).unwrap();
    write_frame_file(&terminal_directory, 0, b"abc");
    // A whole frame for 3..6 whose body is not gzip (an earlier run's file).
    let path = terminal_directory.join(format!("{}-{:020}.{SUFFIX}", generation_key("g1"), 0));
    let mut handle = fs::OpenOptions::new().append(true).open(&path).unwrap();
    handle.write_all(&3_u64.to_le_bytes()).unwrap();
    handle.write_all(&4_u32.to_le_bytes()).unwrap();
    handle.write_all(&3_u32.to_le_bytes()).unwrap();
    handle.write_all(&[0xde, 0xad, 0xbe, 0xef]).unwrap();
    drop(handle);
    let before = fs::read(&path).unwrap();
    // The writer resumes at 6: the frame must not go after the bad one.
    append_frame(&Segments::default(), &terminal_directory, "g1", 6, b"ghi").unwrap();
    assert_eq!(fs::read(&path).unwrap(), before, "the file is left as it is");
    assert_eq!(
        generation_files(&terminal_directory, "g1").len(),
        2,
        "the frame went to a new file"
    );
    let window = read_after(&directory, &terminal(), "g1", 6, 1024).unwrap();
    assert_eq!(window.bytes, b"ghi", "the newly flushed bytes are readable");
    assert!(!window.truncated);
    // The next frame goes on in the new file.
    append_frame(&Segments::default(), &terminal_directory, "g1", 9, b"jkl").unwrap();
    assert_eq!(generation_files(&terminal_directory, "g1").len(), 2);
    let window = read_after(&directory, &terminal(), "g1", 6, 1024).unwrap();
    assert_eq!(window.bytes, b"ghijkl");
    fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn a_failing_write_keeps_at_most_the_unwritten_bound_and_a_read_reports_the_gap() {
    let directory = store_directory("failed-bound");
    fs::write(terminal_directory(&directory, &terminal()), b"").unwrap();
    let extra = 10;
    let bytes = (0..MAX_UNWRITTEN_BYTES + extra).map(|at| (at % 251) as u8).collect::<Vec<_>>();
    let log = pending_log(&bytes);
    let policy = PersistencePolicy::resolve(Some("full"), None, None);
    assert!(flush_logs(&Segments::default(), &directory, &[(log.clone(), Some(1))], policy, false));
    {
        let state = log.state.lock().unwrap();
        // The bound is deliberate: a busy terminal on a full disk must not
        // grow the daemon without limit. The newest bytes are kept.
        assert_eq!(state.pending.len(), MAX_UNWRITTEN_BYTES);
        assert_eq!(state.pending_start, extra as u64);
        assert_eq!(state.pending.as_slice(), &bytes[extra..]);
    }
    fs::remove_file(terminal_directory(&directory, &terminal())).unwrap();
    flush_logs(&Segments::default(), &directory, &[(log.clone(), Some(1))], policy, false);
    assert!(log.state.lock().unwrap().pending.is_empty());
    // A read from the start begins after the dropped bytes and says where.
    let window = read_after(&directory, &terminal(), "g1", 0, bytes.len()).unwrap();
    assert_eq!(window.start_offset, extra as u64, "the dropped range is a reported gap");
    assert_eq!(window.bytes.as_slice(), &bytes[extra..]);
    fs::remove_dir_all(&directory).unwrap();
}
