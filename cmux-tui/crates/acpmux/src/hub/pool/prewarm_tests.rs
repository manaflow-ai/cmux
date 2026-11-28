use super::*;
use crate::agent_credentials::AgentCredential;

#[tokio::test]
async fn saved_cloud_keys_and_claude_tokens_are_declined_before_the_pool_queues_a_start() {
    let root = tempfile::tempdir().unwrap();
    let store = crate::store::LocalStore::new(root.path().join("sessions"), 64 * 1024).unwrap();
    let hub = Hub::new(crate::config::Config::default(), Box::new(store));
    hub.enable_agent_hosts();
    assert!(hub.pool_enabled().await);

    for (harness, variable, value) in [
        ("claude", "ANTHROPIC_API_KEY", "fixture-key"),
        ("claude", "ANTHROPIC_AUTH_TOKEN", "sk-ant-oat-fixture"),
        ("claude", "CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat-fixture"),
        ("codex", "OPENAI_API_KEY", "fixture-key"),
        ("gemini", "GEMINI_API_KEY", "fixture-key"),
        ("gemini", "GOOGLE_API_KEY", "fixture-key"),
        ("grok", "XAI_API_KEY", "fixture-key"),
    ] {
        let credential = AgentCredential::parse(&json!({"env":{(variable):value}})).unwrap();
        let request = PrewarmRequest {
            harness: Some(harness.to_owned()),
            cwd: Some(root.path().to_path_buf()),
            shape: PrewarmShape { credential: Some(credential), ..Default::default() },
            ..Default::default()
        };
        let reply = hub.prewarm(request).await.unwrap();
        assert_eq!(reply, json!({"accepted": false}), "{variable}");
    }
}

/// A Claude token naming its owner's connection binding is warmed: a withdrawal of the binding
/// reaches the entry (`pool_withdraw_bindings`), so a saved-token Cloud start no longer always
/// runs its harness's `session/new` cold.
#[tokio::test]
async fn a_bound_claude_token_is_accepted_and_its_withdrawal_supersedes_the_hint() {
    let root = tempfile::tempdir().unwrap();
    let store = crate::store::LocalStore::new(root.path().join("sessions"), 64 * 1024).unwrap();
    let hub = Hub::new(crate::config::Config::default(), Box::new(store));
    hub.enable_agent_hosts();
    let binding = format!("claude-token:{}", "a".repeat(64));
    for variable in ["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
        let credential = AgentCredential::parse(
            &json!({"env":{(variable):"sk-ant-oat-fixture"},"connection":binding}),
        )
        .unwrap();
        assert_eq!(credential.connection(), Some(binding.as_str()));
        let request = PrewarmRequest {
            harness: Some("claude".to_owned()),
            cwd: Some(root.path().to_path_buf()),
            shape: PrewarmShape { credential: Some(credential), ..Default::default() },
            ..Default::default()
        };
        let reply = hub.prewarm(request).await.unwrap();
        assert_eq!(reply, json!({"accepted": true}), "{variable}");
        // The hint is still in its debounce: the withdrawal supersedes it, so it never starts.
        let before = hub.pool.hint_gen.load(Ordering::SeqCst);
        hub.pool_withdraw_bindings(&[binding.as_str()].into_iter().collect());
        assert_eq!(hub.pool.hint_gen.load(Ordering::SeqCst), before + 1);
    }
}
