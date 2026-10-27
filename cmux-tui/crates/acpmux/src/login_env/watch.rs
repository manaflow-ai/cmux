//! D26: the login environment follows the person's edits. One watcher over
//! the folders of the startup files (`startup_files`, FSEvents on macOS,
//! inotify on Linux): an edit to one of them reads the login shell again in
//! the background at once, not at the next agent spawn. No polling: the
//! event thread blocks until an event arrives. A folder that does not exist
//! at start is not watched; the spawn check (`refresh_if_changed`) still
//! sees a file created there.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use cmux_config::watch::queue::{DEFAULT_CAPACITY, EventReceiver, event_queue};
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
    let (tx, rx) = event_queue(DEFAULT_CAPACITY);
    let mut watcher = match notify::recommended_watcher(tx) {
        Ok(watcher) => watcher,
        Err(e) => {
            tracing::warn!("login env: the startup-file watcher cannot start: {e}");
            return;
        }
    };
    let mut any = false;
    for dir in dirs.iter().filter(|d| d.is_dir()) {
        match watcher.watch(dir, notify::RecursiveMode::NonRecursive) {
            Ok(()) => any = true,
            Err(e) => tracing::debug!("login env: cannot watch {}: {e}", dir.display()),
        }
    }
    if !any {
        return;
    }
    let spawned =
        std::thread::Builder::new().name("acpmux-login-env-watch".into()).spawn(move || {
            // The thread owns the watcher: its events stop only with the process.
            let _watcher = watcher;
            run(&rx, &files, &rt);
        });
    if let Err(e) = spawned {
        tracing::warn!("login env: the startup-file watcher thread cannot start: {e}");
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

/// Whether an event may have changed a startup file (an error or a rescan
/// may have dropped events: check).
fn touches(event: &notify::Result<notify::Event>, files: &[PathBuf]) -> bool {
    match event {
        Ok(event) => {
            event.need_rescan()
                || (!matches!(event.kind, notify::EventKind::Access(_))
                    && event.paths.iter().any(|p| files.contains(p)))
        }
        Err(_) => true,
    }
}

fn run(rx: &EventReceiver, files: &[PathBuf], rt: &tokio::runtime::Handle) {
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
