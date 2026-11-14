//! Linux: an inotify watch that follows a few paths (folders, or files through their folders),
//! non-recursive, asking only for the events that can change what a folder holds. Each event
//! reaches its sender as a `notify::Event` naming the path (the folder joined with the entry's
//! name); a queue overflow (events lost) is sent as an error.
//!
//! It follows paths, not the folders it found at start (`State::sync`). For each target it
//! watches the folder as named and the folder its symbolic links lead to, each through its
//! nearest existing ancestor while it is missing, plus the folder that holds each link on the
//! way (re-pointing a link is an entry made or moved there). After each event that can change
//! which folders those are (an entry made, removed or moved on the way, a watched folder moved,
//! removed or replaced, a lost queue) the reading thread looks again before it sends the events:
//! a folder that appeared is watched (and named in an event of its own, since a file may be in
//! it before its watch), a folder whose inode changed under the same name (replaced with `mv`)
//! is watched again, and a watch no longer needed is removed. An inotify watch is on an inode,
//! so without this a replaced folder's edits went unseen until restart, a link to a folder made
//! later was never followed, and a refresh that dropped a folder kept its watch (Codex review of
//! #42548, F1 and F2; cmux#42565 for the login environment). Not followed: an existing ancestor
//! of an existing folder replaced under its name (`mv ~/.config ...` while `~/.config/cmux`
//! exists); its parents are not watched, so the old watch keeps the moved folder until restart.
//! Watching every ancestor would wake each watch for every entry made in `$HOME`.
//!
//! Not `notify`'s inotify watcher: it always asks for `IN_OPEN` (notify 8.2), so a watched folder
//! that every program opens files in sent an event per open. The harness profile watch watches
//! the nearest existing ancestor of a missing source folder, which for `/etc/cmux/harnesses` is
//! `/etc`: an idle daemon then woke for every program that started (`tests/daemon_idle.rs`). A
//! folder watched only for its entries (an ancestor on the way to a missing folder, a link's
//! folder) is asked for entries made, removed and moved, and nothing else. No timers: the
//! thread looks again only when an event comes.
//!
//! The reading thread blocks in `poll` on the inotify descriptor and a pipe; dropping the watch
//! writes to the pipe, and the thread ends and drops its sender.

use std::collections::HashMap;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, PoisonError};

use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};

/// What a folder's watch reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    /// Only entries made, removed or moved, and the folder itself removed or moved.
    Entries,
    /// Every change of a file in it, or of the folder itself.
    Changes,
}

fn mask(kind: Kind) -> WatchMask {
    let entries = WatchMask::CREATE
        | WatchMask::DELETE
        | WatchMask::MOVED_FROM
        | WatchMask::MOVED_TO
        | WatchMask::DELETE_SELF
        | WatchMask::MOVE_SELF
        | WatchMask::ONLYDIR;
    match kind {
        Kind::Entries => entries,
        Kind::Changes => entries | WatchMask::ATTRIB | WatchMask::CLOSE_WRITE | WatchMask::MODIFY,
    }
}

/// A path a [`QuietDirs`] follows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Target {
    /// A folder: every change in it.
    Dir(PathBuf),
    /// A file: every change in its folder.
    File(PathBuf),
}

/// A folder's device and inode: a folder replaced under the same name has another.
type Id = (u64, u64);

struct Armed {
    wd: WatchDescriptor,
    kind: Kind,
    id: Id,
}

/// The watches, shared by the owner and the reading thread.
struct State {
    watches: Watches,
    targets: Vec<Target>,
    armed: HashMap<PathBuf, Armed>,
    by_wd: HashMap<WatchDescriptor, PathBuf>,
    /// Every path on the way to a target, as named and resolved, and each link followed: an
    /// entry event naming one of them (or an ancestor) may change which folders are watched.
    on_the_way: Vec<PathBuf>,
}

/// Live while held: dropping it ends the reading thread.
pub(crate) struct QuietDirs {
    state: Arc<Mutex<State>>,
    stop: OwnedFd,
    #[cfg(test)]
    fd: RawFd,
}

impl QuietDirs {
    /// Watches `targets` and starts the reading thread (named `name`), which sends each event on
    /// `tx` until this is dropped or `tx`'s receiver is gone.
    pub(crate) fn follow(
        tx: Sender<notify::Result<notify::Event>>,
        name: &str,
        targets: Vec<Target>,
    ) -> std::io::Result<Self> {
        let mut inotify = Inotify::init()?;
        let mut pipe = [0 as RawFd; 2];
        // SAFETY: `pipe` has room for the two descriptors pipe2 writes.
        if unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: pipe2 succeeded, so both descriptors are open and owned only here.
        let (read_end, write_end) = unsafe {
            use std::os::fd::FromRawFd;
            (OwnedFd::from_raw_fd(pipe[0]), OwnedFd::from_raw_fd(pipe[1]))
        };
        #[cfg(test)]
        let fd = inotify.as_raw_fd();
        let state = Arc::new(Mutex::new(State {
            watches: inotify.watches(),
            targets,
            armed: HashMap::new(),
            by_wd: HashMap::new(),
            on_the_way: Vec::new(),
        }));
        // The first look: the owner reads the targets itself, so nothing is sent for it.
        let _ = state.lock().unwrap_or_else(PoisonError::into_inner).sync();
        let thread_state = state.clone();
        // task-owner: the QuietDirs; ends when it is dropped (its stop pipe) or `tx`'s receiver
        // is gone.
        std::thread::Builder::new().name(name.into()).spawn(move || {
            let mut buffer = vec![0u8; 4096];
            loop {
                let mut fds = [
                    libc::pollfd { fd: inotify.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                    libc::pollfd { fd: read_end.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                ];
                // SAFETY: `fds` is a valid array of two pollfd for the call.
                let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
                if ready < 0 {
                    let e = std::io::Error::last_os_error();
                    if e.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    let _ = tx.send(Err(notify::Error::io(e)));
                    return;
                }
                if fds[1].revents != 0 {
                    return;
                }
                let events = match inotify.read_events(&mut buffer) {
                    Ok(events) => events,
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) =>
                    {
                        continue;
                    }
                    Err(e) => {
                        let _ = tx.send(Err(notify::Error::io(e)));
                        return;
                    }
                };
                let mut state = thread_state.lock().unwrap_or_else(PoisonError::into_inner);
                let mut out = Vec::new();
                let mut look_again = false;
                for event in events {
                    if event.mask.contains(EventMask::Q_OVERFLOW) {
                        out.push(Err(notify::Error::generic("inotify queue overflow")));
                        look_again = true;
                        continue;
                    }
                    let Some(dir) = state.by_wd.get(&event.wd).cloned() else { continue };
                    if event.mask.contains(EventMask::IGNORED) {
                        // The folder is gone (or its watch removed): watch its path again.
                        state.forget(&event.wd);
                        look_again = true;
                        continue;
                    }
                    let self_event =
                        event.mask.intersects(EventMask::MOVE_SELF | EventMask::DELETE_SELF);
                    // A watched folder's own attributes (a chmod or touch of `$HOME` or `/etc`)
                    // change nothing it holds: not sent.
                    if event.name.is_none() && !self_event {
                        continue;
                    }
                    let path = event.name.map_or_else(|| dir.clone(), |n| dir.join(n));
                    let entry = !event
                        .mask
                        .intersects(EventMask::MODIFY | EventMask::CLOSE_WRITE | EventMask::ATTRIB);
                    if self_event
                        || (entry && state.on_the_way.iter().any(|p| p.starts_with(&path)))
                    {
                        look_again = true;
                    }
                    out.push(Ok(notify::Event::new(notify::EventKind::Any).add_path(path)));
                }
                if look_again {
                    for dir in state.sync() {
                        out.push(Ok(notify::Event::new(notify::EventKind::Any).add_path(dir)));
                    }
                }
                drop(state);
                for sent in out {
                    if tx.send(sent).is_err() {
                        return;
                    }
                }
            }
        })?;
        Ok(Self {
            state,
            stop: write_end,
            #[cfg(test)]
            fd,
        })
    }

    /// Looks at the targets' paths again now (the reading thread does after each event that
    /// may change them).
    pub(crate) fn sync(&self) {
        let _ = self.state.lock().unwrap_or_else(PoisonError::into_inner).sync();
    }

    /// The folders watched now.
    #[cfg(test)]
    fn watched(&self) -> Vec<PathBuf> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let mut watched: Vec<PathBuf> = state.armed.keys().cloned().collect();
        watched.sort();
        watched
    }

    /// The kernel's count of this watch's inotify watches (`/proc/self/fdinfo`).
    #[cfg(test)]
    fn kernel_watches(&self) -> usize {
        std::fs::read_to_string(format!("/proc/self/fdinfo/{}", self.fd))
            .map(|info| info.lines().filter(|l| l.starts_with("inotify wd:")).count())
            .unwrap_or(0)
    }
}

impl Drop for QuietDirs {
    fn drop(&mut self) {
        // SAFETY: `stop` is the open write end of the pipe; one byte from a valid buffer.
        let _ = unsafe { libc::write(self.stop.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
    }
}

impl State {
    /// A watch the kernel ended (its folder is gone): forget it.
    fn forget(&mut self, wd: &WatchDescriptor) {
        if let Some(path) = self.by_wd.remove(wd)
            && self.armed.get(&path).is_some_and(|armed| armed.wd == *wd)
        {
            self.armed.remove(&path);
        }
    }

    fn unarm(&mut self, path: &Path) {
        if let Some(armed) = self.armed.remove(path) {
            self.by_wd.remove(&armed.wd);
            let _ = self.watches.remove(armed.wd);
        }
    }

    /// Makes the watches the ones the targets need now (`wanted`): removes each watch no longer
    /// wanted or whose folder was replaced under its name, and adds the missing ones. A folder
    /// made between the look and its parent's watch has no event (the watch came after it), so
    /// after each new watch it looks again, until a look adds none. Returns the folders newly
    /// watched.
    fn sync(&mut self) -> Vec<PathBuf> {
        let mut fresh = Vec::new();
        // Bounded: a path that keeps changing while it is looked at is looked at on its next
        // event.
        for _ in 0..16 {
            let (wanted, on_the_way) = wanted(&self.targets);
            self.on_the_way = on_the_way;
            #[cfg(test)]
            if let Some(mut hook) = tests::AFTER_LOOK.with(|hook| hook.borrow_mut().take()) {
                hook();
            }
            let stale: Vec<PathBuf> = self
                .armed
                .iter()
                .filter(|(path, armed)| !wanted.iter().any(|w| &w.0 == *path && w.2 == armed.id))
                .map(|(path, _)| path.clone())
                .collect();
            for path in &stale {
                self.unarm(path);
            }
            let mut added = false;
            // A folder gone between the look and its watch: the next look watches its nearest
            // existing ancestor in its place, or nothing would see it made again.
            let mut vanished = false;
            for (path, kind, id) in wanted {
                if self.armed.get(&path).is_some_and(|armed| armed.kind == kind) {
                    continue;
                }
                let new = !self.armed.contains_key(&path);
                let wd = match self.watches.add(&path, mask(kind)) {
                    Ok(wd) => wd,
                    Err(e) => {
                        tracing::debug!("quiet dirs: cannot watch {}: {e}", path.display());
                        // Gone since the look: look again now. Still there (a permission
                        // error): looked at again on the next event that may change it.
                        vanished |= !path.exists();
                        continue;
                    }
                };
                // A kind change keeps the folder's watch (the kernel replaces its mask).
                if let Some(old) =
                    self.armed.insert(path.clone(), Armed { wd: wd.clone(), kind, id })
                    && old.wd != wd
                {
                    self.by_wd.remove(&old.wd);
                }
                self.by_wd.insert(wd, path.clone());
                if new {
                    added = true;
                    fresh.push(path);
                }
            }
            if !added && !vanished {
                break;
            }
        }
        fresh
    }
}

/// The folders `targets` need watched, each once (by inode), and the paths on the way to them.
/// For each target: its folder as named and as its links resolve, each the folder itself
/// (every change) when it exists, else its nearest existing ancestor (entries only); and the
/// folder holding each link followed on the way (entries only).
fn wanted(targets: &[Target]) -> (Vec<(PathBuf, Kind, Id)>, Vec<PathBuf>) {
    let mut out: Vec<(PathBuf, Kind, Id)> = Vec::new();
    let mut on_the_way: Vec<PathBuf> = Vec::new();
    let mut add = |dir: &Path, own: bool| {
        let Some((at, meta)) = dir.ancestors().find_map(|a| {
            std::fs::metadata(a).ok().filter(std::fs::Metadata::is_dir).map(|m| (a, m))
        }) else {
            return;
        };
        let kind = if own && at == dir { Kind::Changes } else { Kind::Entries };
        let id = (meta.dev(), meta.ino());
        match out.iter_mut().find(|w| w.2 == id) {
            Some(w) => w.1 = w.1.max(kind),
            None => out.push((at.to_path_buf(), kind, id)),
        }
    };
    for target in targets {
        let (path, file) = match target {
            Target::Dir(path) => (path, false),
            Target::File(path) => (path, true),
        };
        let (real, links) = resolve(path);
        for named in [path, &real] {
            let dir = if file { named.parent() } else { Some(named.as_path()) };
            if let Some(dir) = dir {
                add(dir, true);
            }
            if !on_the_way.contains(named) {
                on_the_way.push(named.clone());
            }
        }
        for link in links {
            if let Some(parent) = link.parent() {
                add(parent, false);
            }
            if !on_the_way.contains(&link) {
                on_the_way.push(link);
            }
        }
    }
    (out, on_the_way)
}

/// `path` with every symbolic link on it followed, including one whose target does not exist
/// yet (`canonicalize` refuses those), and the links followed, in order. At most 40 links (the
/// kernel's own bound); a part that cannot be read is kept as named.
pub(crate) fn resolve(path: &Path) -> (PathBuf, Vec<PathBuf>) {
    let parts = |p: &Path| -> Vec<PathBuf> {
        p.components().rev().map(|c| PathBuf::from(c.as_os_str())).collect()
    };
    let mut todo = parts(path);
    let mut out = PathBuf::new();
    let mut links = Vec::new();
    while let Some(part) = todo.pop() {
        match part.components().next() {
            Some(Component::RootDir) => out = PathBuf::from("/"),
            Some(Component::ParentDir) => {
                out.pop();
            }
            Some(Component::Normal(name)) => {
                let next = out.join(name);
                match std::fs::read_link(&next) {
                    Ok(target) if links.len() < 40 => {
                        links.push(next);
                        todo.extend(parts(&target));
                    }
                    _ => out = next,
                }
            }
            _ => {}
        }
    }
    (out, links)
}

#[cfg(test)]
mod tests;
