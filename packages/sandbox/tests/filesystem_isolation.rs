use cmux_sandbox::models::{CreateSandboxRequest, ExecRequest};
use cmux_sandbox::service::SandboxService;
use cmux_sandbox::BubblewrapService;
use tempfile::tempdir;

#[tokio::test]
async fn test_filesystem_isolation() {
    // This test requires Linux, bwrap, ip, and root privileges (for veth creation)
    if which::which("bwrap").is_err() || which::which("ip").is_err() {
        println!("Skipping test: bwrap or ip not found (requires Linux)");
        return;
    }

    // Check for root (rough check)
    if std::process::Command::new("id")
        .arg("-u")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() != "0")
        .unwrap_or(true)
    {
        println!("Skipping test: requires root privileges for network interface management");
        return;
    }

    let tmp_dir = tempdir().unwrap();
    // Use port 0 as we don't strictly need the HTTP back-connect for this test
    let service = BubblewrapService::new(tmp_dir.path().to_path_buf(), 0)
        .await
        .unwrap();

    // 1. Create Sandbox A
    let req_a = CreateSandboxRequest {
        name: Some("sandbox-a".into()),
        workspace: None,
        tab_id: None,
        read_only_paths: vec![],
        tmpfs: vec![],
        env: vec![],
    };
    let summary_a = service
        .create(req_a)
        .await
        .expect("Failed to create sandbox A");

    // 2. Create a marker file in Sandbox A
    let exec_touch = ExecRequest {
        command: vec!["touch".into(), "/workspace/marker".into()],
        workdir: None,
        env: vec![],
    };
    let resp_touch = service
        .exec(summary_a.id.to_string(), exec_touch)
        .await
        .expect("Failed to exec in A");
    assert_eq!(
        resp_touch.exit_code, 0,
        "Failed to touch file: {}",
        resp_touch.stderr
    );

    // 3. Create Sandbox B
    let req_b = CreateSandboxRequest {
        name: Some("sandbox-b".into()),
        workspace: None,
        tab_id: None,
        read_only_paths: vec![],
        tmpfs: vec![],
        env: vec![],
    };
    let summary_b = service
        .create(req_b)
        .await
        .expect("Failed to create sandbox B");

    // 4. Verify marker file does NOT exist in Sandbox B
    let exec_check = ExecRequest {
        command: vec!["ls".into(), "/workspace/marker".into()],
        workdir: None,
        env: vec![],
    };
    let resp_check = service
        .exec(summary_b.id.to_string(), exec_check)
        .await
        .expect("Failed to exec in B");

    // 5. Clean up
    service.delete(summary_a.id.to_string()).await.unwrap();
    service.delete(summary_b.id.to_string()).await.unwrap();

    assert_ne!(
        resp_check.exit_code, 0,
        "File /workspace/marker SHOULD NOT exist in sandbox B"
    );
}
