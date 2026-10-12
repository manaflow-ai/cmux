//! A Claude chat's context usage (cx-ncc.79): the pane's context ring fills by
//! `usage_update`'s `used` over `size`, so a Claude stdio chat sends the
//! window Claude Code reports for the chat's model, not 0 (which the pane
//! cannot draw).

use super::*;

/// Each `usage_update` the chat recorded, as (used, size).
fn usages(hub: &Arc<Hub>, id: &str) -> Vec<(u64, u64)> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "usage_update")
        .map(|e| {
            let update = e.msg.pointer("/params/update").cloned().unwrap_or(Value::Null);
            (update["used"].as_u64().unwrap_or(0), update["size"].as_u64().unwrap_or(0))
        })
        .collect()
}

#[tokio::test]
async fn a_claude_chats_usage_carries_its_models_context_window() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "usage-probe"}]});

    c.request(method::SESSION_PROMPT, prompt.clone()).await.unwrap();
    // The turn ends with its usage over the chat model's window (not the subagent model's).
    assert_eq!(usages(&hub, &id).last(), Some(&(4500, 200_000)), "{:?}", usages(&hub, &id));

    // Once known, the window rides on the usage Claude streams during the next turn.
    let before = usages(&hub, &id).len();
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let next = usages(&hub, &id)[before..].to_vec();
    assert!(!next.is_empty() && next.iter().all(|u| *u == (4500, 200_000)), "{next:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_claude_chat_that_switched_models_uses_the_new_models_window() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "switched-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    // The model the main loop now runs (its messages name it), not the earlier 1M one still in
    // Claude's cumulative modelUsage.
    assert_eq!(usages(&hub, &id).last(), Some(&(4500, 200_000)), "{:?}", usages(&hub, &id));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_claude_chat_that_compacted_does_not_refill_the_ring() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "compact-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    // The streamed usage only: the result after the compaction does not resend the
    // pre-compaction count.
    assert_eq!(usages(&hub, &id), vec![(4500, 0)]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
