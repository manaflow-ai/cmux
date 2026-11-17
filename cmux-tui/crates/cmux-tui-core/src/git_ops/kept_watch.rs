//! The kept Files listings (`kept`), one per repository the Files tree asks
//! about, each kept current by one watch of its work tree.
//!
//! The daemon had no watch of a work tree: the Files page's refresh comes
//! from the app's own watch, and every request listed the folder again. Here
//! the first `git.files.list` or `git.files.search` of a repository starts a
//! thread that arms one recursive watch of the work tree (notify, as the
//! daemon's app folder watch: FSEvents on macOS, inotify on Linux), and of
//! the git folder when it is outside the work tree, then lists the
//! repository once. That first request, and any while the tree is not ready,
//! is answered by the direct path, as before.
//!
//! The watch's thread drains each burst of events and follows it in the
//! tree: changed work-tree paths (`KeptTree::apply`), the index
//! (`KeptTree::apply_index`). An ignore file, the git folder's `config` or
//! `info/exclude`, an event for the top folder itself, and a watch that
//! reports lost events (an overflow, a rescan, an error) make the thread
//! build the tree again; until it is built, requests take the direct path.
//! No request waits for a build.
//!
//! A request is answered from the tree only after the watch has caught up
//! with the disk: it makes a mark file in the git folder (`cmux-files-sync-*`,
//! made and removed at once) and waits for the watch thread to have followed
//! the burst that holds the mark's event, so every change made before the
//! request is in the tree (the same mark watchman calls a cookie). A request
//! whose mark does not come back in time takes the direct path.
//!
//! At most [`MAX_KEPT`] repositories are kept, the least recently asked
//! dropped first; one not asked for [`IDLE`] is dropped at the next request.
//! A dropped repository's watch and thread end with it.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant};

use notify::Watcher as _;

use super::Repository;
use super::kept::KeptTree;

/// Repositories kept at once.
const MAX_KEPT: usize = 8;
/// A repository not asked about for this long is dropped.
const IDLE: Duration = Duration::from_secs(30 * 60);
/// How long a request waits for the watch to catch up.
const SYNC_WAIT: Duration = Duration::from_millis(250);
/// After a failed start, the repository is tried again after this long.
const RETRY: Duration = Duration::from_secs(5 * 60);
/// The mark files' names start with this.
const MARK: &str = "cmux-files-sync-";

static KEPT: Mutex<Vec<Arc<Kept>>> = Mutex::new(Vec::new());

/// One kept repository.
pub(super) struct Kept {
    root: PathBuf,
    git_dir: PathBuf,
    state: Mutex<State>,
    changed: Condvar,
    next_mark: AtomicU64,
    /// The watch; dropped with this, which ends the watch thread.
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

struct State {
    tree: Option<KeptTree>,
    status: Status,
    /// The newest mark the watch thread has followed.
    followed: u64,
    asked: Instant,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Status {
    /// The tree is being built; requests take the direct path.
    Building,
    Ready,
    /// The watch or the listing failed; the direct path answers.
    Failed(Instant),
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The kept tree of `repository`, current with the disk, for `use_tree`; or
/// `None` when it is not ready (its build is started here the first time):
/// the caller answers by the direct path.
pub(super) fn with_tree<T>(
    repository: &Repository,
    use_tree: impl FnOnce(&mut KeptTree) -> T,
) -> Option<T> {
    let kept = kept(repository)?;
    let mut state = kept.sync()?;
    state.tree.as_mut().map(use_tree)
}

/// The kept repository at `repository.root`, started when there is none.
fn kept(repository: &Repository) -> Option<Arc<Kept>> {
    let now = Instant::now();
    let mut kept = lock(&KEPT);
    kept.retain(|one| {
        let state = lock(&one.state);
        let idle = now.duration_since(state.asked) > IDLE;
        let retry = matches!(state.status, Status::Failed(at) if now.duration_since(at) > RETRY);
        !idle && !retry
    });
    if let Some(at) = kept.iter().position(|one| one.root == repository.root) {
        let one = kept.remove(at);
        lock(&one.state).asked = now;
        kept.push(Arc::clone(&one));
        return Some(one);
    }
    let git_dir = git_dir(repository)?;
    let one = Arc::new(Kept {
        root: repository.root.clone(),
        git_dir,
        state: Mutex::new(State { tree: None, status: Status::Building, followed: 0, asked: now }),
        changed: Condvar::new(),
        next_mark: AtomicU64::new(0),
        watcher: Mutex::new(None),
    });
    let weak = Arc::downgrade(&one);
    let repository = Repository::open(&repository.root).ok()?;
    let started = std::thread::Builder::new()
        .name("files-kept".into())
        .spawn(move || watch(&weak, &repository));
    if started.is_err() {
        return None;
    }
    if kept.len() >= MAX_KEPT {
        kept.remove(0);
    }
    kept.push(Arc::clone(&one));
    // Not ready yet: this request takes the direct path.
    None
}

/// The repository's git folder (outside the work tree for a linked one).
fn git_dir(repository: &Repository) -> Option<PathBuf> {
    let output = repository.run(&["rev-parse", "--absolute-git-dir"], 64 * 1024).ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let path = PathBuf::from(text.trim_end_matches('\n'));
    path.is_absolute().then_some(path)
}

impl Kept {
    /// Waits until the watch thread has followed every change made before
    /// this call; the state then, or `None` when the tree is not ready or
    /// the watch did not catch up in time.
    fn sync(&self) -> Option<MutexGuard<'_, State>> {
        if lock(&self.state).status != Status::Ready {
            return None;
        }
        let mark = self.next_mark.fetch_add(1, Ordering::Relaxed) + 1;
        let path = self.git_dir.join(format!("{MARK}{}-{mark}", std::process::id()));
        std::fs::OpenOptions::new().write(true).create_new(true).open(&path).ok()?;
        let _ = std::fs::remove_file(&path);
        let deadline = Instant::now() + SYNC_WAIT;
        let mut state = lock(&self.state);
        while state.followed < mark {
            if state.status != Status::Ready {
                return None;
            }
            let left = deadline.checked_duration_since(Instant::now())?;
            state =
                self.changed.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        (state.status == Status::Ready).then_some(state)
    }

    fn set(&self, change: impl FnOnce(&mut State)) {
        change(&mut lock(&self.state));
        self.changed.notify_all();
    }
}

/// What one burst of events asks of the tree.
#[derive(Default)]
struct Burst {
    rebuild: bool,
    index: bool,
    paths: Vec<String>,
    mark: u64,
}

/// The watch thread of one kept repository.
fn watch(kept: &Weak<Kept>, repository: &Repository) {
    let (sender, events) = channel();
    let watcher = notify::recommended_watcher(move |event| {
        let _ = sender.send(event);
    });
    let Some((root, git_dir)) = kept.upgrade().map(|one| (one.root.clone(), one.git_dir.clone()))
    else {
        return;
    };
    let armed = watcher.and_then(|mut watcher| {
        watcher.watch(&root, notify::RecursiveMode::Recursive)?;
        if !git_dir.starts_with(&root) {
            watcher.watch(&git_dir, notify::RecursiveMode::NonRecursive)?;
        }
        Ok(watcher)
    });
    let Some(one) = kept.upgrade() else { return };
    match armed {
        Ok(watcher) => *lock(&one.watcher) = Some(watcher),
        Err(_) => {
            one.set(|state| state.status = Status::Failed(Instant::now()));
            return;
        }
    }
    drop(one);
    // Armed before the listing: a change after it is an event.
    if !rebuild(kept, repository) {
        return;
    }
    while let Some(burst) = next_burst(&events, &root, &git_dir) {
        let Some(one) = kept.upgrade() else { return };
        if burst.rebuild {
            drop(one);
            if !rebuild(kept, repository) {
                return;
            }
            let Some(one) = kept.upgrade() else { return };
            one.set(|state| state.followed = state.followed.max(burst.mark));
            continue;
        }
        let mut state = lock(&one.state);
        let followed = match state.tree.as_mut() {
            Some(tree) => {
                (!burst.index || tree.apply_index(repository)) && tree.apply(&burst.paths)
            }
            None => false,
        };
        drop(state);
        if !followed {
            drop(one);
            if !rebuild(kept, repository) {
                return;
            }
            let Some(one) = kept.upgrade() else { return };
            one.set(|state| state.followed = state.followed.max(burst.mark));
            continue;
        }
        one.set(|state| state.followed = state.followed.max(burst.mark));
    }
}

/// Builds the tree again, off any request: requests take the direct path
/// meanwhile. False when the repository is gone (the thread ends).
fn rebuild(kept: &Weak<Kept>, repository: &Repository) -> bool {
    let Some(one) = kept.upgrade() else { return false };
    // Every mark made before the build is covered by it.
    let covered = one.next_mark.load(Ordering::Relaxed);
    one.set(|state| state.status = Status::Building);
    drop(one);
    let built = KeptTree::build(repository).map(|mut tree| {
        // The index's digest, so its next change touches what changed only.
        let _ = tree.apply_index(repository);
        tree
    });
    let Some(one) = kept.upgrade() else { return false };
    one.set(|state| match built {
        Ok(tree) => {
            state.tree = Some(tree);
            state.status = Status::Ready;
            state.followed = state.followed.max(covered);
        }
        Err(_) => {
            state.tree = None;
            state.status = Status::Failed(Instant::now());
        }
    });
    true
}

/// The next burst: one event, then each one already queued. `None` when
/// the watch ended.
fn next_burst(
    events: &Receiver<notify::Result<notify::Event>>,
    root: &Path,
    git_dir: &Path,
) -> Option<Burst> {
    let mut burst = Burst::default();
    let first = events.recv().ok()?;
    let take = |event: notify::Result<notify::Event>, burst: &mut Burst| match event {
        Err(_) => burst.rebuild = true,
        Ok(event) => {
            if event.need_rescan() {
                burst.rebuild = true;
            }
            // An open, a read or a close, and a write of a file's content,
            // change no name and no kind: the listing's own walk (git's,
            // and the looks) opens the folders it lists.
            if matches!(
                event.kind,
                notify::EventKind::Access(_)
                    | notify::EventKind::Modify(notify::event::ModifyKind::Data(_))
            ) {
                return;
            }
            for path in &event.paths {
                classify(path, root, git_dir, burst);
            }
        }
    };
    take(first, &mut burst);
    while let Ok(event) = events.try_recv() {
        take(event, &mut burst);
    }
    Some(burst)
}

/// What a changed `path` asks of the tree.
fn classify(path: &Path, root: &Path, git_dir: &Path, burst: &mut Burst) {
    if let Ok(inside) = path.strip_prefix(git_dir) {
        let name = inside.to_str().unwrap_or_default();
        if let Some(mark) = name.strip_prefix(MARK) {
            let ours = mark
                .split_once('-')
                .filter(|(pid, _)| *pid == std::process::id().to_string())
                .and_then(|(_, mark)| mark.parse::<u64>().ok());
            if let Some(mark) = ours {
                burst.mark = burst.mark.max(mark);
            }
        } else if name == "index" {
            burst.index = true;
        } else if name == "config" || name == "info/exclude" || name == "info" {
            burst.rebuild = true;
        }
        return;
    }
    let Ok(inside) = path.strip_prefix(root) else { return };
    let Some(inside) = inside.to_str() else { return };
    if inside.is_empty() {
        burst.rebuild = true;
        return;
    }
    let parts: Vec<&str> = inside.split('/').collect();
    if parts.last() == Some(&".gitignore") {
        burst.rebuild = true;
        return;
    }
    // A `.git` that comes or goes makes or unmakes a nested repository:
    // its folder changed. Below one, nothing git lists here.
    match parts.iter().position(|part| *part == ".git") {
        Some(at) if at + 1 == parts.len() && at > 0 => burst.paths.push(parts[..at].join("/")),
        Some(_) => {}
        None => burst.paths.push(inside.to_owned()),
    }
}

/// Test only: waits until the kept tree of `root` is ready (or failed).
#[cfg(test)]
pub(super) fn wait_ready(root: &Path, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    let Some(one) = lock(&KEPT).iter().find(|one| one.root == root).cloned() else {
        return false;
    };
    let mut state = lock(&one.state);
    while state.status == Status::Building {
        let Some(left) = deadline.checked_duration_since(Instant::now()) else { return false };
        state = one.changed.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0;
    }
    state.status == Status::Ready
}
