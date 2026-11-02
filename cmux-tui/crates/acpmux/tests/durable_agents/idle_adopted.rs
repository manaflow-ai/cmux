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

/// An adopted harness whose only processes are the MCP servers the daemon gave it hibernates
/// like one this daemon started: the servers were kept with the session (`StoredLaunch`). Before,
/// a next daemon knew none of them, so after a crash or an update every adopted agent with a
/// server stayed up for good (cmux NIGHTLY, 2026-10-30: about 150 idle agents, 27 GB).
#[tokio::test]
async fn an_adopted_harness_running_only_its_mcp_servers_hibernates() {
    let pids_file = std::env::temp_dir().join(format!("amd-idlemcp-{}", std::process::id()));
    let mut daemon = Daemon::with_env(
        "idlemcp",
        "approve-all",
        &[("FAKE_RUN_MCP", pids_file.to_str().unwrap())],
    );
    let session = new_session(&daemon).await;
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let pids_path = format!("{}.{harness}", pids_file.display());
    let servers: Vec<i64> = std::fs::read_to_string(&pids_path)
        .unwrap()
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect();
    let _ = std::fs::remove_file(&pids_path);
    assert!(!servers.is_empty(), "the daemon gave the agent no MCP server to run");
    assert!(servers.iter().all(|p| alive(*p)), "an MCP server exited at its start");
    // A restart with a short idle period: the next daemon adopts the host.
    daemon.sigterm();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let ended = gone_within(harness, Duration::from_secs(20));
    let servers_ended = servers.iter().all(|p| gone_within(*p, Duration::from_secs(10)));
    if !ended {
        daemon.rpc().await.call("_acpmux/kill", json!({"sessionId": session})).await;
    }
    assert!(ended, "the adopted idle harness kept running with only its MCP servers under it");
    assert!(servers_ended, "its MCP servers outlived the hibernation");
}
