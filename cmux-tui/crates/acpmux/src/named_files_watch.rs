//! A watch of a few named files (the login shell's startup files, the cmux settings file) that
//! wakes the daemon only when one of them changes. macOS only: kqueue vnode watches
//! (`record_watch::DirWatch`) on each file that exists and on the entries of its folder (or of
//! the nearest folder that exists, so a folder made later is seen), as named and through
//! symlinks.
//!
//! Not FSEvents: a stream over a folder reports every change below it, and the folder of most of
//! these files is `$HOME` (`~/.zshrc`), or is `$HOME` while `~/.config/cmux` does not exist yet.
//! Every write anywhere under the home (each agent's logs and transcripts in `~/.codex` and
//! `~/.claude`, every build in a checkout) then woke the daemon's FSEvents threads (lead order,
//! 2026-11-12: about 130 context switches per 12 s at 20 writes a second in `~/.codex`, on top
//! of the chat watch). A change of a watched folder's entries that changes no named file
//! (`~/.claude.json` saved by rename next to `~/.zshrc`) costs one stat of each file and hands
//! nothing on.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, Weak};

use crate::agent_host::record_watch::DirWatch;

/// What a file is now: (device, inode, length, modified, changed), or absent.
type Stamp = Option<(u64, u64, u64, (i64, i64), (i64, i64))>;

/// A watched path and the (device, inode) it had when its watch was armed.
type Target = (PathBuf, Option<(u64, u64)>);

/// At most this many re-arms in one event: a folder made and filled in a burst settles in a few.
const MAX_REARMS: usize = 8;

fn stamp(path: &Path) -> Stamp {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::metadata(path).ok()?;
    Some((m.dev(), m.ino(), m.len(), (m.mtime(), m.mtime_nsec()), (m.ctime(), m.ctime_nsec())))
}

fn identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

/// `path` resolved through its nearest existing folder: a file not made yet under a symlinked
/// folder (`~/.config` linked to a dotfiles checkout) still names its real place.
pub(crate) fn real(path: &Path) -> PathBuf {
    let mut tail = Vec::new();
    let mut at = path;
    loop {
        if let Ok(base) = std::fs::canonicalize(at) {
            return tail.iter().rev().fold(base, |acc, part| acc.join(part));
        }
        match (at.parent(), at.file_name()) {
            (Some(parent), Some(name)) => {
                tail.push(name.to_owned());
                at = parent;
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// What to watch for `files` now: each file that exists, and the nearest existing folder of
/// each, as named and resolved; each once, with its identity.
fn targets(files: &[PathBuf]) -> Vec<Target> {
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut add = |path: PathBuf| {
        if !paths.contains(&path) {
            paths.push(path);
        }
    };
    for file in files {
        for named in [file.clone(), real(file)] {
            if let Some(folder) = named.parent().and_then(|p| p.ancestors().find(|a| a.is_dir())) {
                add(folder.to_path_buf());
            }
            if named.is_file() {
                add(named);
            }
        }
    }
    paths
        .into_iter()
        .map(|path| {
            let id = identity(&path);
            (path, id)
        })
        .collect()
}

type OnChange = Box<dyn Fn(&[PathBuf]) -> bool + Send + Sync>;

struct Inner {
    stamps: Vec<Stamp>,
    armed: Vec<Target>,
    watch: Option<DirWatch>,
}

struct State {
    files: Vec<PathBuf>,
    on_change: OnChange,
    inner: Mutex<Inner>,
}

/// Live while held: dropping it ends the kqueue thread.
pub(crate) struct NamedFilesWatch {
    _state: Arc<State>,
}

impl NamedFilesWatch {
    /// Watches `files`. `on_change` gets the files whose stamp changed, from the watch's thread;
    /// it returns true when it needs no more events (its receiver is gone). None when nothing
    /// could be watched.
    pub(crate) fn start(
        files: Vec<PathBuf>,
        on_change: impl Fn(&[PathBuf]) -> bool + Send + Sync + 'static,
    ) -> Option<Self> {
        let stamps = files.iter().map(|f| stamp(f)).collect();
        let state = Arc::new(State {
            files,
            on_change: Box::new(on_change),
            inner: Mutex::new(Inner { stamps, armed: Vec::new(), watch: None }),
        });
        let mut inner = state.inner.lock().unwrap_or_else(PoisonError::into_inner);
        arm(&state, &mut inner, targets(&state.files));
        let armed = inner.watch.is_some();
        drop(inner);
        armed.then_some(Self { _state: state })
    }
}

/// Watches `now`; the watch it replaces ends at its next event (dropping it triggers its stop).
fn arm(state: &Arc<State>, inner: &mut Inner, now: Vec<Target>) {
    let paths: Vec<PathBuf> = now.iter().map(|(path, _)| path.clone()).collect();
    let weak: Weak<State> = Arc::downgrade(state);
    inner.watch = DirWatch::start(&paths, move || match weak.upgrade() {
        Some(state) => check(&state),
        None => true,
    });
    inner.armed = now;
}

/// One kqueue event: hands on each file whose stamp changed, and arms the watch again when what
/// it should hold changed (a file or folder made, removed or replaced). True when this watch's
/// thread is done: the receiver is gone, or a new watch took over.
fn check(state: &Arc<State>) -> bool {
    let mut changed: Vec<PathBuf> = Vec::new();
    let mut replaced = false;
    let mut inner = state.inner.lock().unwrap_or_else(PoisonError::into_inner);
    for _ in 0..MAX_REARMS {
        // Stamps after the watch is armed, so a change between the two is seen by one of them.
        let now: Vec<Stamp> = state.files.iter().map(|f| stamp(f)).collect();
        for ((file, was), is) in state.files.iter().zip(&inner.stamps).zip(&now) {
            if was != is && !changed.contains(file) {
                changed.push(file.clone());
            }
        }
        inner.stamps = now;
        let wanted = targets(&state.files);
        if wanted == inner.armed {
            break;
        }
        arm(state, &mut inner, wanted);
        replaced = true;
    }
    drop(inner);
    let gone = !changed.is_empty() && (state.on_change)(&changed);
    gone || replaced
}

#[cfg(test)]
mod tests;
