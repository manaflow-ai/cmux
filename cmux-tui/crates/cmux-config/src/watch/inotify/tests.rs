//! What the kernel queues for a plan's watches. An event that the watch
//! thread reads and drops (another entry's name) gives no hint, but it is
//! still a wake of that thread: a busy folder (Codex appends to its logs in
//! ~/.codex several times a second) then keeps an idle daemon awake. So these
//! tests ask the descriptor itself, not the hints. inotify queues an event
//! before the system call that causes it returns, so no test waits for one.

use std::fs;
use std::io::Write as _;
use std::os::fd::AsRawFd as _;
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::{Wake, Watches, wait};

/// A folder of this test's own, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!("cwi-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The watches of `files`, armed.
fn armed(files: &[PathBuf], writes: bool) -> Watches {
    let mut watches = Watches::new(writes).unwrap();
    watches.rearm(files).unwrap();
    watches
}

/// Whether the kernel has an event queued (the watch thread would wake).
fn queued(watches: &Watches) -> bool {
    let (_open, stop) = UnixStream::pair().unwrap();
    let timeout = Some(Duration::from_millis(50));
    matches!(wait(watches.file.as_raw_fd(), stop.as_raw_fd(), timeout), Wake::Events)
}

/// Reads all that is queued; true when an event of it counts (it would hint).
fn counts(watches: &mut Watches) -> bool {
    let mut buffer = vec![0u8; 64 * 1024];
    let mut relevant = false;
    while queued(watches) {
        relevant |= watches.read(&mut buffer).unwrap();
    }
    relevant
}

fn append(path: &Path, text: &str) -> fs::File {
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    file.write_all(text.as_bytes()).unwrap();
    file
}

fn set_mode(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

/// The folder's watch names no entry to the kernel, so its mask must leave out
/// each event that an entry nobody watches can cause while it stays an entry.
#[test]
fn a_write_a_close_and_a_mode_change_of_another_entry_queue_nothing() {
    for writes in [false, true] {
        let scratch = Scratch::new(if writes { "other-writes" } else { "other" });
        let watched = scratch.0.join("state.json");
        let busy = scratch.0.join("logs.sqlite-wal");
        fs::write(&watched, "{}").unwrap();
        fs::write(&busy, "").unwrap();
        let watches = armed(&[watched], writes);
        assert!(!queued(&watches), "arming queued an event (writes: {writes})");
        for round in 0..20 {
            drop(append(&busy, &format!("{round}\n")));
        }
        assert!(!queued(&watches), "a write and a close of another entry woke (writes: {writes})");
        set_mode(&busy, 0o600);
        assert!(!queued(&watches), "a mode change of another entry woke (writes: {writes})");
    }
}

#[test]
fn a_close_after_a_write_and_a_mode_change_of_a_watched_file_count() {
    let scratch = Scratch::new("own");
    let watched = scratch.0.join("state.json");
    fs::write(&watched, "{}").unwrap();
    let mut watches = armed(std::slice::from_ref(&watched), false);
    let writer = append(&watched, "a");
    // Without `writes`, an open writer is seen when it closes the file.
    assert!(!queued(&watches), "a write its writer keeps open woke a watch without writes");
    drop(writer);
    assert!(counts(&mut watches), "a close after a write of a watched file did not count");
    set_mode(&watched, 0o600);
    assert!(counts(&mut watches), "a mode change of a watched file did not count");
}

#[test]
fn with_writes_a_write_its_writer_keeps_open_counts() {
    let scratch = Scratch::new("open");
    let watched = scratch.0.join("state.sqlite-wal");
    fs::write(&watched, "").unwrap();
    let mut watches = armed(std::slice::from_ref(&watched), true);
    let writer = append(&watched, "commit");
    assert!(counts(&mut watches), "a write its writer keeps open did not count");
    drop(writer);
    assert!(counts(&mut watches), "the close after it did not count");
}

/// A watch of a file is a watch of its inode: after a replace by rename the
/// folder's event counts, and the rearm watches the file that is there now.
#[test]
fn a_file_replaced_by_rename_is_watched_again_by_the_rearm() {
    let scratch = Scratch::new("replace");
    let watched = scratch.0.join("state.json");
    fs::write(&watched, "one").unwrap();
    let files = [watched.clone()];
    let mut watches = armed(&files, false);
    let staged = scratch.0.join("state.json.tmp");
    fs::write(&staged, "two").unwrap();
    fs::rename(&staged, &watched).unwrap();
    assert!(counts(&mut watches), "a replace by rename did not count");
    watches.rearm(&files).unwrap();
    counts(&mut watches);
    drop(append(&watched, "three"));
    assert!(counts(&mut watches), "a write to the file that replaced it did not count");
}

/// A file the watcher may not read gets no watch of its own (inotify refuses
/// it). Its folder then reports its closes and metadata changes, so the
/// change that makes it readable is seen and the next rearm watches it.
#[test]
fn a_file_that_cannot_be_watched_is_seen_through_its_folder() {
    let scratch = Scratch::new("unreadable");
    let watched = scratch.0.join("state.json");
    let busy = scratch.0.join("logs.sqlite-wal");
    fs::write(&watched, "{}").unwrap();
    fs::write(&busy, "").unwrap();
    set_mode(&watched, 0o000);
    let files = [watched.clone()];
    let mut watches = armed(&files, false);
    set_mode(&watched, 0o644);
    assert!(counts(&mut watches), "a file made readable did not count");
    watches.rearm(&files).unwrap();
    counts(&mut watches);
    drop(append(&busy, "1"));
    assert!(!queued(&watches), "another entry woke after the file got its own watch");
    drop(append(&watched, "1"));
    assert!(counts(&mut watches), "a write to the file made readable did not count");
}
