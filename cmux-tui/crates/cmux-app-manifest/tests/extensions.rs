//! Manifest v2 extensions (app-platform.md 12.5): scope classes, catalog
//! fragments, interface options, requires, openWith, notices, and every
//! first-party app package.

use cmux_app_manifest::{
    Issue, ScopeClass, Severity, is_valid, scope_info, validate_catalog, validate_manifest,
    validate_package_file,
};
use serde_json::{Value, json};
use std::path::Path;

fn manifest(extra: Value) -> Value {
    let mut m = json!({ "manifestVersion": 2, "id": "local/x", "name": "X", "version": "1.0.0", "description": "d", "engines": { "cmux": "^2.0" } });
    for (k, v) in extra.as_object().expect("object") {
        m[k] = v.clone();
    }
    m
}

fn codes(issues: &[Issue]) -> Vec<(&'static str, Severity)> {
    issues.iter().map(|i| (i.code, i.severity)).collect()
}

#[test]
fn every_scope_in_the_grammar_has_a_class() {
    let cases = [
        ("git:read", ScopeClass::Standard, false),
        ("integration:github:read", ScopeClass::Standard, false),
        ("embed:run", ScopeClass::Standard, false),
        ("storage:synced", ScopeClass::Standard, false),
        ("git:write", ScopeClass::Sensitive, false),
        ("host:control", ScopeClass::Sensitive, false),
        ("agent_cli:execute", ScopeClass::Sensitive, false),
        ("net:*.github.com", ScopeClass::Sensitive, false),
        ("actions:run", ScopeClass::Sensitive, false),
        ("feed:answer", ScopeClass::Restricted, false),
        ("terminal:input", ScopeClass::Restricted, false),
        ("fs:write", ScopeClass::Restricted, false),
        ("usage:read", ScopeClass::Restricted, false),
        ("mcp:expose", ScopeClass::Restricted, false),
        ("clipboard:write", ScopeClass::Restricted, false),
        ("coderouter:keys", ScopeClass::Restricted, false),
        ("process:spawn:sr", ScopeClass::Restricted, true),
        ("op:coderouter.accounts.usage", ScopeClass::Sensitive, true),
    ];
    for (scope, class, server_only) in cases {
        let info = scope_info(scope).unwrap_or_else(|| panic!("{scope} has no class"));
        assert_eq!((info.class, info.server_only), (class, server_only), "{scope}");
    }
    assert!(scope_info("nonsense").is_none());
}

#[test]
fn restricted_scopes_warn_for_third_party_apps_only() {
    let scopes = json!({ "feed:answer": "Answer what you tap." });
    let third = manifest(
        json!({ "id": "octo/x", "repository": "https://github.com/octo/x", "scopes": scopes }),
    );
    let issues = validate_manifest(&third);
    assert_eq!(codes(&issues), vec![("scope.restricted", Severity::Warning)]);
    assert!(is_valid(&issues));
    let first = manifest(
        json!({ "id": "cmux/x", "repository": "https://github.com/manaflow-ai/cmux", "scopes": scopes }),
    );
    assert!(validate_manifest(&first).is_empty());
}

#[test]
fn process_spawn_needs_a_native_server() {
    let js = manifest(json!({ "server": { "kind": "js", "instances": "user", "hosts": ["local"],
        "scopes": { "process:spawn:sr": "Run sr." } } }));
    let got = codes(&validate_manifest(&js));
    assert!(got.contains(&("scope.processSpawn", Severity::Error)), "{got:?}");
}

#[test]
fn interface_options_follow_the_interface_schema() {
    let m = manifest(json!({ "runtime": { "main": "m.js" }, "implements": {
        "cmux.status/1": { "export": "s", "options": { "placement": "statusStrip" } },
        "cmux.pane/1": { "export": "p", "options": { "anything": true } } } }));
    let issues = validate_manifest(&m);
    let got: Vec<_> = issues.iter().map(|i| (i.path.as_str(), i.code)).collect();
    assert_eq!(got, vec![("/implements/cmux.pane~11/options", "interface.options")]);
}

#[test]
fn open_with_names_an_implemented_interface() {
    let m = manifest(
        json!({ "openWith": [{ "interface": "cmux.editor/1", "types": ["public.text"] }] }),
    );
    assert_eq!(codes(&validate_manifest(&m)), vec![("openWith.notImplemented", Severity::Error)]);
}

fn op(extra: Value) -> Value {
    let mut o = json!({ "name": "demo.save", "owner": "app:local/x", "class": "mutation", "risk": "mutate-own",
        "idempotency": "required", "input": { "type": "object" }, "docs": "Save.", "since": "demo/1" });
    for (k, v) in extra.as_object().expect("object") {
        o[k] = v.clone();
    }
    o
}

#[test]
fn catalog_ops_carry_keyboard_gesture_and_presets() {
    let m = manifest(json!({ "runtime": { "main": "m.js" } }));
    let catalog = json!({ "family": "demo", "operations": [
        op(json!({ "export": "save", "keyboard": [{ "key": "cmd+s", "when": "paneFocused:editor && !readOnly" }],
            "gesture": "required",
            "palette": { "title": "Save", "presets": [{ "id": "hour", "title": "Save for an hour", "args": { "minutes": 60 }, "when": "paneFocused:editor" }] } })),
    ] });
    assert!(validate_catalog(&m, &catalog).is_empty());
}

#[test]
fn catalog_rules_tie_ops_to_the_manifest() {
    let m = manifest(json!({}));
    let catalog = json!({ "family": "demo", "operations": [
        op(json!({ "export": "save", "keyboard": [{ "key": "cmd+s" }] })),
        op(json!({ "owner": "app:local/y", "keyboard": [{ "key": "cmd+s" }] })),
        op(json!({ "name": "other.thing" })),
    ] });
    let issues = validate_catalog(&m, &catalog);
    let got: Vec<_> = issues.iter().map(|i| (i.path.as_str(), i.code)).collect();
    assert_eq!(
        got,
        vec![
            ("/catalog/operations/0/export", "runtime.main.required"),
            ("/catalog/operations/1/owner", "catalog.owner"),
            ("/catalog/operations/1/name", "catalog.duplicate"),
            ("/catalog/operations/1/keyboard/0", "catalog.shortcutConflict"),
            ("/catalog/operations/2/name", "catalog.family"),
        ]
    );
}

#[test]
fn catalog_structure_is_checked() {
    let m = manifest(json!({}));
    let bad = json!({ "family": "demo", "operations": [op(json!({ "keyboard": [{ "key": "hyper+s" }], "gesture": "always" }))] });
    let issues = validate_catalog(&m, &bad);
    assert!(!issues.is_empty() && issues.iter().all(|i| i.code == "catalog.schema"), "{issues:?}");
}

#[test]
fn every_first_party_app_package_validates() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../first-party-apps");
    let mut checked = 0;
    for entry in std::fs::read_dir(&root).expect("first-party-apps") {
        let dir = entry.expect("entry").path();
        if !dir.join("cmux-app.v2.json").exists() {
            continue;
        }
        let report = validate_package_file(&dir, "cmux-app.v2.json");
        let errors: Vec<_> =
            report.issues.iter().filter(|i| i.severity == Severity::Error).collect();
        assert!(errors.is_empty(), "{}: {errors:?}", dir.display());
        checked += 1;
    }
    assert!(checked >= 14, "only {checked} first-party apps have a v2 manifest");
}
