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
    assert_eq!(ends.get(&(terminal(), key_of("g1"))), Some(&7));
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
