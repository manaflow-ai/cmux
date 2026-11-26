//! The names a workspace takes: from the tab a workspace is made of (a drag,
//! a tear-off, Move Pane, a tab group), from its front tab while the person
//! never named it (`workspaces.autoName`, hq#1957: the sidebar row's live
//! label and the chat title the `persist` variant writes to the daemon), and
//! from its activity (Name from Activity's prompt and reply,
//! [`activity`]).
//!
//! Pure. The Mac app reads its tab models and the chat store, asks here
//! (app FFI ops `workspace_name_*`) and shows or sends the answer.
//! schemas/workspace-naming/vectors.json pins the Swift rules' answers
//! (`NewWorkspaceName`, `WorkspaceAutoName`, `WorkspaceActivityName`) from
//! before the move.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

#[path = "naming_activity.rs"]
pub mod activity;

/// The most characters (grapheme clusters, as Swift counts) a name keeps.
pub const MAX_LENGTH: usize = 80;

// MARK: Text

/// Swift's `Character.isNewline`.
pub(crate) fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The first `count` grapheme clusters of `text` (Swift's `String.prefix`).
pub(crate) fn prefix(text: &str, count: usize) -> &str {
    match text.grapheme_indices(true).nth(count) {
        Some((end, _)) => &text[..end],
        None => text,
    }
}

/// How many grapheme clusters `text` holds (Swift's `String.count`).
pub(crate) fn length(text: &str) -> usize {
    text.graphemes(true).count()
}

/// One line, trimmed, at most [`MAX_LENGTH`] characters; `None` when empty.
/// Every workspace name the app writes or shows passes through it.
pub fn clean(raw: Option<&str>) -> Option<String> {
    let raw = raw?;
    let line = raw.split(is_newline).filter(|part| !part.is_empty()).collect::<Vec<_>>().join(" ");
    let line = line.trim_matches(char::is_whitespace);
    if line.is_empty() { None } else { Some(prefix(line, MAX_LENGTH).to_owned()) }
}

/// The daemon's numbered default, `workspace-N`, exactly (untrimmed, like
/// the daemon's `is_default_workspace_name`): never renamed, it is no one's
/// choice whatever source the daemon recorded (#26680).
pub fn is_numbered_default_name(name: &str) -> bool {
    name.strip_prefix("workspace-")
        .is_some_and(|number| !number.is_empty() && number.chars().all(|c| c.is_ascii_digit()))
}

/// A name the daemon gave: `workspace-N`, or the empty and home-folder
/// defaults older daemons kept. A person could type `workspace-7`; the
/// daemon records no flag, so that reads as default too.
pub fn is_default_workspace_name(name: &str) -> bool {
    let name = name.trim_matches(char::is_whitespace);
    name.is_empty() || name == "~" || is_numbered_default_name(name)
}

/// Shell names a terminal reports as its title while idle: they say nothing
/// of the work, so its folder names the workspace (`TerminalTitle.isBareShell`).
pub fn is_bare_shell(title: &str) -> bool {
    let title = title.strip_prefix('-').unwrap_or(title);
    ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login", "~"]
        .contains(&title)
}

/// The blank page's and the New Tab page's addresses: what a conversation,
/// page or app tab's record carries as its title, never a name.
fn is_placeholder(title: &str) -> bool {
    matches!(title.to_lowercase().as_str(), "about:blank" | "chrome://newtab" | "chrome://newtab/")
}

/// The last path component, as `NSString.lastPathComponent` reads it.
pub(crate) fn last_path_component(path: &str) -> &str {
    if path.is_empty() {
        return "";
    }
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return "/";
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

/// The host of `url` as Foundation's `URL(string:)?.host()` reads a well
/// formed address (no IDNA, no lower-casing); `None` without an authority.
pub fn url_host(url: &str) -> Option<&str> {
    let rest = match url.find(':') {
        Some(colon)
            if colon > 0
                && url[..colon].starts_with(|c: char| c.is_ascii_alphabetic())
                && url[..colon]
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')) =>
        {
            &url[colon + 1..]
        }
        _ => url,
    };
    let authority = rest.strip_prefix("//")?;
    let authority = &authority[..authority.find(['/', '?', '#']).unwrap_or(authority.len())];
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = match host.strip_prefix('[') {
        Some(bracketed) => bracketed.split_once(']').map_or(bracketed, |(inner, _)| inner),
        None => host.split_once(':').map_or(host, |(name, _)| name),
    };
    if host.is_empty() { None } else { Some(host) }
}

fn without_www(host: &str) -> &str {
    host.strip_prefix("www.").unwrap_or(host)
}

// MARK: A workspace made from tabs

/// What the rule reads of one tab (`NewWorkspaceName.Tab`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tab {
    pub kind: TabKind,
    /// The name the person gave the tab.
    pub user_name: Option<String>,
    /// A terminal's live title (OSC 0/2), a browser record's title, or the
    /// name a page tab shows of its own.
    pub title: Option<String>,
    /// A browser's live page title.
    pub page_title: Option<String>,
    pub url: Option<String>,
    pub cwd: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TabKind {
    #[default]
    Terminal,
    Browser,
    RemoteTerminal,
    /// A conversation, page or app tab: its record's title is the
    /// `about:blank` placeholder, so `title` is the name it shows of its own.
    /// It never falls back to a folder.
    Page,
}

/// The name for a workspace made from `tab`, or `None` to keep the daemon's
/// default (Lawrence, 2026-10-02: "workspace name should be adopted from the
/// name of the tab that was dragged out"). The tab's user name, then a
/// browser's page title (else its host), or a terminal's live title (a bare
/// shell name reads as its folder), then the folder.
pub fn for_tab(tab: &Tab) -> Option<String> {
    if let Some(name) = clean(tab.user_name.as_deref()) {
        return Some(name);
    }
    match tab.kind {
        TabKind::Browser => {
            let address = clean(tab.url.as_deref());
            for candidate in [&tab.page_title, &tab.title] {
                if let Some(title) = clean(candidate.as_deref())
                    && Some(&title) != address.as_ref()
                {
                    return Some(title);
                }
            }
            clean(tab.url.as_deref().and_then(url_host).map(without_www))
        }
        TabKind::Page => clean(tab.title.as_deref()).filter(|title| !is_placeholder(title)),
        TabKind::Terminal | TabKind::RemoteTerminal => {
            if let Some(title) = clean(tab.title.as_deref())
                && !is_bare_shell(&title)
                && !is_placeholder(&title)
            {
                return Some(title);
            }
            let directory = tab.cwd.as_deref().map(last_path_component);
            clean(directory.filter(|directory| *directory != "/"))
        }
    }
}

/// Who supplied a workspace's name (`WorkspaceNameSource`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NameSource {
    /// A person or a legacy daemon.
    User,
    /// An automatic naming pass.
    #[default]
    Auto,
}

/// What the rules read of a workspace's own name.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Named {
    pub name: String,
    pub title: Option<String>,
    pub name_source: NameSource,
    pub name_revision: u64,
    /// Whether an old daemon's missing provenance may count `~` or an empty
    /// name as automatic.
    pub allows_legacy_defaults: bool,
}

impl Default for Named {
    fn default() -> Self {
        Named {
            name: String::new(),
            title: None,
            name_source: NameSource::Auto,
            name_revision: 0,
            allows_legacy_defaults: true,
        }
    }
}

/// The name for a workspace made from the last tab of another one
/// (coordinator decision 2026-10-03): the old workspace's title or the name
/// a person gave it, else `tab_name`.
pub fn for_last_tab(workspace: &Named, tab_name: Option<String>) -> Option<String> {
    if let Some(title) = clean(workspace.title.as_deref()) {
        return Some(title);
    }
    let created_default = workspace.name_revision == 0 && is_numbered_default_name(&workspace.name);
    if workspace.name_source == NameSource::User
        && !created_default
        && (workspace.name_revision > 0 || !workspace.allows_legacy_defaults)
        && let Some(name) = clean(Some(&workspace.name))
    {
        return Some(name);
    }
    if !is_default_workspace_name(&workspace.name)
        && let Some(name) = clean(Some(&workspace.name))
    {
        return Some(name);
    }
    tab_name
}

/// The name for a workspace made from a tab group: its name, else its first tab's.
pub fn for_group(name: Option<&str>, first_tab: Option<&Tab>) -> Option<String> {
    clean(name).or_else(|| first_tab.and_then(for_tab))
}

// MARK: Automatic naming

/// The `workspaces.autoName.variant` choices (hq#1957).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Variant {
    /// The sidebar row shows its front tab's name; the daemon keeps its own.
    Live,
    /// The focused chat's generated title is written to the daemon.
    #[default]
    Persist,
}

/// What the rule reads of a workspace's front tab (`WorkspaceAutoName.Front`).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Front {
    /// A browser tab: its title as the sidebar showed it (user name, page
    /// title, host); `off_the_record` for an incognito page.
    #[serde(rename_all = "camelCase")]
    Browser {
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        off_the_record: bool,
    },
    /// An agent chat: the tab's user name, its chat's title (perhaps only its
    /// first prompt) and its generated title, the only name `persist` writes.
    #[serde(rename_all = "camelCase")]
    Chat {
        #[serde(default)]
        user_name: Option<String>,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        generated_title: Option<String>,
    },
    /// A terminal, or any other tab: [`for_tab`]'s input.
    Terminal { tab: Tab },
}

/// The name `front` gives: one line, at most [`MAX_LENGTH`] characters.
pub fn derived(front: &Front) -> Option<String> {
    match front {
        Front::Browser { title, .. } => clean(title.as_deref()),
        Front::Chat { user_name, title, .. } => {
            clean(user_name.as_deref()).or_else(|| clean(title.as_deref()))
        }
        Front::Terminal { tab } => for_tab(tab),
    }
}

/// Whether a title or the name's source protects the workspace from automatic naming.
pub fn is_user_named(workspace: &Named) -> bool {
    if workspace.title.as_deref().is_some_and(|title| !title.is_empty()) {
        return true;
    }
    if workspace.name_source != NameSource::User {
        return false;
    }
    if workspace.name_revision == 0 && is_numbered_default_name(&workspace.name) {
        return false;
    }
    workspace.name_revision > 0
        || !workspace.allows_legacy_defaults
        || !is_default_workspace_name(&workspace.name)
}

/// The rule as `workspaces.autoName` and its variant set it (`WorkspaceAutoName`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AutoName {
    /// `workspaces.autoName`: off turns both variants off.
    pub enabled: bool,
    pub variant: Variant,
}

/// Where a persisted name would go.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Destination {
    pub is_local_machine: bool,
    /// The daemon advertises `workspace-name-source-v1`.
    pub supports_name_source: bool,
    /// One submission per app run.
    pub already_renamed: bool,
}

impl AutoName {
    /// The name the sidebar row shows for `workspace` while `front` fronts
    /// it; `None` keeps its own name. `anchor` is the work tab a browser
    /// front yields to (a page opened beside a chat never renames the row).
    pub fn label(
        &self,
        workspace: &Named,
        front: Option<&Front>,
        anchor: Option<&Front>,
    ) -> Option<String> {
        if !self.enabled || is_user_named(workspace) {
            return None;
        }
        let front = front?;
        if let (Front::Browser { .. }, Some(anchor)) = (front, anchor) {
            return derived(anchor);
        }
        derived(front)
    }

    /// The name to write to the daemon (variant `persist`), or `None`: only
    /// a front chat's generated title, only for a daemon that records the
    /// name's source (the local one is accepted for older callers).
    pub fn persisted_name(
        &self,
        workspace: &Named,
        front: Option<&Front>,
        to: Destination,
    ) -> Option<String> {
        if !self.enabled
            || self.variant != Variant::Persist
            || !(to.is_local_machine || to.supports_name_source)
            || to.already_renamed
            || is_user_named(workspace)
        {
            return None;
        }
        let Some(Front::Chat { generated_title, .. }) = front else { return None };
        let generated = clean(generated_title.as_deref())?;
        if Some(&generated) == clean(Some(&workspace.name)).as_ref() {
            return None;
        }
        Some(generated)
    }

    /// Whether a rename decided earlier may still go out now.
    pub fn confirms_rename(&self, workspace: &Named) -> bool {
        !is_user_named(workspace)
    }
}

#[cfg(test)]
#[path = "naming_tests.rs"]
mod tests;
