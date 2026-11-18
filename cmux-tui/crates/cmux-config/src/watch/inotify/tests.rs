//! What the kernel queues for a plan's watches. An event that the watch
//! thread reads and drops (another entry's name) gives no hint, but it is
//! still a wake of that thread: a busy folder (Codex appends to its logs in
//! ~/.codex several times a second) then keeps an idle daemon awake. So these
//! tests ask the descriptor itself, not the hints. inotify queues an event
//! before the system call that causes it returns, so no test waits for one.

use std::ffi::OsString;
use std::fs;
use std::io::{Read as _, Write as _};
use std::os::fd::AsRawFd as _;
use std::os::unix::ffi::OsStringExt as _;
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::{EVENT_HEADER, IN_CLOSE_WRITE, Wake, Watches, wait};

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

/// Reads all that is queued, past the watcher's own reader: the mask and the
/// entry name of each event. Each of them is a wake at most, so their number
/// is the ceiling of the wakes.
fn events(watches: &Watches) -> Vec<(u32, OsString)> {
    let mut buffer = vec![0u8; 64 * 1024];
    let mut seen = Vec::new();
    while queued(watches) {
        let length = (&watches.file).read(&mut buffer).unwrap();
        let mut rest = buffer.get(..length).unwrap();
        while let Some((header, tail)) = rest.split_first_chunk::<EVENT_HEADER>() {
            let [_, _, _, _, m0, m1, m2, m3, _, _, _, _, l0, l1, l2, l3] = *header;
            let (name, next) = tail.split_at(u32::from_ne_bytes([l0, l1, l2, l3]) as usize);
            rest = next;
            // The name is NUL-padded.
            let name = name.split(|byte| *byte == 0).next().unwrap_or_default();
            seen.push((u32::from_ne_bytes([m0, m1, m2, m3]), OsString::from_vec(name.to_vec())));
        }
    }
    seen
}

fn append(path: &Path, text: &str) -> fs::File {
    let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
    file.write_all(text.as_bytes()).unwrap();
    file
}

fn set_mode(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

/// Writes the user of the test run on stderr (a failed test's output holds
/// it). No mode binds root: as root, a test of a name that may not be read
/// proves the name's own watch and not the folder's wider one.
fn note_user(scratch: &Scratch) {
    use std::os::unix::fs::MetadataExt as _;
    let uid = fs::metadata(&scratch.0).map(|metadata| metadata.uid());
    eprintln!("inotify tests: the user of this run is uid {uid:?}");
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
///
/// For a process with CAP_DAC_OVERRIDE (root) this test passes and proves
/// less: no mode binds it, so the file has a watch of its own from the
/// start, and each event here is that watch's, not the folder's. Nothing in
/// a green run shows that: `note_user` writes the user of the run, and a
/// runner shows it for a failed test only.
#[test]
fn a_file_that_cannot_be_watched_is_seen_through_its_folder() {
    let scratch = Scratch::new("unreadable");
    note_user(&scratch);
    let watched = scratch.0.join("state.json");
    fs::write(&watched, "{}").unwrap();
    set_mode(&watched, 0o000);
    let files = [watched.clone()];
    let mut watches = armed(&files, false);
    set_mode(&watched, 0o644);
    assert!(counts(&mut watches), "a file made readable did not count");
    watches.rearm(&files).unwrap();
    counts(&mut watches);
    drop(append(&watched, "1"));
    assert!(counts(&mut watches), "a write to the file made readable did not count");
}

/// The cost of a mask that only grows: a folder that fell back (its file
/// could not be watched) keeps the close and metadata events after the file
/// has a watch of its own. A close after a write of another entry of that
/// one folder then wakes one time, which is what each watched folder did
/// before a file had a watch of its own, and no more than that: the kernel
/// queues ONE event for the write and its close, a close after a write of
/// that entry, and it gives no hint. A fallback that asked more of the
/// folder (each write, each open, each read, each close after a read) would
/// queue more than one, so the test also reads the entry.
///
/// A process with CAP_DAC_OVERRIDE (root) cannot make this test's fallback
/// (no mode binds it, so the file has a watch of its own from the start);
/// the test then fails at its first assert, which says so.
#[test]
fn a_folder_that_fell_back_wakes_one_time_for_each_close_of_another_entry() {
    const ROUNDS: usize = 20;
    let scratch = Scratch::new("fell-back");
    note_user(&scratch);
    let watched = scratch.0.join("state.json");
    let busy = scratch.0.join("logs.sqlite-wal");
    fs::write(&watched, "{}").unwrap();
    fs::write(&busy, "").unwrap();
    set_mode(&watched, 0o000);
    assert!(
        fs::File::open(&watched).is_err(),
        "this user reads a file of mode 000 (root?): no folder falls back, the test proves nothing"
    );
    let files = [watched.clone()];
    let mut watches = armed(&files, false);
    set_mode(&watched, 0o644);
    assert!(counts(&mut watches), "a file made readable did not count");
    watches.rearm(&files).unwrap();
    counts(&mut watches);
    let one_close = [(IN_CLOSE_WRITE, OsString::from("logs.sqlite-wal"))];
    for round in 0..ROUNDS {
        // The watcher's own reader: the close wakes it, and it gives no hint.
        drop(append(&busy, &format!("{round}\n")));
        assert!(queued(&watches), "a close of another entry queued nothing (no fallback)");
        assert!(!counts(&mut watches), "a close of another entry counted (it would hint)");
        // The events themselves: one for a write and its close, and none
        // for the open, the read and the close of a reader.
        drop(append(&busy, &format!("{round}\n")));
        fs::read(&busy).unwrap();
        let seen = events(&watches);
        assert_eq!(seen, one_close, "the events of a write, its close and a read (round {round})");
    }
}

/// A folder that loses its search bit hides its names: the look at a watched
/// file in it fails, which does not say that the file is gone. Its folder
/// then reports each entry (as for a file that cannot be watched), so a
/// write in place is seen after the folder can be searched again, which no
/// event of an entry says.
///
/// For a process with CAP_DAC_OVERRIDE (root) this test passes and proves
/// nothing of the fallback: such a process can search the folder of mode
/// 600, so the file keeps its own watch.
#[test]
fn a_file_whose_folder_cannot_be_searched_for_a_time_is_still_seen() {
    let scratch = Scratch::new("search");
    note_user(&scratch);
    let (shut, open) = (scratch.0.join("shut"), scratch.0.join("open"));
    fs::create_dir_all(&shut).unwrap();
    fs::create_dir_all(&open).unwrap();
    let (hidden, other) = (shut.join("state.json"), open.join("state.json"));
    fs::write(&hidden, "{}").unwrap();
    fs::write(&other, "{}").unwrap();
    let files = [hidden.clone(), other.clone()];
    let mut watches = armed(&files, false);
    set_mode(&shut, 0o600);
    counts(&mut watches);
    // An event that counts elsewhere arms the watches while the file is hidden.
    drop(append(&other, "1"));
    let other_counted = counts(&mut watches);
    watches.rearm(&files).unwrap();
    counts(&mut watches);
    set_mode(&shut, 0o700);
    counts(&mut watches);
    drop(append(&hidden, "1"));
    assert!(other_counted, "a write to the file of the other folder did not count");
    assert!(
        counts(&mut watches),
        "a write in place was lost after its folder could be searched again"
    );
}
