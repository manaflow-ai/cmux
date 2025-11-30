use cmux_sandbox::models::{CreateSandboxRequest, ExecRequest};
use cmux_sandbox::service::SandboxService;
use cmux_sandbox::BubblewrapService;
use std::process::Command;
use tempfile::tempdir;

#[tokio::test]
async fn test_package_isolation() {
    // Prerequisites check
    if which::which("bwrap").is_err() || which::which("ip").is_err() {
        println!("Skipping test: bwrap or ip not found");
        return;
    }
    if which::which("apt-get").is_err() {
        println!("Skipping test: apt-get not found");
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
    let summary_a = service.create(req_a).await.expect("Failed to create A");

    // 2. Update apt (needed for install)
    let update_exec = ExecRequest {
        command: vec!["apt-get".into(), "update".into(), "-y".into()],
        workdir: None,
        env: vec![],
    };
    let update_resp = service
        .exec(summary_a.id.to_string(), update_exec)
        .await
        .expect("Exec update failed");
    assert_eq!(
        update_resp.exit_code, 0,
        "apt-get update failed: {}",
        update_resp.stderr
    );

    // 3. Install a package (we use 'hello' or 'dos2unix' or something small)
    // 'hello' is a standard gnu package often used for testing.
    let install_exec = ExecRequest {
        command: vec![
            "apt-get".into(),
            "install".into(),
            "-y".into(),
            "hello".into(),
        ],
        workdir: None,
        env: vec![],
    };
    let install_resp = service
        .exec(summary_a.id.to_string(), install_exec)
        .await
        .expect("Exec install failed");
    assert_eq!(
        install_resp.exit_code, 0,
        "apt-get install hello failed: {}",
        install_resp.stderr
    );

    // 4. Verify 'hello' works in A
    let verify_a = ExecRequest {
        command: vec!["hello".into()],
        workdir: None,
        env: vec![],
    };
    let verify_resp_a = service
        .exec(summary_a.id.to_string(), verify_a)
        .await
        .expect("Exec hello in A failed");
    assert_eq!(
        verify_resp_a.exit_code, 0,
        "hello should run in A. Stderr: {}",
        verify_resp_a.stderr
    );

    // 5. Create Sandbox B
    let req_b = CreateSandboxRequest {
        name: Some("sandbox-b".into()),
        workspace: None,
        tab_id: None,
        read_only_paths: vec![],
        tmpfs: vec![],
        env: vec![],
    };
    let summary_b = service.create(req_b).await.expect("Failed to create B");

    // 6. Verify 'hello' does NOT work in B (isolation)
    let verify_b = ExecRequest {
        command: vec!["hello".into()],
        workdir: None,
        env: vec![],
    };
    let verify_resp_b = service
        .exec(summary_b.id.to_string(), verify_b)
        .await
        .expect("Exec hello in B failed");
    assert_ne!(verify_resp_b.exit_code, 0, "hello SHOULD NOT run in B");

    // Cleanup
    service.delete(summary_a.id.to_string()).await.unwrap();
    service.delete(summary_b.id.to_string()).await.unwrap();
}
