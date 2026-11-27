//! Sidebar looks (`sidebar.look`): the sidebar drawn like another app's
//! (`claude`, `codex`, `studio`, `rex`), or cmux's own (`cmux`, the default).
//!
//! A look is data: a shipped file of ordinary public settings
//! (`Resources/sidebar-looks/<look>.json`, in the theme-file shape), so a
//! person can rebuild or change any look in cmux-next.json with no code.
//! It is the lowest layer above the schema defaults: it fills only the keys
//! that cmux-next.json, the managed layers and the theme file leave unset, so
//! a person's own setting always wins. Swift `SidebarLookPreset`
//! (CmuxNextSettings) reads the same files the same way.
//!
//! A look never moves the pane or a row's height. It may set only
//! [`GRID_KEYS`]: grouping, headings, which marks a row draws and how status
//! shows. Row height, sidebar width, the trailing column and motion stay on
//! the shared grid (`sidebar.density`, `appearance.metrics.*`), so switching
//! looks or reloading one keeps the pane where it is. The tests hold every
//! shipped file to that list.

use serde_json::Value;

use crate::domains::Domains;
use crate::jsonc;
use crate::keypath::{dotted, key_path};
use crate::schema::{Schema, accepts};
use crate::value::{value_at, with_value};

/// The setting that picks the look.
pub const SETTING_KEY: &str = "sidebar.look";
/// An explicit group style overrides the look even when it equals the schema default.
pub(crate) const GROUP_BACKGROUND: &str = "sidebar.groupHeader.background";
/// cmux's own sidebar: no file, nothing filled.
pub const DEFAULT: &str = "cmux";
/// Every look, the default first: the setting's choices.
pub const LOOKS: [&str; 5] = [DEFAULT, "claude", "codex", "studio", "rex"];
/// The folder that holds the look files, in the repository's `Resources`
/// and the app's `Contents/Resources`.
pub const FOLDER_NAME: &str = "sidebar-looks";

/// Keys a look may set: none of them changes a row's height, the sidebar's
/// width, the trailing column or motion (the shared grid,
/// docs/cmux-next/sidebar-customization.md "No shift").
pub const GRID_KEYS: [&str; 13] = [
    "sidebar.groupBy",
    GROUP_BACKGROUND,
    "sidebar.groupHeader.memberCount",
    "sidebar.groupHeader.unreadCount",
    "sidebar.sectionLook",
    "sidebar.workspaceRow.icon",
    "sidebar.showColors",
    "workspaceColors.indicatorStyle",
    "sidebar.showTimestamps",
    "sidebar.detailedStatusIcons",
    "appearance.statusIndicator.style",
    // Where the status mark draws: the row keeps its leading slot while idle, so the name never moves.
    "sidebar.workspaceRow.statusPlacement",
    "sidebar.showSpaces",
];

/// Keys a file reads that are not settings.
const RESERVED_KEYS: [&str; 3] = ["name", "description", "$schema"];

const SHIPPED: [(&str, &str); 4] = [
    ("claude", include_str!("../../../../Resources/sidebar-looks/claude.json")),
    ("codex", include_str!("../../../../Resources/sidebar-looks/codex.json")),
    ("studio", include_str!("../../../../Resources/sidebar-looks/studio.json")),
    ("rex", include_str!("../../../../Resources/sidebar-looks/rex.json")),
];

/// The text of look `name`'s file; `None` for `cmux` or an unknown name.
pub fn shipped(name: &str) -> Option<&'static str> {
    SHIPPED.iter().find(|(look, _)| *look == name).map(|(_, text)| *text)
}

/// The look `root` picks when it is one with a file (not `cmux`, not unknown).
pub fn look_in(root: &Value) -> Option<&str> {
    value_at(root, &key_path(SETTING_KEY))
        .and_then(Value::as_str)
        .filter(|name| shipped(name).is_some())
}

/// One look file read: each value it sets, by key path, in key order, and
/// what it could not take (an unknown key, a refused value, a key off the grid).
#[derive(Debug, Clone, PartialEq)]
pub struct SidebarLook {
    pub name: String,
    pub values: Vec<(Vec<String>, Value)>,
    pub problems: Vec<String>,
}

impl SidebarLook {
    /// Reads `text` as look `name`, nested (`{"sidebar": {"groupBy": ...}}`)
    /// or dotted (`{"sidebar.groupBy": ...}`).
    pub fn read(name: &str, text: &str, schema: &Schema, domains: &Domains) -> SidebarLook {
        let mut look =
            SidebarLook { name: name.to_string(), values: Vec::new(), problems: Vec::new() };
        let root = match jsonc::parse(text) {
            Ok(root @ Value::Object(_)) => root,
            Ok(_) => {
                look.problems.push("root is not an object".to_string());
                return look;
            }
            Err(error) => {
                look.problems.push(error.to_string());
                return look;
            }
        };
        let Value::Object(members) = &root else { return look };
        let mut keys: Vec<&String> = members.keys().collect();
        keys.sort();
        for key in keys.into_iter().filter(|key| !RESERVED_KEYS.contains(&key.as_str())) {
            look.walk(&members[key], key_path(key), schema, domains);
        }
        look.values.sort_by(|a, b| a.0.cmp(&b.0));
        look
    }

    /// The shipped look `name`; `None` for `cmux` or an unknown name.
    pub fn shipped(name: &str, schema: &Schema, domains: &Domains) -> Option<SidebarLook> {
        shipped(name).map(|text| SidebarLook::read(name, text, schema, domains))
    }

    fn walk(&mut self, value: &Value, path: Vec<String>, schema: &Schema, domains: &Domains) {
        if let Some(row) = schema.row_at(&path) {
            if !GRID_KEYS.contains(&row.key.as_str()) {
                self.problems.push(format!("{}: a sidebar look sets only grid keys", row.key));
            } else if let Err(refusal) = accepts(row, value, domains) {
                self.problems.push(format!("{}: {refusal}", row.key));
            } else {
                self.values.retain(|(held, _)| *held != row.path);
                self.values.push((row.path.clone(), value.clone()));
            }
        } else if let Value::Object(members) = value {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort();
            for key in keys {
                let mut child = path.clone();
                child.push(key.clone());
                self.walk(&members[key], child, schema, domains);
            }
        } else {
            self.problems.push(format!("{}: not a cmux setting", dotted(&path)));
        }
    }

    /// `root` with every value of the look whose key `root` leaves unset.
    pub fn filling(&self, root: &Value) -> Value {
        self.values.iter().fold(root.clone(), |root, (path, value)| {
            if value_at(&root, path).is_some() {
                root
            } else {
                with_value(&root, value.clone(), path)
            }
        })
    }
}

/// The shipped look selected by the settings layers above the preset.
pub(crate) fn selected(root: &Value, schema: &Schema, domains: &Domains) -> Option<SidebarLook> {
    look_in(root).and_then(|name| SidebarLook::shipped(name, schema, domains))
}

/// `root` with the look it picks filled in under it (unchanged for `cmux`).
pub fn filled(root: &Value, schema: &Schema, domains: &Domains) -> Value {
    match selected(root, schema, domains) {
        Some(look) => look.filling(root),
        None => root.clone(),
    }
}

#[cfg(test)]
#[path = "sidebar_look_tests.rs"]
mod tests;
