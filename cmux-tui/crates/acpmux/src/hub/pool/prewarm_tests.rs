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
