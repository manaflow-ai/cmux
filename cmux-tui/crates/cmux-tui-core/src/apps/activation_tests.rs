use super::*;
use serde_json::json;

fn package(activation: Value) -> Package {
    Package {
        id: "local/a".into(),
        version: "1.0.0".into(),
        tier: super::super::mirror::Tier::Unverified,
        source: super::super::mirror::Source::Local,
        dir: std::path::PathBuf::new(),
        manifest: json!({ "activation": activation }),
        fragment: None,
    }
}

#[test]
fn reads_on_startup_and_on_event_streams_and_ignores_the_rest() {
    let parsed = Activation::of(&package(json!([
        "onStartup",
        "onEvent:workspace.changed",
        "onEvent:",
        "onInterface:cmux.section/1",
        "onOp:a.go",
        7
    ])));
    assert!(parsed.on_startup);
    assert_eq!(parsed.on_event, BTreeSet::from(["workspace.changed".to_string()]));
    assert!(!Activation::of(&package(Value::Null)).background());
    assert!(!Activation::of(&package(json!(["onInterface:cmux.section/1"]))).background());
}
