//! Local apps reload when their files change (cx-swovq.1): the user's
//! customization folder (`Sources::customize`, id `local/customize`) and the
//! local development folder (`<state>/apps/local`). A file watch (FSEvents on
//! macOS, inotify on Linux) wakes one thread; no timer, no polling. A burst of
//! events is drained before one catalog read. Only an app whose files changed
//! restarts its host (its mounts are sent again, so a hover card or a section
//! renders the new script); a removed app's mounts fail. A script that fails
//! to load shows its error where the app renders (the mount fails), and the
//! host never takes the daemon down. The customization app installs itself
//! with its required scopes when it first appears (the user wrote it).
//!
//! The watch must never lose the last change. Fingerprints are taken before
//! the catalog read they describe (`PrintsBefore`), so a save that lands
//! during a read changes the next fingerprint and its event reads again. A
//! fingerprint hashes file contents, which a coarse file clock cannot hide.
//! Only a change wakes the watch: inotify also reports every open, and the
//! reload's own reads open the watched files. An overflowed queue or a watch
//! error, which can lose events, reads again. A folder that is missing, or
//! deleted and made again, is watched once it is there (`Folders`).

use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Weak};

use notify::event::{AccessKind, AccessMode, EventKind};
use serde_json::json;

use super::catalog::{self, CUSTOMIZE_APP, Package};
use super::mirror::{self, Op, Source};
use super::supervisor::{Out, Supervisor};

/// Fingerprints of the local packages (`fingerprint`), by app id.
type Prints = HashMap<String, u64>;

/// Files read per package for its fingerprint (a runaway folder costs no more).
const MAX_FILES: usize = 2_000;

/// File bytes hashed per package for its fingerprint. An app's scripts and
/// manifest are kilobytes; a large asset past this budget is fingerprinted by
/// its size and modification time, so a reload never reads more than this.
const MAX_HASHED_BYTES: u64 = 4 << 20;

impl Supervisor {
    /// Starts the watch thread; returns at once. `prints` are the startup
    /// catalog's, taken before its read (`PrintsBefore`). In-crate tests
    /// build many supervisors and read no real folders.
    pub(crate) fn start_local_watch(self: &Arc<Self>, prints: Prints) {
        if cfg!(test) {
            return;
        }
        let me = Arc::downgrade(self);
        let local = self.config.sources.local.clone();
        let customize = self.config.sources.customize.clone();
        let spawned = std::thread::Builder::new()
            .name("apps-local-reload".into())
            .spawn(move || watch(&me, local, customize, prints));
        if let Err(error) = spawned {
            eprintln!("cmux-tui: apps local reload thread did not start: {error}");
        }
    }

    /// Reads the catalog again and applies what changed in local apps since
    /// `prints`; returns the new fingerprints.
    pub(crate) fn reload_local_apps(&self, prints: &Prints) -> Prints {
        self.reload_local_apps_from(prints, catalog::load)
    }

    /// `reload_local_apps` with the catalog read given: a test lands a save
    /// right after the read.
    pub(super) fn reload_local_apps_from(
        &self,
        prints: &Prints,
        load: impl FnOnce(&catalog::Sources) -> catalog::Catalog,
    ) -> Prints {
        let before = PrintsBefore::take(&self.config.sources);
        let catalog = load(&self.config.sources);
        let next = before.of(&self.config.sources, &catalog);
        let changed: Vec<String> = next
            .iter()
            .filter(|(id, print)| prints.get(*id) != Some(*print))
            .map(|(id, _)| id.clone())
            .collect();
        let removed: Vec<String> =
            prints.keys().filter(|id| !next.contains_key(*id)).cloned().collect();
        if changed.is_empty() && removed.is_empty() {
            return next;
        }
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let mut outs = Vec::new();
            for (dir, issue) in &catalog.rejected {
                if is_local_dir(&self.config.sources, dir) {
                    let message = format!("{}: {issue}", dir.display());
                    outs.extend(self.log_locked(&mut inner, "cmux/supervisor", "warn", message));
                }
            }
            inner.catalog = catalog;
            if changed.iter().any(|id| id == CUSTOMIZE_APP) {
                self.seed_customize_locked(&mut inner);
            }
            for app in &changed {
                outs.extend(self.regrant_locked(&mut inner, app));
            }
            for app in &removed {
                outs.extend(self.stop_app_locked(&mut inner, app, "removed"));
            }
            for app in changed.iter().chain(&removed) {
                outs.push(Out::Broadcast(json!({
                    "event": "apps-changed",
                    "revision": inner.mirror.revision,
                    "transaction": "local-reload",
                    "app": app,
                })));
            }
            outs.extend(Self::inventory_demand_locked(&mut inner));
            outs
        };
        self.emit(outs);
        next
    }

    /// Installs the customization app with its required scopes the first
    /// time it appears; a record the user changed (uninstalled) stays.
    pub(super) fn seed_customize_locked(&self, inner: &mut super::supervisor::Inner) {
        let Some(facts) = inner.catalog.packages.get(CUSTOMIZE_APP).map(Package::facts) else {
            return;
        };
        let seed = Op::Seed { app: CUSTOMIZE_APP.into(), hidden: false };
        if let Ok(outcome) = mirror::reduce(&inner.mirror, &seed, Some(&facts))
            && outcome.changed
            && self.persist(&outcome.mirror).is_ok()
        {
            inner.mirror = outcome.mirror;
        }
    }
}

/// The mirror with the customization app installed as an unverified install
/// would be: read scopes only and the sandbox on (more needs the user's
/// grant), never the deployment default's wider grant. `None` when the
/// mirror already has a record for it.
pub(super) fn seed_customize(mirror: &mirror::Mirror, package: &Package) -> Option<mirror::Mirror> {
    let facts = package.facts();
    let seed = Op::Seed { app: CUSTOMIZE_APP.into(), hidden: false };
    let outcome =
        mirror::reduce(mirror, &seed, Some(&facts)).ok().filter(|outcome| outcome.changed)?;
    let mut next = outcome.mirror;
    let (grants, sandboxed) = facts.install_defaults();
    if let Some(record) = next.apps.get_mut(CUSTOMIZE_APP) {
        record.grants = grants;
        record.sandboxed = sandboxed;
        record.source = Source::Local;
    }
    Some(next)
}

fn is_local_dir(sources: &catalog::Sources, dir: &Path) -> bool {
    sources.customize.as_deref() == Some(dir)
        || sources.local.as_deref().is_some_and(|local| dir.starts_with(local))
}

/// Fingerprints of the watched local folders (the customization folder and
/// each folder in the local directory), taken BEFORE the catalog read they
/// describe. A save after them changes the next fingerprint, so its event
/// reads again. Taken after the read, they could already hold a save the read
/// missed, and that save's event saw no change: the app kept its old files
/// until the next save.
pub(super) struct PrintsBefore(HashMap<PathBuf, u64>);

impl PrintsBefore {
    pub(super) fn take(sources: &catalog::Sources) -> Self {
        let mut dirs: Vec<PathBuf> = sources.customize.iter().cloned().collect();
        if let Some(Ok(entries)) = sources.local.as_deref().map(std::fs::read_dir) {
            dirs.extend(entries.flatten().map(|entry| entry.path()));
        }
        let prints = dirs.into_iter().filter(|dir| dir.is_dir()).map(|dir| {
            let print = fingerprint(&dir);
            (dir, print)
        });
        Self(prints.collect())
    }

    /// The fingerprints of `catalog`'s local packages, by app id, for a
    /// catalog read after `take`. A watched folder made during the read has
    /// no fingerprint from before it: it gets `UNREAD`, which no fingerprint
    /// equals, so the next event reads it again. A local package outside the
    /// watched folders (a `local/` id in an apps directory) is not watched;
    /// its fingerprint is taken now.
    pub(super) fn of(&self, sources: &catalog::Sources, catalog: &catalog::Catalog) -> Prints {
        catalog
            .packages
            .values()
            .filter(|p| p.source == Source::Local)
            .map(|p| {
                let print = match self.0.get(&p.dir) {
                    Some(print) => *print,
                    None if is_local_dir(sources, &p.dir) => UNREAD,
                    None => fingerprint(&p.dir),
                };
                (p.id.clone(), print)
            })
            .collect()
    }
}

/// The fingerprint of a watched folder that had none before the catalog
/// read (`PrintsBefore::of`); `fingerprint` never returns it.
const UNREAD: u64 = 0;

/// Every file's path, size and contents under `dir` (dot folders and
/// node_modules skipped), hashed. Contents, not the modification time: a
/// coarse file clock gives a same-size save the old time. Files past
/// `MAX_HASHED_BYTES` in all count by their modification time.
fn fingerprint(dir: &Path) -> u64 {
    let mut files = Vec::new();
    collect(dir, &mut files);
    files.sort();
    let mut hasher = DefaultHasher::new();
    let mut budget = MAX_HASHED_BYTES;
    for (path, len, modified) in files {
        (&path, len).hash(&mut hasher);
        if let Some(rest) = budget.checked_sub(len) {
            budget = rest;
            hash_contents(&path, len, &mut hasher);
        } else {
            modified.hash(&mut hasher);
        }
    }
    // UNREAD is reserved (a 1 in 2^64 collision costs one more read).
    hasher.finish().max(1)
}

/// Feeds at most `len` of `path`'s bytes to `hasher` (fewer when it cannot be
/// read or shrank; a file that grows is read no further).
fn hash_contents(path: &Path, len: u64, hasher: &mut DefaultHasher) {
    use std::io::Read as _;
    let Ok(file) = std::fs::File::open(path) else { return };
    let mut file = file.take(len);
    let mut buffer = [0u8; 16 * 1024];
    loop {
        match file.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(n) => hasher.write(buffer.get(..n).unwrap_or(&buffer)),
        }
    }
}

fn collect(dir: &Path, files: &mut Vec<(PathBuf, u64, u128)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if files.len() >= MAX_FILES {
            return;
        }
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Ok(meta) = entry.metadata() else { continue };
        // Editor swap and backup files change while the user types, before a save.
        if name.starts_with('.') || name.ends_with('~') || name == "node_modules" {
            continue;
        }
        if meta.is_dir() {
            collect(&path, files);
        } else {
            let modified = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos());
            files.push((path, meta.len(), modified));
        }
    }
}

fn watch(
    me: &Weak<Supervisor>,
    local: Option<PathBuf>,
    customize: Option<PathBuf>,
    mut prints: Prints,
) {
    let (sender, events) = channel();
    let files = sender.clone();
    let watcher = notify::recommended_watcher(move |event| {
        let _ = files.send(Wake::File(event));
    });
    let mut watcher = match watcher {
        Ok(watcher) => watcher,
        Err(error) => {
            eprintln!("cmux-tui: apps local reload watch unavailable: {error}");
            return;
        }
    };
    let dirs: Vec<PathBuf> = [customize.clone(), local.clone()].into_iter().flatten().collect();
    // Each folder's entry in its parent (or, while the parent is missing,
    // the nearest existing ancestor's next missing name) is watched for the
    // folder appearing, vanishing or being replaced (`Folders`). It is armed
    // before the folders, so a folder replaced after they are armed hints.
    // Its first hint only says it is armed: the folders are armed and read
    // next anyway.
    let mut armed = false;
    let entries = cmux_config::watch::Watcher::start(dirs.clone(), move || {
        if std::mem::replace(&mut armed, true) {
            let _ = sender.send(Wake::Folder);
        }
    });
    let _entries = match entries {
        Ok(entries) => Some(entries),
        Err(error) => {
            eprintln!("cmux-tui: apps local folder watch unavailable: {error}");
            None
        }
    };
    let mut folders = Folders::default();
    folders.arm(&mut watcher, &dirs);
    // Only events inside the watched app folders count. FSEvents names the
    // real path, so a folder under a symlink (`/tmp`, a linked `~/.config`)
    // is matched by its resolved spelling too.
    let mut roots = watch_roots([customize.as_deref(), local.as_deref()]);
    // FSEvents reports only what changes after its stream starts, and the
    // catalog in `prints` was read before this thread armed it: a write in
    // between (a loaded machine, an app saved as cmux starts) had no event
    // and was never read. Read once more now that the watch is on.
    match me.upgrade() {
        Some(supervisor) => prints = supervisor.reload_local_apps(&prints),
        None => return,
    }
    loop {
        let relevant = |path: &Path| roots.iter().any(|root| path.starts_with(root));
        let root = |path: &Path| roots.iter().any(|root| path == root);
        let Some(burst) = next_burst(&events, &relevant, &root) else { return };
        if burst.folder {
            // Armed before the read: the read sees every file written before
            // the new folder was watched, and the watch every write after.
            folders.arm(&mut watcher, &dirs);
            roots = watch_roots([customize.as_deref(), local.as_deref()]);
        }
        let Some(supervisor) = me.upgrade() else { return };
        prints = supervisor.reload_local_apps(&prints);
    }
}

/// What woke the watch thread.
enum Wake {
    /// A file event from the recursive folder watch.
    File(notify::Result<notify::Event>),
    /// A watched folder's entry changed: it appeared, vanished or was
    /// replaced, or a missing folder on the way to it did.
    Folder,
}

/// The burst `next_burst` drained.
struct Burst {
    /// It held a `Wake::Folder`, or a watched folder itself was removed or
    /// renamed: the folders are armed again.
    folder: bool,
}

/// The local folders with a recursive watch.
///
/// A kernel watch follows the folder, not its path: on Linux inotify's watch
/// ends with the old folder (IN_DELETE_SELF, IN_IGNORED) or stays on it after
/// a rename (IN_MOVE_SELF), so a folder deleted and made again (a `git
/// checkout`, an editor that saves a folder by replacing it, `rm -rf` then a
/// copy) was never watched again, and its saves were not reloaded until the
/// daemon restarted. The folder's entry in its parent is watched instead
/// (`cmux_config::watch`, which climbs to the nearest existing ancestor
/// while the parent is missing too), and each of its hints arms every folder
/// again. Its identity cannot tell whether its watch is still on: a folder
/// deleted and made again at once often gets the freed inode number back,
/// with no watch on it. On macOS the folder watch is notify's FSEvents,
/// which watches a path, so it already reported the new folder; there the
/// entry watch is cmux_config's kqueue vnode watch. Arming again restarts
/// the FSEvents stream (once for the unwatch and once for the watch, per
/// folder) on this thread, and the read after it covers what changed while
/// the stream was down.
#[derive(Default)]
struct Folders(HashSet<PathBuf>);

impl Folders {
    /// Watches each folder in `dirs` that exists, dropping its old watch
    /// first: a renamed folder keeps its watch, and its events would come
    /// under this path.
    fn arm(&mut self, watcher: &mut impl notify::Watcher, dirs: &[PathBuf]) {
        for dir in dirs {
            if self.0.remove(dir) {
                let _ = watcher.unwatch(dir);
            }
            if dir.is_dir() && watcher.watch(dir, notify::RecursiveMode::Recursive).is_ok() {
                self.0.insert(dir.clone());
            }
        }
    }
}

/// Each folder as configured and, when it differs, as resolved: the folder
/// itself when it exists, else its parent resolved with its name (a
/// customize folder the user has not made yet).
fn watch_roots(dirs: [Option<&Path>; 2]) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for dir in dirs.into_iter().flatten() {
        roots.push(dir.to_path_buf());
        let resolved = std::fs::canonicalize(dir).ok().or_else(|| {
            let parent = std::fs::canonicalize(dir.parent()?).ok()?;
            Some(parent.join(dir.file_name()?))
        });
        if let Some(resolved) = resolved.filter(|resolved| resolved != dir) {
            roots.push(resolved);
        }
    }
    roots
}

/// Waits for a folder hint or an event that can mean a change (`is_change`),
/// then drains the burst queued behind it. `None` when the watch ended.
fn next_burst(
    events: &Receiver<Wake>,
    relevant: &dyn Fn(&Path) -> bool,
    root: &dyn Fn(&Path) -> bool,
) -> Option<Burst> {
    loop {
        let mut folder = match events.recv().ok()? {
            Wake::Folder => true,
            Wake::File(event) if is_change(&event, relevant) => folder_gone(&event, root),
            Wake::File(_) => continue,
        };
        while let Ok(wake) = events.try_recv() {
            folder |= match wake {
                Wake::Folder => true,
                Wake::File(event) => folder_gone(&event, root),
            };
        }
        return Some(Burst { folder });
    }
}

/// Whether `event` says a watched folder itself (`root`) was removed or
/// renamed. notify ends its own record of a deleted folder's watch only when
/// it reads the kernel's event: read late, it can end the watch just armed
/// on the new folder, so the folders are armed again after it.
fn folder_gone(event: &notify::Result<notify::Event>, root: &dyn Fn(&Path) -> bool) -> bool {
    use notify::event::ModifyKind;
    let Ok(event) = event else { return false };
    matches!(event.kind, EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_)))
        && event.paths.iter().any(|path| root(path))
}

/// Whether `event` can mean a watched file changed. A read is no change:
/// inotify reports every open, and the reload's own reads open the watched
/// folders and files, so waking on them read again in a loop that never
/// slept. A finished write is a change. An overflowed queue (a `Rescan` event
/// that names no path) or a watch error may have lost events: read again.
fn is_change(event: &notify::Result<notify::Event>, relevant: &dyn Fn(&Path) -> bool) -> bool {
    let Ok(event) = event else { return true };
    if event.need_rescan() {
        return true;
    }
    match event.kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => {}
        EventKind::Access(_) => return false,
        _ => {}
    }
    event.paths.iter().any(|path| relevant(path))
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::mpsc::{Receiver, channel};
    use std::time::{Duration, Instant};

    use notify::event::{
        AccessKind, AccessMode, DataChange, Event, EventKind, Flag, ModifyKind, RemoveKind,
        RenameMode,
    };

    use super::{Folders, Wake, fingerprint, next_burst};

    const ROOT: &str = "/apps/customize";

    /// Whether this queue of events wakes the watch.
    fn wakes(events: Vec<notify::Result<Event>>) -> bool {
        let (sender, receiver) = channel();
        for event in events {
            sender.send(Wake::File(event)).unwrap();
        }
        drop(sender);
        next_burst(&receiver, &|path: &Path| path.starts_with(ROOT), &|path: &Path| {
            path == Path::new(ROOT)
        })
        .is_some()
    }

    fn on(kind: EventKind) -> notify::Result<Event> {
        Ok(Event::new(kind).add_path(PathBuf::from(ROOT).join("cmux-app.v2.json")))
    }

    /// Reading a local app opens its folder and files, and inotify reports
    /// every open: a read that woke the watch made it read again, in a loop
    /// that never slept (Linux).
    #[test]
    fn a_read_does_not_wake_the_watch_and_a_write_does() {
        let read = vec![
            on(EventKind::Access(AccessKind::Open(AccessMode::Any))),
            on(EventKind::Access(AccessKind::Close(AccessMode::Read))),
        ];
        assert!(!wakes(read), "opening and reading a file changes nothing");
        assert!(wakes(vec![on(EventKind::Modify(ModifyKind::Data(DataChange::Any)))]));
        assert!(
            wakes(vec![on(EventKind::Access(AccessKind::Close(AccessMode::Write)))]),
            "a finished write is a change"
        );
    }

    /// An overflowed inotify queue drops events and says so in one event that
    /// names no path; a watch error can lose events too. Both read again.
    #[test]
    fn a_watch_that_lost_events_reads_again() {
        assert!(wakes(vec![Ok(Event::new(EventKind::Other).set_flag(Flag::Rescan))]));
        assert!(wakes(vec![Err(notify::Error::generic("inotify read failed"))]));
    }

    /// A folder hint (the folder appeared, vanished or was replaced), or the
    /// watched folder itself removed or renamed, arms the folders again, also
    /// behind a save in the same burst. A save alone arms nothing.
    #[test]
    fn a_folder_hint_or_a_removed_folder_arms_the_folders_again() {
        let burst = |wakes: Vec<Wake>| {
            let (sender, receiver) = channel();
            for wake in wakes {
                sender.send(wake).unwrap();
            }
            drop(sender);
            next_burst(&receiver, &|path: &Path| path.starts_with(ROOT), &|path: &Path| {
                path == Path::new(ROOT)
            })
            .map(|burst| burst.folder)
        };
        let write = || Wake::File(on(EventKind::Modify(ModifyKind::Data(DataChange::Any))));
        let folder = |kind| Wake::File(Ok(Event::new(kind).add_path(PathBuf::from(ROOT))));
        assert_eq!(burst(vec![Wake::Folder]), Some(true));
        assert_eq!(burst(vec![write(), Wake::Folder]), Some(true));
        assert_eq!(burst(vec![folder(EventKind::Remove(RemoveKind::Folder))]), Some(true));
        assert_eq!(
            burst(vec![folder(EventKind::Modify(ModifyKind::Name(RenameMode::From)))]),
            Some(true)
        );
        assert_eq!(burst(vec![write()]), Some(false), "a save alone arms nothing");
    }

    /// Waits (at most 10 s) for a change event naming `want`; panics on one
    /// naming a path in `never` first.
    fn change_named(events: &Receiver<notify::Result<Event>>, want: &Path, never: &Path) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let Ok(event) = events.recv_timeout(left) else {
                panic!("no event for {} in 10 s", want.display())
            };
            let Ok(event) = event else { continue };
            if matches!(event.kind, EventKind::Access(_)) {
                continue;
            }
            assert!(
                !event.paths.iter().any(|path| path == never),
                "the old folder's watch still names {}: {event:?}",
                never.display()
            );
            if event.paths.iter().any(|path| path == want) {
                return;
            }
        }
    }

    /// A folder deleted and made again at once, or renamed away and made
    /// again, is watched once armed again: a save in the new folder is seen,
    /// and the old folder's watch reports nothing under the path. Deleted
    /// and made at once, the new folder often gets the freed inode number
    /// back, so its identity did not say that it had no watch (Linux).
    #[test]
    fn a_folder_made_again_is_watched_once_armed_again() {
        let stamp =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let base = std::env::temp_dir().canonicalize().unwrap();
        let root = base.join(format!("cmux-local-rewatch-{}-{stamp}", std::process::id()));
        let dir = root.join("customize");
        std::fs::create_dir_all(&dir).unwrap();
        let (sender, events) = channel();
        let mut watcher = notify::recommended_watcher(move |event| {
            let _ = sender.send(event);
        })
        .unwrap();
        let dirs = vec![dir.clone()];
        let mut folders = Folders::default();
        folders.arm(&mut watcher, &dirs);
        std::fs::write(dir.join("main.js"), "1").unwrap();
        change_named(&events, &dir.join("main.js"), Path::new("/nothing"));

        // The watch thread arms again once it hears of the removal (a folder
        // hint, or notify's own event for the folder): so does the test.
        std::fs::remove_dir_all(&dir).unwrap();
        change_named(&events, &dir, Path::new("/nothing"));
        std::fs::create_dir(&dir).unwrap();
        folders.arm(&mut watcher, &dirs);
        std::fs::write(dir.join("main.js"), "2").unwrap();
        change_named(&events, &dir.join("main.js"), Path::new("/nothing"));

        let old = root.join("customize.old");
        std::fs::rename(&dir, &old).unwrap();
        std::fs::create_dir(&dir).unwrap();
        folders.arm(&mut watcher, &dirs);
        std::fs::write(old.join("stale.js"), "old").unwrap();
        std::fs::write(dir.join("next.js"), "3").unwrap();
        change_named(&events, &dir.join("next.js"), &dir.join("stale.js"));
        drop(watcher);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A coarse file clock (a timer tick on Linux before 6.13, one second on
    /// some file systems) gives a same-size save its old modification time.
    #[test]
    fn a_same_size_save_with_the_old_modification_time_changes_the_fingerprint() {
        let stamp =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            std::env::temp_dir().join(format!("cmux-local-reload-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let manifest = dir.join("cmux-app.v2.json");
        std::fs::write(&manifest, r#"{"version":"1.0.0"}"#).unwrap();
        let modified = std::fs::metadata(&manifest).unwrap().modified().unwrap();
        let before = fingerprint(&dir);
        std::fs::write(&manifest, r#"{"version":"1.0.1"}"#).unwrap();
        std::fs::File::options()
            .write(true)
            .open(&manifest)
            .unwrap()
            .set_modified(modified)
            .unwrap();
        let after = fingerprint(&dir);
        let _ = std::fs::remove_dir_all(&dir);
        assert_ne!(before, after, "the content changed");
    }
}
