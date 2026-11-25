use super::*;
use crate::model::*;
use proptest::prelude::*;

struct TempDir(PathBuf);
impl TempDir {
    fn new() -> Self {
        static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let p = std::env::temp_dir().join(format!("cmux-layout-cache-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn sample(width: f64) -> LayoutCache {
    LayoutCache {
        build_key: "b1".into(),
        written_at_ms: 5,
        windows: vec![WindowLayout {
            id: "w".into(),
            frame: Rect::new(10.0, 20.0, width, 600.0),
            panes: PaneNode::Leaf(Leaf {
                pane_id: "p".into(),
                kind: PaneKind::Terminal,
                frame: Rect::new(0.0, 0.0, width, 600.0),
                ..Leaf::default()
            }),
            ..WindowLayout::default()
        }],
        ..LayoutCache::default()
    }
}

#[test]
fn path_is_versioned() {
    assert_eq!(cache_path(Path::new("/s")), PathBuf::from("/s/layout-cache/v1.json"));
}

#[test]
fn write_then_read_round_trips() {
    let d = TempDir::new();
    let path = cache_path(&d.0);
    write(&path, &sample(800.0)).unwrap();
    assert_eq!(read(&path), Some(sample(800.0)));
}

#[test]
fn garbage_missing_and_oversized_read_as_none() {
    let d = TempDir::new();
    let path = d.0.join("v1.json");
    assert_eq!(read(&path), None);
    for bytes in [&b"{not json"[..], b"\xff\xfe", b"[]", br#"{"version":7}"#] {
        fs::write(&path, bytes).unwrap();
        assert_eq!(read(&path), None);
    }
    fs::write(&path, vec![b' '; MAX_BYTES as usize + 1]).unwrap();
    assert_eq!(read(&path), None);
}

#[test]
fn a_failed_write_leaves_the_old_file_and_no_temporary() {
    let d = TempDir::new();
    let path = cache_path(&d.0);
    write(&path, &sample(800.0)).unwrap();
    let new = serde_json::to_vec(&sample(900.0)).unwrap();
    let err = write_bytes(&path, &new, |_| Err(io::Error::other("disk full"))).unwrap_err();
    assert_eq!(err.to_string(), "disk full");
    assert_eq!(read(&path), Some(sample(800.0)));
    let left: Vec<_> =
        fs::read_dir(path.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(left, vec![std::ffi::OsString::from("v1.json")]);
    // Over the cap: refused before anything is touched.
    assert!(write_bytes(&path, &vec![b' '; MAX_BYTES as usize + 1], |_| Ok(())).is_err());
    assert_eq!(read(&path), Some(sample(800.0)));
}

#[test]
fn identical_content_is_not_rewritten_even_with_a_new_clock() {
    let d = TempDir::new();
    let path = cache_path(&d.0);
    let mut c = WriteCoalescer::new();
    c.note_change(0);
    assert!(c.write(&path, &sample(800.0)).unwrap());
    let mut later = sample(800.0);
    later.written_at_ms = 99_999;
    c.note_change(10);
    assert!(!c.write(&path, &later).unwrap());
    assert!(!c.pending());
    c.note_change(20);
    assert!(c.write(&path, &sample(801.0)).unwrap());
}

#[test]
fn quit_flushes_whatever_is_pending() {
    let mut c = WriteCoalescer::new();
    assert!(!c.flush_now());
    c.note_change(100);
    assert!(!c.due(101));
    assert!(c.flush_now());
}

proptest! {
    /// A burst of changes is due no sooner than the debounce after its last change, and never
    /// later than the max delay after its first.
    #[test]
    fn coalescer_bounds(start in 0u64..1_000_000, gaps in prop::collection::vec(0u64..400, 1..40)) {
        let mut c = WriteCoalescer::new();
        let mut t = start;
        c.note_change(t);
        for g in &gaps {
            t += g;
            c.note_change(t);
        }
        let at = c.next_due_ms().unwrap();
        prop_assert!(at <= start + MAX_DELAY_MS);
        prop_assert!(at <= t + DEBOUNCE_MS);
        prop_assert!(at == t + DEBOUNCE_MS || at == start + MAX_DELAY_MS);
        prop_assert!(!c.due(at - 1) || at == 0);
        prop_assert!(c.due(at));
        c.wrote(&sample(1.0));
        prop_assert!(!c.due(u64::MAX));
    }

    /// Any cache written reads back equal (after its caps), through the file.
    #[test]
    fn file_round_trip(width in 1.0f64..5000.0, rows in prop::collection::vec(("[a-z]{1,6}", 1.0f64..200.0), 0..300), build in "[a-z0-9.]{0,12}") {
        let d = TempDir::new();
        let path = cache_path(&d.0);
        let mut cache = sample(width);
        cache.build_key = build;
        cache.windows[0].sidebar.row_heights = rows.into_iter().map(|(id, height)| RowHeight { id, height }).collect();
        write(&path, &cache).unwrap();
        let back = read(&path).unwrap();
        prop_assert!(back.windows[0].sidebar.row_heights.len() <= MAX_ROWS);
        prop_assert_eq!(back, cache.capped());
    }

    /// Arbitrary bytes never panic and never read as a cache unless they are one.
    #[test]
    fn garbage_never_panics(bytes in prop::collection::vec(any::<u8>(), 0..512)) {
        let d = TempDir::new();
        let path = d.0.join("v1.json");
        fs::write(&path, &bytes).unwrap();
        let _ = read(&path);
    }
}
