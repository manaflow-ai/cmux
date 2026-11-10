//! One-step rollback of a local app (the customize folder, `<state>/apps/
//! local/*`) to its last version that worked (docs/cmux-next/extensions/
//! safe-mode.md).
//!
//! When a host of a local app reports a mount without an error, the
//! supervisor copies the files that host loaded to
//! `<state>/apps-last-good/<app>/files`, with `meta.json` (version and
//! fingerprint). One copy per app: a newer good version replaces it, so the
//! store is bounded by the apps, and each copy by [`MAX_BYTES`] and the
//! local reload's file cap. The copy is taken off the supervisor lock, and
//! only when the folder still holds what the host loaded (its fingerprint
//! is the one taken when the host spawned, before and after the copy).
//!
//! `apps.rollback {app}` puts those files back into the app's folder; the
//! files it replaces go to `<state>/apps-last-good/<app>/replaced`, so a
//! rollback loses nothing. The app then reloads like a save (in safe mode the
//! reload waits until safe mode ends). Shipped apps (first-party, samples,
//! `CMUX_APPS_DIRS`) are read in place and change only with cmux or their
//! folder, so there is no earlier version of theirs on disk to keep:
//! rollback answers `apps.rollback.unsupported` for them.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::mirror::{Origin, Source};
use super::supervisor::{ApiError, Inner, Supervisor};

/// The last good copies, one folder per app, under the state dir.
const DIR: &str = "apps-last-good";
/// Bytes one copy may hold; a bigger app keeps no copy (and says so).
pub(super) const MAX_BYTES: u64 = 16 << 20;

/// What a last good copy is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Good {
    pub version: String,
    /// The app folder's fingerprint (`local_reload::fingerprint`) when the
    /// host that mounted loaded it.
    pub print: u64,
    pub saved_ms: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RollbackParams {
    app: String,
}

/// The copy folder of `app` (ids are `publisher/name`; `/` cannot be in a name).
fn app_dir(state: &Path, app: &str) -> PathBuf {
    state.join(DIR).join(app.replace('/', "~"))
}

/// The last good copies on disk, by app id.
pub(super) fn load(state: Option<&Path>) -> std::collections::HashMap<String, Good> {
    let Some(root) = state.map(|s| s.join(DIR)) else { return Default::default() };
    let Ok(entries) = std::fs::read_dir(root) else { return Default::default() };
    entries
        .flatten()
        .filter_map(|entry| {
            let app = entry.file_name().to_str()?.replace('~', "/");
            let raw = std::fs::read(entry.path().join("meta.json")).ok()?;
            let good: Good = serde_json::from_slice(&raw).ok()?;
            entry.path().join("files").is_dir().then_some((app, good))
        })
        .collect()
}

/// The app's files the copy covers, relative to its folder, with their sizes:
/// the files the fingerprint reads (no dot files, no editor backups, no
/// `node_modules`). `None` past the caps.
fn files(dir: &Path) -> Option<Vec<(PathBuf, u64)>> {
    let mut out = Vec::new();
    let mut total = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(folder) = stack.pop() {
        for entry in std::fs::read_dir(&folder).ok()?.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') || name.ends_with('~') || name == "node_modules" {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else if meta.is_file() {
                total += meta.len();
                let relative = entry.path().strip_prefix(dir).ok()?.to_path_buf();
                out.push((relative, meta.len()));
                if total > MAX_BYTES || out.len() > super::local_reload::MAX_FILES {
                    return None;
                }
            }
        }
    }
    out.sort();
    Some(out)
}

/// Copies `files` from `from` into a fresh `to`.
fn copy_tree(from: &Path, files: &[(PathBuf, u64)], to: &Path) -> std::io::Result<()> {
    let _ = std::fs::remove_dir_all(to);
    std::fs::create_dir_all(to)?;
    for (relative, _) in files {
        let target = to.join(relative);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(from.join(relative), target)?;
    }
    Ok(())
}

/// Copies `dir` as `app`'s last good version when it still holds the files
/// fingerprinted `print`.
fn copy_good(
    state: &Path,
    app: &str,
    dir: &Path,
    version: &str,
    print: u64,
) -> Result<Good, String> {
    if super::local_reload::fingerprint(dir) != print {
        return Err("its files changed since it loaded".into());
    }
    let files = files(dir).ok_or_else(|| {
        format!("it is bigger than {} MiB or has too many files", MAX_BYTES >> 20)
    })?;
    let target = app_dir(state, app);
    let staging = target.join("files.tmp");
    copy_tree(dir, &files, &staging).map_err(|e| e.to_string())?;
    if super::local_reload::fingerprint(dir) != print {
        let _ = std::fs::remove_dir_all(&staging);
        return Err("its files changed during the copy".into());
    }
    let good = Good { version: version.to_string(), print, saved_ms: super::supervisor::now_ms() };
    let _ = std::fs::remove_dir_all(target.join("files"));
    std::fs::rename(&staging, target.join("files")).map_err(|e| e.to_string())?;
    let meta = serde_json::to_vec(&good).map_err(|e| e.to_string())?;
    std::fs::write(target.join("meta.json"), meta).map_err(|e| e.to_string())?;
    Ok(good)
}

/// Puts the copy in `target/files` back into `dir`, keeping what `dir`
/// held in `target/replaced` first.
fn restore(dir: &Path, target: &Path) -> std::io::Result<()> {
    let kept = target.join("files");
    let good_files = files(&kept).ok_or_else(|| std::io::Error::other("copy unreadable"))?;
    // Whatever the folder holds now is kept first, so nothing is lost.
    let current = files(dir).ok_or_else(|| std::io::Error::other("folder too big"))?;
    let staging = target.join("replaced.tmp");
    copy_tree(dir, &current, &staging)?;
    let _ = std::fs::remove_dir_all(target.join("replaced"));
    std::fs::rename(&staging, target.join("replaced"))?;
    let keep: BTreeSet<&PathBuf> = good_files.iter().map(|(path, _)| path).collect();
    for (relative, _) in &current {
        if !keep.contains(relative) {
            std::fs::remove_file(dir.join(relative))?;
        }
    }
    for (relative, _) in &good_files {
        let to = dir.join(relative);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(kept.join(relative), to)?;
    }
    Ok(())
}

impl Supervisor {
    /// Keeps the files a host of `app` loaded as its last good version
    /// (off the lock; `Out::KeepGood`).
    pub(super) fn keep_good(&self, app: &str, dir: &Path, version: &str, print: u64) {
        let Some(state) = self.config.state_dir.clone() else { return };
        let kept = copy_good(&state, app, dir, version, print);
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            match kept {
                Ok(good) => {
                    let message = format!("kept {} as the version to roll back to", good.version);
                    inner.last_good.insert(app.to_string(), good);
                    self.log_locked(&mut inner, app, "info", message)
                }
                Err(why) => self.log_locked(
                    &mut inner,
                    app,
                    "info",
                    format!("no rollback copy of this version: {why}"),
                ),
            }
        };
        self.emit(outs);
    }

    /// Whether `apps.rollback` would restore something for `app`: a last
    /// good copy exists and the folder holds something else now.
    pub(super) fn can_rollback_locked(inner: &Inner, app: &str) -> bool {
        inner
            .last_good
            .get(app)
            .is_some_and(|good| inner.local_prints.get(app).is_some_and(|now| *now != good.print))
    }

    /// `(run_state, can_rollback)` of `app` for listings.
    pub(super) fn run_facts(inner: &Inner, app: &str) -> (Option<String>, bool) {
        let package = inner.catalog.packages.get(app);
        let run_state =
            if inner.safe_mode.is_some() && package.is_some_and(super::safe_mode::holds_off) {
                Some(super::safe_mode::OFF.to_string())
            } else {
                inner.failed.get(app).map(|reason| format!("failed: {reason}"))
            };
        (run_state, Self::can_rollback_locked(inner, app))
    }

    /// `apps.rollback {app}`: origin user or cli.
    pub(super) fn rollback(&self, p: RollbackParams, origin: Origin) -> Result<Value, ApiError> {
        if !matches!(origin, Origin::User | Origin::Cli) {
            return Err(ApiError::new("apps.origin", "rollback is for you or the cmux CLI"));
        }
        let Some(state) = self.config.state_dir.clone() else {
            return Err(ApiError::new("apps.rollback.none", "this daemon keeps no state"));
        };
        let (dir, good) = {
            let inner = self.inner.lock().unwrap();
            let package = inner
                .catalog
                .packages
                .get(&p.app)
                .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
            if package.source != Source::Local {
                return Err(ApiError::new(
                    "apps.rollback.unsupported",
                    format!(
                        "{} ships with cmux or its folder: only local and customize apps keep an earlier version",
                        p.app
                    ),
                ));
            }
            let good = inner.last_good.get(&p.app).cloned().ok_or_else(|| {
                ApiError::new(
                    "apps.rollback.none",
                    format!("no earlier version of {} that worked is kept", p.app),
                )
            })?;
            if !Self::can_rollback_locked(&inner, &p.app) {
                return Err(ApiError::new(
                    "apps.rollback.none",
                    format!("{} already holds its last version that worked", p.app),
                ));
            }
            (package.dir.clone(), good)
        };
        let target = app_dir(&state, &p.app);
        restore(&dir, &target).map_err(|e| {
            ApiError::new("apps.rollback.failed", format!("{}: {e}", dir.display()))
        })?;
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            inner.failed.remove(&p.app);
            self.log_locked(
                &mut inner,
                &p.app,
                "info",
                format!(
                    "rolled back to {}; the replaced files are in {}",
                    good.version,
                    target.join("replaced").display()
                ),
            )
        };
        self.emit(outs);
        // Reload it as a save: its prints entry is dropped so it reads as changed.
        let mut prints = self.inner.lock().unwrap().local_prints.clone();
        prints.remove(&p.app);
        self.reload_local_apps(&prints);
        Ok(json!({ "app": p.app, "version": good.version, "restored": true }))
    }
}
