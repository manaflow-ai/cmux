//! What a Claude chat spent and holds (`SessionSummary.usageStats`), read from the
//! transcript Claude Code writes under its CLAUDE_CONFIG_DIR: the session list and
//! a chat's info carry it, and each turn's call is counted once.

use super::*;

fn stats_in(list: &Value, id: &str) -> Value {
    let rows = list["sessions"].as_array().cloned().unwrap_or_default();
    let row = rows.into_iter().find(|r| r["sessionId"] == id).unwrap_or(Value::Null);
    row["usageStats"].clone()
}

#[tokio::test]
async fn the_session_list_and_info_carry_what_the_chats_transcript_says() {
    let root = std::env::temp_dir().join(format!("acpmux-usage-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[("FAKE_CLAUDE_TRANSCRIPT_USAGE", "1")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt.clone()).await.unwrap();

    // A plain list reads nothing; one that asks for usage reads the transcript first.
    let list = c.request(method::MUX_SESSIONS, json!({"usage": true})).await.unwrap();
    let stats = stats_in(&list, &id);
    // fake_claude.py's reply: 3 input, 1000 cache write, 200000 cache read, 50 output.
    assert_eq!(stats["contextTokens"], 201_003, "{stats}");
    assert_eq!(stats["tokens24h"], 201_053, "{stats}");
    assert_eq!(stats["launcher"], "python3", "{stats}");
    // This daemon started it with no cap, and its Claude home has no settings: known uncapped.
    assert_eq!(stats["autocompact"], "none", "{stats}");
    assert_eq!(stats["autocompactCap"], Value::Null, "{stats}");
    assert_eq!(stats["subagents24h"], 0, "{stats}");
    assert!(stats["costUsd24h"].as_f64().is_some_and(|c| c > 0.0), "{stats}");

    // A second turn, within the list's 5 s: its end has the next list read again, and only
    // its own call is added; info carries what that read found.
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let list = c.request(method::MUX_SESSIONS, json!({"usage": true})).await.unwrap();
    assert_eq!(stats_in(&list, &id)["tokens24h"], 2 * 201_053, "{}", stats_in(&list, &id));
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["usageStats"]["tokens24h"], 2 * 201_053, "{}", info["usageStats"]);
    // Each turn's end is followed by its usage, which watchers hear as session_changed.
    let mut recorded = Vec::new();
    for _ in 0..100 {
        recorded = hub.events(&id, 0, 10_000).unwrap();
        recorded.retain(|e| e.kind == "usage_stats");
        if recorded.len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let tokens: Vec<_> = recorded.iter().map(|e| e.msg["tokens24h"].clone()).collect();
    assert_eq!(tokens, vec![json!(201_053), json!(2 * 201_053)]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A new connection, as each `acpmux ls` makes one: its list is not paced by an earlier one's.
async fn connect(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "ls"}}))
        .await
        .unwrap();
    c
}

/// A measurement, not a check: `_acpmux/sessions` latency over `LS_LATENCY_SESSIONS` (default
/// 30) Claude chats that each ran a turn, `LS_LATENCY_RUNS` (default 50) runs each of a plain
/// list (`acpmux ls`) and one that asks for usage (`ls --wide`, `--json`), each on a new
/// connection. An acpmux without usageStats ignores `usage`, so the same bench runs on a base.
/// `cargo test -p acpmux --test hub_integration ls_latency -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn ls_latency() {
    let n = |k: &str, d: usize| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
    let (sessions, runs) = (n("LS_LATENCY_SESSIONS", 30), n("LS_LATENCY_RUNS", 50));
    let root = std::env::temp_dir().join(format!("acpmux-ls-bench-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[("FAKE_CLAUDE_TRANSCRIPT_USAGE", "1")]).await;
    for i in 0..sessions {
        let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
        let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
        let text = format!("turn {i}");
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    }
    for (label, params) in [("plain", json!({})), ("usage", json!({"usage": true}))] {
        let mut took = Vec::with_capacity(runs);
        for _ in 0..runs {
            let mut ls = connect(&hub).await;
            let started = std::time::Instant::now();
            let list = ls.request(method::MUX_SESSIONS, params.clone()).await.unwrap();
            took.push(started.elapsed());
            assert_eq!(list["sessions"].as_array().map(Vec::len), Some(sessions));
        }
        took.sort();
        let at = |q: f64| took[((took.len() as f64 * q).ceil() as usize).clamp(1, took.len()) - 1];
        println!(
            "ls_latency {label}: sessions={sessions} runs={runs} p50={:?} p95={:?} max={:?}",
            at(0.50),
            at(0.95),
            took[took.len() - 1]
        );
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
