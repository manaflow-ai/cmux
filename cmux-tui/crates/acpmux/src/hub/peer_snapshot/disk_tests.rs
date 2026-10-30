//! `disk.rs`: names, a copy written and read back whole, and what a scan leaves out.

use super::*;
use serde_json::json;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

thread_local! {
    static RECORD_BYTES_ALLOCS: Cell<Option<usize>> = const { Cell::new(None) };
}

struct AllocationCounter;

// Test-only allocator: counting is enabled per thread, so unrelated tests do not
// affect the record-size assertion while the old `to_vec` implementation allocates.
unsafe impl GlobalAlloc for AllocationCounter {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = RECORD_BYTES_ALLOCS.try_with(|count| {
            if let Some(value) = count.get() {
                count.set(Some(value.saturating_add(1)));
            }
        });
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let _ = RECORD_BYTES_ALLOCS.try_with(|count| {
            if let Some(value) = count.get() {
                count.set(Some(value.saturating_add(1)));
            }
        });
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let _ = RECORD_BYTES_ALLOCS.try_with(|count| {
            if let Some(value) = count.get() {
                count.set(Some(value.saturating_add(1)));
            }
        });
        unsafe { System.realloc(ptr, layout, size) }
    }
}

#[global_allocator]
static ALLOCATOR: AllocationCounter = AllocationCounter;

fn key(mux: &str) -> Key {
    ("huge-blue".to_owned(), mux.to_owned())
}

fn head(mux: &str) -> Head {
    Head {
        peer: "huge-blue".into(),
        session_id: mux.into(),
        generation: Some(7),
        ..Head::default()
    }
}

#[test]
fn record_size_includes_its_line_terminator_without_building_a_vec() {
    let value = json!({"sessionId": "m1", "seq": 1, "msg": "🙂"});
    let expected = serde_json::to_vec(&value).unwrap().len() as u64 + 1;
    RECORD_BYTES_ALLOCS.with(|count| count.set(Some(0)));
    assert_eq!(record_bytes(&value), expected);
    let allocations = RECORD_BYTES_ALLOCS.with(|count| count.replace(None).unwrap_or(0));
    assert_eq!(allocations, 0, "record_bytes allocated {allocations} times");
}

#[test]
fn names_are_lowercase_hex_so_ids_that_differ_in_case_never_share_a_file() {
    let root = Path::new("/r");
    let (lower, upper) = (path(root, &key("m1")).unwrap(), path(root, &key("M1")).unwrap());
    assert_ne!(lower.to_string_lossy().to_lowercase(), upper.to_string_lossy().to_lowercase());
    assert_eq!(unhex(&hex("M1/../x").unwrap()).as_deref(), Some("M1/../x"));
    assert_eq!(unhex("4D31"), None, "uppercase hex is not a name this writes");
    assert!(path(root, &key(&"x".repeat(ID_BYTES + 1))).is_none());
    // The longest id kept still names a file once `write_atomic` swaps `.json` for its longest
    // temporary suffix.
    let longest = path(root, &key(&"x".repeat(ID_BYTES))).unwrap();
    let stem = longest.file_stem().unwrap().len();
    assert!(stem + TMP_SUFFIX_BYTES <= 255, "{stem}");
    assert!(path(root, &key("")).is_none());
}

#[test]
fn a_copy_reads_back_whole_or_not_at_all() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psd");
    let root = dir.path().join(".snapshots");
    let records: BTreeMap<u64, Value> =
        (1..=3).map(|s| (s, json!({"sessionId": "m1", "seq": s, "kind": "k"}))).collect();
    let bytes = encode(&head("m1"), &records);
    write(crate::config::write_atomic, &root, &key("m1"), &bytes).unwrap();
    let file = path(&root, &key("m1")).unwrap();
    let (got, read_back) = read(&file, &key("m1")).unwrap().unwrap();
    assert_eq!((got, read_back), (head("m1"), records));
    assert_eq!(read_head(&file, &key("m1")).unwrap(), Some(head("m1")));
    // Another session's head under this name is not this session's copy.
    assert!(read(&file, &key("m2")).is_err());
    // A cut copy, or one with a line that does not parse, is not a copy.
    std::fs::write(&file, &bytes[..bytes.len() - 3]).unwrap();
    assert!(read(&file, &key("m1")).is_err());
    let mut bad = bytes.clone();
    bad.extend_from_slice(b"{not json\n");
    std::fs::write(&file, &bad).unwrap();
    assert!(read(&file, &key("m1")).is_err());
    // A record of another session in this session's copy.
    let mut other = bytes.clone();
    other.extend_from_slice(b"{\"sessionId\":\"m2\",\"seq\":4}\n");
    std::fs::write(&file, &other).unwrap();
    assert!(read(&file, &key("m1")).is_err());
    assert!(read(&path(&root, &key("m9")).unwrap(), &key("m9")).unwrap().is_none());
}

// Symlinks are made with the Unix call; the scan's code is the same on Windows.
#[cfg(unix)]
#[test]
fn a_scan_finds_copies_and_reports_everything_else_as_stray() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psd");
    let root = dir.path().join(".snapshots");
    let records = BTreeMap::new();
    write(crate::config::write_atomic, &root, &key("m1"), &encode(&head("m1"), &records)).unwrap();
    let peer = peer_dir(&root, "huge-blue").unwrap();
    std::fs::write(peer.join("6d31.tmp-1-2"), b"left by a crash").unwrap();
    std::fs::write(root.join("not-hex"), b"x").unwrap();
    std::os::unix::fs::symlink("/etc/hosts", peer.join("6d32.json")).unwrap();
    // A peer directory that is a symlink to a directory elsewhere, and an empty peer directory.
    let elsewhere = dir.path().join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    std::fs::write(elsewhere.join("6d31.json"), b"not ours").unwrap();
    std::os::unix::fs::symlink(&elsewhere, peer_dir(&root, "other").unwrap()).unwrap();
    std::fs::create_dir(peer_dir(&root, "gone").unwrap()).unwrap();
    let found = scan(&root).unwrap();
    assert_eq!(found.copies.len(), 1);
    assert_eq!(found.copies[0].0, key("m1"));
    assert_eq!(found.stray.len(), 4, "{:?}", found.stray);
    assert_eq!(found.empty, vec![peer_dir(&root, "gone").unwrap()]);
    for (path, _) in &found.stray {
        remove(path).unwrap();
    }
    assert!(std::fs::metadata("/etc/hosts").is_ok(), "a symlink's target is never touched");
    assert!(elsewhere.join("6d31.json").exists(), "nor what a symlinked directory holds");
    assert!(scan(&root).unwrap().stray.is_empty());
    assert!(scan(&dir.path().join("missing")).unwrap().copies.is_empty());
}

#[test]
fn a_file_or_head_past_its_bound_is_not_written_scanned_or_read() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psd");
    let root = dir.path().join(".snapshots");
    // As another program (or an earlier, larger build) could leave them.
    let put = |mux: &str, bytes: &[u8]| {
        let file = path(&root, &key(mux)).unwrap();
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, bytes).unwrap();
        file
    };
    let mut bytes = encode(&head("m1"), &BTreeMap::new());
    bytes.extend(std::iter::repeat_n(b' ', super::super::FILE_BYTES as usize));
    assert!(write(crate::config::write_atomic, &root, &key("m1"), &bytes).is_err());
    let big = put("m1", &bytes);
    assert!(read(&big, &key("m1")).is_err());
    assert!(read_head(&big, &key("m1")).is_err(), "a whole head does not make it a copy");
    // A cut line is never written.
    assert!(write(crate::config::write_atomic, &root, &key("m3"), b"{}").is_err());
    let found = scan(&root).unwrap();
    assert!(found.copies.is_empty() && found.stray.iter().any(|(p, _)| *p == big));
    // A head with no end within its bound.
    let endless = vec![b'{'; super::super::HEAD_BYTES as usize * 2];
    assert!(write(crate::config::write_atomic, &root, &key("m2"), &endless).is_err());
    assert!(read_head(&put("m2", &endless), &key("m2")).is_err());
    // A seq past what a client's number holds is no seq.
    assert_eq!(seq_of(&json!({"seq": 1u64 << 53})), None);
    assert_eq!(seq_of(&json!({"seq": (1u64 << 53) - 1})), Some((1 << 53) - 1));
}

#[test]
fn a_head_reads_only_within_the_bound_the_writer_holds_it_to() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-psd");
    let root = dir.path().join(".snapshots");
    let padded = |n: u64| Head { summary: Value::String("x".repeat(n as usize)), ..head("m1") };
    let bare = serde_json::to_vec(&padded(0)).unwrap().len() as u64;
    // A head whose line and newline are exactly the bound reads; one byte more does not.
    for (extra, fits) in [(0, true), (1, false)] {
        let h = padded(super::super::HEAD_BYTES - 1 - bare + extra);
        let line = serde_json::to_vec(&h).unwrap().len() as u64;
        assert_eq!(head_fits(line), fits);
        let bytes = encode(&h, &BTreeMap::new());
        assert_eq!(write(crate::config::write_atomic, &root, &key("m1"), &bytes).is_ok(), fits);
        let file = path(&root, &key("m1")).unwrap();
        std::fs::write(&file, &bytes).unwrap();
        assert_eq!(read_head(&file, &key("m1")).is_ok(), fits);
        assert_eq!(read(&file, &key("m1")).is_ok(), fits);
    }
}
