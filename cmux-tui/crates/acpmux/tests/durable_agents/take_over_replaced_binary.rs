//! A cmux NIGHTLY install replaces the binary every agent host runs from, then starts `daemon run
//! --take-over`; the new daemon adopts each host and marks it stale (`hub/stale_host_respawn.rs`).
//! On cosmic-gray (2026-11-17) each install, every 20-30 min, then restarted a coordinator 10-20 s
//! after its host was adopted (09:48Z, 10:14Z, 10:42Z, 11:20Z): no turn was open, but its
//! background subagents and waits were running, and the restart cut them all mid-task. Now an
//! agent at work keeps its host and harness through the take-over, and restarts on the installed
//! binary only once nothing runs in it. Leo: "the dream is infinite chats of infinite length".

use super::*;

/// The update as nightly-update does it: the old file moves to a backup, a new build takes the
/// path (a new file, so each host started from the path now runs a replaced binary).
fn replace_binary(path: &Path) {
    std::fs::rename(path, path.with_extension("backup")).unwrap();
    std::fs::copy(daemon_env::bin(), path).unwrap();
}

async fn prompt(daemon: &Daemon, session: &str, text: &str) {
    let reply = daemon
        .rpc()
        .await
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
}

#[tokio::test]
async fn a_take_over_after_an_update_keeps_an_agent_at_work_alive_and_attached() {
    let mut daemon =
        Daemon::with_env("tovbin", "approve-all", &[("ACPMUX_TEST_QUIET_RESPAWN_MS", "300")]);
    daemon.sigterm();
    let exe = daemon.home.join("bin").join("acpmux");
    std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
    std::fs::copy(daemon_env::bin(), &exe).unwrap();
    daemon.exe = exe.clone();
    daemon.start();
    let session = new_session(&daemon).await;
    // Its turn ends; the background subagent it started runs on.
    prompt(&daemon, &session, "background-subagent").await;
    let record = daemon.host_record(&session);
    let host = record["host_pid"].as_i64().unwrap();
    let harness = record["harness_pid"].as_i64().unwrap();

    replace_binary(&exe);
    daemon.take_over();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // Many quiet periods, and well past when the old restart ran.
    std::thread::sleep(Duration::from_secs(4));
    let kept = alive(host) && alive(harness);
    let exited = daemon.events(&session).iter().any(|e| e["kind"] == "exited");
    let attached = daemon.host_record(&session)["host_pid"].as_i64() == Some(host);
    assert!(kept, "the take-over ended an agent host whose background subagent was at work");
    assert!(!exited, "the agent at work exited after the take-over");
    assert!(attached, "the agent no longer runs on the adopted host");
    // Its live agent answers on the adopted host.
    prompt(&daemon, &session, "hello").await;
    assert!(alive(harness), "a prompt replaced the adopted agent");

    // Once nothing runs in it, it ends and its next prompt starts it on the installed binary.
    prompt(&daemon, &session, "background-subagent-done").await;
    assert!(gone_within(harness, Duration::from_secs(20)), "the quiet agent never restarted");
    assert!(gone_within(host, Duration::from_secs(10)), "its stale host outlived it");
    prompt(&daemon, &session, "hello again").await;
    let next = daemon.host_record(&session)["host_pid"].as_i64().unwrap();
    assert_ne!(next, host, "the next prompt ran on the stale host");
    assert!(alive(next), "the new host is not running");
}
