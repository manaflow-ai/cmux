use cmux_sandbox::models::{CreateSandboxRequest, ExecRequest};
use cmux_sandbox::service::SandboxService;
use cmux_sandbox::BubblewrapService;
use tempfile::tempdir;

/// Test that agent notification config files are created in sandboxes.
/// These files configure Claude Code, Codex, and OpenCode to send notifications via cmux-bridge.
#[tokio::test]
async fn test_agent_config_files_exist_in_sandbox() {
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

    // Check that source config files exist in Docker image location
    let agent_config_dir = std::path::Path::new("/usr/share/cmux/agent-config");
    if !agent_config_dir.exists() {
        println!(
            "Skipping test: agent config directory not found at {:?} (requires Docker image)",
            agent_config_dir
        );
        return;
    }

    let tmp_dir = tempdir().unwrap();
    let service = BubblewrapService::new(tmp_dir.path().to_path_buf(), 0)
        .await
        .unwrap();

    // Create a sandbox
    let req = CreateSandboxRequest {
        name: Some("agent-config-test".into()),
        workspace: None,
        tab_id: None,
        read_only_paths: vec![],
        tmpfs: vec![],
        env: vec![],
    };
    let summary = service.create(req).await.expect("Failed to create sandbox");

    // Check Claude Code settings.json exists
    let check_claude = ExecRequest {
        command: vec!["cat".into(), "/root/.claude/settings.json".into()],
        workdir: None,
        env: vec![],
    };
    let resp_claude = service
        .exec(summary.id.to_string(), check_claude)
        .await
        .expect("Failed to exec claude check");
    assert_eq!(
        resp_claude.exit_code, 0,
        "Claude Code settings.json should exist: {}",
        resp_claude.stderr
    );
    assert!(
        resp_claude.stdout.contains("Notification"),
        "Claude settings.json should contain Notification hook: {}",
        resp_claude.stdout
    );

    // Check Codex config.toml exists
    let check_codex = ExecRequest {
        command: vec!["cat".into(), "/root/.codex/config.toml".into()],
        workdir: None,
        env: vec![],
    };
    let resp_codex = service
        .exec(summary.id.to_string(), check_codex)
        .await
        .expect("Failed to exec codex check");
    assert_eq!(
        resp_codex.exit_code, 0,
        "Codex config.toml should exist: {}",
        resp_codex.stderr
    );
    assert!(
        resp_codex.stdout.contains("notify"),
        "Codex config.toml should contain notify config: {}",
        resp_codex.stdout
    );

    // Check OpenCode notification.js exists
    let check_opencode = ExecRequest {
        command: vec![
            "cat".into(),
            "/root/.config/opencode/plugin/notification.js".into(),
        ],
        workdir: None,
        env: vec![],
    };
    let resp_opencode = service
        .exec(summary.id.to_string(), check_opencode)
        .await
        .expect("Failed to exec opencode check");
    assert_eq!(
        resp_opencode.exit_code, 0,
        "OpenCode notification.js should exist: {}",
        resp_opencode.stderr
    );
    assert!(
        resp_opencode.stdout.contains("NotificationPlugin"),
        "OpenCode notification.js should contain NotificationPlugin: {}",
        resp_opencode.stdout
    );

    // Clean up
    service.delete(summary.id.to_string()).await.unwrap();
}
