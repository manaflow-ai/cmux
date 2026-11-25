//! Pins Swift `ShortcutKeymapPreset`, `ShortcutDigitScheme`,
//! `ClassicShortcutImport`, `SettingsController+Keymap` and the keyboard
//! switches (`CommandDigitsSetting`, `SwapCmdTAndCmdNSetting`,
//! `app.globalHotKey`, `app.startAgentGlobalHotKey`) before the move, case by
//! case, including the cases of Swift `ClassicShortcutsUpgradeTests`,
//! `ShortcutKeymapFileTests` and `CommandDigitsSettingTests`.

use serde_json::{Map, Value, json};

use super::*;
use crate::app_ops;

fn map(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap()
}

fn op(name: &str, request: Value) -> Value {
    app_ops::call(name, &request).unwrap()
}

fn changes(plan: &Plan) -> Vec<(&str, Option<&Value>)> {
    plan.changes.iter().map(|(id, write)| (id.as_str(), write.as_ref())).collect()
}

// MARK: presets

#[test]
fn every_preset_overrides_something_but_cmux() {
    assert_eq!(
        op("keymap.presets", json!({}))["presets"],
        json!(["cmux", "iterm2", "terminal", "tmux"])
    );
    assert!(Preset::Cmux.overrides().is_empty());
    for preset in [Preset::ITerm2, Preset::Terminal, Preset::Tmux] {
        assert!(!preset.overrides().is_empty(), "{}", preset.name());
        for (id, value) in preset.overrides() {
            assert!(shortcut::parse(&value).is_some(), "{id}");
        }
    }
}

#[test]
fn a_fresh_file_takes_every_override_in_preset_order() {
    let plan = Preset::ITerm2.plan(&Map::new());
    let written: Vec<&str> = plan.changes.iter().map(|(id, _)| id.as_str()).collect();
    assert_eq!(
        written,
        [
            "selectSurfaceByNumber",
            "selectWorkspaceByNumber",
            "toggleTerminalCopyMode",
            "resizePaneLeft",
            "resizePaneRight",
            "resizePaneUp",
            "resizePaneDown",
        ]
    );
    assert!(plan.kept.is_empty());
    assert_eq!(plan.changes[0].1, Some(json!("cmd+1")));
}

#[test]
fn switching_presets_removes_the_old_ones_bindings() {
    let mut bindings = Map::new();
    for (id, value) in Preset::Terminal.overrides() {
        bindings.insert(id.to_owned(), value);
    }
    let plan = Preset::Cmux.plan(&bindings);
    assert_eq!(changes(&plan), [("closeOtherTabsInPane", None), ("renameTab", None)]);
    assert_eq!(
        plan.edits(),
        [
            json!({"path": ["shortcuts", "bindings", "closeOtherTabsInPane"]}),
            json!({"path": ["shortcuts", "closeOtherTabsInPane"]}),
            json!({"path": ["shortcuts", "bindings", "renameTab"]}),
            json!({"path": ["shortcuts", "renameTab"]}),
        ]
    );
    // To tmux: terminal's two go, tmux's take their place.
    let plan = Preset::Tmux.plan(&bindings);
    assert!(plan.changes.contains(&("closeOtherTabsInPane".to_owned(), None)));
    assert!(plan.changes.contains(&("newTab".to_owned(), Some(json!(["ctrl+b", "c"])))));
}

#[test]
fn a_binding_set_by_hand_is_kept() {
    let bindings = map(json!({"selectSurfaceByNumber": "cmd+shift+9", "renameTab": "cmd+shift+r"}));
    let plan = Preset::ITerm2.plan(&bindings);
    assert_eq!(plan.kept, ["selectSurfaceByNumber"]);
    assert!(!plan.changes.iter().any(|(id, _)| id == "selectSurfaceByNumber"));
    // cmux removes only what a preset wrote.
    let plan = Preset::Cmux.plan(&bindings);
    assert!(plan.changes.is_empty());
    assert!(plan.kept.is_empty());
}

#[test]
fn a_hand_typed_preset_value_counts_as_the_presets_and_compares_parsed() {
    // `opt+cmd+1` is iTerm2's `cmd+opt+1`, so tmux may replace it.
    let bindings = map(json!({"selectWorkspaceByNumber": "opt+cmd+1"}));
    let plan = Preset::Tmux.plan(&bindings);
    assert!(plan.kept.is_empty());
    assert!(
        plan.changes
            .contains(&("selectWorkspaceByNumber".to_owned(), Some(json!(["ctrl+b", "1"]))))
    );
    // Already on the value: no change.
    let plan = Preset::ITerm2.plan(&bindings);
    assert!(!plan.changes.iter().any(|(id, _)| id == "selectWorkspaceByNumber"));
}

#[test]
fn the_active_preset() {
    assert_eq!(Preset::active(&Map::new()), Some(Preset::Cmux));
    let mut bindings = Map::new();
    for (id, value) in Preset::Tmux.overrides() {
        bindings.insert(id.to_owned(), value);
    }
    assert_eq!(Preset::active(&bindings), Some(Preset::Tmux));
    // One of another preset's on top: mixed.
    bindings.insert("renameTab".to_owned(), json!("cmd+shift+i"));
    assert_eq!(Preset::active(&bindings), None);
    // A hand binding of an action no preset touches is still cmux.
    assert_eq!(Preset::active(&map(json!({"newWindow": "cmd+shift+n"}))), Some(Preset::Cmux));
    // A hand binding over a preset action blocks nothing (it is kept), so the preset stays active.
    let mut terminal = map(json!({"closeOtherTabsInPane": "cmd+opt+w"}));
    terminal.insert("renameTab".to_owned(), json!("cmd+shift+e"));
    assert_eq!(Preset::active(&terminal), Some(Preset::Terminal));
    assert_eq!(op("keymap.active", json!({"bindings": terminal}))["preset"], json!("terminal"));
}

#[test]
fn plan_op_wire_shape() {
    let reply =
        op("keymap.plan", json!({"preset": "terminal", "bindings": {"renameTab": "cmd+r"}}));
    assert_eq!(
        reply,
        json!({
            "changes": [{"action": "closeOtherTabsInPane", "write": "cmd+opt+w"}],
            "kept": ["renameTab"],
            "edits": [{"path": ["shortcuts", "bindings", "closeOtherTabsInPane"], "value": "cmd+opt+w"}],
        })
    );
    assert!(matches!(
        app_ops::call("keymap.plan", &json!({"preset": "emacs"})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        app_ops::call("keymap.plan", &json!({"preset": "cmux", "bindings": []})),
        Err(OpError::Invalid(_))
    ));
}

// MARK: digit scheme

#[test]
fn tabs_is_the_default_scheme_and_writes_nothing() {
    assert_eq!(DigitScheme::active(&Map::new()), Some(DigitScheme::Tabs));
    let plan = DigitScheme::Tabs.plan(&Map::new());
    assert!(plan.changes.is_empty() && plan.kept.is_empty());
}

#[test]
fn spaces_writes_both_and_tabs_removes_them() {
    let plan = DigitScheme::Spaces.plan(&Map::new());
    assert_eq!(
        changes(&plan),
        [
            ("space.selectByNumber", Some(&json!("ctrl+1"))),
            ("selectSurfaceByNumber", Some(&json!("ctrl+opt+1"))),
        ]
    );
    let spaces =
        map(json!({"space.selectByNumber": "ctrl+1", "selectSurfaceByNumber": "ctrl+opt+1"}));
    assert_eq!(DigitScheme::active(&spaces), Some(DigitScheme::Spaces));
    let back = DigitScheme::Tabs.plan(&spaces);
    assert_eq!(changes(&back), [("space.selectByNumber", None), ("selectSurfaceByNumber", None)]);
    assert_eq!(op("keymap.digit_active", json!({"bindings": spaces}))["scheme"], json!("spaces"));
}

#[test]
fn a_digit_value_typed_by_hand_compares_parsed() {
    // `opt+ctrl+1` is the catalog default of Spaces: on tabs already.
    let bindings = map(json!({"space.selectByNumber": "opt+ctrl+1"}));
    assert_eq!(DigitScheme::active(&bindings), Some(DigitScheme::Tabs));
    // And it is a scheme's value, so spaces replaces it.
    let plan = DigitScheme::Spaces.plan(&bindings);
    assert!(plan.kept.is_empty());
    assert_eq!(plan.changes.len(), 2);
}

#[test]
fn another_digit_value_stays_and_no_scheme_is_active() {
    // iTerm2's Cmd-1 on tabs.
    let bindings = map(json!({"selectSurfaceByNumber": "cmd+1"}));
    let plan = DigitScheme::Spaces.plan(&bindings);
    assert_eq!(plan.kept, ["selectSurfaceByNumber"]);
    assert_eq!(changes(&plan), [("space.selectByNumber", Some(&json!("ctrl+1")))]);
    assert_eq!(DigitScheme::active(&bindings), None);
    let reply = op("keymap.digit_plan", json!({"scheme": "spaces", "bindings": bindings}));
    assert_eq!(reply["kept"], json!(["selectSurfaceByNumber"]));
}

// MARK: bindings and the keymap file

#[test]
fn bindings_merge_over_the_legacy_keys() {
    let shortcuts = json!({
        "newTab": "cmd+t",
        "renameTab": "cmd+r",
        "bindings": {"renameTab": "cmd+shift+r"},
        "tiers": {}, "when": {}, "showModifierHoldHints": true,
    });
    assert_eq!(
        op("keymap.bindings", json!({"shortcuts": shortcuts}))["bindings"],
        json!({"newTab": "cmd+t", "renameTab": "cmd+shift+r"})
    );
    assert_eq!(op("keymap.bindings", json!({}))["bindings"], json!({}));
}

#[test]
fn a_keymap_file_imports_its_shortcuts_and_two_app_keys() {
    let file = json!({
        "app": {"keyStyle": "vim", "shortcutLayout": "qwertyPositions", "uiScale": 1.2},
        "shortcuts": {"bindings": {"newTab": "cmd+shift+t"}, "tiers": {"x": 1}},
    });
    assert_eq!(
        import_edits(&file).unwrap(),
        [
            json!({"path": ["app", "keyStyle"], "value": "vim"}),
            json!({"path": ["app", "shortcutLayout"], "value": "qwertyPositions"}),
            json!({"path": ["shortcuts", "bindings"], "value": {"newTab": "cmd+shift+t"}}),
            json!({"path": ["shortcuts", "tiers"], "value": {"x": 1}}),
        ]
    );
}

#[test]
fn bare_keymap_forms() {
    // A bare shortcuts object.
    assert_eq!(
        import_edits(&json!({"bindings": {"a": "cmd+a"}})).unwrap(),
        [json!({"path": ["shortcuts", "bindings"], "value": {"a": "cmd+a"}})]
    );
    // A bare bindings object.
    assert_eq!(
        import_edits(&json!({"newTab": "cmd+t"})).unwrap(),
        [json!({"path": ["shortcuts", "bindings"], "value": {"newTab": "cmd+t"}})]
    );
    // An app-only file writes no bindings; an empty one nothing.
    assert_eq!(
        import_edits(&json!({"app": {"keyStyle": "emacs"}})).unwrap(),
        [json!({"path": ["app", "keyStyle"], "value": "emacs"})]
    );
    assert!(import_edits(&json!({})).unwrap().is_empty());
    assert_eq!(
        app_ops::call("keymap.import_edits", &json!({"value": [1]})),
        Err(OpError::Invalid("keymap must be a JSON object".to_owned()))
    );
}

// MARK: classic shortcuts

/// A shortcut as classic's Settings recorder stored it (`StoredShortcut`).
fn stored(key: &str, mods: &str, chord_key: Option<&str>) -> String {
    let mut object = json!({
        "key": key,
        "command": mods.contains('c'), "shift": mods.contains('s'),
        "option": mods.contains('o'), "control": mods.contains('t'),
        "chordCommand": false, "chordShift": false, "chordOption": false, "chordControl": false,
    });
    if let Some(chord_key) = chord_key {
        object["chordKey"] = json!(chord_key);
    }
    object.to_string()
}

#[test]
fn classic_strokes_and_chords() {
    assert_eq!(
        classic_binding(&stored("b", "cot", None)),
        Some(
            json!({"first": {"key": "b", "command": true, "shift": false, "option": true, "control": true}})
        )
    );
    assert_eq!(
        classic_binding(&stored("b", "t", Some("p"))),
        Some(json!({
            "first": {"key": "b", "command": false, "shift": false, "option": false, "control": true},
            "second": {"key": "p", "command": false, "shift": false, "option": false, "control": false},
        }))
    );
    // The chord's modifiers come from the `chord*` fields.
    let text =
        json!({"key": "k", "control": true, "chordKey": "x", "chordShift": true}).to_string();
    assert_eq!(classic_binding(&text).unwrap()["second"]["shift"], json!(true));
    // An empty chord key is one stroke.
    assert!(classic_binding(&stored("k", "c", Some(""))).unwrap().get("second").is_none());
}

#[test]
fn classic_empty_key_is_an_unbind_and_media_keys_stay_behind() {
    let cleared = classic_binding(&stored("", "", None)).unwrap();
    assert_eq!(shortcut::parse(&cleared), Some(Binding::Unbound));
    assert_eq!(classic_binding(&stored("media.playpause", "", None)), None);
    // A named key next knows comes over as written.
    let left = classic_binding(&stored("left", "c", None)).unwrap();
    assert_eq!(left["first"]["key"], json!("left"));
    assert_eq!(classic_binding(&stored("k", "c", Some("media.next"))), None);
    assert_eq!(classic_binding("not json"), None);
    assert_eq!(classic_binding("[1]"), None);
    // Missing modifiers are off; 0 and 1 read as Foundation bridges them.
    assert_eq!(
        classic_binding(r#"{"key": "k", "command": 1, "shift": 0}"#).unwrap()["first"],
        json!({"key": "k", "command": true, "shift": false, "option": false, "control": false})
    );
}

#[test]
fn classic_first_source_with_any_wins() {
    let stable = json!({"other": "x", "shortcut.bogus": "not json"});
    let nightly = json!({
        "shortcut.toggleSidebar": stored("b", "cot", None),
        "shortcut.focusLeft": stored("media.playpause", "", None),
        "shortcut.closeTab": stored("", "", None),
        "notShortcut.x": stored("z", "c", None),
    });
    let rc = json!({"shortcut.newTab": stored("t", "c", None)});
    let found = classic_bindings(&[stable, nightly, rc]);
    let mut ids: Vec<&String> = found.keys().collect();
    ids.sort();
    assert_eq!(ids, ["closeTab", "toggleSidebar"]);
    let reply = op("keymap.classic_bindings", json!({"sources": [{}, {}]}));
    assert_eq!(reply["bindings"], json!({}));
    assert_eq!(
        op("keymap.classic_binding", json!({"text": stored("y", "cot", None)}))["binding"]["first"]
            ["key"],
        json!("y")
    );
}

// MARK: keyboard switches

#[test]
fn switch_defaults() {
    assert_eq!(
        settings(&json!({})),
        json!({
            "commandDigits": "workspaces", "swapCmdTAndCmdN": false,
            "globalHotKey": false, "startAgentGlobalHotKey": false, "diagnostics": [],
        })
    );
}

#[test]
fn switch_values() {
    let reply = op(
        "keymap.settings",
        json!({"root": {
            "tabs": {"commandDigits": "tabs", "swapCmdTAndCmdN": true},
            "app": {"globalHotKey": true, "startAgentGlobalHotKey": true},
        }}),
    );
    assert_eq!(reply["commandDigits"], json!("tabs"));
    assert_eq!(reply["swapCmdTAndCmdN"], json!(true));
    assert_eq!(reply["globalHotKey"], json!(true));
    assert_eq!(reply["startAgentGlobalHotKey"], json!(true));
    assert_eq!(reply["diagnostics"], json!([]));
}

#[test]
fn a_bad_switch_is_the_default_plus_a_diagnostic() {
    let reply = settings(&json!({
        "tabs": {"commandDigits": "spaces", "swapCmdTAndCmdN": "yes"},
        "app": {"globalHotKey": 1, "startAgentGlobalHotKey": null},
    }));
    assert_eq!(reply["commandDigits"], json!("workspaces"));
    assert_eq!(reply["swapCmdTAndCmdN"], json!(false));
    assert_eq!(reply["globalHotKey"], json!(false));
    assert_eq!(
        reply["diagnostics"],
        json!([
            {"kind": "invalidValue", "path": "app.globalHotKey", "message": "expected true or false"},
            {"kind": "invalidValue", "path": "app.startAgentGlobalHotKey", "message": "expected true or false"},
            {"kind": "invalidValue", "path": "tabs.swapCmdTAndCmdN", "message": "expected true or false"},
            {"kind": "invalidValue", "path": "tabs.commandDigits",
             "message": "expected one of \"workspaces\", \"tabs\""},
        ])
    );
}
