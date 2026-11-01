//! The folders a new chat of this machine can start in
//! (`agent-session-folders-v1`), for the app on another Mac (through the SSH
//! or Cloud carrier): a chat started there with no folder of its own (no seed
//! folder, no terminal in its workspace) starts in this machine's work folder
//! instead of refusing, and the composer's "Choose folder" lists this
//! machine's folders, never the Mac's.
//!
//! Leo, 2026-10-31, on "Open a terminal in a folder on fs-firstsend-exercise
//! first; the chat starts there.": "let's work on improving this a LOT".
//!
//! `agent-session-folders {surface}` answers `{default, folders}`:
//! - `default`: the work folder, `$HOME/work` (Cloud images make it for the
//!   work user), when it is a folder; else null, and the app says what to do.
//!   On a Cloud VM a missing `$HOME/work` is made (0755) so a new machine has
//!   one; elsewhere (a Mac, an SSH host) nothing is made.
//! - `folders`: the work folder and its direct subfolders (not hidden),
//!   repositories first, then by name, at most [`MAX_FOLDERS`]. Names only, no
//!   file in them is read.
//!
//! Who: the same as `agent-session-trust` (a trusted local connection; an
//! agent tab of this store). A folder name is not the chat's trust: starting
//! there still goes through `agent-session-start`'s machine kind gate and the
//! folder's trust question.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::agent_session_trust::own_agent_tab;
use super::{MessageWriter, Refusal, SurfaceId, ok, refuse};
use crate::mux::Mux;

pub const AGENT_SESSION_FOLDERS_CAPABILITY: &str = "agent-session-folders-v1";

/// The work folder under the home folder.
pub(crate) const WORK_FOLDER: &str = "work";
/// Per-chat folders for Cloud starts that have no repository.
pub(crate) const CHAT_FOLDER: &str = "chats";
/// Folders one answer lists.
pub(crate) const MAX_FOLDERS: usize = 200;
/// Entries of the work folder read at most (a huge folder answers its first).
const MAX_ENTRIES: usize = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FoldersParams {
    surface: SurfaceId,
}

/// `agent-session-folders` of a trusted local connection (the parent checked
/// trust).
pub(super) fn folders(
    mux: &Arc<Mux>,
    id: Option<Value>,
    params: FoldersParams,
    writer: &MessageWriter,
) -> bool {
    if !own_agent_tab(mux, params.surface) {
        return refuse(writer, id, Refusal::UnknownTab);
    }
    let home = crate::platform::home_dir();
    let answer = answer(home.as_deref(), mux.on_cloud_host());
    ok(writer, id, answer)
}

/// The answer for `home` (none: no default, no folders). `make`: a missing
/// work folder is made (a Cloud VM).
pub(crate) fn answer(home: Option<&Path>, make: bool) -> Value {
    let Some(work) = home.and_then(|home| work_folder(home, make)) else {
        return json!({"default": Value::Null, "folders": []});
    };
    let folders = list(&work);
    json!({"default": work.to_string_lossy(), "folders": folders})
}

/// This user's own work folder (`$HOME/work`, made first when `make`),
/// canonical; None without a home folder or when it is not a folder.
pub(crate) fn own_work_folder(make: bool) -> Option<PathBuf> {
    crate::platform::home_dir().and_then(|home| work_folder(&home, make))
}

/// The fresh folder for a Cloud chat with no selected repository. The tab's
/// surface id is stable before the acp session exists, so retries reuse the
/// same folder without making Swift choose a path. Surface ids come from the
/// mux's persisted `next_id` snapshot and are never reset during restore.
pub(crate) fn own_chat_folder(chat_id: u64, make: bool) -> Option<PathBuf> {
    let home = crate::platform::home_dir()?;
    chat_folder(&home, chat_id, make)
}

/// Resolve a per-chat folder under `home`, refusing symlinks and creating the
/// parent and child only when `make` is true.
pub(crate) fn chat_folder(home: &Path, chat_id: u64, make: bool) -> Option<PathBuf> {
    let chats = home.join(CHAT_FOLDER);
    let chat = chats.join(chat_id.to_string());
    let is_dir = |path: &Path| private_owned_dir(path);
    if !is_dir(&chats) && make && std::fs::symlink_metadata(&chats).is_err() {
        let _ = make_private_dir(&chats);
    }
    if !is_dir(&chats) {
        return None;
    }
    if !is_dir(&chat) && make && std::fs::symlink_metadata(&chat).is_err() {
        let _ = make_private_dir(&chat);
    }
    is_dir(&chat).then(|| std::fs::canonicalize(chat).ok()).flatten()
}

/// Existing Cloud chat folders are trusted automatically, so only reuse a
/// real directory owned by this user without group/world write access.
pub(crate) fn private_owned_dir(path: &Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else { return false };
    if !metadata.is_dir() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o022 == 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// `home/work` when it is a folder (made first when `make`), canonical.
fn work_folder(home: &Path, make: bool) -> Option<PathBuf> {
    let work = home.join(WORK_FOLDER);
    // Never follow a symlink out of the home folder: the folder itself, not a link.
    let is_dir = |path: &Path| std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir());
    if !is_dir(&work) && make && std::fs::symlink_metadata(&work).is_err() {
        let _ = make_dir(&work);
    }
    if !is_dir(&work) {
        return None;
    }
    std::fs::canonicalize(&work).ok()
}

#[cfg(unix)]
fn make_dir(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt as _;
    std::fs::DirBuilder::new().mode(0o755).create(path)
}

#[cfg(unix)]
fn make_private_dir(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt as _;
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

#[cfg(not(unix))]
fn make_private_dir(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir(path)
}

#[cfg(not(unix))]
fn make_dir(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir(path)
}

/// The work folder, then its direct subfolders (not hidden, not symlinks),
/// repositories first, then by name.
fn list(work: &Path) -> Vec<String> {
    let mut children: Vec<(bool, String, String)> = std::fs::read_dir(work)
        .into_iter()
        .flatten()
        .take(MAX_ENTRIES)
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_str()?.to_owned();
            if name.starts_with('.') || name.chars().any(char::is_control) {
                return None;
            }
            // file_type does not follow a symlink.
            if !entry.file_type().ok()?.is_dir() {
                return None;
            }
            let path = entry.path();
            let repo = path.join(".git").exists();
            Some((!repo, name.to_lowercase(), path.to_string_lossy().into_owned()))
        })
        .collect();
    children.sort();
    std::iter::once(work.to_string_lossy().into_owned())
        .chain(children.into_iter().map(|(_, _, path)| path))
        .take(MAX_FOLDERS)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-folders-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    #[test]
    fn no_home_or_no_work_folder_has_no_default() {
        assert_eq!(answer(None, true), json!({"default": null, "folders": []}));
        let home = temp("nowork");
        assert_eq!(answer(Some(&home), false), json!({"default": null, "folders": []}));
        assert!(!home.join("work").exists(), "nothing is made off a Cloud VM");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn a_cloud_vm_makes_its_missing_work_folder() {
        let home = temp("make");
        let got = answer(Some(&home), true);
        let work = home.join("work");
        assert!(work.is_dir());
        assert_eq!(
            got,
            json!({"default": work.to_string_lossy(), "folders": [work.to_string_lossy()]})
        );
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn folders_list_repositories_first_and_skip_files_hidden_and_links() {
        let home = temp("list");
        let work = home.join("work");
        for dir in ["zeta", "Alpha", ".hidden", "repo/.git", "beta"] {
            std::fs::create_dir_all(work.join(dir)).unwrap();
        }
        std::fs::write(work.join("notes.txt"), "x").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&home, work.join("link")).unwrap();
        let got = answer(Some(&home), false);
        let path = |name: &str| work.join(name).to_string_lossy().into_owned();
        assert_eq!(got["default"], json!(work.to_string_lossy()));
        assert_eq!(
            got["folders"],
            json!([
                work.to_string_lossy(),
                path("repo"),
                path("Alpha"),
                path("beta"),
                path("zeta")
            ])
        );
        let _ = std::fs::remove_dir_all(home);
    }

    #[cfg(unix)]
    #[test]
    fn a_work_symlink_is_never_the_default() {
        let home = temp("worklink");
        let elsewhere = temp("elsewhere");
        std::os::unix::fs::symlink(&elsewhere, home.join("work")).unwrap();
        assert_eq!(answer(Some(&home), true), json!({"default": null, "folders": []}));
        let _ = std::fs::remove_dir_all(home);
        let _ = std::fs::remove_dir_all(elsewhere);
    }

    #[test]
    fn a_cloud_chat_folder_is_private_and_stable() {
        let home = temp("chat");
        let first = chat_folder(&home, 42, true).expect("chat folder");
        assert_eq!(first, std::fs::canonicalize(home.join("chats/42")).unwrap());
        assert!(home.join("chats").metadata().unwrap().is_dir());
        assert!(private_owned_dir(&home.join("chats")));
        assert!(private_owned_dir(&first));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(home.join("chats")).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(std::fs::metadata(&first).unwrap().permissions().mode() & 0o777, 0o700);
        }
        assert_eq!(chat_folder(&home, 42, false), Some(first.clone()));
        assert!(chat_folder(&home, 43, false).is_none());
        let _ = std::fs::remove_dir_all(home);
    }
}
