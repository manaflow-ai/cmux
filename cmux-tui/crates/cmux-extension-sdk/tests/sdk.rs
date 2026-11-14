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
    for stream in ["settings.changed", "theme.changed"] {
        assert_eq!(event(stream).map(|e| e.scope), Some("settings:read"), "{stream}");
    }
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

/// A whole New Tab page (`cmux.newtab/1`, picked with `tabs.newTabApp`): the builder writes the
/// place, its activation and the scope a launcher's buttons need, and cmux's validator takes it.
#[test]
fn the_builder_makes_a_whole_new_tab_page_cmux_loads() {
    let manifest = Manifest::new("local/launcher", "Launcher", "0.1.0", "A calm New Tab page.")
        .new_tab("renderNewTab", "Launcher", "house")
        .scope(
            "actions:run",
            "Open a chat, a terminal or a browser tab when you click its button.",
        );
    let issues = manifest.validate();
    assert!(is_valid(&issues), "{issues:?}");
    let json = manifest.to_json();
    assert_eq!(json["implements"]["cmux.newtab/1"]["export"], "renderNewTab");
    assert_eq!(json["activation"], serde_json::json!(["onInterface:cmux.newtab/1"]));
    let index = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("typescript/src/index.ts"),
    )
    .expect("index.ts");
    assert!(
        index.contains("export function newTab("),
        "the TypeScript package names the place too"
    );
}

/// A chat widget (`cmux.chat.widget/1`): the builder writes the place, the tools it answers and
/// its activation, and cmux's validator takes it; a pattern that would answer every call is refused.
#[test]
fn the_builder_makes_a_chat_widget_cmux_loads() {
    let manifest =
        Manifest::new("local/pr-card", "PR card", "0.1.0", "A pull request, in the chat.")
            .chat_widget(
                "renderCard",
                "Pull request",
                "arrow.triangle.pull",
                &["mcp__github__*pull_request*"],
            )
            .scope("actions:run", "Open the pull request when you click it.");
    let issues = manifest.validate();
    assert!(is_valid(&issues), "{issues:?}");
    let built = manifest.to_json();
    assert_eq!(built["implements"]["cmux.chat.widget/1"]["export"], "renderCard");
    assert_eq!(
        built["implements"]["cmux.chat.widget/1"]["options"]["tools"],
        serde_json::json!(["mcp__github__*pull_request*"])
    );
    assert_eq!(built["activation"], serde_json::json!(["onInterface:cmux.chat.widget/1"]));

    let every = Manifest::new("local/greedy", "Greedy", "0.1.0", "d").chat_widget(
        "renderCard",
        "All",
        "star",
        &["*"],
    );
    assert!(!is_valid(&every.validate()), "a widget may not answer every tool call");

    // The example widget (examples/extensions/pr-card) is the one cmux's validator takes; its
    // dist/main.js is build output, the only error an unbuilt checkout has.
    let dir = repo().join("examples/extensions/pr-card");
    let example = json(dir.join("cmux-app.json"));
    assert_eq!(example["implements"]["cmux.chat.widget/1"]["export"], "renderCard");
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

    let index = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("typescript/src/index.ts"),
    )
    .expect("index.ts");
    assert!(
        index.contains("export function chatWidget("),
        "the TypeScript package names the place too"
    );
}
