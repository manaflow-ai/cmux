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
    assert_eq!(usages(&hub, &id).last(), Some(&(4200, 200_000)), "{:?}", usages(&hub, &id));

    // Once known, the window rides on the usage Claude streams during the next turn.
    let before = usages(&hub, &id).len();
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let next = usages(&hub, &id)[before..].to_vec();
    assert!(!next.is_empty() && next.iter().all(|u| *u == (4200, 200_000)), "{next:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The `used` of each `usage_update` acpmux marked as one model call's (`_meta.acpmux.call`):
/// the pane adds these up for the running turn's tokens (webviews WorkingFor.tsx).
fn call_usages(hub: &Arc<Hub>, id: &str) -> Vec<u64> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "usage_update")
        .filter_map(|e| e.msg.pointer("/params/update"))
        .filter(|u| u.pointer("/_meta/acpmux/call") == Some(&json!(true)))
        .map(|u| u["used"].as_u64().unwrap_or(0))
        .collect()
}

#[tokio::test]
async fn only_a_streamed_calls_usage_is_marked_as_a_call() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "usage-probe"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    // The streamed call and the result that repeats it for the ring: only the call is marked, so
    // a turn's last call (and a steer's or late Stop's result) never counts twice.
    assert!(usages(&hub, &id).len() >= 2, "{:?}", usages(&hub, &id));
    assert_eq!(call_usages(&hub, &id), vec![4200]);
    // The call's split: what it read (fresh input, cache reads, cache writes) and what it wrote,
    // so the pane's line can say output apart from input. `used` above is the read side only.
    let splits: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "usage_update")
        .filter_map(|e| e.msg.pointer("/params/update"))
        .filter(|u| u.pointer("/_meta/acpmux/call") == Some(&json!(true)))
        .map(|u| {
            json!([
                u["inputTokens"],
                u["cachedReadTokens"],
                u["cachedWriteTokens"],
                u["outputTokens"]
            ])
        })
        .collect();
    assert_eq!(splits, vec![json!([1200, 3000, 0, 300])]);
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
    assert_eq!(usages(&hub, &id).last(), Some(&(4200, 200_000)), "{:?}", usages(&hub, &id));
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
    assert_eq!(usages(&hub, &id), vec![(4200, 0)]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The chat's `contextBreakdown` as `_acpmux/info` says it, once it is there (it comes after the
/// turn's answer: acpmux asks Claude Code for it at the turn's result), else null after 5 s.
async fn breakdown(c: &mut TestClient, id: &str) -> Value {
    for _ in 0..100 {
        let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
        if !info["contextBreakdown"].is_null() {
            return info["contextBreakdown"].clone();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    Value::Null
}

/// Claude Code's /context, for the pane's Context card: after each turn the chat holds what its
/// context holds by category, without Claude Code's grid and colors.
#[tokio::test]
async fn a_claude_chat_keeps_its_context_breakdown_after_a_turn() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[("FAKE_CLAUDE_CONTEXT", "1")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let got = breakdown(&mut c, &id).await;
    assert_eq!(
        got,
        json!({
            "categories": [
                {"id": "system_prompt", "name": "System prompt", "tokens": 3000, "kind": "used"},
                {"name": "MCP tools (deferred)", "tokens": 900, "kind": "deferred"},
                {"id": "messages", "name": "Messages", "tokens": 1500, "kind": "used"},
                {"id": "free_space", "name": "Free space", "tokens": 195500, "kind": "free"},
            ],
            "memoryFiles": [{"path": "/repo/CLAUDE.md", "type": "Project", "tokens": 120}],
            "mcpTools": [
                {"name": "mcp__cmux__b", "serverName": "cmux", "tokens": 60},
                {"name": "mcp__cmux__a", "serverName": "cmux", "tokens": 40},
            ],
            "skills": [{"name": "demo-skill", "tokens": 30}],
            "totalTokens": 4500,
            "maxTokens": 200000,
        })
    );
    // Claude Code's whole answer (its grid) is not logged; the breakdown is, for a pane that
    // attaches.
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(!events.iter().any(|e| e.msg.to_string().contains("gridRows")));
    assert!(events.iter().any(|e| e.kind == "session_info_update"
        && e.msg.pointer("/params/update/_meta/acpmux/contextBreakdown") == Some(&got)));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A Claude Code that cannot answer get_context_usage (an older one) leaves the chat without a
/// breakdown, and its turns are not held for it.
#[tokio::test]
async fn a_claude_chat_whose_claude_refuses_context_keeps_none() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[("FAKE_CLAUDE_CONTEXT", "error")]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt.clone()).await.unwrap();
    // A second turn runs after the first refusal came back.
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(info["contextBreakdown"].is_null(), "{info}");
    let asked = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "claude.stdin")
        .filter(|e| e.msg.pointer("/request/subtype") == Some(&json!("get_context_usage")))
        .count();
    assert!(asked >= 1, "acpmux never asked");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// `_acpmux/mcp/reconnect` sends Claude Code's mcp_reconnect for the named server and answers as
/// Claude Code did; a reconnected server reads connected. Another harness is refused.
#[tokio::test]
async fn a_claude_chat_reconnects_an_mcp_server() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let init = json!({"mcp_servers": [
        {"name": "github", "status": "failed"},
        {"name": "linear", "status": "failed"},
    ]})
    .to_string();
    let controls = root.join("controls.log");
    let controls_path = controls.to_string_lossy().into_owned();
    let env = [
        ("FAKE_CLAUDE_INIT", init.as_str()),
        ("FAKE_CLAUDE_MCP_DOWN", "linear"),
        ("FAKE_CLAUDE_CONTROL_LOG", controls_path.as_str()),
    ];
    let (hub, mut c) = claude_setup(&claude, &env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let status = |info: &Value, name: &str| {
        info["mcpServers"]
            .as_array()
            .and_then(|s| s.iter().find(|s| s["name"] == name))
            .map(|s| s["status"].clone())
            .unwrap_or(Value::Null)
    };
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(status(&info, "github"), "failed", "{info}");

    let reconnect = |server: &str| json!({"sessionId": id, "server": server});
    let done = c.request("_acpmux/mcp/reconnect", reconnect("github")).await.unwrap();
    assert_eq!(done, json!({}));
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(status(&info, "github"), "connected", "{info}");
    let sent = std::fs::read_to_string(&controls).unwrap();
    assert!(sent.lines().any(|l| l == "mcp_reconnect"), "{sent}");

    // Claude Code's refusal is the answer, and the row keeps its status.
    let refused = c.request("_acpmux/mcp/reconnect", reconnect("linear")).await.unwrap_err();
    assert_eq!(refused, "Server status: failed");
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(status(&info, "linear"), "failed", "{info}");
    // A server the chat does not have is not sent.
    assert!(c.request("_acpmux/mcp/reconnect", reconnect("nope")).await.is_err());
    hub.shutdown_all().await;

    // Another harness: refused, as only Claude Code has the request.
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let other = s["sessionId"].as_str().unwrap().to_owned();
    let refused = c
        .request("_acpmux/mcp/reconnect", json!({"sessionId": other, "server": "github"}))
        .await
        .unwrap_err();
    assert!(refused.contains("only Claude Code"), "{refused}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The breakdown comes after the turn ended and its meta was saved, so it is saved when it
/// arrives: a restarted daemon still has it.
#[tokio::test]
async fn a_claude_chats_context_breakdown_survives_a_restart() {
    let root = std::env::temp_dir().join(format!("acpmux-context-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    let store_dir = root.join("store");
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::create_dir_all(&store_dir).unwrap();
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let env = BTreeMap::from([
        ("CLAUDE_CONFIG_DIR".to_owned(), claude.to_string_lossy().into_owned()),
        ("FAKE_CLAUDE_CONTEXT".to_owned(), "1".to_owned()),
    ]);
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let connect = |hub: &Arc<Hub>| {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
        TestClient { tx: in_tx, rx: out_rx, next: 0 }
    };
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &store_dir).unwrap());
    let mut c = connect(&hub);
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let got = breakdown(&mut c, &id).await;
    assert!(!got.is_null(), "no breakdown after the turn");
    hub.shutdown_all().await;
    drop(hub);

    let hub2 = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &store_dir).unwrap());
    let mut c2 = connect(&hub2);
    c2.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    let info = c2.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["contextBreakdown"], got, "{info}");
    hub2.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
