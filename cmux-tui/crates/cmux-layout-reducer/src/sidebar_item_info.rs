//! How a sidebar layout item draws when the app has not described it, moved
//! from CmuxNextSidebar `SidebarItemInfo` (Sections/SidebarItemInfo.swift):
//! a built-in's symbol and cmux icon and whether it hides (the App Store
//! until Labs shows it, the Forum while its experiment is off), the look an
//! undescribed reference falls back to (a first-party app keeps its former
//! built-in's look, a closed workspace dims under its stored name or hides),
//! the items of a layout that draw nothing (the bands and the Cmd-1...9
//! order skip the same set), and a profile avatar's initials.
//!
//! Localized words stay in the app: a reply names the built-in whose title
//! and caption the app reads, never the words. The app resolves an icon's
//! SF Symbol fallback from its icon catalog, so a reply names the icon only.
//!
//! Pure, no I/O, over `cmux_layout_reducer_json` op `sidebar_item_info`, one
//! rule per call tagged by `rule`.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub const BUILT_IN_KIND: &str = "built_in";
pub const WORKSPACE_KIND: &str = "workspace";
pub const TAB_KIND: &str = "tab";
pub const ROOM_KIND: &str = "room";
pub const SAVED_GROUP_KIND: &str = "saved_group";
pub const URL_KIND: &str = "url";
pub const APP_KIND: &str = "app";

/// The built-ins a first-party app replaced, whose look it keeps
/// (`SidebarLayoutDocument.firstPartyApps`).
pub const FIRST_PARTY_APPS: [(&str, &str); 2] =
    [("home", "cmux/home"), ("app_store", "cmux/app-store")];

/// One built-in's look: its SF Symbol, its cmux icon (none where the symbol
/// draws) and whether it has a short tile caption (the App Store).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BuiltIn {
    pub name: &'static str,
    pub symbol: &'static str,
    pub icon: Option<&'static str>,
    pub has_caption: bool,
}

const fn built_in(
    name: &'static str,
    symbol: &'static str,
    icon: Option<&'static str>,
    has_caption: bool,
) -> BuiltIn {
    BuiltIn { name, symbol, icon, has_caption }
}

/// Every built-in in `SidebarBuiltIn`'s order. The Chief draws the sparkles
/// symbol, not the icon pack's crown (Lawrence 2026-11-23); Home keeps its
/// house (Lucas 2026-11-23).
pub const BUILT_INS: [BuiltIn; 15] = [
    built_in("home", "house", Some("home"), false),
    built_in("settings", "gearshape", Some("settings"), false),
    built_in("account", "person.crop.circle", Some("account"), false),
    built_in("notifications", "bell", Some("notification"), false),
    built_in("history", "clock.arrow.circlepath", Some("history"), false),
    built_in("bookmarks", "bookmark", Some("bookmark.manager"), false),
    built_in("app_store", "bag", Some("store"), true),
    built_in("new_terminal", "apple.terminal", Some("terminal.new"), false),
    built_in("new_browser", "globe", Some("browser.new"), false),
    built_in("new_agent_chat", "bubble.left.and.text.bubble.right", Some("agent.chat.new"), false),
    built_in("customize", "paintbrush", Some("theme"), false),
    built_in("search_chats", "magnifyingglass", Some("search"), false),
    built_in("chief", "sparkles", None, false),
    built_in("automations", "clock.badge.checkmark", Some("automation"), false),
    built_in("forum", "text.bubble", Some("agent.chat.list"), false),
];

/// The built-in named `name` (a stored raw value), or none (a built-in from
/// a newer client).
pub fn built_in_named(name: &str) -> Option<BuiltIn> {
    BUILT_INS.iter().copied().find(|b| b.name == name)
}

/// The built-in a ref names: a `built_in` ref, or a first-party app (Home and
/// the App Store read as their built-ins until the app registry answers).
pub fn look_of(reference: &Ref) -> Option<BuiltIn> {
    if reference.kind == BUILT_IN_KIND {
        return built_in_named(&reference.value);
    }
    if reference.kind == APP_KIND {
        let (name, _) = FIRST_PARTY_APPS.iter().find(|(_, app)| *app == reference.value)?;
        return built_in_named(name);
    }
    None
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ref {
    pub kind: String,
    pub value: String,
}

/// A layout item as the hidden-items rule reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    #[serde(rename = "ref")]
    pub reference: Ref,
    /// The label stored with the item (a closed workspace's last known name).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    #[serde(default)]
    pub items: Vec<Item>,
}

/// A built-in's presentation (`SidebarBuiltIn.defaultInfo(showsStore:showsForum:)`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuiltInLook {
    pub symbol: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub has_caption: bool,
    pub is_hidden: bool,
}

/// `defaultInfo(showsStore:showsForum:)`: the App Store hides until Labs
/// shows it, the Forum while `experiments.forum` is off.
pub fn built_in_look(b: BuiltIn, shows_store: bool, shows_forum: bool) -> BuiltInLook {
    BuiltInLook {
        symbol: b.symbol.into(),
        icon: b.icon.map(Into::into),
        has_caption: b.has_caption,
        is_hidden: (b.name == "app_store" && !shows_store) || (b.name == "forum" && !shows_forum),
    }
}

/// What an undescribed item draws (`SidebarItemInfo.fallback(for:)`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Face {
    /// The built-in whose look and localized title and caption it takes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub built_in: Option<String>,
    /// The built-in's SF Symbol; none: the app reads the icon's catalog symbol.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// The title when it is not a built-in's: the stored label, else the raw value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub is_missing: bool,
    pub is_hidden: bool,
}

/// The icon an undescribed reference of `kind` draws.
pub fn kind_icon(kind: &str) -> &'static str {
    match kind {
        WORKSPACE_KIND => "workspace",
        TAB_KIND => "terminal",
        ROOM_KIND => "space",
        SAVED_GROUP_KIND => "folder",
        URL_KIND => "browser",
        APP_KIND => "app.generic",
        _ => "icon.missing",
    }
}

/// `fallback(for: LayoutItemRef)`, then `fallback(for: LayoutItem)` when a
/// stored label is given: the built-in's own look, else the raw reference
/// dimmed, titled with the stored label. A workspace item with no stored
/// label hides: a closed workspace never draws as its raw `<session>:<ws_…>`
/// reference (#42372).
pub fn fallback(reference: &Ref, label: Option<&str>, as_item: bool) -> Face {
    let hidden = as_item && reference.kind == WORKSPACE_KIND && label.is_none();
    if let Some(b) = look_of(reference) {
        return Face {
            built_in: Some(b.name.into()),
            symbol: Some(b.symbol.into()),
            icon: b.icon.map(Into::into),
            title: None,
            is_missing: false,
            is_hidden: hidden,
        };
    }
    let title = match label {
        Some(label) if as_item => label.to_string(),
        _ => reference.value.clone(),
    };
    Face {
        built_in: None,
        symbol: None,
        icon: Some(kind_icon(&reference.kind).into()),
        title: Some(title),
        is_missing: true,
        is_hidden: hidden,
    }
}

/// `hiddenItems(in:infos:)`: the ids `infos` hides, and every undescribed
/// workspace item with no stored label. Sorted, so a reply is stable.
pub fn hidden_items(sections: &[Section], infos: &BTreeMap<String, bool>) -> Vec<String> {
    let mut hidden: BTreeSet<String> =
        infos.iter().filter(|(_, hides)| **hides).map(|(id, _)| id.clone()).collect();
    for item in sections.iter().flat_map(|s| &s.items) {
        if item.label.is_none()
            && item.reference.kind == WORKSPACE_KIND
            && !infos.contains_key(&item.id)
        {
            hidden.insert(item.id.clone());
        }
    }
    hidden.into_iter().collect()
}

/// `SidebarAvatar.initial(of:)`: the first letter or digit, uppercased; "?"
/// without one.
pub fn initial(name: &str) -> String {
    match name.chars().find(|c| c.is_alphanumeric()) {
        Some(c) => c.to_uppercase().collect(),
        None => "?".into(),
    }
}

/// `SidebarAvatar.initials(for:)`: the first letters of the first and last
/// words ("Leo Li" is "LL"), of an email's local part; "?" without a word.
pub fn initials(name: &str) -> String {
    let local = if name.contains('@') { name.split('@').next().unwrap_or("") } else { name };
    let firsts: Vec<char> = local.split_whitespace().filter_map(|w| w.chars().next()).collect();
    let (Some(first), Some(last)) = (firsts.first(), firsts.last()) else {
        return "?".into();
    };
    let letters: String =
        if firsts.len() > 1 { [*first, *last].iter().collect() } else { first.to_string() };
    letters.to_uppercase()
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Avatar {
    pub initial: String,
    pub initials: String,
    /// The email an account avatar shows as its tooltip when the name is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Request {
    BuiltIn {
        built_in: String,
        #[serde(default)]
        shows_store: bool,
        #[serde(default)]
        shows_forum: bool,
    },
    Fallback {
        #[serde(rename = "ref")]
        reference: Ref,
        /// Present: `fallback(for: LayoutItem)` with this stored label (null: none).
        #[serde(default)]
        item: Option<ItemLabel>,
    },
    HiddenItems {
        #[serde(default)]
        sections: Vec<Section>,
        /// Each described item's id and whether its info hides it.
        #[serde(default)]
        infos: BTreeMap<String, bool>,
    },
    Avatar {
        name: String,
        #[serde(default)]
        email: Option<String>,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemLabel {
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reply {
    BuiltIn { look: Option<BuiltInLook> },
    Face { face: Face },
    Hidden { hidden: Vec<String> },
    Avatar { avatar: Avatar },
}

pub fn respond(request: &Request) -> Reply {
    match request {
        Request::BuiltIn { built_in, shows_store, shows_forum } => Reply::BuiltIn {
            look: built_in_named(built_in).map(|b| built_in_look(b, *shows_store, *shows_forum)),
        },
        Request::Fallback { reference, item } => Reply::Face {
            face: fallback(
                reference,
                item.as_ref().and_then(|i| i.label.as_deref()),
                item.is_some(),
            ),
        },
        Request::HiddenItems { sections, infos } => {
            Reply::Hidden { hidden: hidden_items(sections, infos) }
        }
        Request::Avatar { name, email } => Reply::Avatar {
            avatar: Avatar {
                initial: initial(name),
                initials: initials(name),
                email: email.clone().or_else(|| name.contains('@').then(|| name.clone())),
            },
        },
    }
}

#[cfg(test)]
#[path = "sidebar_item_info_tests.rs"]
mod tests;
