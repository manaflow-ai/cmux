//! D26: the login environment follows the person's edits. One watcher over
//! the folders of the startup files (`startup_files`; kqueue on macOS, `kq`;
//! on Linux `quiet_dirs`, inotify for changes only, following each file's
//! path): an edit to one of them reads the login shell again in the
//! background at once, not at the next agent spawn. No polling: the event
//! thread blocks until an event arrives. On Linux a folder that does not
//! exist at start is watched through its nearest existing ancestor, and the
//! watch moves down the path as folders appear (cmux#42565); elsewhere it is
//! not watched, and the spawn check (`refresh_if_changed`) still sees a file
//! created there.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
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
    let Some(source) = source(&dirs, &files, tx) else { return };
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

/// What a watch of the startup files sends on `tx`: kept alive for as long as events should
/// come. None when the watch could not start.
///
/// Linux: inotify over the startup files' folders, for changes only, following each file's path
/// (`quiet_dirs`): a folder missing at start is watched through its nearest existing ancestor,
/// and a folder that appears, or is replaced, is watched when it does. `notify`'s inotify
/// watcher always asks for `IN_OPEN` (notify 8.2), so every file a program opened in a watched
/// folder woke this daemon twice: the shell's folder (`/usr/bin`) and `/etc`, which every
/// program that starts opens, sent about 1,300 events a second on a busy agent VM. Only the
/// events that can change a file are asked for. A queue overflow (events lost) is sent as an
/// error, which `touches` reads as a change.
#[cfg(target_os = "linux")]
fn source(
    _dirs: &[PathBuf],
    files: &[PathBuf],
    tx: Sender<notify::Result<notify::Event>>,
) -> Option<Box<dyn Send>> {
    use crate::quiet_dirs::{QuietDirs, Target};
    let targets = files.iter().cloned().map(Target::File).collect();
    match QuietDirs::follow(tx, "acpmux-login-env-inotify", targets) {
        Ok(watch) => Some(Box::new(watch)),
        Err(e) => {
            tracing::warn!("login env: the startup-file watcher cannot start: {e}");
            None
        }
    }
}

/// macOS: kqueue on each startup file and its folder's entries (`kq`).
#[cfg(target_os = "macos")]
fn source(
    _dirs: &[PathBuf],
    files: &[PathBuf],
    tx: Sender<notify::Result<notify::Event>>,
) -> Option<Box<dyn Send>> {
    kq::watch(files, tx)
}

/// Other systems: `notify`'s watcher.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn source(
    dirs: &[PathBuf],
    _files: &[PathBuf],
    tx: Sender<notify::Result<notify::Event>>,
) -> Option<Box<dyn Send>> {
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

/// macOS: kqueue on each startup file and its folder's entries (`named_files_watch`), not an
/// FSEvents stream over `$HOME`, which woke for every write below it. It sends each startup file
/// whose stamp changed.
#[cfg(target_os = "macos")]
mod kq {
    use super::*;
    use crate::named_files_watch::NamedFilesWatch;

    pub(super) fn watch(
        files: &[PathBuf],
        tx: Sender<notify::Result<notify::Event>>,
    ) -> Option<Box<dyn Send>> {
        let watch = NamedFilesWatch::start(files.to_vec(), move |changed| {
            changed.iter().any(|path| {
                let event = notify::Event::new(notify::EventKind::Any).add_path(path.clone());
                tx.send(Ok(event)).is_err()
            })
        })?;
        Some(Box::new(watch))
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

/// Whether an event may have changed a startup file: one of them, or a folder on the way to one
/// (made, removed or replaced: a file may be in a folder before its watch is). An error may have
/// dropped events: check.
fn touches(event: &notify::Result<notify::Event>, files: &[PathBuf]) -> bool {
    match event {
        Ok(event) => {
            !matches!(event.kind, notify::EventKind::Access(_))
                && event.paths.iter().any(|p| files.iter().any(|f| f.starts_with(p)))
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

// The tests read the inotify (Linux) and kqueue (macOS) sources: elsewhere the module is empty.
#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
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
        let source = source(&[dir.path().to_path_buf()], std::slice::from_ref(&file), tx)
            .expect("the folder is watched");
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

    /// cmux#42565: a startup file whose folder does not exist when the watch starts
    /// (`~/.config/cmux/machine.env` with no `~/.config`) is seen once the folder and the file
    /// are made, with no agent spawn: the nearest existing folder stands in and the watch moves
    /// down the path as each folder appears.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_startup_file_in_a_folder_made_after_the_start_is_seen() {
        let base = tempfile::tempdir().unwrap();
        let home = std::fs::canonicalize(base.path()).unwrap();
        let folder = home.join(".config").join("cmux");
        let file = folder.join("machine.env");
        let files = watched(vec![home.join(".profile"), file.clone()]);
        let dirs = vec![home.clone(), folder.clone()];
        let (tx, rx) = std::sync::mpsc::channel();
        let source = source(&dirs, &files, tx).expect("the home is watched");
        std::fs::create_dir_all(&folder).unwrap();
        // The folders' arrival counts (a file may be in them before their watch is armed).
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            let left = end.saturating_duration_since(Instant::now());
            let event = rx.recv_timeout(left).expect("making the folder sent no event touching it");
            if touches(&event, &files) {
                break;
            }
        }
        while rx.recv_timeout(Duration::from_millis(300)).is_ok() {}
        std::fs::write(&file, "A=1\n").unwrap();
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            let left = end.saturating_duration_since(Instant::now());
            let event = rx.recv_timeout(left).expect("writing the startup file sent no event");
            if event.as_ref().is_ok_and(|e| e.paths.contains(&file)) {
                break;
            }
        }
        drop(source);
    }
}
