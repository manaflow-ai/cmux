use super::*;
use crate::agent_credentials::AgentCredential;

#[tokio::test]
async fn native_cloud_keys_are_declined_before_the_pool_queues_a_start() {
    let root = tempfile::tempdir().unwrap();
    let store = crate::store::LocalStore::new(root.path().join("sessions"), 64 * 1024).unwrap();
    let hub = Hub::new(crate::config::Config::default(), Box::new(store));
    hub.enable_agent_hosts();
    assert!(hub.pool_enabled().await);

    for (harness, variable) in
        [("gemini", "GEMINI_API_KEY"), ("gemini", "GOOGLE_API_KEY"), ("grok", "XAI_API_KEY")]
    {
        let credential =
            AgentCredential::parse(&json!({"env":{(variable):"fixture-key"}})).unwrap();
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
