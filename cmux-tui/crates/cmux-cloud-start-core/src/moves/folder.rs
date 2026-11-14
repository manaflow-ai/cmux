//! The folder a chat moves with, and where a New Workspace the Cloud toggle sends goes.
//!
//! A chat moves with the git working copy that holds its folder (`cmux link sync push` copies only
//! a working copy's top folder), or with its folder itself outside git.

use serde::{Deserialize, Serialize};

/// `path` with its `.` and `..` parts resolved and no trailing slash, as written otherwise:
/// standardizing would also turn /private/tmp into /tmp, a path the chat never reported. None
/// for a relative path or one whose `..` parts climb above the disk's root.
pub fn normalized(path: &str) -> Option<String> {
    if !path.starts_with('/') {
        return None;
    }
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/').filter(|part| !part.is_empty()) {
        match part {
            "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    Some(format!("/{}", parts.join("/")))
}

/// The folder a chat moves with.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveFolder {
    /// The folder that is synced, absolute, on this Mac.
    pub root: String,
    /// The chat's folder inside `root`; empty for `root` itself.
    pub subpath: String,
    /// `root` is a git working copy's top (it holds `.git`).
    pub git: bool,
    /// The folder's name on a machine ([`remote_name`]).
    pub remote_name: String,
}

/// The parent of an absolute normalized path; none for the root.
fn parent(folder: &str) -> Option<&str> {
    if folder == "/" {
        return None;
    }
    match folder.rfind('/') {
        Some(0) => Some("/"),
        Some(index) => folder.get(..index),
        None => None,
    }
}

/// The folder for a chat in `folder`: the nearest folder at or above it that `has_git` says holds
/// `.git`, else `folder` itself. None for a relative folder or one that climbs above the root.
pub fn move_folder(folder: &str, has_git: impl Fn(&str) -> bool) -> Option<MoveFolder> {
    let start = normalized(folder)?;
    let top = std::iter::successors(Some(start.as_str()), |folder| parent(folder))
        .find(|folder| has_git(folder));
    let (root, git) = match top {
        Some(top) => (top.to_owned(), true),
        None => (start.clone(), false),
    };
    // `root` is `start` or a folder above it, so the chat's folder never escapes the synced one.
    let prefix = if root == "/" { "/".to_owned() } else { format!("{root}/") };
    if start != root && !start.starts_with(&prefix) {
        return None;
    }
    let subpath = start.get(root.len()..).unwrap_or("").trim_matches('/').to_owned();
    Some(MoveFolder { remote_name: remote_name(&root), root, subpath, git })
}

/// The folder's name on a machine: its own name and a short hash (FNV-1a) of where it is on this
/// Mac, so two folders with one name never share a synced folder.
pub fn remote_name(root: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    let name = root.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let name = if name.is_empty() { "folder" } else { name };
    format!("{name}-{:06x}", hash & 0x00ff_ffff)
}

/// The synced folder under `work_root` on the machine, and the chat's folder there.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Remote {
    pub folder: String,
    pub chat: String,
}

pub fn remote(root: &str, subpath: &str, work_root: &str) -> Remote {
    let name = remote_name(root);
    let folder = if work_root.ends_with('/') {
        format!("{work_root}{name}")
    } else {
        format!("{work_root}/{name}")
    };
    let chat = if subpath.is_empty() { folder.clone() } else { format!("{folder}/{subpath}") };
    Remote { folder, chat }
}

/// Where a planned New Workspace goes. A machine costs money, so one is asked for only where its
/// progress, Cancel and Retry show (a window), and only when Cloud can make it; otherwise the
/// workspace opens on this Mac and the person is told why, never silently.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "route", rename_all = "camelCase")]
pub enum Route {
    Cloud,
    ThisMac { refusal: Refusal },
}

/// Why a New Workspace the toggle would send to Cloud opened on this Mac instead.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Refusal {
    /// Cloud cannot run in this build or for this account (the reason as Cloud says it).
    Unavailable {
        reason: String,
    },
    SignedOut,
    /// No open window to show the new machine's progress in (Cmd-N with every window closed).
    NoWindow,
}

pub fn route(unavailable_reason: Option<&str>, signed_in: bool, has_window: bool) -> Route {
    let refusal = match (unavailable_reason, signed_in, has_window) {
        (Some(reason), _, _) => Refusal::Unavailable { reason: reason.to_owned() },
        (None, false, _) => Refusal::SignedOut,
        (None, true, false) => Refusal::NoWindow,
        (None, true, true) => return Route::Cloud,
    };
    Route::ThisMac { refusal }
}

/// The facts the Cloud toggle (`cloud.newWorkspacesInCloud`) decides a New Workspace by.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Toggle {
    pub in_cloud: bool,
    /// `cloud.newWorkspaceFolder` is `inherit`, and this app can copy a folder.
    pub inherits_folder: bool,
    pub cwd: Option<String>,
    /// A person's gesture; a script, the CLI or an agent keeps its workspace where it asked.
    pub by_person: bool,
    /// The run names a machine (it opens there) or a command (it runs here).
    pub names_machine_or_command: bool,
}

/// Whether the New Workspace goes to a new Cloud machine, and the folder it copies there (none:
/// the machine's own empty folder). None keeps it on this Mac.
pub fn plan(toggle: &Toggle) -> Option<Option<String>> {
    (toggle.in_cloud && toggle.by_person && !toggle.names_machine_or_command)
        .then(|| toggle.cwd.clone().filter(|_| toggle.inherits_folder))
}

/// What one copy of a folder answered (`cmux link sync push`'s JSON line).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CopyAnswer {
    pub ok: bool,
    pub error_code: Option<String>,
    pub error: Option<String>,
}

/// What a New Workspace's folder copy does after one push.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "step", rename_all = "camelCase")]
pub enum CopyStep {
    /// Copied: this work root holds it.
    Done,
    /// This work root refused the write (an image without the work user refuses its home with
    /// `fs.permission_denied`): the next one is tried.
    Next,
    /// The machine's cmux-tui is older than the copy needs.
    Outdated,
    /// Any other refusal, as the copy said it.
    Failed { message: String },
}

/// The step after a push under one of the work roots (`last`: no other is left to try). With no
/// work root at all the caller asks with a refusal and `last`.
pub fn copy_step(answer: &CopyAnswer, last: bool) -> CopyStep {
    if answer.ok {
        return CopyStep::Done;
    }
    match answer.error_code.as_deref() {
        Some("fs.permission_denied") if !last => CopyStep::Next,
        Some("machine_outdated") => CopyStep::Outdated,
        _ => CopyStep::Failed {
            message: answer.error.clone().or_else(|| answer.error_code.clone()).unwrap_or_default(),
        },
    }
}

/// Which machine New Cloud Workspace (`cmux cloud new-workspace`) opens on. One workspace, one new
/// small machine: with no machine named, a workspace gets a new machine of its own, never one
/// picked from the machines already listed (a teammate's, a fleet lane VM).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum NewWorkspaceMachine {
    /// `--target machine:<id>`: that machine, refused when it is not there.
    Named(String),
    /// The person's own gesture in a window that shows a Cloud machine.
    Focused(String),
    /// A new machine of the workspace's own.
    New,
}

pub fn new_workspace_machine(
    named: Option<&str>,
    by_person: bool,
    focused: Option<&str>,
) -> NewWorkspaceMachine {
    match (
        named.filter(|named| !named.is_empty()),
        focused.filter(|focused| by_person && !focused.is_empty()),
    ) {
        (Some(named), _) => NewWorkspaceMachine::Named(named.to_owned()),
        (None, Some(focused)) => NewWorkspaceMachine::Focused(focused.to_owned()),
        (None, None) => NewWorkspaceMachine::New,
    }
}

#[cfg(test)]
mod tests;
