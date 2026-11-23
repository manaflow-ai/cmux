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
/// `agent-session-list-dir` (a folder chooser over this machine's own disk).
pub const AGENT_SESSION_LIST_DIR_CAPABILITY: &str = "agent-session-list-dir-v1";
/// Entries one `agent-session-list-dir` answer lists.
pub(crate) const MAX_LIST_DIR: usize = 500;

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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ListDirParams {
    surface: SurfaceId,
    /// An absolute folder; none or empty starts at the work folder, else the home folder.
    #[serde(default)]
    path: Option<String>,
    /// Files too (default: folders only), so a files view can reuse the verb.
    #[serde(default)]
    files: bool,
    /// Hidden names too (default: skipped).
    #[serde(default)]
    hidden: bool,
}

/// `agent-session-list-dir {surface, path?, files?, hidden?}`: the folders of one folder of this
/// machine, for the app's folder chooser on another Mac (the same checks as `agent-session-folders`).
/// Answers `{path, parent, home, work, entries: [{name, path, kind, repo}], truncated}`.
pub(super) fn list_dir(
    mux: &Arc<Mux>,
    id: Option<Value>,
    params: ListDirParams,
    writer: &MessageWriter,
) -> bool {
    if !own_agent_tab(mux, params.surface) {
        return refuse(writer, id, Refusal::UnknownTab);
    }
    let home = crate::platform::home_dir();
    match browse(home.as_deref(), params.path.as_deref(), params.files, params.hidden) {
        Ok(answer) => ok(writer, id, answer),
        // A folder that cannot be listed is the chooser's inline message, not a refused verb.
        Err(error) => {
            ok(writer, id, json!({"error": {"code": error.code(), "message": error.message()}}))
        }
    }
}

/// Why a folder could not be listed: the code the page shows and a sentence.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum BrowseError {
    NotAbsolute,
    NotFound,
    NotAFolder,
    Denied,
    NoStart,
}

impl BrowseError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::NotAbsolute => "list_dir.not_absolute",
            Self::NotFound => "list_dir.not_found",
            Self::NotAFolder => "list_dir.not_a_folder",
            Self::Denied => "list_dir.denied",
            Self::NoStart => "list_dir.no_start",
        }
    }
    pub(crate) fn message(&self) -> &'static str {
        match self {
            Self::NotAbsolute => "Enter a full path starting with /",
            Self::NotFound => "That folder does not exist on this machine",
            Self::NotAFolder => "That is a file, not a folder",
            Self::Denied => "This machine does not let cmux read that folder",
            Self::NoStart => "This machine has no home folder to start from",
        }
    }
}

/// The entries of `path` (none or empty: the work folder under `home`, else `home`), canonical.
/// Folders first, repositories first among them, then by name; symlinked folders are listed as
/// folders (a person picks where a link goes), never followed past the canonical path.
pub(crate) fn browse(
    home: Option<&Path>,
    path: Option<&str>,
    files: bool,
    hidden: bool,
) -> Result<Value, BrowseError> {
    let work = home.and_then(|home| work_folder(home, false));
    let requested = path.map(str::trim).filter(|path| !path.is_empty());
    let start = match requested {
        Some(path) => {
            let path = Path::new(path);
            if !path.is_absolute() {
                return Err(BrowseError::NotAbsolute);
            }
            path.to_path_buf()
        }
        None => work.clone().or_else(|| home.map(Path::to_path_buf)).ok_or(BrowseError::NoStart)?,
    };
    let dir = std::fs::canonicalize(&start).map_err(|error| match error.kind() {
        std::io::ErrorKind::PermissionDenied => BrowseError::Denied,
        _ => BrowseError::NotFound,
    })?;
    if !dir.is_dir() {
        return Err(BrowseError::NotAFolder);
    }
    let read = std::fs::read_dir(&dir).map_err(|error| match error.kind() {
        std::io::ErrorKind::PermissionDenied => BrowseError::Denied,
        _ => BrowseError::NotFound,
    })?;
    let mut truncated = false;
    let mut rows: Vec<(bool, bool, String, Value)> = Vec::new();
    for (index, entry) in read.filter_map(Result::ok).enumerate() {
        if index >= MAX_ENTRIES {
            truncated = true;
            break;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
        if name.chars().any(char::is_control) || (!hidden && name.starts_with('.')) {
            continue;
        }
        let entry_path = entry.path();
        // A link counts as the folder it points at (metadata follows it); a broken one is a file.
        let is_dir = std::fs::metadata(&entry_path).is_ok_and(|m| m.is_dir());
        if !is_dir && !files {
            continue;
        }
        let repo = is_dir && entry_path.join(".git").exists();
        rows.push((
            !is_dir,
            !repo,
            name.to_lowercase(),
            json!({
                "name": name,
                "path": entry_path.to_string_lossy(),
                "kind": if is_dir { "dir" } else { "file" },
                "repo": repo,
            }),
        ));
    }
    rows.sort_by(|a, b| (a.0, a.1, &a.2).cmp(&(b.0, b.1, &b.2)));
    if rows.len() > MAX_LIST_DIR {
        truncated = true;
        rows.truncate(MAX_LIST_DIR);
    }
    Ok(json!({
        "path": dir.to_string_lossy(),
        "parent": dir.parent().map(|parent| parent.to_string_lossy().into_owned()),
        "home": home.and_then(|home| std::fs::canonicalize(home).ok()).map(|home| home.to_string_lossy().into_owned()),
        "work": work.map(|work| work.to_string_lossy().into_owned()),
        "entries": rows.into_iter().map(|row| row.3).collect::<Vec<_>>(),
        "truncated": truncated,
    }))
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
#[path = "agent_session_folders_tests.rs"]
mod tests;
