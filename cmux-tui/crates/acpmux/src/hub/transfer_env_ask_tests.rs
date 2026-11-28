use super::*;

fn hub(dir: &std::path::Path) -> Arc<Hub> {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"argv": ["true"], "env": {"ANTHROPIC_BASE_URL": "http://x"}}},
        "presets": {"fast": {"harness": "claude", "env": {"OPENAI_API_KEY": "k"}}},
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Local;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, dir).unwrap())
}

#[tokio::test]
async fn a_target_names_the_recorded_env_a_start_there_would_lack() {
    let dir = tempfile::tempdir().unwrap();
    let hub = hub(dir.path());
    let asked = |preset: Value| {
        json!({"sessionId": "s1", "session": {"harness": "claude"}, "preset": preset,
               "env": ["ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "GITHUB_TOKEN", "CLAUDE_CONFIG_DIR"]})
    };
    let before = crate::session_manifest::env_lacking_at_move();
    // Its preset there adds one; the profile has another; no one has the third. The store
    // home is set by each start, never asked.
    assert_eq!(hub.env_lacking_with(true, &asked(json!("fast")), None).await, ["GITHUB_TOKEN"]);
    assert_eq!(
        hub.env_lacking_with(true, &asked(Value::Null), None).await,
        ["GITHUB_TOKEN", "OPENAI_API_KEY"]
    );
    assert!(crate::session_manifest::env_lacking_at_move() >= before + 2);
    // Off here: nothing is built or said.
    assert!(hub.env_lacking_with(false, &asked(json!("fast")), None).await.is_empty());
    // A harness this daemon has no profile for: the admission refuses it, nothing is said here.
    assert!(hub.env_lacking_with(true, &asked(Value::Null), Some("nope")).await.is_empty());
    // Nothing recorded: nothing asked.
    let none = json!({"sessionId": "s1", "session": {"harness": "claude"}});
    assert!(hub.env_lacking_with(true, &none, None).await.is_empty());
}
