use super::*;

#[test]
fn name_family_strips_a_short_generation_only() {
    assert_eq!(name_family("dep-fleet-2"), "dep-fleet");
    assert_eq!(name_family("dep-fleet-12"), "dep-fleet");
    assert_eq!(name_family("dep-fleet"), "dep-fleet");
    assert_eq!(name_family("review-27903"), "review-27903");
    assert_eq!(name_family("-2"), "-2");
}

#[test]
fn autocompact_reads_argv_then_env() {
    let argv = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        autocompact(&argv(&["claude", "--autocompact", "400000"]), &[]),
        Some("400000".into())
    );
    assert_eq!(autocompact(&argv(&["claude", "--autocompact=380000"]), &[]), Some("380000".into()));
    let env = BTreeMap::from([("SR2_AUTO_COMPACT_TOKENS".to_owned(), "400000".to_owned())]);
    assert_eq!(
        autocompact(&argv(&["claude"]), &[&env]),
        Some("SR2_AUTO_COMPACT_TOKENS=400000".into())
    );
    assert_eq!(autocompact(&argv(&["claude"]), &[]), None);
}

fn meta(options: Value) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": "p", "name": "p", "harness": "claude-sr2", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1, "configOptions": options,
        "harnessArgv": ["claude"], "spawnArgv": ["sr2", "claude", "--autocompact", "400000"],
    }))
    .unwrap()
}

#[test]
fn harness_from_copies_ultracode_and_codex_reasoning_effort() {
    let opt = |id: &str, v: &str| json!({"id": id, "currentValue": v});
    let claude = meta(json!([opt("effort", "xhigh"), opt("ultracode", "on")]));
    assert_eq!(harness_copy(&claude).effort.as_deref(), Some("ultracode"));
    assert_eq!(harness_copy(&claude).harness.as_deref(), Some("claude-sr2"));
    let codex = meta(json!([opt("reasoning_effort", "high")]));
    assert_eq!(harness_copy(&codex).effort.as_deref(), Some("high"));
}

#[test]
fn the_launcher_and_cap_are_what_it_last_started_with() {
    let s = shape(&meta(json!([])), &Config::default());
    assert_eq!(s.launcher.as_deref(), Some("sr2"));
    assert_eq!(s.autocompact.as_deref(), Some("400000"));
}

#[test]
fn an_unknown_model_or_effort_is_no_difference() {
    let s = |model: Option<&str>| Shape {
        profile: "claude".into(),
        launcher: Some("claude".into()),
        model: model.map(str::to_owned),
        effort: None,
        autocompact: None,
    };
    assert!(differences(&s(Some("opus")), &s(None)).is_empty());
    assert_eq!(differences(&s(Some("opus")), &s(Some("sonnet"))), vec!["model opus -> sonnet"]);
}
