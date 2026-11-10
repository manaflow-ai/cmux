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

/// The lead (2026-11-10): scripts and agents get a real signal, not a poll. `daemon status
/// --wait-adopted [--timeout SECS]` returns once the restart has adopted every agent it can, or
/// exits 3 at the timeout and says how many it still adopts, in the locale's language.
#[tokio::test]
async fn w5s_daemon_status_wait_adopted_returns_when_adoption_ends_or_times_out() {
    let mut daemon =
        Daemon::with_env("statwait", "approve-all", &[("ACPMUX_TEST_ADOPT_HOLD_MS", "8000")]);
    let session = new_session(&daemon).await;
    let mut rpc = daemon.rpc().await;
    let hello = json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]});
    rpc.call("session/prompt", hello).await;
    drop(rpc);
    daemon.sigterm();
    daemon.start();

    let status = |args: &[&str], lang: &str| {
        let mut cli = std::process::Command::new(&daemon.exe);
        daemon_env::apply(&mut cli, &daemon.home, daemon_env::Agents::StandIn, &[]);
        let started = std::time::Instant::now();
        let out = cli
            .args(args)
            .env("ACPMUX_HOME", &daemon.home)
            .env("ACPMUX_SOCKET", &daemon.socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("LC_ALL", lang)
            .output()
            .unwrap();
        (out, started.elapsed())
    };
    let said = |out: &std::process::Output| {
        String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr)
    };

    // The hold outlasts a 1 s timeout: exit 3, with the count it still adopts.
    let (short, took) = status(&["daemon", "status", "--wait-adopted", "--timeout", "1"], "C");
    assert_eq!(short.status.code(), Some(3), "{}", said(&short));
    assert!(said(&short).contains("still adopting 1"), "{}", said(&short));
    assert!(took < Duration::from_secs(5), "the timeout was not kept: {took:?}");
    let (ja, _) = status(&["daemon", "status", "--wait-adopted", "--timeout", "1"], "ja_JP.UTF-8");
    assert_eq!(ja.status.code(), Some(3), "{}", said(&ja));
    assert!(said(&ja).contains("引き継ぎ中"), "the Japanese message: {}", said(&ja));

    // Then it returns as soon as adoption ends, well before its own timeout.
    let (long, took) =
        status(&["--json", "daemon", "status", "--wait-adopted", "--timeout", "30"], "C");
    assert!(long.status.success(), "{}", said(&long));
    let v: Value = serde_json::from_slice(&long.stdout)
        .unwrap_or_else(|e| panic!("not JSON ({e}): {}", said(&long)));
    assert_eq!(v["adopting"], 0, "{v}");
    assert_eq!(v["liveAgents"], 1, "{v}");
    assert!(took < Duration::from_secs(25), "it waited out its timeout: {took:?}");
}
