use cmux_sandbox::models::{CreateSandboxRequest, ExecRequest};
use cmux_sandbox::service::SandboxService;
use cmux_sandbox::BubblewrapService;
use std::process::Command;
use tempfile::tempdir;

#[tokio::test]
async fn test_network_connectivity_apt_update() {
    // Prerequisites check
    if which::which("bwrap").is_err()
        || which::which("ip").is_err()
        || which::which("iptables").is_err()
    {
        println!("Skipping test: bwrap, ip, or iptables not found");
        return;
    }
    // check root
    if Command::new("id")
        .arg("-u")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() != "0")
        .unwrap_or(true)
    {
        println!("Skipping test: requires root");
        return;
    }

    let tmp_dir = tempdir().unwrap();
    // Use port 0 as we don't strictly need the HTTP back-connect for this test
    let service = BubblewrapService::new(tmp_dir.path().to_path_buf(), 0)
        .await
        .unwrap();

    // 1. Create Sandbox
    let req = CreateSandboxRequest {
        name: Some("net-test".into()),
        workspace: None,
        tab_id: None,
        read_only_paths: vec![],
        tmpfs: vec![],
        env: vec![],
    };
    let summary = service.create(req).await.expect("Failed to create sandbox");

    // 2. Try to reach the internet (DNS + HTTP) via apt-get update
    // We accept exit code 0 (success) or fail.
    let exec = ExecRequest {
        command: vec!["apt-get".into(), "update".into(), "-y".into()],
        workdir: None,
        env: vec![],
    };

    let resp = service
        .exec(summary.id.to_string(), exec)
        .await
        .expect("Exec failed");

    println!("Stdout: {}", resp.stdout);
    println!("Stderr: {}", resp.stderr);

    assert_eq!(
        resp.exit_code, 0,
        "apt-get update failed, network likely broken"
    );

    // Cleanup
    service.delete(summary.id.to_string()).await.unwrap();
}
