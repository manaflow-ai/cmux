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

    let list = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    let stats = stats_in(&list, &id);
    // fake_claude.py's reply: 3 input, 1000 cache write, 200000 cache read, 50 output.
    assert_eq!(stats["contextTokens"], 201_003, "{stats}");
    assert_eq!(stats["tokens24h"], 201_053, "{stats}");
    assert_eq!(stats["launcher"], "python3", "{stats}");
    assert_eq!(stats["autocompactCap"], Value::Null, "nothing caps it: {stats}");
    assert_eq!(stats["subagents24h"], 0, "{stats}");
    assert!(stats["costUsd24h"].as_f64().is_some_and(|c| c > 0.0), "{stats}");

    // A second turn: only its own call is added, whatever reads come between.
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["usageStats"]["tokens24h"], 2 * 201_053, "{}", info["usageStats"]);
    let list = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert_eq!(stats_in(&list, &id)["tokens24h"], 2 * 201_053);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
