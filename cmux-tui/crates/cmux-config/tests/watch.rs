//! `cmux_config::watch` hints for every way a watched name changes in a
//! folder that exists, including the ones FSEvents does not report: the
//! daemon's agent chat notices watch acpmux's socket with it
//! (`agent_chat_notices.rs`), and binding a Unix socket gives FSEvents no
//! create event, so on macOS the daemon never saw acpmux start while its
//! runtime folder was already there (idle_wakeups.rs
//! `cmux_next_daemon_idle_has_no_periodic_wakeups`).
#![cfg(unix)]

use std::fs;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use cmux_config::watch::Watcher;

/// A hint comes at most `MAX_DELAY` (1 s) after a burst starts, after `QUIET`
/// (100 ms) without another event: 2 s leaves room for a loaded CI host.
const HINT_WITHIN: Duration = Duration::from_secs(2);
/// How long a change that must not hint is given to hint anyway.
const NO_HINT_FOR: Duration = Duration::from_millis(800);

/// A folder of this test's own, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        // Short: a Unix socket path must fit in 104 bytes on macOS.
        let path = std::env::temp_dir().join(format!("cw-{}-{name}", std::process::id()));
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

/// A watch of `files` after its first hint (it hints once when armed).
fn armed(files: &[&Path]) -> (Watcher, Receiver<()>) {
    let (hint, hints) = mpsc::channel();
    let watcher =
        Watcher::start(files.iter().map(|file| file.to_path_buf()).collect(), move || {
            let _ = hint.send(());
        })
        .expect("the watch starts");
    hints.recv_timeout(Duration::from_secs(5)).expect("the watch hints once when armed");
    (watcher, hints)
}

fn expect_hint(hints: &Receiver<()>, what: &str) {
    assert!(hints.recv_timeout(HINT_WITHIN).is_ok(), "no hint within {HINT_WITHIN:?} of {what}");
    // The rest of the same burst.
    while hints.recv_timeout(Duration::from_millis(300)).is_ok() {}
}

#[test]
fn watch_hints_when_a_socket_is_bound_in_a_watched_folder() {
    let scratch = Scratch::new("sock");
    let socket = scratch.0.join("acpmux.sock");
    let (_watcher, hints) = armed(&[&socket]);
    let listener = UnixListener::bind(&socket).unwrap();
    expect_hint(&hints, "a socket bound at a watched name");
    drop(listener);
    fs::remove_file(socket).unwrap();
    expect_hint(&hints, "a watched socket removed");
}

#[test]
fn watch_hints_when_a_watched_file_is_created_written_and_removed() {
    let scratch = Scratch::new("file");
    let file = scratch.0.join("cmux-next.json");
    let (_watcher, hints) = armed(&[&file]);
    fs::write(&file, "{}").unwrap();
    expect_hint(&hints, "a watched file created");
    fs::write(&file, "{\"a\": 1}").unwrap();
    expect_hint(&hints, "a watched file written in place");
    let staged = scratch.0.join("cmux-next.json.tmp");
    fs::write(&staged, "{\"a\": 2}").unwrap();
    fs::rename(staged, &file).unwrap();
    expect_hint(&hints, "a watched file replaced by rename");
    fs::remove_file(file).unwrap();
    expect_hint(&hints, "a watched file removed");
}

#[test]
fn watch_ignores_other_entries_of_a_watched_folder() {
    let scratch = Scratch::new("other");
    let file = scratch.0.join("cmux-next.json");
    fs::write(&file, "{}").unwrap();
    let (_watcher, hints) = armed(&[&file]);
    let other = scratch.0.join("other");
    fs::write(&other, "1").unwrap();
    fs::write(&other, "2").unwrap();
    let staged = scratch.0.join("other.tmp");
    fs::write(&staged, "3").unwrap();
    fs::rename(staged, &other).unwrap();
    let socket = UnixListener::bind(scratch.0.join("other.sock")).unwrap();
    fs::remove_file(other).unwrap();
    assert!(hints.recv_timeout(NO_HINT_FOR).is_err(), "a change to an entry nobody watches hinted");
    drop(socket);
}

/// A database's write-ahead log stays open in its writer while it runs: each
/// commit is a write with no close. `start_with_writes` hints for it; writes
/// in place to other entries of the folder (a busy log beside it) do not.
#[test]
fn watch_with_writes_hints_for_a_write_its_writer_keeps_open() {
    use std::io::Write as _;
    let scratch = Scratch::new("writes");
    let log = scratch.0.join("state.sqlite-wal");
    let busy = scratch.0.join("logs.sqlite-wal");
    fs::write(&log, "").unwrap();
    fs::write(&busy, "").unwrap();
    let (hint, hints) = mpsc::channel();
    let _watcher = Watcher::start_with_writes(vec![log.clone()], move || {
        let _ = hint.send(());
    })
    .expect("the watch starts");
    hints.recv_timeout(Duration::from_secs(5)).expect("the watch hints once when armed");
    let mut other = fs::OpenOptions::new().append(true).open(&busy).unwrap();
    for round in 0..10 {
        writeln!(other, "{round}").unwrap();
    }
    other.sync_all().unwrap();
    assert!(hints.recv_timeout(NO_HINT_FOR).is_err(), "a write to an entry nobody watches hinted");
    let mut writer = fs::OpenOptions::new().append(true).open(&log).unwrap();
    writeln!(writer, "commit").unwrap();
    writer.sync_all().unwrap();
    expect_hint(&hints, "a write to a watched file its writer keeps open");
    drop(writer);
}

/// A watched file that was there when the watch started (no create event
/// came first): an append that its writer then closes hints.
#[test]
fn watch_hints_when_a_watched_file_is_appended_and_closed() {
    use std::io::Write as _;
    let scratch = Scratch::new("append");
    let file = scratch.0.join("cmux-next.json");
    fs::write(&file, "{}").unwrap();
    let (_watcher, hints) = armed(&[&file]);
    let mut writer = fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(writer).unwrap();
    drop(writer);
    expect_hint(&hints, "an append to a watched file, closed");
}

/// A mode change decides whether the reader can read the file, so it hints:
/// also the one that makes the file unreadable, and the one that undoes it.
#[test]
fn watch_hints_when_a_watched_file_changes_mode() {
    use std::os::unix::fs::PermissionsExt as _;
    let scratch = Scratch::new("mode");
    let file = scratch.0.join("cmux-next.json");
    fs::write(&file, "{}").unwrap();
    let (_watcher, hints) = armed(&[&file]);
    fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
    expect_hint(&hints, "a mode change of a watched file");
    fs::set_permissions(&file, fs::Permissions::from_mode(0o000)).unwrap();
    expect_hint(&hints, "a watched file made unreadable");
    fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
    expect_hint(&hints, "a watched file made readable again");
}

/// A settings file kept in another folder (a dotfiles checkout) and linked to
/// its place: the watch follows the link, so a write in place to the file it
/// names hints, and after the link is pointed at another file, a write to
/// that one hints.
#[test]
fn watch_hints_when_the_target_of_a_watched_symbolic_link_is_written() {
    let scratch = Scratch::new("link");
    let (real, linked) = (scratch.0.join("real"), scratch.0.join("linked"));
    fs::create_dir_all(&real).unwrap();
    fs::create_dir_all(&linked).unwrap();
    let (first, second) = (real.join("first.json"), real.join("second.json"));
    fs::write(&first, "{}").unwrap();
    fs::write(&second, "{}").unwrap();
    let file = linked.join("cmux-next.json");
    std::os::unix::fs::symlink(&first, &file).unwrap();
    let (_watcher, hints) = armed(&[&file]);
    fs::write(&first, "{\"a\": 1}").unwrap();
    expect_hint(&hints, "a write to the file a watched link names");
    let staged = linked.join("cmux-next.json.tmp");
    std::os::unix::fs::symlink(&second, &staged).unwrap();
    fs::rename(staged, &file).unwrap();
    expect_hint(&hints, "a watched link pointed at another file");
    fs::write(&second, "{\"a\": 2}").unwrap();
    expect_hint(&hints, "a write to the file the link names now");
}

/// A watch of a file's contents is a watch of the file that was at the name
/// when it was armed. After a replace by rename the watcher arms the new
/// file before it hints, so the reader's read has each write made before
/// that, and a later write hints again: the reader ends with what is on disk.
#[test]
fn a_reader_sees_a_write_made_right_after_a_replace_by_rename() {
    use std::io::Write as _;
    let scratch = Scratch::new("race");
    let file = scratch.0.join("cmux-next.json");
    fs::write(&file, "one").unwrap();
    let (read, reads) = mpsc::channel();
    let watched = file.clone();
    let _watcher = Watcher::start(vec![file.clone()], move || {
        let _ = read.send(fs::read_to_string(&watched).unwrap_or_default());
    })
    .expect("the watch starts");
    let seen = |want: &str, what: &str| {
        let mut last = String::new();
        while last != want {
            last = reads
                .recv_timeout(HINT_WITHIN)
                .unwrap_or_else(|_| panic!("after {what} the reader's last read was {last:?}"));
        }
    };
    seen("one", "the watch was armed");
    let staged = scratch.0.join("cmux-next.json.tmp");
    fs::write(&staged, "two").unwrap();
    fs::rename(staged, &file).unwrap();
    let mut writer = fs::OpenOptions::new().append(true).open(&file).unwrap();
    write!(writer, " three").unwrap();
    drop(writer);
    seen("two three", "a replace by rename and a write at once");
    // The file that replaced it has a watch of its own now.
    let mut writer = fs::OpenOptions::new().append(true).open(&file).unwrap();
    write!(writer, " four").unwrap();
    drop(writer);
    seen("two three four", "a write to the file that replaced it");
}

/// Each watch has its own thread: a hint that runs long (the daemon's
/// project-source import, `state/project_watch.rs`) delays no other watch.
/// A settings file written while another watch's hint is busy is still
/// hinted within the normal bound.
#[test]
fn a_busy_watch_does_not_delay_another_watch() {
    let scratch = Scratch::new("busy");
    let project = scratch.0.join("state.sqlite-wal");
    let settings = scratch.0.join("cmux-next.json");
    fs::write(&project, "").unwrap();
    fs::write(&settings, "{}").unwrap();
    let (busy_tx, busy) = mpsc::channel();
    let mut armed_once = false;
    let _project = Watcher::start_with_writes(vec![project.clone()], move || {
        if std::mem::replace(&mut armed_once, true) {
            let _ = busy_tx.send(());
            // A long import on this watch's thread.
            std::thread::sleep(Duration::from_secs(4));
        }
    })
    .expect("the project watch starts");
    let (_settings, hints) = armed(&[&settings]);
    fs::write(&project, "commit").unwrap();
    busy.recv_timeout(HINT_WITHIN).expect("the project watch's hint started");
    fs::write(&settings, "{\"a\": 1}").unwrap();
    expect_hint(&hints, "a settings change while another watch's hint is busy");
}
