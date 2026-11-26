//! `contributes.keybindings` and `onKeybinding`: key bindings an app ships as
//! typed data, in keybindings.json form.

use cmux_app_manifest::keybindings::{AppKeybinding, keybindings};
use cmux_app_manifest::{is_valid, validate_catalog, validate_manifest};
use serde_json::{Value, json};

fn manifest(bindings: Value) -> Value {
    json!({ "manifestVersion": 2, "id": "local/branchy", "name": "Branchy", "version": "1.0.0", "description": "d",
            "engines": { "cmux": "^2.0" }, "icon": "assets/icon.png", "catalog": "catalog.json",
            "runtime": { "main": "main.js" },
            "activation": ["onKeybinding"], "contributes": { "keybindings": bindings } })
}

fn catalog() -> Value {
    json!({ "family": "local.branchy", "operations": [{
        "name": "local.branchy.copy_branch", "owner": "app:local/branchy", "class": "read", "risk": "read",
        "idempotency": "forbidden", "input": { "type": "object" }, "docs": "Copies the branch.", "since": "1"
    }] })
}

fn codes(issues: &[cmux_app_manifest::Issue]) -> Vec<&'static str> {
    issues.iter().map(|i| i.code).collect()
}

#[test]
fn an_own_op_and_a_cmux_action_are_valid() {
    let m = manifest(json!([
        { "key": "cmd+shift+b", "command": "local.branchy.copy_branch" },
        { "key": "ctrl+k s", "command": "newTab", "when": "terminalFocused" }
    ]));
    let issues = validate_manifest(&m);
    assert!(is_valid(&issues), "{issues:?}");
    assert!(!codes(&issues).contains(&"keybindings.shortcutConflict"), "{issues:?}");
    assert!(validate_catalog(&m, &catalog()).is_empty());
    assert_eq!(
        keybindings(&m),
        vec![
            AppKeybinding {
                keys: vec!["cmd+shift+b".into()],
                command: "local.branchy.copy_branch".into(),
                when: None,
                args: None
            },
            AppKeybinding {
                keys: vec!["ctrl+k".into(), "s".into()],
                command: "newTab".into(),
                when: Some("terminalFocused".into()),
                args: None
            },
        ]
    );
}

#[test]
fn a_bad_key_is_refused_by_keybindings_json_rules() {
    // A bare first stroke with no bare-key `when` would eat typing.
    let issues = validate_manifest(&manifest(json!([{ "key": "b", "command": "newTab" }])));
    assert!(!is_valid(&issues));
    assert!(
        issues
            .iter()
            .any(|i| i.code == "keybindings.invalid" && i.path == "/contributes/keybindings/0/key"),
        "{issues:?}"
    );
    let five = json!([{ "key": "cmd+a b c d e", "command": "newTab" }]);
    assert!(!is_valid(&validate_manifest(&manifest(five))));
}

#[test]
fn a_removal_is_the_persons_alone() {
    let issues =
        validate_manifest(&manifest(json!([{ "key": "cmd+t", "command": "-workspace.new" }])));
    assert!(!is_valid(&issues));
    assert!(issues.iter().any(|i| i.path == "/contributes/keybindings/0/command"), "{issues:?}");
}

#[test]
fn a_duplicate_key_and_condition_warns() {
    let m = manifest(json!([
        { "key": "cmd+shift+b", "command": "local.branchy.copy_branch" },
        { "key": "Cmd+Shift+B", "command": "newTab" }
    ]));
    let issues = validate_manifest(&m);
    assert!(is_valid(&issues), "{issues:?}");
    assert!(codes(&issues).contains(&"keybindings.shortcutConflict"), "{issues:?}");
}

#[test]
fn an_op_outside_the_catalog_is_refused() {
    let m = manifest(json!([
        { "key": "cmd+shift+b", "command": "local.branchy.nope" },
        { "key": "cmd+shift+c", "command": "other.app.op" }
    ]));
    let issues = validate_catalog(&m, &catalog());
    assert_eq!(
        codes(&issues),
        ["keybindings.unknownOp", "keybindings.unknownCommand"],
        "{issues:?}"
    );
}

#[test]
fn an_op_without_a_catalog_or_with_args_is_refused() {
    let mut m = manifest(json!([{ "key": "cmd+shift+b", "command": "local.branchy.copy_branch" }]));
    m.as_object_mut().unwrap().remove("catalog");
    assert!(codes(&validate_manifest(&m)).contains(&"keybindings.unknownCommand"));
    let args = manifest(
        json!([{ "key": "cmd+shift+b", "command": "local.branchy.copy_branch", "args": { "x": 1 } }]),
    );
    assert!(codes(&validate_manifest(&args)).contains(&"keybindings.opArgs"));
}

#[test]
fn on_keybinding_needs_bindings() {
    let mut m = manifest(json!([]));
    m["contributes"] = json!({});
    let issues = validate_manifest(&m);
    assert!(codes(&issues).contains(&"activation.noKeybindings"), "{issues:?}");
}

#[test]
fn an_unknown_field_is_refused_by_the_schema() {
    let issues = validate_manifest(&manifest(
        json!([{ "key": "cmd+b", "command": "newTab", "action": "x" }]),
    ));
    assert!(!is_valid(&issues), "{issues:?}");
}
