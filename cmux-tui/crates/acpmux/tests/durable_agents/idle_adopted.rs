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
