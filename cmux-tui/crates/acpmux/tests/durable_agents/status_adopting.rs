//! Bench round 5 (row 10, W6-H item 2): after `daemon restart`, `daemon status` said
//! `0 live agents` for about 7 s while the new daemon still adopted the agents the old one left,
//! so a live agent read as gone. While it adopts, status says so and counts what it adopts.

use super::*;

#[tokio::test]
async fn w5s_daemon_status_says_adopting_while_the_restart_adopts() {
    // The debug seam holds adoption, so the window is long enough to read.
    let mut daemon =
        Daemon::with_env("statadopt", "approve-all", &[("ACPMUX_TEST_ADOPT_HOLD_MS", "8000")]);
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let hello = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    rpc.call("session/prompt", hello).await;
    drop(rpc);
    // As `daemon restart`: SIGTERM keeps the agent host for the next daemon to adopt.
    daemon.sigterm();
    daemon.start();

    let mut rpc = daemon.rpc().await;
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["liveAgents"], 0, "adopted before the hold ended: {status}");
    assert_eq!(status["adopting"], 1, "status names no agent it adopts: {status}");

    let mut cli = std::process::Command::new(&daemon.exe);
    daemon_env::apply(&mut cli, &daemon.home, daemon_env::Agents::StandIn, &[]);
    let out = cli
        .args(["daemon", "status"])
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{text}{}", String::from_utf8_lossy(&out.stderr));
    assert!(text.contains("adopting 1"), "status text: {text}");
}
