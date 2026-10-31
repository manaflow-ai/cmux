//! An adopted harness with a child process: the idle pass keeps it up, and a stop still ends it
//! and its child as it always did (`hub/idle_census.rs`).

use super::*;

#[tokio::test]
async fn an_adopted_harness_with_a_child_stays_up_idle_and_a_stop_still_ends_both() {
    let helper_file = std::env::temp_dir().join(format!("amd-idlead-{}", std::process::id()));
    let mut daemon = Daemon::with_env(
        "idlead",
        "approve-all",
        &[("FAKE_SETSID_CHILD", helper_file.to_str().unwrap()), ("ACPMUX_IDLE_CHILD_SECS", "1")],
    );
    let session = new_session(&daemon).await;
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let helper_path = format!("{}.{harness}", helper_file.display());
    let helper: i64 = std::fs::read_to_string(&helper_path).unwrap().trim().parse().unwrap();
    let _ = std::fs::remove_file(&helper_path);
    // A restart: the next daemon adopts the host and knows nothing of how it started.
    daemon.sigterm();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // Several idle periods pass: its child runs under it, so the harness stays up.
    std::thread::sleep(Duration::from_secs(5));
    let kept = alive(harness) && alive(helper);
    // A stop ends the harness and its child as before.
    daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    let ended = gone_within(harness, Duration::from_secs(10));
    let child_ended = gone_within(helper, Duration::from_secs(10));
    if !child_ended {
        // SAFETY: this test's agent started the helper; end it before failing.
        unsafe { libc::kill(helper as i32, libc::SIGKILL) };
    }
    assert!(kept, "the idle pass ended an adopted harness with a child running under it");
    assert!(ended, "a stop left the adopted harness running");
    assert!(child_ended, "a stop left the adopted harness's child running");
}

/// An app update restarts acpmux, and the next daemon adopts every agent host. An adopted harness
/// that is idle but for its own MCP server ends at the idle pass, and the server with it. Before,
/// the adopting daemon knew none of its servers, so every agent of an earlier daemon stayed up for
/// good (163 Claude Code harnesses idle for days on one Mac, load 125, 2026-10-30).
#[tokio::test]
async fn an_adopted_harness_idle_but_for_its_mcp_server_ends() {
    adopted_mcp_server_case("idlemcp", false).await;
}

/// The update also moved the bundle the server runs from aside and put a new one at its path, as
/// the app's updater does: the kernel then names the moved file, which is no longer the file at
/// the server's configured path. The server still is the harness's own.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn an_adopted_harness_ends_when_an_update_moved_its_mcp_server_aside() {
    adopted_mcp_server_case("idlemv", true).await;
}

async fn adopted_mcp_server_case(tag: &str, moved: bool) {
    let pids_file = std::env::temp_dir().join(format!("amd-{tag}-mcp-{}", std::process::id()));
    let _ = std::fs::remove_file(&pids_file);
    let mut daemon =
        Daemon::claude_router(tag, &[("FAKE_CLAUDE_START_MCP", pids_file.to_str().unwrap())]);
    // The harness's MCP server: a program of its own (a copy of sleep), which the session
    // folder's .mcp.json names, as a user or project server is named.
    let bin = daemon.home.join("app bin");
    std::fs::create_dir_all(&bin).unwrap();
    let program = bin.join("side-mcp");
    std::fs::copy("/bin/sleep", &program).unwrap();
    let mcp = json!({"mcpServers": {"side": {"command": program, "args": ["3599"]}}});
    std::fs::write(daemon.home.join(".mcp.json"), mcp.to_string()).unwrap();
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    assert_eq!(rpc.call("session/prompt", prompt).await["stopReason"], "end_turn");
    drop(rpc);
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let server = loop {
        if let Ok(text) = std::fs::read_to_string(&pids_file) {
            let pids: Value = serde_json::from_str(&text).unwrap();
            break pids["side"].as_i64().unwrap();
        }
        assert!(Instant::now() < deadline, "the harness did not start its MCP server");
        std::thread::sleep(Duration::from_millis(50));
    };
    let _ = std::fs::remove_file(&pids_file);
    // The update restart, with a one-second idle period for the next daemon.
    daemon.sigterm();
    assert!(alive(harness) && alive(server), "the restart ended the agent or its server");
    if moved {
        let aside = daemon.home.join("updater cache");
        std::fs::create_dir_all(&aside).unwrap();
        std::fs::rename(&program, aside.join("side-mcp")).unwrap();
        std::fs::copy("/bin/sleep", &program).unwrap();
    }
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let ended = gone_within(harness, Duration::from_secs(20));
    let server_ended = gone_within(server, Duration::from_secs(10));
    for pid in [harness, server] {
        if alive(pid) {
            // SAFETY: this test's harness and the server it started; end them before failing.
            unsafe { libc::kill(pid as i32, libc::SIGKILL) };
        }
    }
    assert!(ended, "the idle adopted harness stayed up with only its own MCP server under it");
    assert!(server_ended, "the MCP server outlived its ended harness");
}
