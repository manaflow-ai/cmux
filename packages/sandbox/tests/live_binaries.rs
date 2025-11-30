use cmux_sandbox::models::{CreateSandboxRequest, ExecRequest};

#[tokio::test]
#[ignore]
async fn test_global_binaries_in_sandbox() {
    let client = reqwest::Client::new();
    let base_url = "http://127.0.0.1:46831";

    // Check health
    let health = client.get(format!("{}/healthz", base_url)).send().await;
    if health.is_err() || !health.unwrap().status().is_success() {
        eprintln!(
            "Server not running at {}, skipping test. Make sure to run ./scripts/reload.sh first.",
            base_url
        );
        return;
    }

    // Create sandbox
    let create_req = CreateSandboxRequest {
        name: Some("binary-check".into()),
        workspace: None,
        tab_id: None,
        read_only_paths: vec![],
        tmpfs: vec![],
        env: vec![],
    };

    let resp = client
        .post(format!("{}/sandboxes", base_url))
        .json(&create_req)
        .send()
        .await
        .expect("Failed to create sandbox");

    if !resp.status().is_success() {
        panic!("Failed to create sandbox: {}", resp.status());
    }

    let summary: serde_json::Value = resp.json().await.expect("Failed to parse sandbox summary");
    let id = summary["id"].as_str().expect("No ID in summary");

    // Test codex-acp with actual args
    let exec_req = ExecRequest {
        command: vec![
            "codex-acp".into(),
            "-c".into(),
            "model=\"gpt-5.1-codex-max\"".into(),
        ],
        workdir: None,
        env: vec![],
    };
    let exec_resp = client
        .post(format!("{}/sandboxes/{}/exec", base_url, id))
        .json(&exec_req)
        .send()
        .await
        .expect("Failed to exec codex-acp");
    let result: serde_json::Value = exec_resp.json().await.expect("Failed to parse");
    println!("codex-acp result: {:?}", result);
    // It might fail because we aren't providing input/connection, but let's see stderr

    // Cleanup
    let _ = client
        .delete(format!("{}/sandboxes/{}", base_url, id))
        .send()
        .await;
}
