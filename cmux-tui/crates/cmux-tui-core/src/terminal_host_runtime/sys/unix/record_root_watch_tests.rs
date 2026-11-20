use std::fs::File;
use std::sync::mpsc;
use std::time::Duration;

use super::*;

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir()
        .join(format!(
            "cmux-record-root-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_nanos())
        ))
        .join("records");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The host keeps files open inside its record directory (its PTY lock,
/// its lease); the removal is still reported at once (on Linux the
/// directory's own IN_DELETE_SELF waits until those files close).
#[test]
fn removing_the_directory_reports_once_and_a_write_in_it_does_not() {
    let dir = scratch("removed");
    let held = File::create(dir.join("t.pty.lock")).unwrap();
    let (tx, rx) = mpsc::channel();
    follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
    // Records are written and replaced inside the directory all the time.
    std::fs::write(dir.join("a.json.tmp"), b"{}").unwrap();
    std::fs::rename(dir.join("a.json.tmp"), dir.join("a.json")).unwrap();
    std::fs::remove_file(dir.join("a.json")).unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "a write reported removal");
    std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("the removal was not reported");
    drop(held);
}

#[test]
fn a_directory_renamed_away_is_reported() {
    let dir = scratch("renamed");
    let _held = File::create(dir.join("t.live")).unwrap();
    let (tx, rx) = mpsc::channel();
    follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
    std::fs::rename(&dir, dir.with_file_name("moved")).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("the rename was not reported");
    std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
}

#[test]
fn a_directory_gone_before_the_watch_is_reported_at_once() {
    let dir = scratch("gone");
    std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    let (tx, rx) = mpsc::channel();
    follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("a gone directory was not reported");
}
