use serde_json::{Value, json};

use super::call;

fn run(op: &str, request: Value) -> Value {
    call(op, &request).expect("known op").expect("ok")
}

#[test]
fn theme_edits_keep_valid_colors_lowercased_and_say_why_the_rest_fail() {
    let root = json!({"appearance": {"themeEdits": {
        "Rose Pine/background": "#ABCDEF",
        "Rose Pine/3": "#000000",
        "Rose Pine/nope": "#000000",
        "Rose Pine/cursor": "red",
        "background": "#000000",
    }}});
    let out = run("theme_edits.parse", json!({"root": root}));
    assert_eq!(out["colors"], json!({"Rose Pine": {"background": "#abcdef", "3": "#000000"}}));
    assert_eq!(out["diagnostics"].as_array().unwrap().len(), 3);
    let none = run("theme_edits.parse", json!({"root": {}}));
    assert_eq!(none, json!({"colors": {}, "diagnostics": []}));
    let bad = run("theme_edits.parse", json!({"root": {"appearance": {"themeEdits": 3}}}));
    assert_eq!(bad["diagnostics"][0]["message"], "expected an object");
}

#[test]
fn computer_use_maps_earlier_modes_and_the_retired_switch() {
    let mode =
        |root: Value| run("computer_use.parse", json!({"root": root}))["values"]["mode"].clone();
    assert_eq!(mode(json!({"computerUse": {"mode": "standard"}})), "fullAccess");
    assert_eq!(mode(json!({"computerUse": {"mode": "bounded"}})), "approvedApps");
    assert_eq!(mode(json!({"computerUse": {"mode": "ask"}})), "askEveryTime");
    assert_eq!(mode(json!({"computerUse": {"enabled": false}})), "off");
    let junk = run("computer_use.parse", json!({"root": {"computerUse": {"mode": "zzz"}}}));
    assert_eq!(junk["diagnostics"][0]["path"], "computerUse.mode");
}

#[test]
fn computer_use_denied_apps_dedupe_and_refuse_non_lists() {
    let out = run(
        "computer_use.parse",
        json!({"root": {"computerUse": {"deniedApps": ["a", "b", "a"]}}}),
    );
    assert_eq!(out["values"]["deniedApps"], json!(["a", "b"]));
    let bad =
        run("computer_use.parse", json!({"root": {"computerUse": {"deniedApps": ["a", ""]}}}));
    assert_eq!(bad["diagnostics"][0]["message"], "expected a list of app ids");
    assert!(
        bad["values"].get("deniedApps").is_none()
            || bad["values"]["deniedApps"] != json!(["a", ""])
    );
}

#[test]
fn migration_drops_the_retired_list_only_when_all_of_it_is_present() {
    let all: Vec<&str> = super::RETIRED_DENIED_APPS.to_vec();
    let mut with_extra = all.clone();
    with_extra.push("com.example.mine");
    let out = run("computer_use.migrated_denied_apps", json!({"list": with_extra}));
    assert_eq!(out["list"], json!(["com.example.mine"]));
    let partial = run("computer_use.migrated_denied_apps", json!({"list": &all[1..]}));
    assert_eq!(partial, json!({}));
}

#[test]
fn computer_use_settings_are_person_only() {
    assert_eq!(
        run("computer_use.person_only", json!({"path": ["computerUse", "mode"]}))["person_only"],
        true
    );
    assert_eq!(run("computer_use.person_only", json!({"path": ["browser"]}))["person_only"], false);
}

#[test]
fn hibernation_modes_and_diagnostics() {
    let read = |browser: Value| run("browser.hibernation", json!({"root": {"browser": browser}}));
    let aggressive = read(json!({"hibernation": "aggressive"}));
    assert_eq!(aggressive["hidden_minutes"], 10.0);
    assert_eq!(aggressive["discards_automatically"], true);
    let minutes = read(json!({"hibernation": 45}));
    assert_eq!(minutes["mode"], "minutes");
    assert_eq!(minutes["hidden_minutes"], 45.0);
    let off = read(json!({"hibernation": "off"}));
    assert_eq!(off["enabled"], false);
    let unset = run("browser.hibernation", json!({"root": {}}));
    assert_eq!(unset["discards_automatically"], false);
    assert_eq!(unset["hidden_minutes"], 30.0);
    let bad =
        read(json!({"hibernation": 0, "keepNeighborTabsAwake": 1.5, "freezeHiddenTabs": "off"}));
    assert_eq!(bad["diagnostics"].as_array().unwrap().len(), 2);
    assert_eq!(bad["freeze_seconds"], Value::Null);
}

#[test]
fn hibernation_exclusions_match_hosts_and_subdomains() {
    let excludes = |host: &str| {
        run(
            "browser.hibernation_excludes",
            json!({"exclusions": ["Example.com", "*.docs.dev"], "host": host}),
        )["excluded"]
            .as_bool()
            .unwrap()
    };
    assert!(excludes("example.com"));
    assert!(excludes("WWW.example.com"));
    assert!(excludes("a.docs.dev"));
    assert!(!excludes("docs.dev"));
    assert!(!excludes("notexample.com"));
    let added =
        run("browser.hibernation_add_exclusion", json!({"exclusions": ["a.com"], "host": "B.com"}));
    assert_eq!(added["exclusions"], json!(["a.com", "b.com"]));
    let again = run(
        "browser.hibernation_add_exclusion",
        json!({"exclusions": ["a.com"], "host": "x.a.com"}),
    );
    assert_eq!(again["exclusions"], json!(["a.com"]));
}

#[test]
fn dictation_shortcuts_need_a_command_control_or_option_modifier() {
    let ok = run("agent_pane.dictation_shortcut", json!({"text": "Cmd + Shift+D"}));
    assert_eq!(ok, json!({"valid": true, "modifiers": ["command", "shift"], "key": "d"}));
    for text in ["shift+d", "d", "cmd+cmd+d", "cmd+", "cmd+f20", "hyper+d"] {
        assert_eq!(
            run("agent_pane.dictation_shortcut", json!({"text": text}))["valid"],
            false,
            "{text}"
        );
    }
}

#[test]
fn reader_section_reads_defaults_and_flags_bad_values() {
    let out = run(
        "settings.reader_section",
        json!({"root": {"appearance": {"colorTransition": {"enabled": "yes", "duration": 99999}}}, "prefix": "appearance.colorTransition"}),
    );
    let messages: Vec<&str> = out["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["message"].as_str().unwrap())
        .collect();
    assert!(messages.contains(&"expected true or false"), "{messages:?}");
    assert!(messages.iter().any(|m| m.starts_with("clamped to ")), "{messages:?}");
    let not_object = run(
        "settings.reader_section",
        json!({"root": {"appearance": {"colorTransition": 3}}, "prefix": "appearance.colorTransition"}),
    );
    assert_eq!(not_object["diagnostics"][0]["message"], "expected an object");
}

#[test]
fn rows_parse_keeps_accepted_keys_and_explains_the_rest() {
    let out = run(
        "settings.rows_parse",
        json!({"root": {"browser": {"wakeTabsOnHover": "x"}}, "keys": ["browser.wakeTabsOnHover"]}),
    );
    assert_eq!(out["diagnostics"][0]["message"], "expected true or false");
    assert_eq!(out["values"], json!({}));
}
