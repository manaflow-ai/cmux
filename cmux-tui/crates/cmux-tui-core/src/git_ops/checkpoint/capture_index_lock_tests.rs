use super::*;
use std::path::PathBuf;

/// A fresh lock file in its own temporary folder (removed by the test).
fn held_lock(name: &str) -> (PathBuf, PathBuf) {
    let unique = format!("cmux-index-lock-{name}-{}", std::process::id());
    let dir = std::env::temp_dir().join(unique);
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join("index.lock");
    std::fs::write(&lock, "").unwrap();
    (dir, lock)
}

#[test]
fn a_capture_waits_for_a_short_lived_index_lock() {
    let (dir, lock) = held_lock("short");
    std::thread::scope(|scope| {
        scope.spawn(|| {
            std::thread::sleep(Duration::from_millis(200));
            assert!(std::fs::remove_file(&lock).is_ok());
        });
        assert_eq!(wait_for_index_lock(&lock, Duration::from_secs(5)), Ok(()));
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_lock_left_behind_names_the_stale_file() {
    let (dir, lock) = held_lock("stale");
    let message = wait_for_index_lock(&lock, Duration::from_millis(150)).unwrap_err();
    std::fs::remove_dir_all(dir).unwrap();
    assert!(message.contains("remove the stale"), "{message}");
    assert!(!message.contains("try again"), "{message}");
}
