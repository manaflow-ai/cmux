use super::*;

fn directory(name: &str) -> PathBuf {
    let stamp =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let directory = std::env::temp_dir()
        .join(format!("cmux-output-tail-{name}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&directory).unwrap();
    directory
}

fn id() -> TerminalPublicId {
    TerminalPublicId::parse("term_0123456789abcdef0123456789abcdef").unwrap()
}

#[test]
fn tail_bytes_continue_the_snapshot_offset_and_stop_at_a_gap_or_cut_frame() {
    let directory = directory("gap");
    let id = id();
    append(&directory, &id, "g1", 100, 100, b"abc", false).unwrap();
    append(&directory, &id, "g1", 100, 103, b"def", true).unwrap();
    // A gap: offset 109 does not follow 106.
    append(&directory, &id, "g1", 100, 109, b"zzz", false).unwrap();
    assert_eq!(bytes_after(&directory, &id, "g1", 100), b"abcdef");
    assert_eq!(bytes_after(&directory, &id, "g1", 102), b"cdef");
    assert!(bytes_after(&directory, &id, "g2", 100).is_empty(), "another generation");
    assert!(bytes_after(&directory, &id, "g1", 99).is_empty(), "a gap before the tail");
    // A cut last frame (a crash mid-write) ends the read; earlier frames stay.
    remove(&directory, &id);
    append(&directory, &id, "g1", 0, 0, b"one", false).unwrap();
    append(&directory, &id, "g1", 0, 3, b"two", false).unwrap();
    let file = path(&directory, &id);
    let len = fs::metadata(&file).unwrap().len();
    fs::OpenOptions::new().write(true).open(&file).unwrap().set_len(len - 2).unwrap();
    assert_eq!(bytes_after(&directory, &id, "g1", 0), b"one");
    assert_eq!(stream_ends(&directory).get(&id), Some(&("g1".to_string(), 3)));
    let _ = fs::remove_dir_all(&directory);
}

#[test]
fn restore_writes_the_tail_over_the_snapshot_screen() {
    let directory = directory("restore");
    let id = id();
    let mut source = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
    source.vt_write(b"first\r\nsecond\r\n");
    let snapshot = TerminalReplay {
        cols: 40,
        rows: 5,
        bytes: source.vt_replay_bounded(1 << 20).unwrap().into_self_contained_bytes(),
    };
    let tail = b"third\r\nfourth\r\nfifth\r\nsixth\r\n";
    append(&directory, &id, "g", 15, 15, tail, false).unwrap();
    source.vt_write(tail);
    let restored = restore(snapshot, &bytes_after(&directory, &id, "g", 15));
    let mut rebuilt = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
    rebuilt.vt_write(&restored.bytes);
    assert_eq!(rebuilt.plain_text().unwrap(), source.plain_text().unwrap());
    let _ = fs::remove_dir_all(&directory);
}

/// Failure-mode table, "unreplayable screen": a tail that ends inside a
/// Kitty upload too large to replay still restores the text before it.
#[test]
fn a_tail_that_ends_inside_an_oversized_upload_still_restores_its_text() {
    let directory = directory("upload");
    let id = id();
    let mut source = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
    source.vt_write(b"first\r\n");
    let snapshot = TerminalReplay {
        cols: 40,
        rows: 5,
        bytes: source.vt_replay_bounded(1 << 20).unwrap().into_self_contained_bytes(),
    };
    let mut tail = b"after-snapshot\r\n".to_vec();
    // Chunks of a multipart upload past what a replay can hold, never ended.
    let chunk = vec![b'A'; 1 << 20];
    for _ in 0..16 {
        tail.extend_from_slice(b"\x1b_Ga=t,f=100,m=1;");
        tail.extend_from_slice(&chunk);
        tail.extend_from_slice(b"\x1b\\");
    }
    append(&directory, &id, "g", 7, 7, &tail, false).unwrap();
    let restored = restore(snapshot, &bytes_after(&directory, &id, "g", 7));
    let mut rebuilt = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
    rebuilt.vt_write(&restored.bytes);
    let text = rebuilt.plain_text().unwrap();
    let _ = fs::remove_dir_all(&directory);
    assert!(text.contains("after-snapshot"), "the tail's text was dropped: {text:?}");
}
