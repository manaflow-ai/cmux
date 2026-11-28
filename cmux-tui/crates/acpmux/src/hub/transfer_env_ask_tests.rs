use super::*;

fn hub(dir: &std::path::Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    let profile = json!({"argv": ["true"], "env": {"ANTHROPIC_BASE_URL": "http://x"}});
    cfg.harnesses.insert("claude".into(), serde_json::from_value(profile).unwrap());
    let preset = json!({"harness": "claude", "env": {"OPENAI_API_KEY": "k"}});
    cfg.presets.insert("fast".into(), serde_json::from_value(preset).unwrap());
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

#[tokio::test]
async fn a_hub_move_names_the_recorded_env_its_target_lacks_in_its_answer() {
    let dir = tempfile::tempdir().unwrap();
    let hub = hub(dir.path());
    let manifest = json!({"sessionId": "s1", "session": {"harness": "claude", "name": "lane"}});
    let body = |preset: Value| json!({"envAsk": {"names": ["OPENAI_API_KEY", "GITHUB_TOKEN"], "preset": preset}});
    let ask = hub_ask(&body(json!("fast")), &manifest).unwrap();
    assert_eq!(ask["session"]["harness"], "claude");
    assert_eq!(ask["env"], json!(["OPENAI_API_KEY", "GITHUB_TOKEN"]));
    // Asked under the switch, as a preflight is: the preset there adds one, no one has the other.
    assert_eq!(hub.env_lacking_with(true, &ask, None).await, ["GITHUB_TOKEN"]);
    let bare = hub_ask(&body(Value::Null), &manifest).unwrap();
    assert_eq!(hub.env_lacking_with(true, &bare, None).await, ["GITHUB_TOKEN", "OPENAI_API_KEY"]);
    // A source older than the question sends no names: nothing is asked.
    assert!(hub_ask(&json!({}), &manifest).is_none());
    assert!(hub.env_lacking_for_move(&json!({}), &manifest).await.is_empty());
}
