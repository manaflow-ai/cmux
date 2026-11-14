use cmux_extension_sdk::{
    API_VERSION, EVENTS, Manifest, RUNTIME_VERSION, Region, SDK_VERSION, SIGNALS, check_package,
    event, is_valid,
};
use serde_json::Value;
use std::path::PathBuf;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn json(path: PathBuf) -> Value {
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn the_rust_table_is_the_json_table_both_sdks_ship() {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let api = json(crate_dir.join("api.json"));
    assert_eq!(api, json(crate_dir.join("typescript/api.json")));
    assert_eq!(api["apiVersion"], API_VERSION);
    assert_eq!(api["runtimeVersion"], RUNTIME_VERSION);
    let events = api["events"].as_object().expect("events");
    assert_eq!(
        events.keys().collect::<Vec<_>>(),
        EVENTS.iter().map(|e| e.name).collect::<Vec<_>>()
    );
    for e in EVENTS {
        assert_eq!(events[e.name]["scope"], e.scope, "{}", e.name);
        assert_eq!(events[e.name]["reads"], e.reads, "{}", e.name);
    }
    let signals = api["signals"].as_object().expect("signals");
    assert_eq!(
        signals.keys().collect::<Vec<_>>(),
        SIGNALS.iter().map(|s| s.name).collect::<Vec<_>>()
    );
}

#[test]
fn the_crate_and_the_typescript_package_carry_one_version() {
    let package = json(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("typescript/package.json"));
    assert_eq!(package["version"], SDK_VERSION);
    let index = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("typescript/src/index.ts"),
    )
    .expect("index.ts");
    assert!(index.contains(&format!("export const SDK_VERSION = \"{SDK_VERSION}\"")));
}

#[test]
fn listening_asks_for_the_events_scope_once_and_refuses_an_unknown_stream() {
    let manifest = Manifest::new("local/x", "X", "0.1.0", "A test.")
        .listen("workspace.changed")
        .and_then(|m| m.listen("pane.changed"))
        .and_then(|m| m.listen("agent_chat.changed"))
        .expect("known streams");
    let scopes = manifest.to_json()["scopes"].clone();
    assert_eq!(
        scopes.as_object().expect("scopes").keys().collect::<Vec<_>>(),
        ["agent_chat:read", "workspace:read"]
    );
    let error =
        Manifest::new("local/x", "X", "0.1.0", "A test.").listen("workspace.chagned").unwrap_err();
    assert!(error.contains("workspace.changed"), "{error}");
    assert_eq!(event("agent.changed").map(|e| e.scope), Some("agent:read"));
}

/// The example extension's manifest, made with the builder: the places, scopes and activation
/// are the ones in examples/extensions/activity/cmux-app.json, and cmux's validator takes both.
#[test]
fn the_builder_makes_the_example_extensions_manifest() {
    let dir = repo().join("examples/extensions/activity");
    let example = json(dir.join("cmux-app.json"));
    let built =
        Manifest::new("local/activity", "Activity", "1.0.0", "Workspaces, agents and chats.")
            .section("renderSection", "Activity", "waveform.path.ecg", Region::Top)
            .pane("renderPane", "Activity feed", "list.bullet.rectangle")
            .listen("workspace.changed")
            .and_then(|m| m.listen("agent.changed"))
            .and_then(|m| m.listen("agent_chat.changed"))
            .expect("known streams")
            .scope("workspace:write", "Show a workspace when you click its row.");
    let issues = built.validate();
    assert!(is_valid(&issues), "{issues:?}");
    let built = built.to_json();
    for key in ["id", "version", "engines", "runtime", "activation"] {
        assert_eq!(built[key], example[key], "{key}");
    }
    let names = |v: &Value| {
        v.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>()).unwrap_or_default()
    };
    assert_eq!(names(&built["implements"]), names(&example["implements"]));
    assert_eq!(names(&built["scopes"]), names(&example["scopes"]));
    for place in ["cmux.section/1", "cmux.pane/1"] {
        assert_eq!(built["implements"][place]["export"], example["implements"][place]["export"]);
    }

    let report = check_package(&dir);
    assert!(report.is_valid(), "{:?}", report.issues);
}
