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
