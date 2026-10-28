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

use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::fs as files;
use cmux_threads::checked::sync as waits;
use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Weak};

use notify::Watcher as _;
use serde_json::json;

use super::catalog::{self, CUSTOMIZE_APP, Package};
use super::mirror::{self, Op, Source};
use super::supervisor::{Out, Supervisor};
use crate::panic_free::RecoverPoison;

/// Fingerprints of the local packages (`fingerprint`), by app id.
type Prints = HashMap<String, u64>;

/// Files read per package for its fingerprint (a runaway folder costs no more).
const MAX_FILES: usize = 2_000;

impl Supervisor {
    /// Starts the watch thread; returns at once. In-crate tests build many
    /// supervisors and read no real folders.
    pub(crate) fn start_local_watch(self: &Arc<Self>) {
        if cfg!(test) {
            return;
        }
        let me = Arc::downgrade(self);
        let local = self.config.sources.local.clone();
        let customize = self.config.sources.customize.clone();
        let prints = {
            let inner = self.inner.lock().recover_poison();
            local_prints(inner.catalog.packages.values())
        };
        let spawned = supervised::spawn_at(
            "apps-local-reload",
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                watch(&me, local, customize, prints);
            },
        );
        if let Err(error) = spawned {
            eprintln!("cmux-tui: apps local reload thread did not start: {error}");
        }
    }

    /// Reads the catalog again and applies what changed in local apps since
    /// `prints`; returns the new fingerprints.
    pub(crate) fn reload_local_apps(&self, prints: &Prints) -> Prints {
        let catalog = catalog::load(&self.config.sources);
        let next = local_prints(catalog.packages.values());
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
            let mut inner = self.inner.lock().recover_poison();
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

fn local_prints<'a>(packages: impl Iterator<Item = &'a Package>) -> Prints {
    packages
        .filter(|p| p.source == Source::Local)
        .map(|p| (p.id.clone(), fingerprint(&p.dir)))
        .collect()
}

/// Every file's path, size and modification time under `dir` (dot folders and
/// node_modules skipped), hashed.
fn fingerprint(dir: &Path) -> u64 {
    let mut files = Vec::new();
    collect(dir, &mut files);
    files.sort();
    let mut hasher = DefaultHasher::new();
    files.hash(&mut hasher);
    hasher.finish()
}

fn collect(dir: &Path, files: &mut Vec<(PathBuf, u64, u128)>) {
    let Ok(entries) = files::read_dir(dir) else { return };
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
    let watcher = notify::recommended_watcher(move |event| {
        let _ = sender.send(event);
    });
    let mut watcher = match watcher {
        Ok(watcher) => watcher,
        Err(error) => {
            eprintln!("cmux-tui: apps local reload watch unavailable: {error}");
            return;
        }
    };
    // The customization folder may not exist yet: its parent is watched for it.
    let mut watched_customize = false;
    let arm = |watcher: &mut notify::RecommendedWatcher, watched_customize: &mut bool| {
        if let Some(local) = local.as_ref().filter(|dir| dir.is_dir()) {
            let _ = watcher.watch(local, notify::RecursiveMode::Recursive);
        }
        if let Some(dir) = customize.as_ref() {
            if !*watched_customize && dir.is_dir() {
                *watched_customize = watcher.watch(dir, notify::RecursiveMode::Recursive).is_ok();
            }
            if let Some(parent) = dir.parent().filter(|parent| parent.is_dir()) {
                let _ = watcher.watch(parent, notify::RecursiveMode::NonRecursive);
            }
        }
    };
    arm(&mut watcher, &mut watched_customize);
    // Only events inside the watched app folders count: the customize
    // folder's parent also holds cmux.json and other files. FSEvents names
    // the real path, so a folder under a symlink (`/tmp`, a linked
    // `~/.config`) is matched by its resolved spelling too.
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
        if !next_burst(&events, &relevant) {
            return;
        }
        let Some(supervisor) = me.upgrade() else { return };
        prints = supervisor.reload_local_apps(&prints);
        drop(supervisor);
        if !watched_customize {
            arm(&mut watcher, &mut watched_customize);
            roots = watch_roots([customize.as_deref(), local.as_deref()]);
            // Arming restarts the stream (see above): read what changed
            // while it was down.
            if watched_customize {
                let Some(supervisor) = me.upgrade() else { return };
                prints = supervisor.reload_local_apps(&prints);
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
        let resolved = files::canonicalize(dir).ok().or_else(|| {
            let parent = files::canonicalize(dir.parent()?).ok()?;
            Some(parent.join(dir.file_name()?))
        });
        if let Some(resolved) = resolved.filter(|resolved| resolved != dir) {
            roots.push(resolved);
        }
    }
    roots
}

/// Waits for an event on a path `relevant` accepts, then drains the burst
/// queued behind it. False when the watch ended.
fn next_burst(
    events: &Receiver<notify::Result<notify::Event>>,
    relevant: &dyn Fn(&Path) -> bool,
) -> bool {
    loop {
        let Ok(event) = waits::recv(events) else { return false };
        if event.is_ok_and(|event| event.paths.iter().any(|path| relevant(path))) {
            while events.try_recv().is_ok() {}
            return true;
        }
    }
}
