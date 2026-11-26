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
        if (1..path.len()).any(|end| path.get(..end).is_some_and(|p| schema.row_at(p).is_some())) {
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
mod tests {
    use super::*;
    use crate::profile::Profile;
    use serde_json::json;
    use std::collections::BTreeMap;

    /// A row of the settings export, as `settings-schema.json` holds one.
    fn row(key: &str, kind: &str, extra: Value) -> Value {
        let mut row = json!({
            "key": key,
            "path": key.split('.').collect::<Vec<_>>(),
            "section": "appearance",
            "group": { "text": "Look", "key": null },
            "title": { "text": key, "key": null },
            "summary": null,
            "help": null,
            "kind": kind,
            "default": null,
            "default_label": null,
            "keywords": [],
            "agent_settable": true,
            "agent_refusal": null,
            "kept_on_reset_all": false,
            "validation": "portable",
            "accepts": [],
            "refuses": [],
        });
        if let (Value::Object(row), Value::Object(extra)) = (&mut row, extra) {
            row.extend(extra);
        }
        row
    }

    /// The new app: `appearance.glow` is still a toggle, `appearance.size`
    /// became a number, `sidebar.old` is gone and `remote.ultraMode` is
    /// retired for `remote.ultra` (the real retired-keys table).
    fn new_app() -> Schema {
        let range = json!({ "min": 0.0, "max": 10.0, "step": 1.0, "unit": "", "placeholder": 0.0 });
        let choices = json!([
            { "value": "compact", "title": { "text": "Compact", "key": null } },
            { "value": "cozy", "title": { "text": "Cozy", "key": null } },
        ]);
        let document = json!({
            "version": 1,
            "sections": [],
            "rows": [
                row("appearance.glow", "toggle", json!({})),
                row("appearance.size", "number", json!({ "range": range })),
                row("appearance.density", "choice", json!({ "choices": choices })),
                row("remote.ultra", "choice", json!({ "choices": choices })),
            ],
        });
        Schema::parse(&document.to_string()).unwrap()
    }

    fn tables(settings: &Schema) -> Tables<'_> {
        Tables {
            settings,
            command: |id| ["palette.open", "closeTab"].contains(&id),
            colors: ["background", "foreground", "palette"].map(str::to_owned).into(),
            interfaces: ["cmux.section/1"].map(str::to_owned).into(),
        }
    }

    fn entry(name: &str, on: bool, settings: Value, files: &[(&str, &str)]) -> Entry {
        let settings: BTreeMap<String, Value> = serde_json::from_value(settings).unwrap();
        Entry {
            on,
            source: "ask".to_owned(),
            words: Vec::new(),
            thumbnail: Default::default(),
            profile: Profile {
                version: 1,
                name: name.to_owned(),
                description: String::new(),
                created_ms: 0,
                settings,
                files: files.iter().map(|(p, t)| ((*p).to_owned(), (*t).to_owned())).collect(),
            },
            added_ms: None,
            generation: None,
            on_ms: None,
            until_ms: None,
            code: None,
        }
    }

    #[test]
    fn a_removed_and_a_retyped_key_are_named_and_a_valid_one_is_not() {
        let schema = new_app();
        let entries = [entry(
            "x",
            true,
            json!({ "appearance.glow": true, "appearance.size": "large", "sidebar.old": 3 }),
            &[],
        )];
        let found = no_longer_applies(&entries, &tables(&schema));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(
            found[0].line(),
            "settings layer \"x\": 2 keys no longer apply: appearance.size (now a number), sidebar.old (gone)"
        );
        // Nothing is rewritten: the check only reads.
        assert_eq!(entries[0].profile.settings["appearance.size"], json!("large"));
    }

    #[test]
    fn nothing_when_everything_applies_or_the_entry_is_off() {
        let schema = new_app();
        let entries = [
            entry("fine", true, json!({ "appearance.glow": false, "appearance.size": 4 }), &[]),
            entry("off", false, json!({ "sidebar.old": 3 }), &[]),
        ];
        assert_eq!(no_longer_applies(&entries, &tables(&schema)), Vec::new());
    }

    #[test]
    fn a_renamed_key_names_its_new_key_and_a_refused_value_is_never_quoted() {
        let schema = new_app();
        let entries = [entry(
            "y",
            true,
            json!({ "remote.ultraMode": true, "appearance.density": "private-value" }),
            &[],
        )];
        let line = no_longer_applies(&entries, &tables(&schema))[0].line();
        assert_eq!(
            line,
            "settings layer \"y\": 2 keys no longer apply: appearance.density (value no longer accepted), remote.ultraMode (renamed to remote.ultra)"
        );
        assert!(!line.contains("private"), "{line}");
    }

    #[test]
    fn file_keys_are_read_against_the_command_token_and_interface_lists() {
        let schema = new_app();
        let bindings = r#"[
  { "key": "cmd+k", "command": "palette.open" },
  { "key": "cmd+shift+g", "command": "glow.toggle" },
  { "command": "-closeTab" }
]"#;
        let theme = r##"{ "name": "dusk", "colors": { "background": "#000000", "glow": "#ffffff" },
  "appearance": { "glow": true, "size": "big" }, "sidebar": { "old": 1 } }"##;
        let views = r#"{ "implements": { "cmux.section/1": {}, "cmux.gone/1": {} } }"#;
        let entries = [entry(
            "z",
            true,
            json!({}),
            &[
                ("keybindings.json", bindings),
                ("themes/dusk.json", theme),
                ("customize/cmux-app.json", views),
                ("agent-pane/theme.css", ".gone { color: red }"),
            ],
        )];
        let found = no_longer_applies(&entries, &tables(&schema));
        let keys: Vec<String> =
            found[0].keys.iter().map(|s| format!("{} ({})", s.key, s.why)).collect();
        assert_eq!(
            keys,
            [
                "customize/cmux-app.json:cmux.gone/1 (interface gone)",
                "keybindings.json:glow.toggle (command gone)",
                "themes/dusk.json:appearance.size (now a number)",
                "themes/dusk.json:colors.glow (gone)",
                "themes/dusk.json:sidebar.old (gone)",
            ]
        );
        assert!(found[0].line().starts_with("layer \"z\": 5 keys no longer apply: "));
    }

    #[test]
    fn a_file_that_cannot_load_is_named_once() {
        let schema = new_app();
        let entries = [entry("w", true, json!({}), &[("keybindings.json", "{ nope")])];
        assert_eq!(
            no_longer_applies(&entries, &tables(&schema))[0].line(),
            "layer \"w\": 1 key no longer applies: keybindings.json (cannot load)"
        );
    }

    #[test]
    fn this_builds_tables_take_its_own_keys() {
        let tables = Tables::current();
        assert!((tables.command)("palette.open"));
        assert!(!(tables.command)("no.such.action"));
        assert!(tables.colors.contains("background"));
        assert!(tables.interfaces.contains("cmux.section/1"));
        // Every row's own default applies; a key no row has does not.
        for row in &tables.settings.rows {
            if let Some(default) = row.default.as_ref()
                && accepts(row, default, &Domains::default()).is_ok()
            {
                assert_eq!(setting(tables.settings, &row.key, default), None, "{}", row.key);
            }
        }
        assert_eq!(setting(tables.settings, "no.such.key", &json!(1)).as_deref(), Some("gone"));
    }
}
