use super::*;

#[test]
fn names_round_trip_and_reject_others() {
    assert_eq!(parse_name("abc.12.png"), Some(("abc", 12)));
    assert_eq!(parse_name("w-00ff.1.png"), Some(("w-00ff", 1)));
    assert_eq!(parse_name(".abc.12.png.7.tmp"), None);
    assert_eq!(parse_name("abc.png"), None);
    assert_eq!(parse_name("abc.x1.png"), None);
    assert_eq!(parse_name("notes.txt"), None);
}

#[test]
fn caps_never_remove_the_image_being_returned() {
    // A publish that linked an older generation than a concurrent one (its folder read came
    // first) must not prune its own file, even when keep_per_window drops it.
    let dir = std::env::temp_dir().join(format!(
        "cmux-launch-image-unit-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    let store = Store::new(&dir, Caps { keep_per_window: 1, ..Caps::default() });
    for name in ["win.9000.png", "win.100.png"] {
        fs::write(dir.join(name), b"x").unwrap();
    }
    store.enforce_caps("win", "win.100.png");
    assert!(dir.join("win.100.png").exists());
    assert!(dir.join("win.9000.png").exists());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_publish_waits_for_the_folder_lock() {
    let dir = std::env::temp_dir().join(format!(
        "cmux-launch-image-lock-{}-{}",
        std::process::id(),
        now_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    let store = Store::new(&dir, Caps::default());
    let held = store.lock().unwrap();
    let done = std::sync::atomic::AtomicBool::new(false);
    std::thread::scope(|scope| {
        let handle = scope.spawn(|| {
            let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13];
            png.extend_from_slice(b"IHDR");
            png.extend_from_slice(&1_u32.to_be_bytes());
            png.extend_from_slice(&1_u32.to_be_bytes());
            png.extend_from_slice(&[8, 6, 0, 0, 0]);
            let image = store.publish("win", &png).unwrap();
            done.store(true, Ordering::SeqCst);
            image
        });
        std::thread::sleep(Duration::from_millis(100));
        assert!(!done.load(Ordering::SeqCst), "publish ran while the lock was held");
        drop(held);
        let image = handle.join().unwrap();
        assert!(image.path.exists());
    });
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn keys_are_file_safe() {
    assert_eq!(window_key("7f3a-WIN_1"), "7f3a-WIN_1");
    for id in ["../../etc/passwd", "a.b", "", "é", &"x".repeat(65)] {
        let key = window_key(id);
        assert!(key.starts_with("w-") && key.len() == 18, "{id:?} -> {key}");
    }
    assert_ne!(window_key("a.b"), window_key("a.c"));
}

/// Review follow-up on #44472 (F1): a publish's caps must not run in another publish's gap
/// between its link and its return, or that publish returns a path already deleted. Two more
/// publishes of the window start while the first sits just before its return; the first's path
/// must still be there.
#[test]
fn a_concurrent_publish_never_prunes_a_path_before_it_is_returned() {
    let dir = std::env::temp_dir()
        .join(format!("cmux-launch-image-unit-{}-race-return", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let store = Store::new(&dir, Caps { keep_per_window: 2, ..Caps::default() });
    let png = |width: u32| {
        let mut bytes = vec![0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
        bytes.extend_from_slice(&13_u32.to_be_bytes());
        bytes.extend_from_slice(b"IHDR");
        bytes.extend_from_slice(&width.to_be_bytes());
        bytes.extend_from_slice(&1_u32.to_be_bytes());
        bytes.resize(40, 7);
        bytes
    };
    let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
    std::thread::scope(|scope| {
        let first = store.publish_with("win", &png(1), 5, |path| {
            for w in [2_u32, 3] {
                let (store, done_tx, png) = (&store, done_tx.clone(), png(w));
                scope.spawn(move || {
                    store.publish_at("win", &png, 5).unwrap();
                    let _ = done_tx.send(());
                });
            }
            for _ in 0..2 {
                let _ = done_rx.recv_timeout(Duration::from_millis(500));
            }
            assert!(path.exists(), "{} was pruned before its publish returned", path.display());
        });
        assert!(first.unwrap().path.starts_with(&dir));
    });
    let _ = fs::remove_dir_all(&dir);
}
