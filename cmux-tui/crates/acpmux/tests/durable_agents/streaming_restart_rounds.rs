//! The relaunch-reconnect bench's rounds without the app (scripts/cmux-next/bench_relaunch_reconnect.py,
//! manaflow-ai/cmuxterm-hq#6338): six chats, one streaming a reply started by `acpmux send
//! --no-wait` (`_acpmux/send_queue`), the shown chat attached and let go as each app launch does,
//! then restarts with a gap. Each round's chat is live again within seconds.

use super::*;

fn live_tick(line: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return false };
    if v.get("id").is_some() {
        return false;
    }
    let text = v.to_string();
    text.contains("agent_message_chunk") && text.contains("\"tick")
}

/// Attach the chat as the pane does and count live words for up to `within`; returns the count
/// and the time to the 20th.
async fn page_live(daemon: &Daemon, session: &str, within: Duration) -> (usize, Duration) {
    let started = Instant::now();
    let mut page = daemon.rpc().await;
    page.send(
        "_acpmux/attach",
        json!({"sessionId": session, "waitLogs": false, "limit": 400,
               "kinds": ["transcript"], "eventStream": true, "visible": true}),
    )
    .await;
    let deadline = started + within;
    let mut live = 0;
    while live < 20 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match tokio::time::timeout(left, page.lines.next_line()).await {
            Ok(Ok(Some(line))) => live += usize::from(live_tick(&line)),
            _ => break,
        }
    }
    (live, started.elapsed())
}

async fn rounds(tag: &str, rate_ms: u64, gap: Duration, chats: usize) {
    let mut daemon = Daemon::new(tag, "approve-all");
    let mut others = Vec::new();
    for _ in 0..chats {
        let s = new_session(&daemon).await;
        let mut c = daemon.rpc().await;
        let _ = c
            .call(
                "session/prompt",
                json!({"sessionId": s, "prompt": [{"type": "text", "text": "hello"}]}),
            )
            .await;
        others.push(s);
    }
    let session = new_session(&daemon).await;
    let mut cli = daemon.rpc().await;
    let queued = cli
        .call(
            "_acpmux/send_queue",
            json!({"request": {"sessionId": session, "prompt": [{"type": "text", "text": format!("ticking:100000:{rate_ms}")}],
                   "_meta": {"acpmux": {"promptId": uuid_like(tag), "steer": true}}}}),
        )
        .await;
    eprintln!("[{tag}] queued: {queued}");
    drop(cli);
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    let mut report = Vec::new();
    // Warm rounds: the app attaches, shows it live, quits.
    for round in 0..3 {
        let (live, took) = page_live(&daemon, &session, Duration::from_secs(15)).await;
        report.push(format!("warm{round}: {live} live by {:.1}s", took.as_secs_f64()));
    }
    // Restart rounds.
    let mut worst = Duration::ZERO;
    let mut fewest = usize::MAX;
    for round in 0..3 {
        std::thread::sleep(Duration::from_secs(5));
        daemon.sigterm();
        std::thread::sleep(gap);
        let started = Instant::now();
        daemon.start();
        std::thread::sleep(Duration::from_millis(500));
        let (live, _) = page_live(&daemon, &session, Duration::from_secs(30)).await;
        let took = started.elapsed();
        report
            .push(format!("restart{round}: {live} live by {:.1}s after start", took.as_secs_f64()));
        worst = worst.max(took);
        fewest = fewest.min(live);
    }
    eprintln!("[{tag}] {}", report.join("; "));
    let kinds: Vec<String> = daemon
        .events(&session)
        .iter()
        .filter(|e| e["dir"] == "mux")
        .map(|e| format!("{}", e["kind"]))
        .collect();
    eprintln!("[{tag}] mux records: {}", kinds.join(","));
    assert!(fewest >= 20 && worst < Duration::from_secs(12), "[{tag}] {}", report.join("; "));
    daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}

fn uuid_like(tag: &str) -> String {
    format!(
        "0190a0a0-0000-7000-8000-{:012x}",
        tag.bytes().fold(0u64, |a, b| a * 31 + u64::from(b)) & 0xffff_ffff_ffff
    )
}

#[tokio::test]
async fn bench_rounds_queued_stream_six_chats() {
    rounds("srq6", 100, Duration::from_secs(6), 6).await;
}

#[tokio::test]
async fn bench_rounds_queued_stream_alone() {
    rounds("srq0", 100, Duration::from_secs(6), 0).await;
}

#[tokio::test]
async fn bench_rounds_fast_stream() {
    rounds("srqf", 10, Duration::from_secs(6), 2).await;
}

/// A loaded Mac: the start's pass misses every host's hello (debug seam), so the retry adopts
/// the streaming chat's host while the page is already attached.
#[tokio::test]
async fn late_hello_streaming_turn_is_live_within_seconds() {
    let mut daemon = Daemon::new("srlh", "approve-all");
    let session = new_session(&daemon).await;
    let mut cli = daemon.rpc().await;
    cli.call(
        "_acpmux/send_queue",
        json!({"request": {"sessionId": session, "prompt": [{"type": "text", "text": "ticking:100000:100"}],
               "_meta": {"acpmux": {"promptId": uuid_like("srlh"), "steer": true}}}}),
    )
    .await;
    drop(cli);
    daemon.wait_event(&session, "tick5", |e| chunk(e, "tick5 "));
    daemon.sigterm();
    daemon.env.push(("ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS".into(), "0".into()));
    std::thread::sleep(Duration::from_secs(6));
    let started = Instant::now();
    daemon.start();
    std::thread::sleep(Duration::from_millis(500));
    let (live, _) = page_live(&daemon, &session, Duration::from_secs(30)).await;
    let took = started.elapsed();
    let kinds: Vec<String> = daemon
        .events(&session)
        .iter()
        .filter(|e| e["dir"] == "mux")
        .map(|e| format!("{}", e["kind"]))
        .collect();
    eprintln!("[srlh] {live} live by {:.1}s; mux records: {}", took.as_secs_f64(), kinds.join(","));
    assert!(
        live >= 20 && took < Duration::from_secs(12),
        "[srlh] {live} live by {:.1}s",
        took.as_secs_f64()
    );
    daemon.rpc().await.send("session/cancel", json!({"sessionId": session})).await;
}
