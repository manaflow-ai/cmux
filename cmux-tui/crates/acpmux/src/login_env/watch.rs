//! D26: the login environment follows the person's edits. One watcher over
//! the folders of the startup files (`startup_files`, FSEvents on macOS,
//! inotify for changes only on Linux, `quiet`): an edit to one of them reads
//! the login shell again in the background at once, not at the next agent
//! spawn. No polling: the
//! event thread blocks until an event arrives. A folder that does not exist
//! at start is not watched; the spawn check (`refresh_if_changed`) still
//! sees a file created there.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

#[cfg(not(target_os = "linux"))]
use notify::Watcher as _;

/// Editors save in bursts (write, rename, chmod): read once after this quiet...
const QUIET: Duration = Duration::from_millis(300);
/// ...or after this long, when the watched folders never go quiet ($HOME).
const MAX_BURST: Duration = Duration::from_secs(2);

static STARTED: AtomicBool = AtomicBool::new(false);

/// Start the watcher once per process, on the tokio runtime of the caller
/// (the refresh runs the shell there). It lives as long as the process.
pub fn start() {
    let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let files = watched(super::startup_files());
    let mut dirs: Vec<PathBuf> =
        files.iter().filter_map(|f| f.parent().map(Path::to_path_buf)).collect();
    dirs.sort();
    dirs.dedup();
    let (tx, rx) = std::sync::mpsc::channel();
    let Some(source) = source(&dirs, tx) else { return };
    let spawned =
        std::thread::Builder::new().name("acpmux-login-env-watch".into()).spawn(move || {
            // The thread owns the event source: its events stop only with the process.
            let _source = source;
            run(&rx, &files, &rt);
        });
    if let Err(e) = spawned {
        tracing::warn!("login env: the startup-file watcher thread cannot start: {e}");
    }
}

/// What a watch of `dirs` sends on `tx`: kept alive for as long as events should come. None when
/// no folder could be watched.
#[cfg(target_os = "linux")]
fn source(dirs: &[PathBuf], tx: Sender<notify::Result<notify::Event>>) -> Option<Box<dyn Send>> {
    quiet::watch(dirs, tx).then(|| Box::new(()) as Box<dyn Send>)
}

/// Other systems: `notify`'s watcher (FSEvents on macOS, which reports no opens).
#[cfg(not(target_os = "linux"))]
fn source(dirs: &[PathBuf], tx: Sender<notify::Result<notify::Event>>) -> Option<Box<dyn Send>> {
    let mut watcher = match notify::recommended_watcher(move |event| {
        let _ = tx.send(event);
    }) {
        Ok(watcher) => watcher,
        Err(e) => {
            tracing::warn!("login env: the startup-file watcher cannot start: {e}");
            return None;
        }
    };
    let mut any = false;
    for dir in dirs.iter().filter(|d| d.is_dir()) {
        match watcher.watch(dir, notify::RecursiveMode::NonRecursive) {
            Ok(()) => any = true,
            Err(e) => tracing::debug!("login env: cannot watch {}: {e}", dir.display()),
        }
    }
    any.then(|| Box::new(watcher) as Box<dyn Send>)
}

/// Linux: inotify over the startup files' folders, for changes only. `notify`'s inotify watcher
/// always asks for `IN_OPEN` (notify 8.2), so every file a program opened in a watched folder woke
/// this daemon twice (its event thread, then `run`): the shell's folder (`/usr/bin`) and `/etc`,
/// which every program that starts opens, sent about 1,300 events a second on a busy agent VM,
/// each dropped as access (`touches`). An open or a read changes no file, so only the events that
/// can are asked for. A queue overflow (events lost) is sent as an error, which `touches` reads
/// as a change.
#[cfg(target_os = "linux")]
mod quiet {
    use super::*;
    use inotify::{EventMask, Inotify, WatchMask};

    /// Every event that can change a file in a folder, or the folder itself.
    fn changes() -> WatchMask {
        WatchMask::ATTRIB
            | WatchMask::CREATE
            | WatchMask::DELETE
            | WatchMask::CLOSE_WRITE
            | WatchMask::MODIFY
            | WatchMask::MOVED_FROM
            | WatchMask::MOVED_TO
            | WatchMask::DELETE_SELF
            | WatchMask::MOVE_SELF
    }

    /// Watches `dirs` and sends each change in them on `tx`, from a thread of its own that lives
    /// as long as the process (or until `tx`'s receiver is gone). False when no folder could be
    /// watched or the thread could not start.
    pub(super) fn watch(dirs: &[PathBuf], tx: Sender<notify::Result<notify::Event>>) -> bool {
        let mut inotify = match Inotify::init() {
            Ok(inotify) => inotify,
            Err(e) => {
                tracing::warn!("login env: the startup-file watcher cannot start: {e}");
                return false;
            }
        };
        let mut folders = std::collections::HashMap::new();
        for dir in dirs.iter().filter(|d| d.is_dir()) {
            match inotify.watches().add(dir, changes()) {
                Ok(wd) => {
                    folders.insert(wd, dir.clone());
                }
                Err(e) => tracing::debug!("login env: cannot watch {}: {e}", dir.display()),
            }
        }
        if folders.is_empty() {
            return false;
        }
        let spawned =
            std::thread::Builder::new().name("acpmux-login-env-inotify".into()).spawn(move || {
                // Room for at least one event with the longest name (NAME_MAX).
                let mut buffer = vec![0u8; 4096];
                loop {
                    let events = match inotify.read_events_blocking(&mut buffer) {
                        Ok(events) => events,
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(e) => {
                            let _ = tx.send(Err(notify::Error::io(e)));
                            return;
                        }
                    };
                    for event in events {
                        let sent = if event.mask.contains(EventMask::Q_OVERFLOW) {
                            Err(notify::Error::generic("inotify queue overflow"))
                        } else {
                            let Some(dir) = folders.get(&event.wd) else { continue };
                            let path = event.name.map_or_else(|| dir.clone(), |n| dir.join(n));
                            Ok(notify::Event::new(notify::EventKind::Any).add_path(path))
                        };
                        if tx.send(sent).is_err() {
                            return;
                        }
                    }
                }
            });
        if let Err(e) = spawned {
            tracing::warn!("login env: the startup-file watcher thread cannot start: {e}");
            return false;
        }
        true
    }
}

/// Each file as listed, plus the same name under its folder's real path
/// (`/etc` is `/private/etc` on macOS, and events carry real paths), plus
/// a symlinked file's real path (`~/.zshrc -> ~/dotfiles/zshrc`), whose
/// folder is then watched too.
fn watched(files: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut out = Vec::with_capacity(files.len() * 3);
    for f in files {
        if let (Some(dir), Some(name)) = (f.parent(), f.file_name())
            && let Ok(real) = std::fs::canonicalize(dir)
        {
            let alias = real.join(name);
            if alias != f {
                out.push(alias);
            }
        }
        if let Ok(target) = std::fs::canonicalize(&f)
            && target != f
            && !out.contains(&target)
        {
            out.push(target);
        }
        out.push(f);
    }
    out
}

/// Whether an event may have changed a startup file (an error may have
/// dropped events: check).
fn touches(event: &notify::Result<notify::Event>, files: &[PathBuf]) -> bool {
    match event {
        Ok(event) => {
            !matches!(event.kind, notify::EventKind::Access(_))
                && event.paths.iter().any(|p| files.contains(p))
        }
        Err(_) => true,
    }
}

fn run(
    rx: &Receiver<notify::Result<notify::Event>>,
    files: &[PathBuf],
    rt: &tokio::runtime::Handle,
) {
    while let Ok(event) = rx.recv() {
        if !touches(&event, files) {
            continue;
        }
        let started = Instant::now();
        loop {
            let left = MAX_BURST.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(QUIET.min(left)) {
                Ok(_) => {}
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
        let _guard = rt.enter();
        super::refresh(false);
    }
}

// The one test reads Linux's inotify source: off Linux the module is empty, and its import unused.
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    /// A program that only opens and reads a file in a watched folder sends nothing: the shell's
    /// folder (`/usr/bin`) and `/etc` are opened by every program that starts, and each open
    /// woke the daemon (about 1,300 a second on a busy agent VM). A write still arrives.
    #[test]
    fn a_read_in_a_watched_folder_sends_nothing_and_a_write_arrives() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("profile");
        std::fs::write(&file, "export A=1\n").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let source = source(&[dir.path().to_path_buf()], tx).expect("the folder is watched");
        for _ in 0..20 {
            let _ = std::fs::read_to_string(&file).unwrap();
        }
        let read = rx.recv_timeout(Duration::from_millis(300));
        assert!(read.is_err(), "a read sent an event: {read:?}");
        std::fs::write(&file, "export A=2\n").unwrap();
        let wrote = rx.recv_timeout(Duration::from_secs(5)).expect("a write sends an event");
        assert!(
            touches(&wrote, std::slice::from_ref(&file)),
            "the write did not name the file: {wrote:?}"
        );
        drop(source);
    }
}
