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
//! `apps.rollback {app}` (origin user only) puts those files back into the
//! app's folder; the files it replaces go to
//! `<state>/apps-last-good/<app>/replaced`, and the ones an earlier rollback
//! replaced move to `replaced.previous`, so a second rollback destroys no
//! only copy. It refuses, before it changes anything, when a path it would
//! write goes through a symbolic link (that write would land outside the
//! folder). Keeping a copy and rolling back are serialized per app. The app
//! then reloads like a save (in safe mode the reload waits until safe mode
//! ends). Shipped apps (first-party, samples,
//! `CMUX_APPS_DIRS`) are read in place and change only with cmux or their
//! folder, so there is no earlier version of theirs on disk to keep:
//! rollback answers `apps.rollback.unsupported` for them.

use std::collections::{BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

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

/// One file name for an app id: every byte outside `[A-Za-z0-9._-]` is
/// `%XX`, so two ids never share a folder and [`decode`] reverses it.
pub(super) fn encode(app: &str) -> String {
    let mut out = String::with_capacity(app.len());
    for byte in app.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// The app id of an [`encode`]d name; `None` for a name `encode` never makes.
pub(super) fn decode(name: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(name.len());
    let mut rest = name.bytes();
    while let Some(byte) = rest.next() {
        if byte == b'%' {
            let hex = [rest.next()?, rest.next()?];
            let hex = std::str::from_utf8(&hex).ok()?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
        } else if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-') {
            bytes.push(byte);
        } else {
            return None;
        }
    }
    let app = String::from_utf8(bytes).ok()?;
    (encode(&app) == name).then_some(app)
}

/// The copy folder of `app`.
fn app_dir(state: &Path, app: &str) -> PathBuf {
    state.join(DIR).join(encode(app))
}

/// Per-app locks that serialize keeping a copy and rolling back.
#[derive(Default)]
pub(super) struct AppLocks(Mutex<HashMap<String, Arc<Mutex<()>>>>);

impl AppLocks {
    fn of(&self, app: &str) -> Arc<Mutex<()>> {
        let mut locks = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        locks.entry(app.to_string()).or_default().clone()
    }
}

/// The last good copies on disk, by app id.
pub(super) fn load(state: Option<&Path>) -> HashMap<String, Good> {
    let Some(root) = state.map(|s| s.join(DIR)) else { return Default::default() };
    let Ok(entries) = std::fs::read_dir(root) else { return Default::default() };
    entries
        .flatten()
        .filter_map(|entry| {
            let app = decode(entry.file_name().to_str()?)?;
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

/// Refuses a `relative` path under `dir` that is not plain or that goes
/// through a symbolic link at any component (the link itself included):
/// writing there would land outside `dir`.
fn no_link_on_the_way(dir: &Path, relative: &Path) -> std::io::Result<()> {
    let mut path = dir.to_path_buf();
    for component in relative.components() {
        let Component::Normal(part) = component else {
            return Err(std::io::Error::other(format!(
                "{} is not a plain path",
                relative.display()
            )));
        };
        path.push(part);
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_symlink() => {
                return Err(std::io::Error::other(format!(
                    "{} is a symbolic link; rollback does not write through links",
                    path.display()
                )));
            }
            Ok(_) => {}
            // Nothing there yet: nothing below it can be a link either.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// Puts the copy in `target/files` back into `dir`, keeping what `dir`
/// held in `target/replaced` first (and the previous `replaced` in
/// `replaced.previous`).
fn restore(dir: &Path, target: &Path) -> std::io::Result<()> {
    let kept = target.join("files");
    let good_files = files(&kept).ok_or_else(|| std::io::Error::other("copy unreadable"))?;
    // Every write is checked before the folder changes at all.
    for (relative, _) in &good_files {
        no_link_on_the_way(dir, relative)?;
    }
    // Whatever the folder holds now is kept first, so nothing is lost.
    let current = files(dir).ok_or_else(|| std::io::Error::other("folder too big"))?;
    let staging = target.join("replaced.tmp");
    copy_tree(dir, &current, &staging)?;
    let replaced = target.join("replaced");
    if replaced.is_dir() {
        let previous = target.join("replaced.previous");
        let _ = std::fs::remove_dir_all(&previous);
        std::fs::rename(&replaced, &previous)?;
    }
    std::fs::rename(&staging, &replaced)?;
    let keep: BTreeSet<&PathBuf> = good_files.iter().map(|(path, _)| path).collect();
    for (relative, _) in &current {
        if !keep.contains(relative) {
            std::fs::remove_file(dir.join(relative))?;
        }
    }
    for (relative, _) in &good_files {
        let to = dir.join(relative);
        // Again at the write, for a link made since the check.
        no_link_on_the_way(dir, relative)?;
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)?;
        }
        no_link_on_the_way(dir, relative)?;
        std::fs::copy(kept.join(relative), to)?;
    }
    Ok(())
}

impl Supervisor {
    /// Keeps the files a host of `app` loaded as its last good version
    /// (off the supervisor lock, on its own thread; `Out::KeepGood`).
    pub(super) fn keep_good(&self, app: &str, dir: &Path, version: &str, print: u64) {
        let Some(state) = self.config.state_dir.clone() else { return };
        let kept = {
            let lock = self.rollback_locks.of(app);
            let _serial = lock.lock().unwrap_or_else(PoisonError::into_inner);
            copy_good(&state, app, dir, version, print)
        };
        let outs = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
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

    /// `apps.rollback {app}`: origin user only, like leaving safe mode (an
    /// agent's CLI call proposes; the person rolls back).
    pub(super) fn rollback(&self, p: RollbackParams, origin: Origin) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new("apps.origin", "only you can roll an app back, in cmux"));
        }
        let Some(state) = self.config.state_dir.clone() else {
            return Err(ApiError::new("apps.rollback.none", "this daemon keeps no state"));
        };
        let (dir, good) = {
            let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
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
        {
            let lock = self.rollback_locks.of(&p.app);
            let _serial = lock.lock().unwrap_or_else(PoisonError::into_inner);
            restore(&dir, &target).map_err(|e| {
                ApiError::new("apps.rollback.failed", format!("{}: {e}", dir.display()))
            })?;
        }
        let outs = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
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
        let mut prints =
            self.inner.lock().unwrap_or_else(PoisonError::into_inner).local_prints.clone();
        prints.remove(&p.app);
        self.reload_local_apps(&prints);
        Ok(json!({ "app": p.app, "version": good.version, "restored": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh empty folder under the system temp dir, removed on drop.
    struct Temp(PathBuf);
    impl Temp {
        fn new(tag: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default();
            let dir = std::env::temp_dir()
                .join(format!("cmux-rollback-{tag}-{}-{nanos}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn read(path: &Path) -> String {
        std::fs::read_to_string(path).unwrap()
    }

    #[test]
    fn rollback_folder_names_are_unambiguous() {
        let apps = ["local/a~b", "local~a/b", "local/a%2Fb", "local/a/b", "x/é"];
        let names: Vec<String> = apps.map(encode).into();
        let unique: BTreeSet<&String> = names.iter().collect();
        assert_eq!(unique.len(), names.len(), "{names:?}");
        for (app, name) in apps.iter().zip(&names) {
            assert_eq!(decode(name).as_deref(), Some(*app), "{name}");
        }
        assert_eq!(encode("local/spy"), "local%2Fspy");
        // Names encode never makes are not apps.
        for name in ["local~spy", "%2f", "%+1", "%2", "a b"] {
            assert_eq!(decode(name), None, "{name}");
        }
    }

    #[test]
    fn rollback_keeps_two_replaced_versions() {
        let root = Temp::new("rotate");
        let (dir, target) = (root.0.join("app"), root.0.join("kept"));
        write(&target.join("files/dist/main.js"), "good");
        write(&dir.join("dist/main.js"), "broken one");
        restore(&dir, &target).unwrap();
        assert_eq!(read(&dir.join("dist/main.js")), "good");
        write(&dir.join("dist/main.js"), "broken two");
        restore(&dir, &target).unwrap();
        assert_eq!(read(&dir.join("dist/main.js")), "good");
        assert_eq!(read(&target.join("replaced/dist/main.js")), "broken two");
        assert_eq!(read(&target.join("replaced.previous/dist/main.js")), "broken one");
    }

    #[cfg(unix)]
    #[test]
    fn rollback_refuses_to_write_through_a_symlink() {
        use std::os::unix::fs::symlink;
        let root = Temp::new("symlink");
        let (dir, target, outside) =
            (root.0.join("app"), root.0.join("kept"), root.0.join("outside"));
        write(&target.join("files/dist/main.js"), "good");
        write(&target.join("files/cmux-app.json"), "{}");
        write(&outside.join("main.js"), "not yours");
        write(&outside.join("victim.json"), "not yours");
        // A linked directory on the way.
        std::fs::create_dir_all(&dir).unwrap();
        symlink(&outside, dir.join("dist")).unwrap();
        let refused = restore(&dir, &target).unwrap_err();
        assert!(refused.to_string().contains("symbolic link"), "{refused}");
        assert_eq!(read(&outside.join("main.js")), "not yours");
        // Refused before anything changed: nothing was moved to replaced.
        assert!(!target.join("replaced").exists());
        // A linked file.
        std::fs::remove_file(dir.join("dist")).unwrap();
        write(&dir.join("dist/main.js"), "broken");
        symlink(outside.join("victim.json"), dir.join("cmux-app.json")).unwrap();
        let refused = restore(&dir, &target).unwrap_err();
        assert!(refused.to_string().contains("symbolic link"), "{refused}");
        assert_eq!(read(&outside.join("victim.json")), "not yours");
        assert_eq!(read(&dir.join("dist/main.js")), "broken");
        // With the link gone it restores.
        std::fs::remove_file(dir.join("cmux-app.json")).unwrap();
        restore(&dir, &target).unwrap();
        assert_eq!(read(&dir.join("dist/main.js")), "good");
        assert_eq!(read(&outside.join("main.js")), "not yours");
    }
}
