//! After an update: which keys of the settings and file entries that are
//! on no longer apply to this app (RFD 0038, phase 1 step 4).
//!
//! The CLI that runs `cmux customize library refresh` and `library status`
//! is the app's own, so its tables are the new app's: the settings schema
//! (`cmux_config::Schema`, the one `cmux customize schema` prints), the
//! retired-keys table, the action catalog's ids (what a keybinding's
//! `command` names), a theme file's color tokens and the interfaces a views
//! app implements. Each entry is read against them and every key that is
//! gone, renamed, retyped or holds a value the app no longer accepts is
//! named. Nothing here writes: the person's values stay as they are, and
//! an entry stays on; the app already skips a key it cannot read.
//!
//! Not checked yet, for want of a list to check against: a stylesheet's
//! selectors (no published part list), an automation's events and ops, and
//! a binding whose chord the app took for a default.

use std::collections::BTreeSet;

use cmux_config::Schema;
use cmux_config::domains::Domains;
use cmux_config::keybindings;
use cmux_config::keypath::key_path;
use cmux_config::schema::{Kind, Row, accepts, replaced_keys};
use cmux_config::{jsonc, theme_file};
use serde::Serialize;
use serde_json::Value;

use super::{Entry, KEYBINDINGS};
use crate::Customize;
use crate::tree::Part;

/// The new app's tables an entry is read against.
pub struct Tables<'a> {
    pub settings: &'a Schema,
    /// Whether a keybinding's `command` is an action the app has.
    pub command: fn(&str) -> bool,
    /// The members a theme file's `colors` may have.
    pub colors: BTreeSet<String>,
    /// The interfaces a views app may implement.
    pub interfaces: BTreeSet<String>,
}

impl Tables<'static> {
    /// This build's tables.
    pub fn current() -> Tables<'static> {
        let settings = Schema::embedded();
        Tables {
            settings,
            command: |id| cmux_action_catalog::find(id).is_some(),
            colors: colors_of(settings),
            interfaces: cmux_app_manifest::KNOWN_INTERFACES
                .iter()
                .map(|name| (*name).to_owned())
                .collect(),
        }
    }
}

/// The members of `colors` in the theme file JSON Schema `settings` writes.
pub fn colors_of(settings: &Schema) -> BTreeSet<String> {
    settings
        .theme_file_json_schema(theme_file::is_look)
        .pointer("/properties/colors/properties")
        .and_then(Value::as_object)
        .map(|colors| colors.keys().cloned().collect())
        .unwrap_or_default()
}

/// One key of an entry that no longer applies.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub struct Stale {
    /// The dotted setting key, `FILE:KEY` for a key in a file, or `FILE`
    /// for a file that does not load.
    pub key: String,
    /// `gone`, `renamed to KEY`, `now a number`, ...
    pub why: String,
    /// It is in one of the entry's files, not its settings.
    #[serde(skip)]
    pub in_file: bool,
}

/// An entry that is on and has keys that no longer apply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NoLongerApplies {
    pub name: String,
    pub keys: Vec<Stale>,
}

impl NoLongerApplies {
    /// `settings layer "x": 2 keys no longer apply: foo.bar (gone), baz (now a number)`.
    pub fn line(&self) -> String {
        let what =
            if self.keys.iter().all(|stale| !stale.in_file) { "settings layer" } else { "layer" };
        let keys: Vec<String> =
            self.keys.iter().map(|stale| format!("{} ({})", stale.key, stale.why)).collect();
        format!(
            "{what} {:?}: {} no longer {}: {}",
            self.name,
            crate::count(self.keys.len(), "key"),
            if self.keys.len() == 1 { "applies" } else { "apply" },
            keys.join(", ")
        )
    }
}

impl Customize {
    /// Every entry that is on with keys this app no longer reads as written;
    /// empty when everything applies or the library does not read (status
    /// says that on its own line).
    pub fn library_no_longer_applies(&self) -> Vec<NoLongerApplies> {
        match self.read_library() {
            Ok(library) => no_longer_applies(&library.entries, &Tables::current()),
            Err(_) => Vec::new(),
        }
    }
}

/// Each entry that is on, top first, with the keys `tables` no longer take.
pub fn no_longer_applies(entries: &[Entry], tables: &Tables<'_>) -> Vec<NoLongerApplies> {
    entries
        .iter()
        .filter(|entry| entry.on)
        .filter_map(|entry| {
            let keys = entry_keys(entry, tables);
            (!keys.is_empty()).then(|| NoLongerApplies { name: entry.name().to_owned(), keys })
        })
        .collect()
}

fn entry_keys(entry: &Entry, tables: &Tables<'_>) -> Vec<Stale> {
    let mut found = Vec::new();
    for (key, value) in &entry.profile.settings {
        // A code entry's web part is no setting.
        if key.starts_with("code:") {
            continue;
        }
        if let Some(why) = setting(tables.settings, key, value) {
            found.push(Stale { key: key.clone(), why, in_file: false });
        }
    }
    for (path, text) in &entry.profile.files {
        let mut add = |key: &str, why: String| {
            let stale = Stale {
                key: if key.is_empty() { path.clone() } else { format!("{path}:{key}") },
                why,
                in_file: true,
            };
            found.push(stale);
        };
        match Part::of(path) {
            Part::Keybindings if path == KEYBINDINGS => keybindings_file(text, tables, &mut add),
            Part::Themes => theme(text, tables, &mut add),
            Part::Views if is_views_manifest(path) => views(text, tables, &mut add),
            // Settings are read above; styles and automations have no
            // list to check against yet (see the module doc).
            _ => {}
        }
    }
    found.sort();
    found.dedup();
    found
}

/// Why the value `value` under `key` no longer applies, or `None` when it does.
fn setting(schema: &Schema, key: &str, value: &Value) -> Option<String> {
    let path = key_path(key);
    let Some(row) = schema.row(key).or_else(|| schema.row_at(&path)) else {
        // A key under a row that holds a map (`appearance.machineColors.x`)
        // is that row's.
        if (1..path.len()).any(|end| schema.row_at(&path[..end]).is_some()) {
            return None;
        }
        return Some(gone(&path));
    };
    value_why(row, value)
}

fn gone(path: &[String]) -> String {
    let renamed = replaced_keys().iter().find(|replaced| replaced.old == path);
    match renamed {
        Some(replaced) => format!("renamed to {}", replaced.row.join(".")),
        None => "gone".to_owned(),
    }
}

/// Why `row` refuses `value`, never quoting the value (it may be a
/// credential typed under the wrong key).
fn value_why(row: &Row, value: &Value) -> Option<String> {
    // Published value domains (themes, fonts, sounds) are the running app's,
    // not this process's: a name is judged by its shape only.
    accepts(row, value, &Domains::default()).err()?;
    let holds: Option<(&[&str], &str)> = match &row.kind {
        Kind::Toggle => Some((&["boolean"], "true or false")),
        Kind::Number(_) => Some((&["number"], "a number")),
        Kind::ChoiceOrNumber(..) => Some((&["string", "number"], "a choice or a number")),
        Kind::Choice(_)
        | Kind::Color
        | Kind::Sound
        | Kind::Url
        | Kind::Theme
        | Kind::FontFamily
        | Kind::Text => Some((&["string"], "text")),
        Kind::HostList
        | Kind::FolderList
        | Kind::StringList
        | Kind::OrderedChoices(_)
        | Kind::NumberList(_) => Some((&["array"], "a list")),
        Kind::StringMap | Kind::SoundRules => Some((&["object"], "an object")),
        // A json row's shape is its own (accepts checked it above).
        Kind::ChoiceOrUrl(..) | Kind::TimeRange | Kind::Json(_) => None,
    };
    Some(match holds {
        Some((types, word)) if !types.contains(&json_type(value)) => format!("now {word}"),
        _ => "value no longer accepted".to_owned(),
    })
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// Every binding's `command` is an action the app has.
fn keybindings_file(text: &str, tables: &Tables<'_>, add: &mut impl FnMut(&str, String)) {
    let parsed = keybindings::parse(text);
    if parsed.diagnostics.iter().any(|d| d.problem == keybindings::Problem::UnreadableFile) {
        return add("", "cannot load".to_owned());
    }
    for entry in parsed.entries {
        if !(tables.command)(&entry.command) {
            add(&entry.command, "command gone".to_owned());
        }
    }
}

/// A theme file read as the app reads one (`cmux_config::theme_file`):
/// its own keys, its colors' tokens and the look settings it sets.
fn theme(text: &str, tables: &Tables<'_>, add: &mut impl FnMut(&str, String)) {
    let Ok(Value::Object(members)) = jsonc::parse(text) else {
        return add("", "cannot load".to_owned());
    };
    for (key, value) in &members {
        if key == "colors" {
            for token in value.as_object().into_iter().flat_map(|colors| colors.keys()) {
                if !tables.colors.contains(token) {
                    add(&format!("colors.{token}"), "gone".to_owned());
                }
            }
        } else if !theme_file::RESERVED_KEYS.contains(&key.as_str()) {
            theme_setting(tables.settings, key_path(key), value, add);
        }
    }
}

fn theme_setting(
    schema: &Schema,
    path: Vec<String>,
    value: &Value,
    add: &mut impl FnMut(&str, String),
) {
    if path.is_empty() {
        return;
    }
    let dotted = path.join(".");
    if let Some(row) = schema.row_at(&path) {
        if !theme_file::is_look(row) {
            return add(&dotted, "no longer a look setting".to_owned());
        }
        if let Some(why) = value_why(row, value) {
            add(&dotted, why);
        }
    } else if let Value::Object(members) = value {
        for (key, value) in members {
            let mut child = path.clone();
            child.push(key.clone());
            theme_setting(schema, child, value, add);
        }
    } else {
        add(&dotted, gone(&path));
    }
}

fn is_views_manifest(path: &str) -> bool {
    path == "customize/cmux-app.json" || path == "customize/cmux-app.v2.json"
}

/// Every interface the views app implements is one this app has.
fn views(text: &str, tables: &Tables<'_>, add: &mut impl FnMut(&str, String)) {
    let Ok(manifest) = jsonc::parse(text) else {
        return add("", "cannot load".to_owned());
    };
    let implements = manifest.get("implements").and_then(Value::as_object);
    for name in implements.into_iter().flat_map(|implements| implements.keys()) {
        if !tables.interfaces.contains(name) {
            add(name, "interface gone".to_owned());
        }
    }
}

#[cfg(test)]
#[path = "applies_tests.rs"]
mod tests;
