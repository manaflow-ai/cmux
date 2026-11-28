//! The daemon's default name for the next workspace (`SidebarMapping.defaultWorkspaceName`, cmux-tui
//! `Mux::default_workspace_name`): the app sends it with the create, so the row's title at the press
//! is the daemon's.

use serde::{Deserialize, Serialize};

/// The prefix of the daemon's default workspace names.
pub const DEFAULT_NAME_PREFIX: &str = "workspace-";

/// The kind of the home workspace, which the numbering leaves out.
pub const HOME_KIND: &str = "home";

/// The number of a default name (`workspace-N`, ASCII digits only, at least one); nil for any other
/// name or a number past `i64`.
pub fn default_name_number(name: &str) -> Option<i64> {
    let digits = name.strip_prefix(DEFAULT_NAME_PREFIX)?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// The daemon's default for the next workspace: one more than the highest `workspace-N` name and than
/// the count of workspaces. `existing` are the machine's listed names (home left out); `reserved`
/// are names given to creates the daemon has not listed yet, so a key-repeat burst numbers each
/// create once, in press order. A reserved name the machine lists already counts once.
pub fn default_workspace_name(existing: &[String], reserved: &[String]) -> String {
    let unlisted: Vec<&String> = reserved.iter().filter(|name| !existing.contains(name)).collect();
    let highest = existing
        .iter()
        .chain(unlisted.iter().copied())
        .filter_map(|name| default_name_number(name))
        .max()
        .unwrap_or(0);
    let count = i64::try_from(existing.len() + unlisted.len()).unwrap_or(i64::MAX);
    format!("{DEFAULT_NAME_PREFIX}{}", highest.max(count).saturating_add(1))
}

/// One listed workspace, as the store has it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ListedWorkspace {
    /// Its name.
    pub name: String,
    /// Its kind (`home` is left out of the numbering).
    pub kind: Option<String>,
}

/// `default_workspace_name` for a machine's listed `workspaces` but its home workspace
/// (`SidebarMapping.nextWorkspaceName`).
pub fn next_workspace_name(workspaces: &[ListedWorkspace], reserved: &[String]) -> String {
    let existing: Vec<String> = workspaces
        .iter()
        .filter(|workspace| workspace.kind.as_deref() != Some(HOME_KIND))
        .map(|workspace| workspace.name.clone())
        .collect();
    default_workspace_name(&existing, reserved)
}
