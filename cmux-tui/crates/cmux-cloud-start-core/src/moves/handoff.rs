//! Transfer to This Mac's and a Cloud chat's hand-off turn rules (`CloudTransferLocal`,
//! `CloudHandoffTurnOpener` in the app): when the menu row shows, what a `path` argument means,
//! whether a pane owns a session and why no hand-off turn opens. The app reads its state and asks.

use serde::Serialize;

/// The host prefix of a chat that runs on a registry machine (`MachineRegistry.registryHostPrefix`).
pub const REGISTRY_HOST_PREFIX: &str = "registry:";

/// Whether Transfer to This Mac hides: unless the chat runs on a machine (`host`, `session`) and
/// no move from this Mac put it there (`moved`: that one has Bring Back Local).
pub fn transfer_hidden(host: Option<&str>, session: Option<&str>, moved: bool) -> bool {
    let on_machine = host.is_some_and(|host| host.starts_with(REGISTRY_HOST_PREFIX));
    !(on_machine && session.is_some() && !moved)
}

/// A transfer's `path` argument, read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Folder {
    /// None or empty: a new folder under `~/Cloud Transfers`.
    New,
    At {
        path: String,
    },
    /// Not absolute after `~` expands; the app says so with `path` as typed.
    Relative {
        path: String,
    },
}

/// `path` with a leading `~` (or `~/`) expanded to `home`, as `NSString.expandingTildeInPath`
/// reads this user's tilde; it must then be absolute.
pub fn transfer_folder(path: Option<&str>, home: &str) -> Folder {
    let Some(path) = path.filter(|path| !path.is_empty()) else { return Folder::New };
    let expanded = if path == "~" {
        home.to_owned()
    } else if let Some(rest) = path.strip_prefix("~/") {
        format!("{}/{}", home.trim_end_matches('/'), rest)
    } else {
        path.to_owned()
    };
    let expanded = if expanded.starts_with('/') && expanded.bytes().all(|byte| byte == b'/') {
        "/".to_owned()
    } else {
        expanded.trim_end_matches('/').to_owned()
    };
    if expanded.starts_with('/') {
        Folder::At { path: expanded }
    } else {
        Folder::Relative { path: path.to_owned() }
    }
}

/// Whether a pane may name hand-off turns for `asked`: only the session recorded on its tab.
pub fn owns_session(recorded: Option<&str>, asked: &str) -> bool {
    recorded.is_some_and(|recorded| !recorded.is_empty() && recorded == asked)
}

/// Why no hand-off turn opens now, as the page's code: Cloud off by policy, not signed in, or a
/// machine list not loaded for the account signed in now.
pub fn refusal(cloud_allowed: bool, signed_in: bool, loaded_current: bool) -> Option<&'static str> {
    if !cloud_allowed {
        Some("cloud_disabled")
    } else if !signed_in {
        Some("not_signed_in")
    } else if !loaded_current {
        Some("machines_unread")
    } else {
        None
    }
}

/// The store's own refusal code (`handoff.closed`, `rate_limited`, ...) when it is one: 1 to 64 of
/// `a-z`, `_` and `.`. The only text the page gets.
pub fn store_code(code: Option<&str>) -> Option<&str> {
    code.filter(|code| {
        (1..=64).contains(&code.len())
            && code.bytes().all(|b| b.is_ascii_lowercase() || b == b'_' || b == b'.')
    })
}

#[cfg(test)]
#[path = "handoff_tests.rs"]
mod tests;
