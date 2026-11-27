//! The name a new workspace takes (`NewWorkspaceName`).

use crate::text::{
    clean, is_bare_shell, is_default_workspace_name, is_numbered_default_name, is_placeholder,
    last_path_component, site,
};
use serde::{Deserialize, Serialize};

/// What kind of tab a name is read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// A local terminal.
    #[default]
    Terminal,
    /// A web page.
    Browser,
    /// A terminal on another machine.
    RemoteTerminal,
    /// A cmux page (Settings, a Markdown page): its record's title.
    Page,
}

/// The facts of a tab a workspace may take its name from.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Tab {
    /// The tab's kind.
    pub kind: Kind,
    /// The name the person gave the tab.
    pub user_name: Option<String>,
    /// The tab's title (a terminal's OSC title, a page's recorded title).
    pub title: Option<String>,
    /// A browser tab's live page title.
    pub page_title: Option<String>,
    /// A browser tab's address.
    pub url: Option<String>,
    /// A terminal's working directory.
    pub cwd: Option<String>,
}

/// Who gave a workspace its name, as the daemon records it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NameSource {
    /// Automatic naming (or a daemon that records none).
    #[default]
    Auto,
    /// A person.
    User,
}

/// The name a workspace takes from `tab`: the tab's own name, then its page title, terminal
/// title or folder. `None` when it says nothing (a bare shell at `/`, a blank page).
pub fn for_tab(tab: &Tab) -> Option<String> {
    if let Some(name) = clean(tab.user_name.as_deref()) {
        return Some(name);
    }
    match tab.kind {
        Kind::Browser => {
            let url = clean(tab.url.as_deref());
            for candidate in [&tab.page_title, &tab.title] {
                if let Some(title) = clean(candidate.as_deref())
                    && Some(&title) != url.as_ref()
                {
                    return Some(title);
                }
            }
            clean(tab.url.as_deref().and_then(site).as_deref())
        }
        Kind::Page => clean(tab.title.as_deref()).filter(|title| !is_placeholder(title)),
        Kind::Terminal | Kind::RemoteTerminal => {
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

/// The name a workspace keeps when its last tab moves out: its title, then a name a person
/// gave it, then a name that is not a default, else the tab's (`tab_name`).
pub fn for_last_tab(
    workspace_name: &str,
    workspace_title: Option<&str>,
    tab_name: Option<String>,
    source: NameSource,
    revision: u64,
    allows_legacy_defaults: bool,
) -> Option<String> {
    if let Some(title) = clean(workspace_title) {
        return Some(title);
    }
    let created_default = revision == 0 && is_numbered_default_name(workspace_name);
    if source == NameSource::User
        && !created_default
        && (revision > 0 || !allows_legacy_defaults)
        && let Some(name) = clean(Some(workspace_name))
    {
        return Some(name);
    }
    if !is_default_workspace_name(workspace_name)
        && let Some(name) = clean(Some(workspace_name))
    {
        return Some(name);
    }
    tab_name
}

/// The name a workspace made of a tab group takes: the group's name, else its first tab's.
pub fn for_group(name: Option<&str>, first_tab: Option<&Tab>) -> Option<String> {
    clean(name).or_else(|| first_tab.and_then(for_tab))
}
