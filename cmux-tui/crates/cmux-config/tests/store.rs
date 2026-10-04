//! The reducer: writes, resets, reset all (ported from Swift
//! `SettingsWriteTests`), idempotency, revisions, the agent policy, domains,
//! team policy, reloads and reads.

mod common;

use cmux_config::store::REPLAY_CAPACITY;
use cmux_config::{
    DiagnosticKind, FileRead, ManagedSource, Op, Origin, Target, TeamPolicyLayer, apply,
};
use common::{file_value, forced, meta, path, reset, reset_all, set, set_with, state};
use serde_json::json;

#[test]
fn writes_valid_values_and_removes_emptied_objects() {
    let start = state("{\n  // mine\n  \"actions\": {}\n}\n", Default::default());
    let written = apply(&start, set("layout.panePadding", json!(8))).unwrap();
    assert_eq!(file_value(&written.state, &path("layout.panePadding")), Some(json!(8)));
    assert_eq!(written.outcome.keys, vec!["layout.panePadding".to_string()]);
    let reset = apply(&written.state, reset("layout.panePadding")).unwrap();
    assert_eq!(file_value(&reset.state, &path("layout")), None);
    assert!(reset.state.source().contains("// mine"));
    assert_eq!(reset.state.revision(), 2);
}

#[test]
fn refuses_values_the_schema_refuses() {
    let start = state("{}", Default::default());
    let refusal = apply(&start, set("ui.animationSpeed", json!("warp"))).unwrap_err();
    assert_eq!(refusal.code(), "invalid_params");
    assert!(refusal.data()["accepted"]["choices"].is_array());
    let number = apply(&start, set("layout.panePadding", json!(10_000))).unwrap_err();
    assert!(number.data()["accepted"]["range"]["max"].is_number());
}

#[test]
fn reset_all_keeps_what_the_schema_does_not_own() {
    let start = state(
        r#"{
          "ui": { "animationSpeed": "off", "surfaceTabBar": { "buttons": [] } },
          "layout": { "paneBorder": "none" },
          "shortcuts": { "showModifierHoldHints": false, "bindings": { "newTab": "cmd+t" }, "splitRight": "cmd+\\" },
          "actions": { "hello": { "command": "echo hi" } },
          "appearance": { "theme": "Nord", "density": "compact" }
        }"#,
        forced(&[("appearance.density", json!("compact"))]),
    );
    let done = apply(&start, reset_all()).unwrap().state;
    let value = |key: &str| file_value(&done, &path(key));
    assert_eq!(value("ui.animationSpeed"), None);
    assert!(value("ui.surfaceTabBar").is_some());
    assert_eq!(value("layout"), None);
    assert_eq!(value("shortcuts.bindings"), None);
    assert_eq!(value("shortcuts.splitRight"), None);
    assert_eq!(value("shortcuts.showModifierHoldHints"), Some(json!(false)));
    assert!(value("actions").is_some());
    assert_eq!(value("appearance.theme"), Some(json!("Nord")), "kept on reset all");
    assert_eq!(value("appearance.density"), Some(json!("compact")), "managed keys stay");
}

#[test]
fn an_idempotency_key_replays_and_refuses_other_params() {
    let start = state("{}", Default::default());
    let op = set_with("ui.animationSpeed", json!("off"), meta(Origin::Cli, Some("op-1"), None));
    let first = apply(&start, op.clone()).unwrap();
    assert!(!first.outcome.replayed);
    let replay = apply(&first.state, op).unwrap();
    assert!(replay.outcome.replayed);
    assert_eq!(replay.outcome.revision, first.outcome.revision);
    assert_eq!(replay.outcome.keys, first.outcome.keys);
    assert!(replay.changes.is_empty() && replay.write.is_none());
    assert_eq!(replay.state.revision(), first.state.revision());
    // The same request spelled as a key path is the same params.
    let as_path = Op::Set {
        target: Target::Path(path("ui.animationSpeed")),
        value: json!("off"),
        meta: meta(Origin::Cli, Some("op-1"), None),
    };
    assert!(apply(&first.state, as_path).unwrap().outcome.replayed);
    let other = set_with("ui.animationSpeed", json!("fast"), meta(Origin::Cli, Some("op-1"), None));
    let conflict = apply(&first.state, other).unwrap_err();
    assert_eq!(conflict.code(), "idempotency_conflict");
    assert_eq!(conflict.data()["committed_operation"], json!("settings.set"));
    let other_op = Op::Reset {
        target: Target::Key("ui.animationSpeed".into()),
        meta: meta(Origin::Cli, Some("op-1"), None),
    };
    assert_eq!(apply(&first.state, other_op).unwrap_err().code(), "idempotency_conflict");
    const { assert!(REPLAY_CAPACITY >= 4096) };
}

#[test]
fn if_revision_must_match() {
    let start = state("{}", Default::default());
    let stale = set_with("ui.animationSpeed", json!("off"), meta(Origin::Cli, None, Some(7)));
    let refusal = apply(&start, stale).unwrap_err();
    assert_eq!(refusal.code(), "revision_conflict");
    assert_eq!(refusal.data(), json!({"expected": 7, "actual": 0}));
    let fresh = set_with("ui.animationSpeed", json!("off"), meta(Origin::Cli, None, Some(0)));
    assert_eq!(apply(&start, fresh).unwrap().state.revision(), 1);
}

#[test]
fn a_write_that_changes_nothing_keeps_the_revision() {
    let start = state("{\"ui\": {\"animationSpeed\": \"off\"}}", Default::default());
    let same = apply(&start, set("ui.animationSpeed", json!("off"))).unwrap();
    assert_eq!(same.state.revision(), 0);
    assert!(same.changes.is_empty() && same.write.is_none());
    let absent = apply(&start, reset("layout.panePadding")).unwrap();
    assert_eq!(absent.state.revision(), 0);
}

#[test]
fn origin_mcp_is_limited_to_agent_settable_rows() {
    let start = state("{}", Default::default());
    let mcp = |key: Option<&str>| meta(Origin::Mcp, key, None);
    let raw = apply(&start, set_with("shortcuts.bindings.newTab", json!("cmd+t"), mcp(None)))
        .unwrap_err();
    assert_eq!(raw.code(), "agent_refused");
    assert_eq!(raw.data()["reason"], json!(null));
    let privacy =
        apply(&start, set_with("history.terminalCommands", json!(true), mcp(None))).unwrap_err();
    assert_eq!(privacy.code(), "agent_refused");
    assert_eq!(privacy.data()["reason"], json!("privacy"));
    let reset_privacy =
        Op::Reset { target: Target::Key("history.terminalCommands".into()), meta: mcp(None) };
    assert_eq!(apply(&start, reset_privacy).unwrap_err().code(), "agent_refused");
    assert_eq!(
        apply(&start, Op::ResetAll { meta: mcp(None) }).unwrap_err().code(),
        "agent_refused"
    );
    assert!(apply(&start, set_with("ui.animationSpeed", json!("off"), mcp(None))).is_ok());
    // The CLI may write non-schema paths.
    let cli = apply(&start, set("shortcuts.bindings.newTab", json!("cmd+t"))).unwrap();
    assert_eq!(file_value(&cli.state, &path("shortcuts.bindings.newTab")), Some(json!("cmd+t")));
}

#[test]
fn non_schema_paths_are_raw_but_guarded() {
    let start = state("{}", forced(&[("browser.newTabPage", json!("https://corp.example"))]));
    assert_eq!(apply(&start, set("browser.newTabPage.x", json!(1))).unwrap_err().code(), "managed");
    assert_eq!(apply(&start, set("browser", json!({"x": 1}))).unwrap_err().code(), "managed");
    let elsewhere = apply(&start, set("actions.hello", json!({"command": "echo hi"}))).unwrap();
    assert_eq!(
        file_value(&elsewhere.state, &path("actions.hello.command")),
        Some(json!("echo hi"))
    );
}

#[test]
fn writes_that_overlap_a_row_are_refused() {
    let start =
        state("{\"appearance\": {\"backgroundOpacity\": 0.5} // keep\n}", Default::default());
    // An ancestor object would replace rows without validating them.
    let ancestor = apply(&start, set("appearance", json!({"backgroundOpacity": "garbage"})));
    assert_eq!(ancestor.unwrap_err().code(), "invalid_params");
    // A path below a row would turn the row's value into an object.
    let below = apply(&start, set("appearance.backgroundOpacity.x", json!(1)));
    assert_eq!(below.unwrap_err().code(), "invalid_params");
    // Paths with no row above or below stay writable.
    assert!(apply(&start, set("actions.hello", json!({"command": "echo hi"}))).is_ok());
}

#[test]
fn an_unreadable_file_refuses_writes_and_keeps_forced_values() {
    let good = state(
        "{\"layout\": {\"stripScrollbar\": \"always\"}}",
        forced(&[("ui.animationSpeed", json!("off"))]),
    );
    let (broken, change) = good.reload(FileRead::Text("{ not json".into()), good.managed().clone());
    let change = change.expect("the diagnostic is visible");
    assert_eq!(change.origin, Origin::File);
    let effective = &broken.effective().root;
    assert_eq!(effective.pointer("/layout/stripScrollbar"), Some(&json!("always")));
    assert_eq!(effective.pointer("/ui/animationSpeed"), Some(&json!("off")));
    assert!(
        broken.effective().diagnostics.iter().any(|d| d.kind == DiagnosticKind::UnreadableFile)
    );
    assert_eq!(
        apply(&broken, set("layout.panePadding", json!(8))).unwrap_err().code(),
        "file_unreadable"
    );
    assert_eq!(apply(&broken, reset_all()).unwrap_err().code(), "file_unreadable");
    let fresh = state("{ broken", forced(&[("ui.animationSpeed", json!("off"))]));
    assert_eq!(fresh.effective().root.pointer("/ui/animationSpeed"), Some(&json!("off")));
}

#[test]
fn reloads_report_only_visible_changes() {
    let start = state("{\"ui\": {\"animationSpeed\": \"off\"}}", Default::default());
    let (same, none) = start.reload(
        FileRead::Text("// note\n{\"ui\": {\"animationSpeed\": \"off\"}}".into()),
        Default::default(),
    );
    assert!(none.is_none());
    assert_eq!(same.revision(), 0);
    let (next, change) = same.reload(
        FileRead::Text("{\"ui\": {\"animationSpeed\": \"fast\"}}".into()),
        Default::default(),
    );
    let change = change.unwrap();
    assert_eq!((change.revision, change.keys), (1, vec!["ui.animationSpeed".to_string()]));
    let (_, managed_change) = next.reload(
        FileRead::Text(next.source().into()),
        forced(&[("ui.animationSpeed", json!("off"))]),
    );
    assert_eq!(managed_change.unwrap().keys, vec!["ui.animationSpeed".to_string()]);
}

#[test]
fn published_domains_validate_domain_kinds() {
    let start = state("{\"appearance\": {\"theme\": \"Dracula\"}}", Default::default());
    assert!(start.effective().diagnostics.is_empty());
    let published = apply(
        &start,
        Op::DomainsPublish { themes: vec!["Nord".into()], font_families: vec![], sounds: vec![] },
    )
    .unwrap();
    let diagnostics = &published.state.effective().diagnostics;
    assert!(
        diagnostics
            .iter()
            .any(|d| d.kind == DiagnosticKind::InvalidValue && d.path == "appearance.theme")
    );
    assert_eq!(published.state.revision(), 1, "the new diagnostic is visible");
    // The snapshot carries the published domains so pages can offer them.
    let snapshot = published.state.snapshot().to_json();
    assert_eq!(snapshot["domains"]["themes"], json!(["Nord"]));
    assert_eq!(snapshot["domains"]["sounds"], json!(null));
    assert_eq!(
        apply(&published.state, set("appearance.theme", json!("Dracula"))).unwrap_err().code(),
        "invalid_params"
    );
    assert!(apply(&published.state, set("appearance.theme", json!("Nord"))).is_ok());
    let theme_row = published
        .state
        .list(Some("appearance"))
        .into_iter()
        .find(|row| row.row.key == "appearance.theme")
        .unwrap();
    assert_eq!(
        theme_row.value, None,
        "an invalid stored value falls back to the (derived) default"
    );
}

#[test]
fn team_policy_manages_keys_and_ignores_stale_versions() {
    let start = state("{}", Default::default());
    let layer = |version: i64, value: &str| TeamPolicyLayer {
        team_name: "Acme".into(),
        enforced: [("ui.animationSpeed".to_string(), json!(value))].into_iter().collect(),
        team_id: "team_1".into(),
        version,
        ..Default::default()
    };
    let applied = apply(&start, Op::TeamPolicySet { layer: layer(2, "off") }).unwrap();
    assert_eq!(applied.changes[0].keys, vec!["ui.animationSpeed".to_string()]);
    let managed = applied.state.effective().managed_keys.get("ui.animationSpeed").cloned();
    assert_eq!(managed, Some(ManagedSource::Team("Acme".into())));
    let refusal = apply(&applied.state, set("ui.animationSpeed", json!("fast"))).unwrap_err();
    assert_eq!(refusal.data()["reason"], json!("ui.animationSpeed is managed by Acme"));
    let stale = apply(&applied.state, Op::TeamPolicySet { layer: layer(1, "normal") }).unwrap();
    assert!(stale.changes.is_empty());
    assert_eq!(stale.state.effective().root.pointer("/ui/animationSpeed"), Some(&json!("off")));
}

#[test]
fn reads_report_values_defaults_and_managers() {
    let start = state(
        "{\"ui\": {\"animationSpeed\": \"off\"}, \"actions\": {\"a\": 1}}",
        forced(&[("appearance.density", json!("compact"))]),
    );
    let snapshot = start.snapshot();
    let json = snapshot.to_json();
    assert_eq!(json["revision"], json!(0));
    assert_eq!(json["managed"]["appearance.density"]["source"], json!("mdm"));
    assert_eq!(json["file"]["actions"], json!({"a": 1}));
    assert_eq!(json["schema_hash"].as_str().map(str::len), Some(64));
    let rows = start.list(None);
    assert_eq!(rows.len(), start.schema().rows.len());
    let speed = rows.iter().find(|row| row.row.key == "ui.animationSpeed").unwrap();
    assert!(speed.customized);
    assert_eq!(speed.value, Some(json!("off")));
    let density = rows.iter().find(|row| row.row.key == "appearance.density").unwrap().to_json();
    assert_eq!(
        density["managed"]["reason"],
        json!("appearance.density is managed by your organization")
    );
    assert_eq!(density["value"], json!("compact"));
    assert!(density.get("accepts").is_none());
    let got = start.get(&Target::Key("actions.a".into()));
    assert_eq!((got.value.clone(), got.row.is_none()), (Some(json!(1)), true));
    let covered = start.get(&Target::Key("appearance".into()));
    assert_eq!(covered.managed.map(|(key, _)| key), Some("appearance.density".to_string()));
}

#[test]
fn a_retired_key_is_refused_as_removed_and_a_reset_cleans_it_up() {
    let start = state(
        r#"{"appearance": {"tabBarBackground": "darker", "density": "compact"}}"#,
        Default::default(),
    );
    let refusal = apply(&start, set("appearance.tabBarBackground", json!("darker"))).unwrap_err();
    assert_eq!(refusal.code(), "removed");
    assert!(refusal.to_string().starts_with("appearance.tabBarBackground was removed: "));
    let cleaned = apply(&start, reset("appearance.tabBarBackground")).unwrap().state;
    assert_eq!(file_value(&cleaned, &path("appearance.tabBarBackground")), None);
    assert_eq!(file_value(&cleaned, &path("appearance.density")), Some(json!("compact")));
    assert!(start.effective().diagnostics.is_empty(), "a retired key loads without a diagnostic");
}
