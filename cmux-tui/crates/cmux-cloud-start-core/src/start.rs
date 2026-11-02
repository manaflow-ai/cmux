//! A `cloud.startChat` start's own checks (the app's `CloudStartChat`): whether a Cloud chat can
//! start at all, whether the account it began in is still the one signed in with its machine list
//! current, and which folder of this Mac it may copy. The app reads the facts (the policy, the
//! account, the paths as Foundation standardizes and canonicalizes them, a working copy's git
//! folders) and asks here; it throws the failures in the person's words.

use serde::{Deserialize, Serialize};

/// Why no Cloud chat can start at all now: the sandbox's codes (the page's `AgentPageChats.wireSandbox`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Refusal {
    /// Cloud is off by policy, or this app may not call Cloud.
    #[serde(rename = "cloud_disabled")]
    CloudDisabled,
    #[serde(rename = "not_signed_in")]
    NotSignedIn,
}

/// Cloud off by policy, or not signed in; nothing else refuses (not behind Labs, Leo, 2026-10-30:
/// "that seems dumb. i dont like putting so much stuff in labs"), and either link takes the start.
pub fn refusal(cloud_disabled: bool, signed_in: bool) -> Option<Refusal> {
    if cloud_disabled {
        Some(Refusal::CloudDisabled)
    } else if signed_in {
        None
    } else {
        Some(Refusal::NotSignedIn)
    }
}

/// The account a send began in as cmux-tui keeps its sends: its user and team, `/`-joined, an
/// absent part empty. A team switch keeps the user signed in, so a send of the previous team never
/// names this team's machine.
pub fn account_text(account: &[Option<String>]) -> String {
    account.iter().map(|part| part.as_deref().unwrap_or("")).collect::<Vec<_>>().join("/")
}

/// Why a send copies or opens nothing now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccountCheck {
    /// The account signed in is not the one the send began in.
    #[serde(rename = "account-changed")]
    AccountChanged,
    /// The machine list is not the server's answer for the account signed in now.
    #[serde(rename = "list-unread")]
    ListUnread,
}

/// `None` while the send may go on: the account it began in (`asked`) is the one signed in now and
/// its machine list is current. After a team switch the previous team's machines stay in the store
/// until that list lands, and the chat's folder must never be copied to one of them.
pub fn check_account(
    asked: &[Option<String>],
    now: &[Option<String>],
    list_current: bool,
) -> Option<AccountCheck> {
    if asked != now {
        Some(AccountCheck::AccountChanged)
    } else if !list_current {
        Some(AccountCheck::ListUnread)
    } else {
        None
    }
}

/// Whether a copied folder's root is the home folder or the disk's root (both as Foundation's
/// `standardizedFileURL` spells them): never copied to a machine.
pub fn too_broad(root: &str, home: &str) -> bool {
    root == "/" || root == home
}

/// What the start knows of the folder it would copy.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Folder {
    /// Whether the page named the folder (`cwd`); else it is the tab's own folder.
    pub cwd_given: bool,
    /// The upload root the pane checked against its roots, for a folder the page named.
    pub upload_root: Option<String>,
    /// The folder that is copied (its working copy's top, or the folder itself outside git).
    pub root: String,
    /// The chat's folder inside `root`; empty for `root` itself.
    pub subpath: String,
    /// `root` and its canonical path, each standardized (`standardizingPath`).
    pub paths: Vec<String>,
    /// The home folder's canonical path and the home folder, each standardized; empty when unknown.
    pub homes: Vec<String>,
}

/// Whether the start may copy the folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Uploads {
    #[serde(rename = "yes")]
    Yes,
    #[serde(rename = "no")]
    No,
    /// Only when every git folder of the root is inside it (a `.git` file or `commondir` can name a
    /// repository elsewhere): the app reads the disk for that.
    #[serde(rename = "if-git-folders-inside")]
    IfGitFoldersInside,
}

/// Path components, empty ones omitted.
fn parts(path: &str) -> impl Iterator<Item = &str> {
    path.split('/').filter(|part| !part.is_empty())
}

/// Whether `path` is `/`, the home folder `home` or a folder above it (by path components; both
/// already standardized). Such a folder is never copied as a tab's own.
fn home_or_above(path: &str, home: Option<&str>) -> bool {
    if path == "/" {
        return true;
    }
    let Some(home) = home else { return false };
    let root: Vec<&str> = parts(path).collect();
    let below: Vec<&str> = parts(home).collect();
    below.len() >= root.len() && root.iter().zip(&below).all(|(a, b)| a == b)
}

/// Whether the start may copy `f`: for a folder the page named, exactly the upload root the pane
/// checked; for the tab's own folder, only that folder itself, never a working copy found above it
/// (a tab in /repo/project never uploads /repo, its siblings and its history), and never the home
/// folder or above it by its canonical path too (a tab in /Users would copy every home folder's
/// credentials).
pub fn uploads(f: &Folder) -> Uploads {
    if f.cwd_given {
        return if f.upload_root.as_deref() == Some(f.root.as_str()) {
            Uploads::Yes
        } else {
            Uploads::No
        };
    }
    if !f.subpath.is_empty() {
        return Uploads::No;
    }
    let homes: Vec<Option<&str>> = if f.homes.is_empty() {
        vec![None]
    } else {
        f.homes.iter().map(|home| Some(home.as_str())).collect()
    };
    if f.paths.iter().any(|path| homes.iter().any(|home| home_or_above(path, *home))) {
        return Uploads::No;
    }
    Uploads::IfGitFoldersInside
}

#[cfg(test)]
mod tests;
