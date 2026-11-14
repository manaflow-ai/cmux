use cmux_extension_sdk::{
    API_VERSION, EVENTS, Manifest, RUNTIME_VERSION, Region, SDK_VERSION, SIGNALS, Severity,
    check_package, event, is_valid,
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
fn the_rust_table_is_the_runtimes_own_tables() {
    let host = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../cmux-app-host");
    let scopes = json(host.join("generated/scopes.json"));
    assert_eq!(scopes["apiVersion"], API_VERSION);
    let runtime = std::fs::read_to_string(host.join("js/src/index.ts")).expect("index.ts");
    assert!(runtime.contains(&format!("export const RUNTIME_VERSION = \"{RUNTIME_VERSION}\"")));
    let events = json(host.join("schema/v2/events.json"));
    let events = events["events"].as_object().expect("events");
    assert_eq!(
        events.keys().collect::<Vec<_>>(),
        EVENTS.iter().map(|e| e.name).collect::<Vec<_>>()
    );
    for e in EVENTS {
        assert_eq!(events[e.name]["reads"], e.reads, "{}", e.name);
        assert_eq!(scopes["ops"][e.reads]["scope"], e.scope, "{}", e.name);
    }
    assert_eq!(event("workspace.changed").map(|e| e.scope), Some("workspace:read"));
    let signals = json(host.join("generated/signals.json"));
    let signals = signals["signals"].as_object().expect("signals");
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

    // dist/main.js is build output (`cmux ext dev` writes it): the only error an unbuilt checkout has.
    let report = check_package(&dir);
    let errors: Vec<_> = report
        .issues
        .iter()
        .filter(|i| i.severity == Severity::Error)
        .map(|i| (i.path.as_str(), i.code))
        .collect();
    assert!(
        errors.is_empty() || errors == [("/runtime/main", "path.missing")],
        "{:?}",
        report.issues
    );
}

/// Composer places are data: the builder writes the slash commands and mention items into the
/// options cmux's validator checks, with no export and no activation, and the validator takes it.
#[test]
fn the_builder_adds_composer_commands_and_mentions_cmux_accepts() {
    let manifest = Manifest::new("local/standup", "Standup", "0.1.0", "Composer commands.")
        .slash_command("standup", "Ask for today's standup", "Write my standup notes.")
        .slash_command("review-pr", "Review a pull request", "Review pull request #")
        .mention("ticket", "ENG-1", "ENG-1 Login fails", Some("ENG-1"))
        .mention("ticket", "ENG-2", "ENG-2 Slow sidebar", None);
    let issues = manifest.validate();
    assert!(is_valid(&issues), "{issues:?}");
    let json = manifest.to_json();
    let commands = &json["implements"]["cmux.composer.command/1"];
    assert_eq!(commands["options"]["commands"][1]["name"], "review-pr");
    assert_eq!(commands["options"]["commands"][0]["insert"], "Write my standup notes.");
    assert!(commands.get("export").is_none());
    let mentions = &json["implements"]["cmux.composer.mention/1"]["options"];
    assert_eq!(mentions["prefix"], "ticket");
    assert_eq!(mentions["items"].as_array().map(Vec::len), Some(2));
    assert!(json.get("activation").is_none(), "data places activate no script: {json}");

    // The same name twice is refused, as cmux refuses it.
    let twice = Manifest::new("local/standup", "Standup", "0.1.0", "Composer commands.")
        .slash_command("standup", "a", "a")
        .slash_command("standup", "b", "b");
    assert!(
        twice.validate().iter().any(|i| i.code == "interface.options.duplicate"),
        "{:?}",
        twice.validate()
    );
}
