//! `contributes.keybindings`: shortcuts an app binds to its own catalog ops.

use cmux_app_manifest::{
    RESERVED_KEYBINDINGS, canonical_chord, is_dispatch_chord, is_valid, validate_catalog,
    validate_manifest,
};
use serde_json::{Value, json};

fn manifest(keybindings: Value, activation: Value) -> Value {
    json!({ "manifestVersion": 2, "id": "local/keys", "name": "Keys", "version": "1.0.0", "description": "d",
            "engines": { "cmux": "^2.0" }, "icon": "assets/icon.png", "runtime": { "main": "dist/main.js" },
            "catalog": "catalog.json", "activation": activation, "contributes": { "keybindings": keybindings } })
}

fn catalog() -> Value {
    json!({ "family": "local.keys", "operations": [{
        "name": "local.keys.focus", "owner": "app:local/keys", "class": "read", "risk": "read",
        "idempotency": "forbidden", "input": { "type": "object" }, "docs": "Focuses.", "since": "1", "export": "focus"
    }] })
}

fn binding(id: &str, key: &str) -> Value {
    json!({ "id": id, "key": key, "op": "local.keys.focus", "title": "Focus" })
}

fn codes(issues: &[cmux_app_manifest::Issue]) -> Vec<&'static str> {
    issues.iter().map(|i| i.code).collect()
}

#[test]
fn a_chord_on_an_own_op_is_valid() {
    let m = manifest(
        json!([binding("focus", "cmd+shift+k"), { "id": "esc", "key": "ctrl+escape", "op": "local.keys.focus", "when": "agentPaneFocused" }]),
        json!(["onKeybinding:focus"]),
    );
    let issues = validate_manifest(&m);
    assert!(is_valid(&issues), "{issues:?}");
    assert!(validate_catalog(&m, &catalog()).is_empty());
}

#[test]
fn a_key_without_a_dispatch_modifier_is_refused() {
    for key in ["k", "shift+k"] {
        let issues = validate_manifest(&manifest(json!([binding("focus", key)]), json!([])));
        assert!(!is_valid(&issues), "{key}: {issues:?}");
        assert!(
            issues.iter().any(|i| i.path.starts_with("/contributes/keybindings/0")),
            "{issues:?}"
        );
    }
}

#[test]
fn a_system_chord_is_refused_in_any_spelling() {
    let issues = validate_manifest(&manifest(json!([binding("quit", "cmd+q")]), json!([])));
    assert_eq!(codes(&issues), vec!["keybindings.reserved"]);
    let issues =
        validate_manifest(&manifest(json!([binding("x", "option+cmd+escape")]), json!([])));
    assert_eq!(codes(&issues), vec!["keybindings.reserved"]);
    assert!(RESERVED_KEYBINDINGS.iter().all(|k| is_dispatch_chord(k)));
}

#[test]
fn an_id_or_a_chord_is_declared_once() {
    let twice = manifest(json!([binding("a", "cmd+k"), binding("a", "cmd+j")]), json!([]));
    assert!(codes(&validate_manifest(&twice)).contains(&"keybindings.duplicate"));
    let same =
        manifest(json!([binding("a", "cmd+shift+k"), binding("b", "shift+cmd+k")]), json!([]));
    assert!(codes(&validate_manifest(&same)).contains(&"keybindings.chordTwice"));
    assert_eq!(canonical_chord("shift+opt+cmd+k"), "alt+cmd+shift+k");
}

#[test]
fn on_keybinding_names_a_declared_binding() {
    let m = manifest(json!([binding("focus", "cmd+k")]), json!(["onKeybinding:other"]));
    assert_eq!(codes(&validate_manifest(&m)), vec!["keybindings.unknownActivation"]);
}

#[test]
fn a_binding_needs_an_op_of_the_apps_own_catalog() {
    let unknown =
        manifest(json!([{ "id": "a", "key": "cmd+k", "op": "local.keys.nope" }]), json!([]));
    assert_eq!(codes(&validate_catalog(&unknown, &catalog())), vec!["keybindings.unknownOp"]);
    let foreign =
        manifest(json!([{ "id": "a", "key": "cmd+k", "op": "workspace.close" }]), json!([]));
    assert_eq!(codes(&validate_catalog(&foreign, &catalog())), vec!["keybindings.foreignOp"]);
}

#[test]
fn a_binding_needs_a_catalog() {
    let mut m = manifest(json!([binding("focus", "cmd+k")]), json!([]));
    m.as_object_mut().unwrap().remove("catalog");
    assert!(codes(&validate_manifest(&m)).contains(&"keybindings.noCatalog"));
}
