//! `--attach` (`grant` and `answer`): the copy just made on the machine put among the chat's
//! folders, live, through the machine daemon's `chat-folder-add` (`chat-folder-add-v1`): acpmux
//! there restarts the chat's agent on them between turns, so the agent can read the folder from its
//! next turn on, and the chat shows one line ("Added ~/x as /vm/path"). Leo, 2026-11-25: "mostly
//! just the one you selected, right? then you can add more folders and files/select more as you
//! go potentially".
//!
//! What may go is decided before the copy (`grants::shareable`, `grants::shareable_item`, the
//! secret lists of `access_cli.rs`): this adds nothing a copy did not already carry.

use std::path::Path;

use serde_json::{Value, json};

use super::{Failure, grants, sync_cli};

/// How the chat line names `local`: `~/x` under this Mac's home, else the path itself.
pub(super) fn shown(local: &Path) -> String {
    for home in grants::homes() {
        if let Ok(inside) = local.strip_prefix(&home) {
            return if inside.as_os_str().is_empty() {
                "~".to_string()
            } else {
                format!("~/{}", inside.to_string_lossy())
            };
        }
    }
    local.to_string_lossy().into_owned()
}

/// The folder at `remote` on the machine added to chat `session`'s folders: the daemon's answer
/// (`applied`, `path`, `additionalDirectories`), or its refusal.
pub(super) fn attach(
    socket: &Path,
    session: &str,
    remote: &str,
    local: &Path,
) -> Result<Value, Failure> {
    sync_cli::machine_call(
        socket,
        "chat-folder-add",
        json!({"session": session, "path": remote, "from": shown(local)}),
    )
    .map_err(|error| Failure::new(&sync_cli::push_failure_code(&error), format!("{error:#}")))
}

/// The machine folder a delivered answer gives the chat: the folder copy itself (`folder_remote`,
/// Always) or the file's own request folder (Allow, `at`'s parent).
pub(super) fn answered_folder(at: &str, folder_remote: Option<&str>) -> Option<String> {
    if let Some(folder) = folder_remote.filter(|folder| !folder.is_empty()) {
        return Some(folder.to_string());
    }
    Path::new(at).parent().map(|parent| parent.to_string_lossy().into_owned()).filter(|p| p != "/")
}

#[cfg(test)]
#[path = "attach_tests.rs"]
mod tests;
