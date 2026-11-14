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
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn watch(files: Vec<PathBuf>) -> (NamedFilesWatch, mpsc::Receiver<Vec<PathBuf>>) {
        let (tx, rx) = mpsc::channel();
        let watch =
            NamedFilesWatch::start(files, move |changed| tx.send(changed.to_vec()).is_err())
                .expect("the files are watched");
        (watch, rx)
    }

    fn arrives(rx: &mpsc::Receiver<Vec<PathBuf>>, file: &Path, what: &str) {
        let changed = rx.recv_timeout(Duration::from_secs(5)).unwrap_or_else(|_| {
            panic!("{what}: no event");
        });
        assert!(changed.iter().any(|c| c == file), "{what}: {changed:?}");
        while rx.recv_timeout(Duration::from_millis(200)).is_ok() {}
    }

    fn quiet(rx: &mpsc::Receiver<Vec<PathBuf>>, what: &str) {
        let noise = rx.recv_timeout(Duration::from_millis(500));
        assert!(noise.is_err(), "{what} sent an event: {noise:?}");
    }

    /// The folder of the file is `$HOME`, where every agent writes its logs and transcripts:
    /// writes below it send nothing; the file created, saved by rename and written in place each
    /// arrives.
    #[test]
    fn writes_to_other_files_send_nothing_and_a_file_saved_by_rename_is_still_seen() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap();
        let file = home.join(".zshrc");
        let deep = home.join(".codex/sessions/2026/11/12");
        std::fs::create_dir_all(&deep).unwrap();
        let (watch, rx) = watch(vec![file.clone()]);
        for n in 0..20 {
            std::fs::write(deep.join("rollout.jsonl"), format!("{n}\n")).unwrap();
            std::fs::write(home.join(".codex/logs_2.sqlite-wal"), format!("{n}\n")).unwrap();
        }
        quiet(&rx, "a write to another file");
        std::fs::write(&file, "export A=1\n").unwrap();
        arrives(&rx, &file, "created");
        let saved = home.join(".zshrc.tmp");
        std::fs::write(&saved, "export A=2\n").unwrap();
        std::fs::rename(&saved, &file).unwrap();
        arrives(&rx, &file, "saved by rename");
        std::fs::write(&file, "export A=3\n").unwrap();
        arrives(&rx, &file, "written in place after the rename");
        let other = home.join(".claude.json.tmp");
        std::fs::write(&other, "{}").unwrap();
        std::fs::rename(&other, home.join(".claude.json")).unwrap();
        quiet(&rx, "a rename of another file");
        drop(watch);
    }

    /// A file whose folders do not exist yet (`~/.config/cmux/cmux-next.json` on a new Mac): the
    /// folders made and the file written in one burst still arrive, and a write after that too.
    #[test]
    fn a_file_in_folders_made_later_is_seen() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap();
        let file = home.join(".config/cmux/cmux-next.json");
        let (watch, rx) = watch(vec![file.clone()]);
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(home.join(".codex/history.jsonl"), "x").unwrap();
        quiet(&rx, "a write in another folder");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "{}").unwrap();
        arrives(&rx, &file, "made with its folders");
        std::fs::write(&file, "{\"a\": 1}").unwrap();
        arrives(&rx, &file, "written again");
        drop(watch);
    }

    /// A symlinked folder (a dotfiles checkout): a save by rename in the link's target folder
    /// arrives under the name as given.
    #[test]
    fn a_file_under_a_symlinked_folder_is_seen_in_its_real_folder() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let dotfiles = root.join("dotfiles/config");
        std::fs::create_dir_all(dotfiles.join("cmux")).unwrap();
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::os::unix::fs::symlink(&dotfiles, home.join(".config")).unwrap();
        let file = home.join(".config/cmux/cmux-next.json");
        let (watch, rx) = watch(vec![file.clone()]);
        let saved = dotfiles.join("cmux/.cmux-next.json.tmp");
        std::fs::write(&saved, "{}").unwrap();
        std::fs::rename(&saved, dotfiles.join("cmux/cmux-next.json")).unwrap();
        arrives(&rx, &file, "saved by rename in the real folder");
        drop(watch);
    }
}
