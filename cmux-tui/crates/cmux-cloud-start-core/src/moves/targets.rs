//! Where a started chat's Move to… can take it, and which folder goes along. Pure: the app reads
//! its live machine list, the chat's record and its Bring Back Local entry, asks here, and draws
//! the answer (the page's Move to… rows, `EnvironmentPicker.tsx`). Leo, 2026-11-10: "the whole
//! \"move to cloud\" deserves a proper \"move to other cloud\" ... and \"move to local\"".

use serde::{Deserialize, Serialize};

/// The id the app and the page name this Mac by.
pub const LOCAL: &str = "local";

/// One Cloud machine of the account, as the app's machine list has it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// The machine's status word (`running`, `stopped`, `failed`, ...).
    #[serde(default)]
    pub status: String,
}

/// What the app knows about the chat and the account.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    /// Signed in, with the machine list loaded for the account signed in now.
    pub offered: bool,
    /// The chat has an acpmux session (a started chat).
    pub started: bool,
    /// The chat is Chief's home chat, which never moves.
    #[serde(default)]
    pub chief: bool,
    /// The Cloud machine the chat runs on; None for a chat of this Mac or another machine.
    #[serde(default)]
    pub running: Option<String>,
    /// The chat runs on a machine that is neither this Mac nor a Cloud machine (an SSH peer).
    #[serde(default)]
    pub elsewhere: bool,
    /// Bring Back Local can take the chat back now (a move from this Mac put it there).
    #[serde(default)]
    pub back_home: bool,
    #[serde(default)]
    pub machines: Vec<Machine>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub id: String,
    /// Empty for this Mac: the page names it.
    pub label: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub status: String,
    /// `local` or `cloud`.
    pub kind: &'static str,
}

/// Machines that are going away or never came up take no chat.
const GONE: [&str; 3] = ["failed", "destroyed", "deleting"];

/// Every place the chat can move now: this Mac first when the chat can come back, then every
/// other live Cloud machine in the list's order. A chat of an SSH peer moves nowhere here.
pub fn targets(chat: &Chat) -> Vec<Target> {
    if !chat.offered || !chat.started || chat.chief || (chat.running.is_none() && chat.elsewhere) {
        return Vec::new();
    }
    let mut targets = Vec::new();
    if chat.running.is_some() && chat.back_home {
        targets.push(Target {
            id: LOCAL.into(),
            label: String::new(),
            status: String::new(),
            kind: "local",
        });
    }
    for machine in &chat.machines {
        if chat.running.as_deref() == Some(machine.id.as_str())
            || GONE.contains(&machine.status.as_str())
            || machine.id.is_empty()
            || machine.id == LOCAL
        {
            continue;
        }
        targets.push(Target {
            id: machine.id.clone(),
            label: machine.title.clone(),
            status: machine.status.clone(),
            kind: "cloud",
        });
    }
    targets
}

/// The folder a Cloud-to-Cloud move takes, and where the chat sits in it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    /// The tree that is copied, at the same path on both machines.
    pub root: String,
    /// The chat's own folder, inside `root`.
    pub chat: String,
}

/// The folder that goes: the one a move from this Mac put there (its root, so a chat in a
/// subfolder keeps its repository), else the chat's own. None without an absolute folder, or
/// when the chat's folder is not inside the recorded root. `/` is never copied whole.
pub fn folder(
    remote_folder: Option<&str>,
    remote_chat: Option<&str>,
    cwd: Option<&str>,
) -> Option<Folder> {
    let chat = remote_chat.or(cwd).filter(|chat| chat.starts_with('/'))?;
    let chat = chat.trim_end_matches('/');
    let root = remote_folder.unwrap_or(chat).trim_end_matches('/');
    let inside = chat == root || chat.strip_prefix(root).is_some_and(|rest| rest.starts_with('/'));
    if root.is_empty() || !root.starts_with('/') || !inside {
        return None;
    }
    Some(Folder { root: root.into(), chat: chat.into() })
}

#[cfg(test)]
mod tests;
