//! The agent-home folder of a closed workspace (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE,
//! cx-gzh.9.2). A workspace with no folder starts its chats in
//! `<agent-home base>/<workspace key>` (`agent_start`), and those chat files
//! must outlive a close. The daemon owns closed history and knows which key a
//! reopened workspace gets, so it moves the folder:
//!
//! - Reopen: `<base>/<closed key>` becomes `<base>/<reopened key>` before the
//!   reopened workspace's first chat (the reopen reply comes after it).
//! - Delete (Delete Permanently, Clear Recently Closed): the folder of a
//!   deleted workspace that no live workspace uses moves to
//!   `<base>/.trash-pending/`; the app moves that to the user's Trash
//!   (never a hard delete; the daemon has no Trash of its own).
//!
//! A symlink at a path is never moved or followed, an existing target is
//! never overwritten, and a key that does not name a folder (`[A-Za-z0-9_-]`,
//! 1 to 128) is ignored. Failures are logged; the folder stays where it was.

use cmux_threads::checked::fs as files;
use std::path::{Path, PathBuf};

use super::agent_start::agent_home_base;

/// The folder the app empties into the Trash.
pub(crate) const TRASH_PENDING: &str = ".trash-pending";

fn safe_key(key: &str) -> bool {
    (1..=128).contains(&key.len())
        && key.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// The agent-home base, only when it is canonical (as the app requires): a
/// symlinked base or parent moves nothing.
fn base() -> Option<PathBuf> {
    // In-crate tests and the request fuzzer never move the person's folders
    // (the daemon's integration tests set their own HOME).
    if cfg!(any(test, feature = "fuzz")) {
        return None;
    }
    let base = agent_home_base(crate::platform::home_dir().as_deref())?;
    (files::canonicalize(&base).ok()? == base).then_some(base)
}

/// A real folder (not a symlink) at `path`.
fn is_folder(path: &Path) -> bool {
    files::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_dir())
}

/// Reopened workspaces: each `(closed key, reopened key)` folder follows.
pub(crate) fn follow_reopen(placements: &[(String, String)]) {
    let Some(base) = base() else { return };
    for (closed, reopened) in placements {
        if !safe_key(closed) || !safe_key(reopened) || closed == reopened {
            continue;
        }
        let from = base.join(closed);
        let to = base.join(reopened);
        if !is_folder(&from) {
            continue;
        }
        if files::symlink_metadata(&to).is_ok() {
            // The reopened workspace already made its own folder: the old one
            // would be named by no record any more, so it waits for the Trash.
            retire_folder(&base, closed);
            continue;
        }
        if let Err(error) = files::rename(&from, &to) {
            eprintln!("cmux-tui: agent-home folder of a reopened workspace did not move ({error})");
        }
    }
}

/// Deleted closed workspaces: each key's folder goes to `.trash-pending`
/// for the app to trash. `live` keys (a workspace that uses the folder now)
/// are kept.
pub(crate) fn retire(keys: &[String], live: &dyn Fn(&str) -> bool) {
    let Some(base) = base() else { return };
    for key in keys {
        if safe_key(key) && !live(key) {
            retire_folder(&base, key);
        }
    }
}

/// Moves `<base>/<key>` (a real folder) into `.trash-pending`.
fn retire_folder(base: &Path, key: &str) {
    let from = base.join(key);
    if !is_folder(&from) {
        return;
    }
    let pending = base.join(TRASH_PENDING);
    if let Err(error) = files::create_dir_all(&pending) {
        eprintln!("cmux-tui: agent-home trash folder not made ({error})");
        return;
    }
    // A key retired twice (a reopen, then a close and delete) keeps both.
    let mut to = pending.join(key);
    let mut n = 1;
    while files::symlink_metadata(&to).is_ok() {
        n += 1;
        to = pending.join(format!("{key}-{n}"));
    }
    if let Err(error) = files::rename(&from, &to) {
        eprintln!("cmux-tui: agent-home folder of a deleted workspace did not move ({error})");
    }
}

/// The workspace keys a closed group's `members` keep folders under.
pub(crate) fn member_keys(members: &[serde_json::Value]) -> Vec<String> {
    members
        .iter()
        .filter(|member| member["kind"] == "workspace")
        .filter_map(|member| member["workspace_key"].as_str().map(str::to_string))
        .collect()
}
