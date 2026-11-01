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
