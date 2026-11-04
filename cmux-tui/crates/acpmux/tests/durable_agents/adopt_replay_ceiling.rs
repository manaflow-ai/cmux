//! Diagnostic: the relaunch-reconnect bench's update round 2 (manaflow-ai/cmuxterm-hq#6338).

use super::*;

fn live_tick(line: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return false };
    if v.get("id").is_some() {
        return false;
    }
    let text = v.to_string();
    text.contains("agent_message_chunk") && text.contains("\"tick")
}

fn mux_kinds(daemon: &Daemon, session: &str) -> Vec<String> {
    daemon
        .events(session)
        .iter()
        .filter(|e| e["dir"] == "mux")
        .map(|e| format!("{}@{}", e["kind"].as_str().unwrap_or("?"), e["at"]))
        .collect()
}

fn replace_binary(copy: &Path) {
    let aside = copy.with_extension("replaced");
    std::fs::rename(copy, &aside).unwrap();
    std::fs::copy(&aside, copy).unwrap();
    std::fs::remove_file(&aside).unwrap();
}

async fn first_live(daemon: &Daemon, session: &str, started: Instant, within: Duration) -> Option<Duration> {
    let mut page = daemon.rpc().await;
    page.call(
        "_acpmux/attach",
        json!({"sessionId": session, "waitLogs": false, "limit": 400,
               "kinds": ["transcript"], "eventStream": true, "visible": true}),
    )
    .await;
    let deadline = started + within;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return None;
        }
        match tokio::time::timeout(left, page.lines.next_line()).await {
            Ok(Ok(Some(line))) if live_tick(&line) => return Some(started.elapsed()),
            Ok(Ok(Some(_))) => {}
            _ => return None,
        }
    }
}

/// `kill_harness`: round 1 ends the streaming harness while no daemon runs (as loginwindow's
/// SIGTERM may have). `kill_host`: it ends the agent host instead.
async fn two_rounds(tag: &str, kill_harness: bool, kill_host: bool, idle: usize) {
    let mut daemon = Daemon::new(tag, "approve-all");
    let copy = daemon.home.join("bin").join("acpmux");
    daemon.sigterm();
    std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
    std::fs::copy(daemon_env::bin(), &copy).unwrap();
    daemon.exe = copy.clone();
    daemon.start();
    let session = new_session(&daemon).await;
    for _ in 0..idle {
        let s = new_session(&daemon).await;
        daemon.rpc().await.call("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]})).await;
    }
    let mut client = daemon.rpc().await;
    client
        .send("session/prompt", json!({"sessionId": session, "prompt": [{"type": "text", "text": "ticking:3000:100"}]}))
        .await;
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    let host = daemon.host_record(&session);
    // Round 1: an update relaunch with a gap.
    replace_binary(&copy);
    daemon.sigterm();
    drop(client);
    if kill_harness {
        // SAFETY: this test's own harness.
        unsafe { libc::kill(host["harness_pid"].as_i64().unwrap() as i32, libc::SIGTERM) };
    }
    if kill_host {
        // SAFETY: this test's own host.
        unsafe { libc::kill(host["host_pid"].as_i64().unwrap() as i32, libc::SIGTERM) };
    }
    std::thread::sleep(Duration::from_secs(3));
    let started = Instant::now();
    daemon.start();
    let r1 = first_live(&daemon, &session, started, Duration::from_secs(15)).await;
    eprintln!("[{tag}] round 1 first live tick: {r1:?}; mux: {:?}", mux_kinds(&daemon, &session));
    std::thread::sleep(Duration::from_secs(8));
    // Round 2: an ordinary handoff (the app asks the old daemon to stop, starts the new build).
    replace_binary(&copy);
    let reply = daemon.rpc().await.call("_acpmux/shutdown", json!({})).await;
    eprintln!("[{tag}] shutdown reply {reply}");
    daemon.wait_exit();
    let started = Instant::now();
    daemon.start();
    std::thread::sleep(Duration::from_millis(800));
    let r2 = first_live(&daemon, &session, started, Duration::from_secs(150)).await;
    eprintln!("[{tag}] round 2 first live tick: {r2:?}; mux: {:?}", mux_kinds(&daemon, &session));
    let _ = daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}

#[tokio::test]
async fn diag_plain() {
    two_rounds("rcplain", false, false, 5).await;
}

#[tokio::test]
async fn diag_harness_killed() {
    two_rounds("rcharn", true, false, 5).await;
}

#[tokio::test]
async fn diag_host_killed() {
    two_rounds("rchost", false, true, 5).await;
}
