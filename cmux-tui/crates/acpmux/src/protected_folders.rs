//! LAUNCH-NO-TCC-PROMPTS: the folders an agent is never started in unless a
//! person asked for that folder. An agent starts with its cwd in the folder and
//! may read it at once; on macOS a read inside a guarded location raises a
//! privacy prompt attributed to cmux, and an agent in the home folder or `/`
//! walks into all of them. Warming (`_acpmux/warm`) and the session pool
//! (`_acpmux/prewarm` and the per-cwd entries) refuse these folders. A
//! session a person creates names its folder and is not limited here.
//!
//! A home folder kept in git (a dotfiles repository, `~/.git`) counts as the
//! home folder for an unasked agent in every folder it holds that has no
//! repository of its own (`unasked_refusal_in`): git there names the home
//! folder as its top level, and an agent's `git status` at start (Claude
//! Code's) lists every untracked file of the home folder, the Photos library
//! and Desktop included. acpmux's own folder is such a folder, so its
//! unattended folder moves to the temp dir then. A chat the person opens
//! there (`chats/open.rs`) and a chat store there (`~/.claude`) are not
//! refused: `refusal_in` does not apply this.

use std::path::{Path, PathBuf};

/// The one protected-folder list for every layer (data/protected-folders.json):
/// Swift and TypeScript get generated copies (scripts/cmux-next/gen-protected-folders.py).
const PROTECTED_FOLDERS_JSON: &str = include_str!("../data/protected-folders.json");

#[derive(serde::Deserialize)]
struct ProtectedEntry {
    path: String,
    kind: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProtectedList {
    /// The locations macOS guards, relative to the home folder.
    in_home: Vec<ProtectedEntry>,
    /// Guarded locations outside the home folder: other and network volumes.
    roots: Vec<ProtectedEntry>,
}

/// The parsed list; `None` only if the embedded file is invalid (the unit
/// tests parse it), and then every folder is refused (fail closed).
fn protected_list() -> Option<&'static ProtectedList> {
    static LIST: std::sync::OnceLock<Option<ProtectedList>> = std::sync::OnceLock::new();
    LIST.get_or_init(|| match serde_json::from_str(PROTECTED_FOLDERS_JSON) {
        Ok(list) => Some(list),
        Err(e) => {
            tracing::error!("data/protected-folders.json: {e}");
            None
        }
    })
    .as_ref()
}

/// A known privacy-protected location, without the broader startup refusal for `/` or home.
/// This is a hint for an OS-denied read, not proof that TCC caused the denial.
pub fn protected_kind_in(path: &Path, home: Option<&Path>) -> Option<&'static str> {
    let list = protected_list()?;
    let path = fold(path);
    let under = |root: &str| path == root || path.starts_with(&format!("{root}/"));
    for entry in &list.roots {
        if under(&entry.path.to_lowercase()) {
            return Some(&entry.kind);
        }
    }
    let home = fold(home?);
    list.in_home.iter().find_map(|entry| {
        under(&format!("{home}/{}", entry.path.to_lowercase())).then_some(entry.kind.as_str())
    })
}

/// Whether `path` is inside a privacy-protected location (the list's folders
/// under the home folder, other and network volumes), as spelled or with its
/// symlinks resolved. Unlike `unasked_refusal`, the home folder and `/` are
/// not guarded here: this is for background reads keyed off a recorded folder
/// (a session's cwd, a worktree), which skip a guarded one until a person
/// opens it (worktree cleanup: `cmux_worktree_care::inventory::Guarded`).
pub fn in_protected_location(path: &Path) -> bool {
    in_protected_location_in(path, dirs::home_dir().as_deref())
}

/// `in_protected_location` for the user whose home folder is `home`.
pub fn in_protected_location_in(path: &Path, home: Option<&Path>) -> bool {
    // The home folder may itself be reached through a symlink (`/var` on macOS).
    let homes: Vec<PathBuf> = home
        .into_iter()
        .flat_map(|h| [Some(h.to_path_buf()), std::fs::canonicalize(h).ok()])
        .flatten()
        .collect();
    let hit = |p: &Path| {
        protected_kind_in(p, None).is_some()
            || homes.iter().any(|h| protected_kind_in(p, Some(h)).is_some())
    };
    // The spelling first: resolving a symlink reads no folder's contents, but
    // a guarded spelling needs no second look.
    hit(path) || std::fs::canonicalize(path).is_ok_and(|resolved| hit(&resolved))
}

/// Why an agent may not be started in `cwd` unasked, or `None` when it may.
/// The folder is checked as spelled and with its symlinks resolved.
pub fn unasked_refusal(cwd: &Path) -> Option<String> {
    unasked_refusal_in(cwd, dirs::home_dir().as_deref())
}

/// `unasked_refusal` for the user whose home folder is `home`: `refusal_in`,
/// and a folder in the home folder's own repository (module text).
pub fn unasked_refusal_in(cwd: &Path, home: Option<&Path>) -> Option<String> {
    refusal_in(cwd, home).or_else(|| {
        in_home_repository(cwd, home).map(|reason| {
            format!(
                "{} is {reason}; an agent starts there only when a person picks it",
                cwd.display()
            )
        })
    })
}

/// Why `cwd` is a guarded location (the root folder, the home folder, another
/// volume, a privacy-protected folder), or `None` when it is not. The folder
/// is checked as spelled and with its symlinks resolved.
pub fn refusal_in(cwd: &Path, home: Option<&Path>) -> Option<String> {
    if !cwd.is_absolute() {
        return Some(format!("{} is not an absolute folder", cwd.display()));
    }
    // The home folder may itself be reached through a symlink (`/var` on macOS).
    let homes: Vec<PathBuf> = home
        .into_iter()
        .flat_map(|h| [Some(h.to_path_buf()), std::fs::canonicalize(h).ok()])
        .flatten()
        .collect();
    let refused = |reason: &str| {
        Some(format!(
            "{} is {reason}; an agent starts there only when a person picks it",
            cwd.display()
        ))
    };
    // The spelling first: resolving a guarded path already reads inside it.
    if let Some(reason) = guarded(cwd, &homes) {
        return refused(reason);
    }
    let resolved = std::fs::canonicalize(cwd).ok()?;
    guarded(&resolved, &homes).and_then(refused)
}

/// Whether git started in `cwd` takes the home folder's own repository for
/// its work tree: `cwd` is below a home folder that has a `.git`, and no
/// folder between them has one. As spelled and with symlinks resolved, on
/// either spelling of the home folder. Only stats: no folder's contents are
/// read. Called once `refusal_in` passed, so no guarded folder is looked in.
fn in_home_repository(cwd: &Path, home: Option<&Path>) -> Option<&'static str> {
    let home = home?;
    let held = |path: &Path, home: &Path| {
        if fold(path) == fold(home) || !path.starts_with(home) {
            return false;
        }
        let mut folder = path;
        while folder != home {
            if std::fs::symlink_metadata(folder.join(".git")).is_ok() {
                return false;
            }
            let Some(parent) = folder.parent() else { return false };
            folder = parent;
        }
        std::fs::symlink_metadata(home.join(".git")).is_ok()
    };
    let resolved_home = std::fs::canonicalize(home).ok();
    let resolved = std::fs::canonicalize(cwd).ok();
    let hit = held(cwd, home)
        || resolved_home.as_deref().is_some_and(|h| held(cwd, h))
        || resolved.as_deref().zip(resolved_home.as_deref()).is_some_and(|(c, h)| held(c, h));
    hit.then_some("in the home folder's git repository")
}

/// Why a spare (`hub/pool/`, the shape of a session the person already
/// started in `cwd`) may not start there, or `None` when it may. As
/// `unasked_refusal`, except that off macOS the home folder itself is
/// allowed: there no privacy prompt guards it, and a machine whose chats run
/// in the home folder (a cmux Cloud machine) is the one a spare is for. The
/// root folder, other volumes and the privacy-protected folders stay refused.
pub fn spare_refusal(cwd: &Path) -> Option<String> {
    spare_refusal_in(cwd, dirs::home_dir().as_deref(), cfg!(target_os = "macos"))
}

/// Why a daemon start may not go on by itself with a chat's restored work in `cwd` (its queued
/// prompts, a cut turn, held agent messages: `hub/protected_hold.rs`), or `None` when it may. As
/// `spare_refusal`: off macOS the home folder itself raises no privacy prompt, and a machine whose
/// chats all run there (a fleet lane VM, a cmux Cloud machine) has no person to open each chat, so
/// a hold there left every queue waiting for good after an update restarted the daemon.
pub fn restored_work_refusal(cwd: &Path) -> Option<String> {
    spare_refusal(cwd)
}

/// `spare_refusal` for the user whose home folder is `home`, on macOS or not.
pub fn spare_refusal_in(cwd: &Path, home: Option<&Path>, macos: bool) -> Option<String> {
    let refusal = unasked_refusal_in(cwd, home)?;
    let is_home = |h: &Path| {
        fold(cwd) == fold(h)
            || std::fs::canonicalize(cwd)
                .ok()
                .zip(std::fs::canonicalize(h).ok())
                .is_some_and(|(c, h)| fold(&c) == fold(&h))
    };
    // The home folder's repository counts as the home folder (module text), for a folder no
    // other rule refuses: a privacy-protected folder or another volume in it stays refused.
    let in_repository =
        |h: &Path| refusal_in(cwd, Some(h)).is_none() && in_home_repository(cwd, Some(h)).is_some();
    if !macos && home.is_some_and(|h| is_home(h) || in_repository(h)) {
        return None;
    }
    Some(refusal)
}

/// The folder for agents acpmux starts with no person asking (the model
/// probes at daemon start): `<acpmux home>/unattended`, owned by acpmux and
/// empty of the person's files. Never the home folder: an agent scans its
/// folder at start. When the acpmux home itself is guarded, or in the home
/// folder's own repository, this user's own folder in the temp dir
/// (`private_temp`). Created if missing.
pub fn unattended_cwd() -> PathBuf {
    unattended_cwd_in(&crate::config::home(), dirs::home_dir().as_deref())
}

/// `unattended_cwd` for an acpmux home and a user home folder.
pub fn unattended_cwd_in(acpmux_home: &Path, home: Option<&Path>) -> PathBuf {
    let own = acpmux_home.join("unattended");
    let dir = if unasked_refusal_in(&own, home).is_none() {
        own
    } else {
        private_temp("acpmux-unattended").unwrap_or_else(|| {
            tracing::warn!("no unattended folder of this user's own in the temp dir; acpmux's own");
            own
        })
    };
    // Not made under a lost home (`config::mark_home_lost`): it may be another daemon's now.
    let made = crate::config::refuse_lost_home(&dir)
        .and_then(|()| owner_only_dir(&dir).map_err(anyhow::Error::from));
    if let Err(e) = made {
        tracing::warn!(dir = %dir.display(), "unattended agent folder: {e}");
    }
    dir
}

/// `name` in the temp dir for this user alone, made if missing, or `None` when that folder is
/// not this user's own owner-only folder (a link, another user's). The temp dir off macOS is the
/// shared `/tmp`, so the name ends with the uid there, and a folder another user made first is
/// never an agent's folder: an agent reads its folder's instructions (`CLAUDE.md`) at start.
pub(crate) fn private_temp(name: &str) -> Option<PathBuf> {
    #[cfg(unix)]
    // SAFETY: getuid has no preconditions.
    let name = format!("{name}-{}", unsafe { libc::getuid() });
    let dir = std::env::temp_dir().join(name);
    owner_only_dir(&dir).ok()?;
    owns(&dir).then_some(dir)
}

/// Whether `dir` is a folder (not a link) this user owns that only this user may open.
#[cfg(unix)]
fn owns(dir: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    std::fs::symlink_metadata(dir)
        .is_ok_and(|meta| meta.is_dir() && meta.uid() == uid && meta.mode() & 0o077 == 0)
}

#[cfg(not(unix))]
fn owns(_dir: &Path) -> bool {
    true
}

/// Makes `dir` (and missing parents) owner-only whatever the umask: under 002 it would be
/// group-writable. One an older build made with the umask is narrowed when it is this user's own
/// folder; a link or another user's folder is left alone.
///
/// Made through the folder this daemon holds (`home_fs`): a home replaced after the check never
/// gets it.
fn owner_only_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        crate::home_fs::private_dir(dir)
    }
    #[cfg(not(unix))]
    {
        crate::home_fs::create_dir_all(dir, 0o700)
    }
}

fn guarded(path: &Path, homes: &[PathBuf]) -> Option<&'static str> {
    let folded = fold(path);
    if folded == "/" {
        return Some("the root folder");
    }
    let under = |root: &str| {
        let root = root.to_lowercase();
        folded == root || folded.starts_with(&format!("{root}/"))
    };
    let Some(list) = protected_list() else {
        return Some("unknown: the protected-folder list is invalid");
    };
    if list.roots.iter().any(|root| under(&root.path)) {
        return Some("on another or a network volume");
    }
    for home in homes {
        let home = fold(home);
        if folded == home {
            return Some("the home folder");
        }
        if list.in_home.iter().any(|relative| under(&format!("{home}/{}", relative.path))) {
            return Some("in a privacy-protected folder");
        }
    }
    None
}

/// The path lowercased (the Mac's disk ignores case) without a trailing `/`.
fn fold(path: &Path) -> String {
    let text = path.to_string_lossy().to_lowercase();
    let trimmed = text.trim_end_matches('/');
    if trimmed.is_empty() { "/".to_owned() } else { trimmed.to_owned() }
}

#[cfg(all(test, unix))]
mod owner_only_tests {
    use super::*;

    /// The unattended folder is owner-only whatever the umask, and one an older build made with
    /// the umask (775 under 002) is narrowed (ergo-walk2, 2026-10-25).
    #[test]
    fn the_unattended_folder_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("acpmux-unatt-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(home.join("unattended")).unwrap();
        let wide = std::fs::Permissions::from_mode(0o775);
        std::fs::set_permissions(home.join("unattended"), wide).unwrap();
        let dir = unattended_cwd_in(&home, None);
        assert_eq!(dir, home.join("unattended"));
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        let _ = std::fs::remove_dir_all(&home);
    }
}

#[cfg(test)]
mod spare_tests {
    use super::*;

    #[test]
    fn a_spare_may_start_in_the_home_folder_off_macos_only() {
        let home = Path::new("/home/someone");
        assert!(spare_refusal_in(home, Some(home), false).is_none());
        assert!(spare_refusal_in(Path::new("/home/someone/"), Some(home), false).is_none());
        assert!(spare_refusal_in(home, Some(home), true).is_some(), "macOS keeps the refusal");
        assert!(spare_refusal_in(Path::new("/"), Some(home), false).is_some());
        assert!(spare_refusal_in(Path::new("relative"), Some(home), false).is_some());
        assert!(spare_refusal_in(Path::new("/home/someone/work"), Some(home), false).is_none());
    }
}

#[cfg(all(test, unix))]
mod home_repository_tests {
    use super::*;

    /// A home folder kept in git: a folder it holds with no repository of its own is refused for
    /// an unasked agent (off macOS a spare may still start there, as in the home folder itself),
    /// a repository of its own is not, and a person's own open is not limited.
    #[test]
    fn a_folder_in_the_home_folders_repository_is_refused_unasked() {
        let home = std::env::temp_dir().join(format!("acpmux-homerepo-{}", uuid::Uuid::now_v7()));
        let tools = home.join("itp-rs/tools");
        let app = home.join("code/app");
        std::fs::create_dir_all(&tools).unwrap();
        std::fs::create_dir_all(app.join(".git")).unwrap();
        let home_ref = Some(home.as_path());
        assert_eq!(unasked_refusal_in(&tools, home_ref), None, "no ~/.git yet");
        std::fs::create_dir_all(home.join(".git")).unwrap();
        let refusal =
            unasked_refusal_in(&tools, home_ref).expect("in the home folder's repository");
        assert!(refusal.contains("home folder's git repository"), "{refusal}");
        // An acpmux home under the home folder, as the daemon's own is.
        let acpmux_home = home.join("daemon-home");
        assert!(unasked_refusal_in(&acpmux_home.join("unattended"), home_ref).is_some());
        assert_eq!(unasked_refusal_in(&app, home_ref), None, "a repository of its own");
        assert_eq!(unasked_refusal_in(&app.join("src"), home_ref), None);
        assert_eq!(refusal_in(&tools, home_ref), None, "a chat the person opens there");
        assert!(spare_refusal_in(&tools, home_ref, true).is_some(), "macOS keeps the refusal");
        assert_eq!(spare_refusal_in(&tools, home_ref, false), None);
        // Off macOS too, a privacy-protected folder in the repository stays refused for a spare.
        let downloads = home.join("Downloads/x");
        std::fs::create_dir_all(&downloads).unwrap();
        assert!(spare_refusal_in(&downloads, home_ref, false).is_some());
        // The unattended folder moves to this user's own folder in the temp dir.
        let moved = unattended_cwd_in(&acpmux_home, home_ref);
        assert_eq!(Some(moved.clone()), private_temp("acpmux-unattended"));
        assert!(moved.starts_with(std::env::temp_dir()) && owns(&moved), "{}", moved.display());
        let _ = std::fs::remove_dir_all(&home);
    }

    /// A temp folder is an agent's only when it is this user's owner-only folder, never a link.
    #[test]
    fn only_a_private_folder_of_this_users_own_is_used() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("acpmux-owns-{}", uuid::Uuid::now_v7()));
        let private = root.join("private");
        std::fs::create_dir_all(&private).unwrap();
        std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o700)).unwrap();
        let open = root.join("open");
        std::fs::create_dir_all(&open).unwrap();
        std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink(&private, root.join("link")).unwrap();
        assert!(owns(&private));
        assert!(!owns(&open), "others may open it");
        assert!(!owns(&root.join("link")), "a link, even to a private folder");
        assert!(!owns(&root.join("missing")));
        let _ = std::fs::remove_dir_all(&root);
    }
}

#[cfg(all(test, unix))]
mod location_tests {
    use super::*;

    /// Worktree cleanup's guard (LAUNCH-NO-TCC-PROMPTS, 2026-11-22: a recorded session on the
    /// Desktop got git run in it at a fresh copy's start): the guarded folders, also through a
    /// symlink, but not the home folder or a plain folder in it.
    #[test]
    fn a_recorded_folder_in_a_protected_location_is_guarded() {
        let home = std::env::temp_dir().join(format!("acpmux-loc-{}", uuid::Uuid::now_v7()));
        let desk = home.join("Desktop/videos");
        std::fs::create_dir_all(&desk).unwrap();
        std::fs::create_dir_all(home.join("Projects")).unwrap();
        std::os::unix::fs::symlink(&desk, home.join("Projects/videos")).unwrap();
        let home_ref = Some(home.as_path());
        assert!(in_protected_location_in(&desk, home_ref));
        assert!(in_protected_location_in(&home.join("desktop/VIDEOS"), home_ref), "case folds");
        assert!(in_protected_location_in(&home.join("Documents/x"), home_ref), "missing too");
        assert!(in_protected_location_in(&home.join("Projects/videos"), home_ref), "symlink");
        assert!(in_protected_location_in(Path::new("/Volumes/Backup/repo"), home_ref));
        assert!(!in_protected_location_in(&home, home_ref), "the home folder itself");
        assert!(!in_protected_location_in(&home.join("Projects"), home_ref));
        assert!(!in_protected_location_in(&home.join("Desktopper"), home_ref));
        let _ = std::fs::remove_dir_all(&home);
    }
}
