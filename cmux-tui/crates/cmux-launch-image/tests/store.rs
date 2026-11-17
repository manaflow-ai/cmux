//! The store's contract: caps, atomic replace, prune on close, and "no image" as a valid read.

use cmux_launch_image::{Caps, PublishError, Store, window_key};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

fn fresh_dir(name: &str) -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "launch-image-{name}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = fs::remove_dir_all(&dir);
    dir
}

/// A PNG header of `width` x `height` padded to `len` bytes (the store reads only the header).
fn png(width: u32, height: u32, len: usize) -> Vec<u8> {
    let mut bytes = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
    bytes.extend_from_slice(&13_u32.to_be_bytes());
    bytes.extend_from_slice(b"IHDR");
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    bytes.resize(len.max(bytes.len()), 7);
    bytes
}

fn files(dir: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map(|r| {
            r.filter_map(Result::ok).filter_map(|e| e.file_name().into_string().ok()).collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

#[test]
fn no_image_reads_as_none_not_an_error() {
    let dir = fresh_dir("none");
    let store = Store::new(&dir, Caps::default());
    // Missing folder.
    assert_eq!(store.current("win-1"), None);
    assert_eq!(store.remove_window("win-1"), 0);
    assert_eq!(store.prune(&["win-1"]), 0);
    // Empty folder, unrelated files, a truncated file, a non-PNG file.
    fs::create_dir_all(&dir).unwrap();
    assert_eq!(store.current("win-1"), None);
    fs::write(dir.join("notes.txt"), b"x").unwrap();
    fs::write(dir.join("win-1.5.png"), &png(10, 10, 30)[..20]).unwrap();
    fs::write(dir.join("win-1.4.png"), b"GIF89a, not a png at all, long enough").unwrap();
    assert_eq!(store.current("win-1"), None);
    assert_eq!(store.current(""), None);
}

#[test]
fn an_oversized_image_is_refused_at_publish_and_ignored_at_read() {
    let dir = fresh_dir("oversized");
    let caps = Caps { max_image_bytes: 1000, ..Caps::default() };
    let store = Store::new(&dir, caps);
    let first = store.publish_at("win", &png(4, 3, 1000), 10).unwrap();
    match store.publish_at("win", &png(8, 6, 1001), 20) {
        Err(PublishError::TooLarge { bytes: 1001, cap: 1000 }) => {}
        other => panic!("expected TooLarge, got {other:?}"),
    }
    // The previous image stays.
    assert_eq!(store.current("win"), Some(first.clone()));
    // A file over the cap that got there another way is no image; the next older one is used.
    fs::write(dir.join("win.30.png"), png(8, 6, 2000)).unwrap();
    assert_eq!(store.current("win"), Some(first));
}

#[test]
fn not_a_png_is_refused() {
    let store = Store::new(fresh_dir("notpng"), Caps::default());
    assert!(matches!(store.publish("win", b"hello"), Err(PublishError::NotPng)));
    assert!(matches!(store.publish("win", &png(0, 10, 40)), Err(PublishError::NotPng)));
    assert!(matches!(store.publish("", &png(1, 1, 40)), Err(PublishError::EmptyWindowId)));
}

#[test]
fn publish_is_an_atomic_replace_under_a_new_name() {
    let dir = fresh_dir("atomic");
    let store = Store::new(&dir, Caps::default());
    let a = store.publish_at("win", &png(100, 50, 64), 1_000).unwrap();
    assert_eq!((a.pixel_width, a.pixel_height, a.bytes), (100, 50, 64));
    assert_eq!(a.path, dir.join("win.1000.png"));
    let a_bytes = fs::read(&a.path).unwrap();
    // A clock that went back still gets a newer generation: a name is never reused.
    let b = store.publish_at("win", &png(200, 100, 80), 500).unwrap();
    assert_eq!(b.generation, 1_001);
    assert_eq!(store.current("win"), Some(b));
    // The older path still holds its own bytes (the launch record may name it until rewritten).
    assert_eq!(fs::read(&a.path).unwrap(), a_bytes);
    // No partial file is left.
    assert!(files(&dir).iter().all(|n| !n.ends_with(".tmp")), "{:?}", files(&dir));
}

#[test]
fn each_window_keeps_its_newest_images_only() {
    let dir = fresh_dir("per-window");
    let store = Store::new(&dir, Caps { keep_per_window: 2, ..Caps::default() });
    for t in 1..=5 {
        store.publish_at("win", &png(t, t, 40), t.into()).unwrap();
    }
    assert_eq!(files(&dir), ["win.4.png", "win.5.png"]);
    assert_eq!(store.current("win").unwrap().pixel_width, 5);
}

#[test]
fn a_path_handed_to_the_record_survives_overlapping_publishes() {
    use std::sync::{Arc, Mutex, mpsc};
    use std::time::Duration;
    let dir = fresh_dir("handoff");
    let store = Arc::new(Store::new(&dir, Caps { keep_per_window: 2, ..Caps::default() }));
    let record: Arc<Mutex<Option<PathBuf>>> = Arc::default();
    let (in_hand_off, entered) = mpsc::channel();
    let first = {
        let (store, record) = (Arc::clone(&store), Arc::clone(&record));
        std::thread::spawn(move || {
            store
                .publish_with("win", &png(1, 1, 40), |image| {
                    in_hand_off.send(()).unwrap();
                    // Two newer publishes of the window try to run while this record write is slow.
                    std::thread::sleep(Duration::from_millis(300));
                    assert!(
                        image.path.exists(),
                        "{:?} was pruned before the record named it",
                        image.path
                    );
                    *record.lock().unwrap() = Some(image.path.clone());
                })
                .unwrap()
        })
    };
    entered.recv().unwrap();
    let later: Vec<_> = (2..=3)
        .map(|w| {
            let (store, record) = (Arc::clone(&store), Arc::clone(&record));
            std::thread::spawn(move || {
                store
                    .publish_with("win", &png(w, w, 40), |image| {
                        *record.lock().unwrap() = Some(image.path.clone());
                    })
                    .unwrap()
            })
        })
        .collect();
    first.join().unwrap();
    for thread in later {
        thread.join().unwrap();
    }
    let named = record.lock().unwrap().clone().unwrap();
    assert!(named.exists(), "the record names {named:?}, which is gone: {:?}", files(&dir));
    assert_eq!(files(&dir).len(), 2, "{:?}", files(&dir));
}

#[test]
fn the_window_count_cap_evicts_the_least_recently_published() {
    let dir = fresh_dir("count");
    let store = Store::new(&dir, Caps { max_windows: 3, keep_per_window: 1, ..Caps::default() });
    store.publish_at("a", &png(1, 1, 40), 1).unwrap();
    store.publish_at("b", &png(1, 1, 40), 2).unwrap();
    store.publish_at("c", &png(1, 1, 40), 3).unwrap();
    // `a` publishes again: it is the newest, so `b` is now the oldest.
    store.publish_at("a", &png(1, 1, 40), 4).unwrap();
    store.publish_at("d", &png(1, 1, 40), 5).unwrap();
    assert_eq!(files(&dir), ["a.4.png", "c.3.png", "d.5.png"]);
    assert_eq!(store.current("b"), None);
}

#[test]
fn closing_a_window_removes_its_images_only() {
    let dir = fresh_dir("close");
    let store = Store::new(&dir, Caps::default());
    store.publish_at("keep", &png(1, 1, 40), 1).unwrap();
    store.publish_at("gone", &png(1, 1, 40), 2).unwrap();
    store.publish_at("gone", &png(1, 1, 40), 3).unwrap();
    assert_eq!(store.remove_window("gone"), 2);
    assert_eq!(store.current("gone"), None);
    assert_eq!(files(&dir), ["keep.1.png"]);
}

#[test]
fn prune_keeps_live_windows_and_drops_partial_writes() {
    let dir = fresh_dir("prune");
    let store = Store::new(&dir, Caps::default());
    store.publish_at("live", &png(1, 1, 40), 1).unwrap();
    store.publish_at("dead", &png(1, 1, 40), 2).unwrap();
    let odd = "window/with.dots";
    store.publish_at(odd, &png(1, 1, 40), 3).unwrap();
    fs::write(dir.join(".live.9.png.123.tmp"), b"partial").unwrap();
    fs::write(dir.join("README"), b"not ours").unwrap();
    assert_eq!(store.prune(&["live", odd]), 0, "nothing is old enough yet");
    assert_eq!(store.prune_older_than(&["live", odd], std::time::Duration::ZERO), 2);
    assert_eq!(
        files(&dir),
        vec!["README".to_owned(), "live.1.png".to_owned(), format!("{}.3.png", window_key(odd))]
    );
}

#[test]
fn ids_that_are_not_file_safe_never_leave_the_folder() {
    let dir = fresh_dir("unsafe");
    let store = Store::new(&dir, Caps::default());
    let image = store.publish_at("../../escape", &png(1, 1, 40), 1).unwrap();
    assert_eq!(image.path.parent(), Some(dir.as_path()));
    assert_eq!(store.current("../../escape"), Some(image));
}

#[test]
fn concurrent_publishes_of_one_window_never_share_a_path() {
    let dir = fresh_dir("race");
    let store = Store::new(&dir, Caps { keep_per_window: 64, ..Caps::default() });
    let images: Vec<_> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..8_u32)
            .map(|i| {
                let store = &store;
                scope.spawn(move || store.publish_at("win", &png(i + 1, 1, 40), 5).unwrap())
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    let mut paths: Vec<_> = images.iter().map(|i| i.path.clone()).collect();
    paths.sort();
    paths.dedup();
    assert_eq!(paths.len(), 8, "every publish got its own path");
    for image in &images {
        let bytes = fs::read(&image.path).unwrap();
        assert_eq!(cmux_launch_image::png_pixel_size(&bytes), Some((image.pixel_width, 1)));
    }
    assert!(files(&dir).iter().all(|n| !n.ends_with(".tmp")));
}
