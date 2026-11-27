//! The name a workspace nobody named takes from its front tab (`WorkspaceAutoName`).

use crate::new_name::{self, NameSource, Tab};
use crate::text::{clean, is_default_workspace_name, is_numbered_default_name, site, trimmed};
use serde::{Deserialize, Serialize};

/// `workspaces.autoName.variant`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Variant {
    /// A: a live sidebar label that follows the front tab.
    Live,
    /// B: the focused chat's generated title becomes the daemon's name (the default).
    #[default]
    Persist,
}

/// What the front tab offers a name, externally tagged as Swift's synthesized `Codable` writes
/// it (`{"browser": {"title": ..., "off_the_record": false}}`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Front {
    /// A web page.
    Browser {
        /// Its title.
        #[serde(default)]
        title: Option<String>,
        /// An incognito page.
        #[serde(default)]
        off_the_record: bool,
    },
    /// An agent chat.
    Chat {
        /// The name the person gave the tab.
        #[serde(default)]
        user_name: Option<String>,
        /// The chat's title (a prompt gist until one is generated).
        #[serde(default)]
        title: Option<String>,
        /// The title the model generated.
        #[serde(default)]
        generated_title: Option<String>,
    },
    /// A terminal (or anything else read as a new workspace's tab).
    Terminal {
        /// The tab (Swift's unlabeled `terminal(Tab)` writes it as `_0`).
        #[serde(rename = "_0")]
        tab: Tab,
    },
}

/// A workspace's name state.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Named {
    /// The daemon's name.
    pub name: String,
    /// The explicit workspace title.
    pub title: Option<String>,
    /// Who gave the name.
    pub source: NameSource,
    /// The name's revision (0: never renamed).
    pub revision: u64,
    /// Whether a never-renamed `~` or empty name counts as the namer's on an old daemon.
    #[serde(default = "yes")]
    pub allows_legacy_defaults: bool,
}

fn yes() -> bool {
    true
}

/// Whether a person named the workspace: a title, or a user-sourced name past a created default.
pub fn is_user_named(named: &Named) -> bool {
    if named.title.as_deref().is_some_and(|title| !title.is_empty()) {
        return true;
    }
    if named.source != NameSource::User {
        return false;
    }
    if named.revision == 0 && is_numbered_default_name(&named.name) {
        return false;
    }
    named.revision > 0 || !named.allows_legacy_defaults || !is_default_workspace_name(&named.name)
}

/// The name `front` gives.
pub fn derived(front: &Front) -> Option<String> {
    match front {
        Front::Browser { title, .. } => clean(title.as_deref()),
        Front::Chat { user_name, title, .. } => {
            clean(user_name.as_deref()).or_else(|| clean(title.as_deref()))
        }
        Front::Terminal { tab } => new_name::for_tab(tab),
    }
}

/// The live label of a workspace nobody named: its front tab's name; a page front reads as the
/// tab it was opened from (`anchor`). `None`: the workspace's own name stands.
pub fn label(
    enabled: bool,
    named: &Named,
    front: Option<&Front>,
    anchor: Option<&Front>,
) -> Option<String> {
    if !enabled || is_user_named(named) {
        return None;
    }
    let front = front?;
    if let (Front::Browser { .. }, Some(anchor)) = (front, anchor) {
        return derived(anchor);
    }
    derived(front)
}

/// The facts of a persisted rename.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Persist {
    /// The workspace runs on this Mac's daemon.
    pub is_local_machine: bool,
    /// Its daemon records who named a workspace (`workspace-name-source-v1`).
    pub supports_name_source: bool,
    /// The rename was already sent.
    pub already_renamed: bool,
}

/// The name variant B writes to the daemon: the front chat's generated title, when it differs
/// from the name. A terminal's or page's title is transient and never persisted.
pub fn persisted_name(
    enabled: bool,
    variant: Variant,
    named: &Named,
    front: Option<&Front>,
    persist: &Persist,
) -> Option<String> {
    if !enabled
        || variant != Variant::Persist
        || !(persist.is_local_machine || persist.supports_name_source)
        || persist.already_renamed
        || is_user_named(named)
    {
        return None;
    }
    let Some(Front::Chat { generated_title, .. }) = front else {
        return None;
    };
    let generated = clean(generated_title.as_deref())?;
    (Some(&generated) != clean(Some(&named.name)).as_ref()).then_some(generated)
}

/// A browser tab's facts for its title.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Page {
    /// The tab's own name.
    pub name: Option<String>,
    /// The live page's title.
    pub live_title: Option<String>,
    /// The live page's address.
    pub live_url: Option<String>,
    /// The tab record's title.
    pub title_text: Option<String>,
    /// The tab record's address.
    pub url: Option<String>,
}

/// A browser tab's title for its label: its name, then a title that is not just its address,
/// else its site (`WorkspaceAutoNameReader.pageTitle`).
pub fn page_title(page: &Page) -> Option<String> {
    if let Some(name) = trimmed(page.name.as_deref()) {
        return Some(name.to_owned());
    }
    let url = page.live_url.as_deref().or(page.url.as_deref());
    let live_url = trimmed(url);
    let record_url = trimmed(page.url.as_deref());
    for candidate in [&page.live_title, &page.title_text] {
        if let Some(title) = trimmed(candidate.as_deref())
            && Some(title) != live_url
            && Some(title) != record_url
        {
            return Some(title.to_owned());
        }
    }
    url.and_then(site)
}
