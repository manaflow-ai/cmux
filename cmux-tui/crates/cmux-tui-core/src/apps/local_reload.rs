//! Apps in the folders a person writes reload when their files change
//! (cx-swovq.1): the user's customization folder (`Sources::customize`, id
//! `local/customize`), the local development folder (`<state>/apps/local`)
//! and each `CMUX_APPS_DIRS` folder (`Sources::extra`: a checkout of an
//! extension, or a fork of a first-party app). The shipped folders inside the
//! signed app (first-party, bundled samples) are not watched: nobody edits
//! them in place. A file watch (FSEvents on
//! macOS, inotify on Linux) wakes one thread; no timer, no polling. A burst of
//! events is drained before one catalog read. Only an app whose files changed
//! restarts its host (its mounts are sent again, so a hover card or a section
//! renders the new script); a removed app's mounts fail. A saved script that
//! does not load, for an app whose views are open, is tried first in a host of
//! its own (`load_trial.rs`): the live host keeps the last script that loaded,
//! its views stay, and `apps-reload-failed` says why. With no view open the
//! script fails where the app next renders. A host never takes the daemon
//! down. The customization app installs itself with its required scopes when
//! it first appears (the user wrote it).
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
use std::sync::{Arc, PoisonError, Weak};

use notify::event::{AccessKind, AccessMode, EventKind};
use serde_json::{Value, json};

use super::catalog::{self, CUSTOMIZE_APP, Package};
use super::mirror::{self, Op, Source};
use super::supervisor::{ApiError, Out, Supervisor};

/// Fingerprints of the local packages (`fingerprint`), by app id.
type Prints = HashMap<String, u64>;

/// What one pass applied: the apps reloaded, the saves refused (the last
/// good script keeps running) with their init error, the apps removed.
#[derive(Default)]
struct Report {
    changed: Vec<String>,
    refused: Vec<(String, String)>,
    removed: Vec<String>,
}

/// The watched package folders a pass reads. A save names its folder (the
/// watch's events, `cmux ext dev`'s copy), so the pass a save makes costs
/// the same with 1 or 200 local apps; the others keep the fingerprint and
/// read of the last pass (`Inner::local_seen`). Base: every save listed,
/// fingerprinted and checked every app folder (200 apps: 16 ms a save).
pub(super) enum Scope {
    /// Every watched folder: a forced reload, safe mode ending, a watch that
    /// may have lost events or was armed again.
    All,
    /// Only these package folders (each the customize folder or a direct
    /// subfolder of a package folder), as `PrintsBefore::take` spells them.
    Folders(HashSet<PathBuf>),
}

/// Files read per package for its fingerprint (a runaway folder costs no more).
pub(super) const MAX_FILES: usize = 2_000;

/// File bytes hashed per package for its fingerprint. An app's scripts and
/// manifest are kilobytes; a large asset past this budget is fingerprinted by
/// its size and modification time, so a reload never reads more than this.
const MAX_HASHED_BYTES: u64 = 4 << 20;

impl Supervisor {
    /// Starts the watch thread; returns at once. Its passes start from the
    /// startup catalog's prints (`Inner::local_prints`, taken before its
    /// read, `PrintsBefore`). In-crate tests build many supervisors and read
    /// no real folders.
    pub(crate) fn start_local_watch(self: &Arc<Self>) {
        if cfg!(test) {
            return;
        }
        let me = Arc::downgrade(self);
        let dirs = watched_dirs(&self.config.sources);
        let spawned = std::thread::Builder::new()
            .name("apps-local-reload".into())
            .spawn(move || watch(&me, dirs));
        if let Err(error) = spawned {
            eprintln!("cmux-tui: apps local reload thread did not start: {error}");
        }
    }

    /// One local reload pass now: reads the watched folders and applies what
    /// changed since the last pass, whoever ran it. The file watch runs it on
    /// a save; `apps-reload-local` runs it when a caller that just wrote an
    /// app's files (`cmux ext dev`) asks, so a reload never waits on file
    /// events, which a loaded Mac delivers seconds late (Leo's NIGHTLY at load
    /// average 93 to 105: `ext dev`'s copy waited 3.6 s, 22.7 s, then past its
    /// 30 s cap three times for the watch's reload, ask-7fc19bd861). Passes
    /// run one at a time, so a late event after an asked pass finds nothing
    /// changed and restarts no host again. A person waits on each pass (they
    /// just saved), so it runs at user-initiated QoS, as acpmux's reads for a
    /// chat opened on screen do (`qos::on_screen`), ahead of default-priority
    /// builds; then the thread's own QoS comes back.
    ///
    /// Answers what an asker cannot read from the pass's events: safe mode
    /// held the pass (`safeMode`), and the watched folders the catalog
    /// refused (`rejected`, each `{dir, issue}`; a refused new folder makes
    /// no event, since it never had a print).
    pub(crate) fn reload_local_apps_now(&self) -> Value {
        self.reload_local_apps_in(&Scope::All, |_| {})
    }

    /// `reload_local_apps_now` for a caller that names the package folders
    /// it wrote (`apps-reload-local`'s `folders`): only those are read when
    /// each is a watched package folder; any other name reads every folder.
    pub(crate) fn reload_local_apps_named(&self, folders: Option<Vec<PathBuf>>) -> Value {
        let sources = &self.config.sources;
        let scope = match folders {
            Some(folders) if folders.iter().all(|dir| is_watched_dir(sources, dir)) => {
                Scope::Folders(folders.into_iter().collect())
            }
            _ => Scope::All,
        };
        self.reload_local_apps_in(&scope, |_| {})
    }

    /// `reload_local_apps_now` from the last pass's prints as `adjust` leaves
    /// them: a rollback drops its app's print so it reads as changed.
    pub(crate) fn reload_local_apps_now_with(&self, adjust: impl FnOnce(&mut Prints)) -> Value {
        self.reload_local_apps_in(&Scope::All, adjust)
    }

    /// `reload_local_apps_now_with`, reading the folders `scope` names.
    fn reload_local_apps_in(&self, scope: &Scope, adjust: impl FnOnce(&mut Prints)) -> Value {
        let _pass = self.local_reload_pass.lock().unwrap_or_else(PoisonError::into_inner);
        let mut prints =
            self.inner.lock().unwrap_or_else(PoisonError::into_inner).local_prints.clone();
        adjust(&mut prints);
        if self.safe_mode_on() {
            return json!({ "safeMode": true, "rejected": [] });
        }
        let (_, rejected) = on_screen(|| self.pass(&prints, scope, catalog::load_reusing));
        let rejected: Vec<Value> = rejected
            .into_iter()
            .map(|(dir, issue)| json!({ "dir": dir.display().to_string(), "issue": issue }))
            .collect();
        json!({ "safeMode": false, "rejected": rejected })
    }

    /// `apps-reload` (`cmux ext reload [APP]`, `cmux reload-config`, the
    /// palette's Reload Custom Views): one pass that reloads `app`, or every
    /// local app, as a save of each would, whether or not its files changed
    /// (a save the watch missed, a host to start over). A script that does
    /// not load keeps the last good view (`refused_saves`); the answer names
    /// it with its init error: `{reloaded, refused: [{app, reason}], removed}`.
    pub fn reload_local_now(&self, app: Option<&str>) -> Result<Value, ApiError> {
        if self.safe_mode_on() {
            return Err(ApiError::new(
                "apps.safe_mode",
                "safe mode is on: no extension runs or reloads until it is off (cmux safe-mode off)",
            ));
        }
        let _pass = self.local_reload_pass.lock().unwrap_or_else(PoisonError::into_inner);
        let mut prints =
            self.inner.lock().unwrap_or_else(PoisonError::into_inner).local_prints.clone();
        // `UNREAD` matches no read package, so the asked apps read as changed,
        // and a folder deleted meanwhile still reads as removed. A folder the
        // watch never reported is not in the prints yet: it reads as new, so
        // naming it loads it.
        match app {
            Some(app) => {
                if let Some(print) = prints.get_mut(app) {
                    *print = UNREAD;
                }
            }
            None => prints.values_mut().for_each(|print| *print = UNREAD),
        }
        let (next, _, report) =
            on_screen(|| self.pass_reporting(&prints, &Scope::All, catalog::load_reusing));
        if let Some(app) = app
            && !next.contains_key(app)
            && !report.removed.iter().any(|gone| gone == app)
        {
            let mut known: Vec<&String> = next.keys().collect();
            known.sort();
            let known = known.iter().map(|id| id.as_str()).collect::<Vec<_>>().join(", ");
            return Err(ApiError::new(
                "apps.local.unknown",
                format!(
                    "{app} is not an extension in a local folder (local: {})",
                    if known.is_empty() { "none" } else { &known }
                ),
            ));
        }
        // A forced read of one app still applies the other saves the watch
        // has not read yet; the answer is about the app asked for.
        let asked = |id: &str| app.is_none_or(|app| app == id);
        let mut reloaded: Vec<String> =
            report.changed.into_iter().filter(|id| asked(id.as_str())).collect();
        reloaded.sort();
        let refused: Vec<Value> = report
            .refused
            .iter()
            .filter(|(id, _)| asked(id.as_str()))
            .map(|(id, reason)| json!({ "app": id, "reason": reason }))
            .collect();
        let mut removed = report.removed;
        removed.sort();
        Ok(json!({ "reloaded": reloaded, "refused": refused, "removed": removed }))
    }

    /// `start_local_watch` for a test that measures a save reaching the
    /// running app through the real file watch (`supervisor_load_tests.rs`).
    #[cfg(test)]
    pub(super) fn start_local_watch_for_test(self: &Arc<Self>) {
        let me = Arc::downgrade(self);
        let dirs = watched_dirs(&self.config.sources);
        let spawned = std::thread::Builder::new()
            .name("apps-local-reload-test".into())
            .spawn(move || watch(&me, dirs));
        if let Err(error) = spawned {
            eprintln!("cmux-tui: test apps local reload thread did not start: {error}");
        }
    }

    /// Reads the catalog again and applies what changed in local apps since
    /// `prints`; returns the new fingerprints.
    #[cfg(test)]
    pub(crate) fn reload_local_apps(&self, prints: &Prints) -> Prints {
        self.pass(prints, &Scope::All, catalog::load_reusing).0
    }

    /// `reload_local_apps` for a save the watch names: reads only `folders`.
    #[cfg(test)]
    pub(super) fn reload_local_apps_saved(
        &self,
        prints: &Prints,
        folders: impl IntoIterator<Item = PathBuf>,
    ) -> Prints {
        self.pass(prints, &Scope::Folders(folders.into_iter().collect()), catalog::load_reusing).0
    }

    /// `reload_local_apps` with the catalog read given: a test lands a save
    /// right after the read. It reads every folder again (no reuse).
    #[cfg(test)]
    pub(super) fn reload_local_apps_from(
        &self,
        prints: &Prints,
        load: impl FnOnce(&catalog::Sources) -> catalog::Catalog,
    ) -> Prints {
        self.pass(prints, &Scope::All, |sources, _, _| load(sources)).0
    }

    /// One pass: the new fingerprints, and the watched folders the catalog
    /// refused with why.
    fn pass(
        &self,
        prints: &Prints,
        scope: &Scope,
        load: impl FnOnce(
            &catalog::Sources,
            &catalog::Reuse<'_>,
            &catalog::Listed<'_>,
        ) -> catalog::Catalog,
    ) -> (Prints, Vec<(PathBuf, String)>) {
        let (next, rejected, _) = self.pass_reporting(prints, scope, load);
        (next, rejected)
    }

    /// `pass`, and what it applied. `load` gets the earlier read of each
    /// watched folder whose fingerprint is the one that read was taken with
    /// (`Inner::local_dir_prints`), so a pass reads only changed folders, and
    /// with `Scope::Folders` each root's package folders as the last pass
    /// left them, so it lists no root either.
    fn pass_reporting(
        &self,
        prints: &Prints,
        scope: &Scope,
        load: impl FnOnce(
            &catalog::Sources,
            &catalog::Reuse<'_>,
            &catalog::Listed<'_>,
        ) -> catalog::Catalog,
    ) -> (Prints, Vec<(PathBuf, String)>, Report) {
        // Safe mode: nothing reloads. The prints stay as they were, so the
        // saves made meanwhile apply when it ends (`safe_mode.rs`), which
        // reads every folder.
        if self.safe_mode_on() {
            return (prints.clone(), Vec::new(), Report::default());
        }
        let sources = &self.config.sources;
        let before = match scope {
            Scope::All => PrintsBefore::take(sources),
            Scope::Folders(folders) => {
                let seen =
                    self.inner.lock().unwrap_or_else(PoisonError::into_inner).local_seen.clone();
                PrintsBefore::again(sources, seen, folders)
            }
        };
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).local_seen =
            before.dirs().clone();
        let earlier = self.earlier_reads(&before);
        let listed = |root: &Path| match scope {
            Scope::All => None,
            Scope::Folders(_) => before.listed(sources, root),
        };
        let catalog = load(sources, &|dir: &Path| earlier.get(dir).cloned(), &listed);
        let next = before.of(&self.config.sources, &catalog);
        let rejected: Vec<(PathBuf, String)> = catalog
            .rejected
            .iter()
            .filter(|(dir, _)| is_watched_dir(&self.config.sources, dir))
            .cloned()
            .collect();
        let changed: Vec<String> = next
            .iter()
            .filter(|(id, print)| prints.get(*id) != Some(*print))
            .map(|(id, _)| id.clone())
            .collect();
        let removed: Vec<String> =
            prints.keys().filter(|id| !next.contains_key(*id)).cloned().collect();
        if changed.is_empty() && removed.is_empty() {
            return (next, rejected, Report::default());
        }
        let refused = self.refused_saves(&changed, &catalog);
        let report = Report {
            changed: changed
                .iter()
                .filter(|app| !refused.iter().any(|(r, _)| r == *app))
                .cloned()
                .collect(),
            refused: refused.clone(),
            removed: removed.clone(),
        };
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let mut outs = Vec::new();
            // A refused folder is said once: when it is new or its reason
            // changed. Base red: every other app's save logged every refused
            // folder again (5 malformed folders, 30 saves: 155 warn lines,
            // pushing real lines out of the 500-line ring).
            let refused_now: HashMap<PathBuf, String> = rejected.iter().cloned().collect();
            for (dir, issue) in &rejected {
                if inner.local_rejected_logged.get(dir) != Some(issue) {
                    let message = format!("{}: {issue}", dir.display());
                    outs.extend(self.log_locked(&mut inner, "cmux/supervisor", "warn", message));
                }
            }
            inner.local_rejected_logged = refused_now;
            if inner.customize_reads_offered.is_none() {
                let declared =
                    inner.catalog.packages.get(CUSTOMIZE_APP).map(|p| p.facts().requested);
                inner.customize_reads_offered = Some(declared.unwrap_or_default());
            }
            inner.local_prints = next.clone();
            let mut catalog = catalog;
            for (app, _) in &refused {
                // The live host goes on running the last script that loaded;
                // its package stays, so a mount or restart names its exports.
                if let Some(package) = inner.catalog.packages.get(app).cloned() {
                    catalog.packages.insert(app.clone(), package);
                }
            }
            inner.catalog = catalog;
            // The prints this catalog was read with, for the next pass's
            // reuse; a refused save's folder holds the last good package, not
            // what is on disk, so it is read again next time.
            let mut dir_prints = before.dirs().clone();
            for (app, _) in &refused {
                if let Some(package) = inner.catalog.packages.get(app) {
                    dir_prints.remove(&package.dir);
                }
            }
            inner.local_dir_prints = dir_prints;
            for (app, error) in &refused {
                let reason = format!("init: {error}");
                let message = format!(
                    "the saved script did not load, the last one that did keeps running: {reason}"
                );
                outs.extend(self.log_locked(&mut inner, app, "error", message));
                outs.push(Out::Broadcast(
                    json!({ "event": "apps-reload-failed", "app": app, "reason": reason }),
                ));
            }
            let changed: Vec<String> =
                changed.into_iter().filter(|app| !refused.iter().any(|(r, _)| r == app)).collect();
            if changed.iter().any(|id| id == CUSTOMIZE_APP) {
                self.seed_customize_locked(&mut inner);
                outs.extend(self.grant_new_customize_reads_locked(&mut inner));
            }
            for app in changed.iter().filter(|id| id.starts_with(catalog::SETUP_LAYER_PREFIX)) {
                self.seed_setup_layer_locked(&mut inner, app);
            }
            for app in &changed {
                // A save is a fix: a paused app runs again.
                outs.extend(self.resume_locked(&mut inner, app, "saved"));
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
        (next, rejected, report)
    }

    /// Each watched folder's read in the current catalog (its package, or why
    /// it was refused) whose fingerprint now is the one that read was taken
    /// with. A package the defaults marked (`Source::Default`) is read again.
    fn earlier_reads(&self, before: &PrintsBefore) -> HashMap<PathBuf, Result<Package, String>> {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let unchanged = |dir: &Path| {
            let now = before.dirs().get(dir);
            now.is_some() && now != Some(&UNREAD) && inner.local_dir_prints.get(dir) == now
        };
        let packages = inner
            .catalog
            .packages
            .values()
            .filter(|p| p.source != Source::Default && unchanged(&p.dir))
            .map(|p| (p.dir.clone(), Ok(p.clone())));
        let refused = inner
            .catalog
            .rejected
            .iter()
            .filter(|(dir, _)| unchanged(dir))
            .map(|(dir, issue)| (dir.clone(), Err(issue.clone())));
        packages.chain(refused).collect()
    }

    /// The changed apps whose live host serves views and whose saved script
    /// does not load (`load_trial`), with the init error of each. Their
    /// hosts are not restarted, so the views keep the last good script.
    fn refused_saves(
        &self,
        changed: &[String],
        catalog: &catalog::Catalog,
    ) -> Vec<(String, String)> {
        let trials: Vec<(Package, super::grants::Grant)> = {
            let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            changed
                .iter()
                .filter_map(|app| {
                    let key = super::supervisor::HostKey { app: app.clone(), preview: false };
                    let host = inner.hosts.get(&key)?;
                    let live = matches!(
                        host.state,
                        super::supervisor::HostState::Starting
                            | super::supervisor::HostState::Running
                    ) && host.process.is_some();
                    let serving = inner.mounts.values().any(|m| m.host == key);
                    let package = catalog.packages.get(app)?.clone();
                    (live && serving).then(|| (package, Self::grant_for(&inner, &key)))
                })
                .collect()
        };
        // Off the lock: each trial waits for a host process's answer.
        trials
            .into_iter()
            .filter_map(|(package, grant)| {
                Some((package.id.clone(), self.load_trial(&package, &grant)?))
            })
            .collect()
    }

    /// Installs the customization app the first time it appears while cmux
    /// runs, as it installs at start (`seed_customize`): its read scopes and
    /// the sandbox, nothing more until the person allows it. A record the
    /// user changed (uninstalled) stays. Base red: this path seeded every
    /// required scope unsandboxed, so a customize folder that a shared
    /// collection (`customize library import ... --on`) or a profile wrote
    /// got `terminal:write` and `actions:run` with no card.
    pub(super) fn seed_customize_locked(&self, inner: &mut super::supervisor::Inner) {
        let Some(next) = inner
            .catalog
            .packages
            .get(CUSTOMIZE_APP)
            .and_then(|package| seed_customize(&inner.mirror, package))
        else {
            return;
        };
        if self.persist(&next).is_ok() {
            inner.mirror = next;
        }
    }
}

impl Supervisor {
    /// Installs setup layer `app` the first time it appears while cmux
    /// runs, as `seed_customize` installs the customization app.
    fn seed_setup_layer_locked(&self, inner: &mut super::supervisor::Inner, app: &str) {
        let Some(next) = inner
            .catalog
            .packages
            .get(app)
            .and_then(|package| seed_customize(&inner.mirror, package))
        else {
            return;
        };
        if self.persist(&next).is_ok() {
            inner.mirror = next;
        }
    }

    /// The read scopes a save of the customization app declares for the first
    /// time, granted as its first install would have (read scopes need no
    /// prompt). A scope offered before keeps whatever the person set, so a
    /// read they turned off stays off; other scopes wait for them.
    fn grant_new_customize_reads_locked(&self, inner: &mut super::supervisor::Inner) -> Vec<Out> {
        let Some(facts) = inner.catalog.packages.get(CUSTOMIZE_APP).map(Package::facts) else {
            return vec![];
        };
        let (reads, _) = facts.install_defaults();
        let offered = inner.customize_reads_offered.get_or_insert_with(Default::default);
        let new: Vec<String> = reads.iter().filter(|s| !offered.contains(*s)).cloned().collect();
        offered.extend(reads);
        let Some(record) = inner.mirror.apps.get(CUSTOMIZE_APP).filter(|r| r.installed) else {
            return vec![];
        };
        let new: Vec<String> = new.into_iter().filter(|s| !record.grants.contains(s)).collect();
        if new.is_empty() {
            return vec![];
        }
        let mut next = inner.mirror.clone();
        if let Some(record) = next.apps.get_mut(CUSTOMIZE_APP) {
            record.grants.extend(new.iter().cloned());
        }
        next.revision += 1;
        match self.persist(&next) {
            Ok(()) => {
                inner.mirror = next;
                vec![]
            }
            Err(error) => {
                // Not offered after all: the next save tries these again.
                if let Some(offered) = inner.customize_reads_offered.as_mut() {
                    offered.retain(|scope| !new.contains(scope));
                }
                self.log_locked(
                    inner,
                    "cmux/supervisor",
                    "warn",
                    format!("{CUSTOMIZE_APP}: its new read scopes were not saved, so the next save tries again: {error}"),
                )
            }
        }
    }
}

/// The mirror with the customization app installed as an unverified install
/// would be: read scopes only and the sandbox on (more needs the user's
/// grant), never the deployment default's wider grant. `None` when the
/// mirror already has a record for it.
///
/// A setup's views layer (`local/setup-...`, `Sources::setups`) installs the
/// same way: the person said yes to the setup's card, and anything past
/// read scopes still waits for them.
pub(super) fn seed_customize(mirror: &mirror::Mirror, package: &Package) -> Option<mirror::Mirror> {
    let facts = package.facts();
    let app = package.id.clone();
    let seed = Op::Seed { app: app.clone(), hidden: false };
    let outcome =
        mirror::reduce(mirror, &seed, Some(&facts)).ok().filter(|outcome| outcome.changed)?;
    let mut next = outcome.mirror;
    // This app appeared after the migration snapshot. Preserve its
    // eligibility if a failed migration retries on the next start.
    next.sidebar_auto_place.insert(app.clone());
    let (grants, sandboxed) = facts.install_defaults();
    if let Some(record) = next.apps.get_mut(&app) {
        record.grants = grants;
        record.sandboxed = sandboxed;
        record.source = Source::Local;
    }
    Some(next)
}

/// The folders the watch covers: the customization folder, then the
/// folders that hold app packages (the local directory and each
/// `CMUX_APPS_DIRS` folder).
fn watched_dirs(sources: &catalog::Sources) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = sources.customize.iter().cloned().collect();
    dirs.extend(package_dirs(sources).cloned());
    dirs
}

/// The watched folders whose subfolders are app packages. An empty entry
/// (`CMUX_APPS_DIRS=":~/ext"` splits into "" and "~/ext") names no folder.
fn package_dirs(sources: &catalog::Sources) -> impl Iterator<Item = &PathBuf> {
    // The setups folder too: each of its layers is a package folder (which
    // of them load, and in what order, its `layers.json` says).
    sources
        .local
        .iter()
        .chain(&sources.extra)
        .chain(&sources.setups)
        .filter(|dir| !dir.as_os_str().is_empty())
}

/// Whether `dir` (a package folder) is one the watch covers: the
/// customization folder, or a direct subfolder of a package folder, as
/// `catalog::load` reads them. Not any path under one: `starts_with` an
/// empty root or an outer folder would count a shipped package in it, which
/// `PrintsBefore::take` never fingerprints, so it read as changed on every
/// reload and its host restarted each time.
fn is_watched_dir(sources: &catalog::Sources, dir: &Path) -> bool {
    sources.customize.as_deref() == Some(dir)
        || package_dirs(sources).any(|root| dir.parent() == Some(root.as_path()))
}

/// Whether `dir` holds an app manifest (`catalog::load` reads no other).
fn is_package(dir: &Path) -> bool {
    dir.join("cmux-app.json").is_file() || dir.join(catalog::V2_MANIFEST).is_file()
}

/// Fingerprints of the watched package folders (the customization folder and
/// each folder in the local directory and the `CMUX_APPS_DIRS` folders),
/// taken BEFORE the catalog read they describe. A save after them changes the
/// next fingerprint, so its event reads again. Taken after the read, they
/// could already hold a save the read missed, and that save's event saw no
/// change: the app kept its old files until the next save.
pub(super) struct PrintsBefore(HashMap<PathBuf, u64>);

impl PrintsBefore {
    pub(super) fn take(sources: &catalog::Sources) -> Self {
        let mut dirs: Vec<PathBuf> = sources.customize.iter().cloned().collect();
        // Only folders with a manifest: a `CMUX_APPS_DIRS` folder may be a
        // checkout whose other folders (`target/`, `docs/`) are no app, and
        // each costs a fingerprint per reload. A folder whose manifest comes
        // during the read gets `UNREAD` and is read on its next event.
        for root in package_dirs(sources) {
            if let Ok(entries) = std::fs::read_dir(root) {
                dirs.extend(entries.flatten().map(|entry| entry.path()).filter(|p| is_package(p)));
            }
        }
        let prints = dirs.into_iter().filter(|dir| dir.is_dir()).map(|dir| {
            let print = fingerprint(&dir);
            (dir, print)
        });
        Self(prints.collect())
    }

    /// `take` for a pass that reads only `folders`: the other folders keep
    /// `seen`, the last pass's fingerprints. A named folder that is no
    /// longer a package (its manifest or the folder went) leaves the prints,
    /// and one that became a package joins them, as `take` would have it.
    pub(super) fn again(
        sources: &catalog::Sources,
        mut seen: HashMap<PathBuf, u64>,
        folders: &HashSet<PathBuf>,
    ) -> Self {
        for dir in folders {
            let customize = sources.customize.as_deref() == Some(dir.as_path());
            if dir.is_dir() && (customize || is_package(dir)) {
                seen.insert(dir.clone(), fingerprint(dir));
            } else {
                seen.remove(dir);
            }
        }
        Self(seen)
    }

    /// Each watched package folder's fingerprint.
    pub(super) fn dirs(&self) -> &HashMap<PathBuf, u64> {
        &self.0
    }

    /// `root`'s package folders, sorted, as `catalog::load` lists them, when
    /// `root` is a package folder these prints cover (`package_dirs`).
    pub(super) fn listed(&self, sources: &catalog::Sources, root: &Path) -> Option<Vec<PathBuf>> {
        // The customize folder has a print with or without a manifest; in a
        // package folder it would be listed without one.
        let holds_customize = sources.customize.as_deref().and_then(Path::parent) == Some(root);
        if holds_customize || !package_dirs(sources).any(|dir| dir == root) {
            return None;
        }
        let mut dirs: Vec<PathBuf> =
            self.0.keys().filter(|dir| dir.parent() == Some(root)).cloned().collect();
        dirs.sort();
        Some(dirs)
    }

    /// The fingerprints of `catalog`'s watched and local packages, by app id,
    /// for a catalog read after `take`. A watched folder made during the read
    /// has no fingerprint from before it: it gets `UNREAD`, which no
    /// fingerprint equals, so the next event reads it again. A local package
    /// outside the watched folders (a `local/` id among the shipped samples)
    /// is not watched; its fingerprint is taken now.
    pub(super) fn of(&self, sources: &catalog::Sources, catalog: &catalog::Catalog) -> Prints {
        catalog
            .packages
            .values()
            .filter(|p| p.source == Source::Local || is_watched_dir(sources, &p.dir))
            .map(|p| {
                let print = match self.0.get(&p.dir) {
                    Some(print) => *print,
                    None if is_watched_dir(sources, &p.dir) => UNREAD,
                    None => fingerprint(&p.dir),
                };
                (p.id.clone(), print)
            })
            .collect()
    }
}

/// The fingerprint of a watched folder that had none before the catalog
/// read (`PrintsBefore::of`); `fingerprint` never returns it.
pub(super) const UNREAD: u64 = 0;

/// Every file's path, size and contents under `dir` (dot folders and
/// node_modules skipped), hashed. Contents, not the modification time: a
/// coarse file clock gives a same-size save the old time. Files past
/// `MAX_HASHED_BYTES` in all count by their modification time.
pub(super) fn fingerprint(dir: &Path) -> u64 {
    let mut files = Vec::new();
    collect(dir, &mut files);
    files.sort_by(|a, b| a.path.cmp(&b.path));
    let mut hasher = DefaultHasher::new();
    let mut budget = MAX_HASHED_BYTES;
    for file in files {
        (&file.path, file.len).hash(&mut hasher);
        if let Some(rest) = budget.checked_sub(file.len) {
            budget = rest;
            content_hash(&file).hash(&mut hasher);
        } else {
            file.modified.hash(&mut hasher);
        }
    }
    // UNREAD is reserved (a 1 in 2^64 collision costs one more read).
    hasher.finish().max(1)
}

/// One file `collect` found: its path, size and modification time, and the
/// identity a write changes (inode and change time, which no tool sets back).
struct Found {
    path: PathBuf,
    len: u64,
    modified: u128,
    stamp: Stamp,
}

/// What a file's cached content hash is valid for: the same inode, size,
/// modification and change time.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    inode: u64,
    len: u64,
    modified: u128,
    changed: u128,
}

/// A change time this close to when the file was hashed may hide a later
/// write in the same clock tick (a timer tick on Linux before 6.13, one
/// second on some file systems): such a hash is not reused.
const RACY_NANOS: u128 = 2_000_000_000;

/// The most files whose content hash is kept; past it the cache starts over.
const CACHED_FILES: usize = 50_000;

/// A cached hash: the stamp it holds for, when it was taken (ns), the hash.
type Hashed = (Stamp, u128, u64);

/// Content hashes by path, with the stamp they hold for and when they were
/// taken. A reload pass reads every watched app, so without this one save
/// re-read every app's bundle (200 apps of 256 KiB: 50 MiB per save). The
/// rule is git's racy-clean check: a file is read again unless its stamp is
/// unchanged and its last change is older than the hash by `RACY_NANOS`.
static HASHES: std::sync::LazyLock<std::sync::Mutex<HashMap<PathBuf, Hashed>>> =
    std::sync::LazyLock::new(Default::default);

fn now_nanos() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos())
}

/// The hash of `file`'s first `len` bytes, from the cache when its stamp
/// says the file has not been written since it was safely hashed.
fn content_hash(file: &Found) -> u64 {
    {
        let hashes = HASHES.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((stamp, hashed_at, hash)) = hashes.get(&file.path)
            && *stamp == file.stamp
            && file.stamp.changed.saturating_add(RACY_NANOS) < *hashed_at
        {
            return *hash;
        }
    }
    let hashed_at = now_nanos();
    let mut hasher = DefaultHasher::new();
    hash_contents(&file.path, file.len, &mut hasher);
    let hash = hasher.finish();
    let mut hashes = HASHES.lock().unwrap_or_else(PoisonError::into_inner);
    if hashes.len() >= CACHED_FILES {
        hashes.clear();
    }
    hashes.insert(file.path.clone(), (file.stamp, hashed_at, hash));
    hash
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

/// The inode and change time (ns) of `meta`; `(0, 0)` where the platform has
/// none, which keeps that file's hash from being reused.
#[cfg(unix)]
fn identity(meta: &std::fs::Metadata) -> (u64, u128) {
    use std::os::unix::fs::MetadataExt as _;
    let changed = u128::try_from(meta.ctime()).unwrap_or(0) * 1_000_000_000
        + u128::try_from(meta.ctime_nsec()).unwrap_or(0);
    (meta.ino(), changed)
}

#[cfg(not(unix))]
fn identity(_meta: &std::fs::Metadata) -> (u64, u128) {
    (0, u128::MAX - RACY_NANOS)
}

fn collect(dir: &Path, files: &mut Vec<Found>) {
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
            let (inode, changed) = identity(&meta);
            let len = meta.len();
            let stamp = Stamp { inode, len, modified, changed };
            files.push(Found { path, len, modified, stamp });
        }
    }
}

/// The watch thread over `dirs` (`watched_dirs`).
fn watch(me: &Weak<Supervisor>, dirs: Vec<PathBuf>) {
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
    let mut roots = watch_roots(&dirs);
    // FSEvents reports only what changes after its stream starts, and the
    // startup catalog (`Inner::local_prints`) was read before this thread armed it: a write in
    // between (a loaded machine, an app saved as cmux starts) had no event
    // and was never read. Read once more now that the watch is on.
    let customize = match me.upgrade() {
        Some(supervisor) => {
            drop(supervisor.reload_local_apps_now());
            supervisor.config.sources.customize.clone()
        }
        None => return,
    };
    loop {
        let relevant = |path: &Path| roots.iter().any(|(root, _)| path.starts_with(root));
        let root = |path: &Path| roots.iter().any(|(root, _)| path == root);
        let package = |path: &Path| package_of(&roots, customize.as_deref(), path);
        let Some(burst) = next_burst(&events, &relevant, &root, &package) else { return };
        if burst.folder {
            // Armed before the read: the read sees every file written before
            // the new folder was watched, and the watch every write after.
            folders.arm(&mut watcher, &dirs);
            roots = watch_roots(&dirs);
        }
        let Some(supervisor) = me.upgrade() else { return };
        supervisor.reload_local_apps_in(&burst.scope, |_| {});
    }
}

/// The package folder (as configured, the spelling `PrintsBefore::take`
/// uses) that `path` is in: the customize folder, or the subfolder of a
/// package folder it is under. `None` for a watched folder itself, whose
/// event can mean any of its packages.
fn package_of(
    roots: &[(PathBuf, PathBuf)],
    customize: Option<&Path>,
    path: &Path,
) -> Option<PathBuf> {
    let (spelling, dir) = roots
        .iter()
        .filter(|(spelling, _)| path.starts_with(spelling))
        .max_by_key(|(spelling, _)| spelling.as_os_str().len())?;
    let first = path.strip_prefix(spelling).ok()?.components().next()?;
    if customize == Some(dir.as_path()) {
        return Some(dir.clone());
    }
    Some(dir.join(first.as_os_str()))
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
    /// The package folders its events name; every folder when it held a
    /// folder hint, a lost-events signal or an event on a watched folder.
    scope: Scope,
}

impl Burst {
    fn add(
        &mut self,
        wake: Wake,
        relevant: &dyn Fn(&Path) -> bool,
        root: &dyn Fn(&Path) -> bool,
        package: &dyn Fn(&Path) -> Option<PathBuf>,
    ) {
        let event = match wake {
            Wake::Folder => {
                self.folder = true;
                self.scope = Scope::All;
                return;
            }
            Wake::File(event) => event,
        };
        if folder_gone(&event, root) {
            self.folder = true;
            self.scope = Scope::All;
        }
        if !is_change(&event, relevant) {
            return;
        }
        let named: Option<Vec<PathBuf>> = match &event {
            Ok(event) if !event.need_rescan() => {
                event.paths.iter().filter(|path| relevant(path)).map(|path| package(path)).collect()
            }
            _ => None,
        };
        match (named, &mut self.scope) {
            (Some(named), Scope::Folders(folders)) => folders.extend(named),
            (None, scope) => *scope = Scope::All,
            (Some(_), Scope::All) => {}
        }
    }
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
/// customize folder the user has not made yet), each with the folder as
/// configured.
fn watch_roots(dirs: &[PathBuf]) -> Vec<(PathBuf, PathBuf)> {
    let mut roots = Vec::new();
    for dir in dirs {
        roots.push((dir.to_path_buf(), dir.to_path_buf()));
        let resolved = std::fs::canonicalize(dir).ok().or_else(|| {
            let parent = std::fs::canonicalize(dir.parent()?).ok()?;
            Some(parent.join(dir.file_name()?))
        });
        if let Some(resolved) = resolved.filter(|resolved| resolved != dir) {
            roots.push((resolved, dir.to_path_buf()));
        }
    }
    roots
}

/// Waits for a folder hint or an event that can mean a change (`is_change`),
/// then drains the burst queued behind it, with the package folders its
/// events name (`package`). `None` when the watch ended.
fn next_burst(
    events: &Receiver<Wake>,
    relevant: &dyn Fn(&Path) -> bool,
    root: &dyn Fn(&Path) -> bool,
    package: &dyn Fn(&Path) -> Option<PathBuf>,
) -> Option<Burst> {
    loop {
        let first = events.recv().ok()?;
        if let Wake::File(event) = &first
            && !is_change(event, relevant)
        {
            continue;
        }
        let mut burst = Burst { folder: false, scope: Scope::Folders(HashSet::new()) };
        burst.add(first, relevant, root, package);
        while let Ok(wake) = events.try_recv() {
            burst.add(wake, relevant, root, package);
        }
        return Some(burst);
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

/// Runs `work` with the calling thread at user-initiated QoS, then puts its
/// class back (acpmux `qos::ThreadOnScreen`: an unspecified class goes back
/// as default, the class such a thread runs at). A thread already above
/// user-initiated (a connection carrying the person's keys,
/// `server/input_qos.rs`) keeps its class. Off macOS it only runs `work`.
fn on_screen<T>(work: impl FnOnce() -> T) -> T {
    #[cfg(target_os = "macos")]
    {
        use libc::qos_class_t::{
            QOS_CLASS_DEFAULT, QOS_CLASS_UNSPECIFIED, QOS_CLASS_USER_INITIATED,
        };
        let mut was = QOS_CLASS_UNSPECIFIED;
        let mut relative = 0;
        // SAFETY: reads the calling thread's own class into locals.
        unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut was, &mut relative) };
        // SAFETY: sets the calling thread's own class; no pointer is passed.
        let raised = (was as u32) < (QOS_CLASS_USER_INITIATED as u32)
            && unsafe { libc::pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) } == 0;
        let out = work();
        if raised {
            let back =
                if was as u32 == QOS_CLASS_UNSPECIFIED as u32 { QOS_CLASS_DEFAULT } else { was };
            // SAFETY: as above.
            unsafe { libc::pthread_set_qos_class_self_np(back, relative) };
        }
        out
    }
    #[cfg(not(target_os = "macos"))]
    work()
}

#[cfg(test)]
#[path = "local_reload_tests.rs"]
mod tests;
