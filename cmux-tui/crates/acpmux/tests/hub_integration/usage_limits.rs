//! A Claude chat's plan usage limits (`claude_stdio/usage_limits.rs`): Claude Code's
//! `rate_limit_event` lines become the session detail's `usageLimits` and a
//! `session_info_update` with `_meta.acpmux.usageLimits`, for the pane's Context card.

use super::*;

#[tokio::test]
async fn a_claude_chat_keeps_its_accounts_usage_limits() {
    let root = std::env::temp_dir().join(format!("acpmux-limits-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(info["usageLimits"].is_null(), "{info}");
    let prompt =
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "rate-limits-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();

    // The later event moved the session window only; the weekly one stays.
    let want = json!({"windows": [
        {"id": "session", "usedPercent": 90.0, "resetsAt": 1_790_000_000},
        {"id": "weekly", "usedPercent": 40.0, "resetsAt": 1_790_500_000},
    ]});
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["usageLimits"], want, "{info}");
    let sent: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "session_info_update")
        .filter_map(|e| e.msg.pointer("/params/update/_meta/acpmux/usageLimits").cloned())
        .collect();
    assert_eq!(sent.len(), 2, "{sent:?}");
    assert_eq!(sent.last(), Some(&want), "{sent:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
