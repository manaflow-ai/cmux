//! What each turn cost (hq#1920): a turn's `turn_result` carries the model it
//! ran on and the tokens and cost its harness reported, and the session keeps
//! running totals (`totals` in session.json and `_acpmux/info`), so a later
//! report can add up spend per session, branch and pull request.

use super::*;

/// The session's `turn_result` records, oldest first.
fn turn_results(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == "turn_result")
        .map(|e| e.msg)
        .collect()
}

/// The session's saved meta as session.json holds it.
fn saved(hub: &Hub, id: &str) -> Value {
    serde_json::to_value(hub.resolve(id).unwrap().meta()).unwrap()
}

async fn say(c: &mut TestClient, id: &str, text: &str) {
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
}

/// The usage fields of a turn record, without its ids and status.
fn spend(turn: &Value) -> Value {
    let keys = ["costUsd", "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"];
    let o = turn.as_object().unwrap();
    Value::Object(keys.iter().filter_map(|k| Some(((*k).to_owned(), o.get(*k)?.clone()))).collect())
}

#[tokio::test]
async fn turn_usage_records_each_claude_turn_and_the_session_totals() {
    let root = std::env::temp_dir().join(format!("acpmux-turn-usage-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();

    say(&mut c, &id, "cost-probe").await;
    say(&mut c, &id, "cost-probe").await;
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    let model = info["model"].clone();
    assert!(model.is_string(), "{info}");
    let turns = turn_results(&hub, &id);
    assert_eq!(turns.len(), 2, "{turns:?}");
    // Claude's cost_usd is its running total (0.25, then 0.5): each turn records its own share.
    let one = json!({"costUsd": 0.25, "inputTokens": 100, "outputTokens": 20,
                     "cacheReadTokens": 300, "cacheWriteTokens": 40});
    for turn in &turns {
        assert_eq!(spend(turn), one, "{turn}");
        assert_eq!(turn["model"], model, "{turn}");
    }
    let two = json!({"costUsd": 0.5, "inputTokens": 200, "outputTokens": 40,
                     "cacheReadTokens": 600, "cacheWriteTokens": 80});
    assert_eq!(saved(&hub, &id)["totals"], two, "{}", saved(&hub, &id));
    assert_eq!(info["totals"], two, "{info}");

    // A new Claude process whose running total started over: its turn is not a negative cost.
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    say(&mut c, &id, "cost-probe").await;
    assert_eq!(spend(&turn_results(&hub, &id)[2]), one, "{:?}", turn_results(&hub, &id));

    // A turn that reports tokens but no cost adds its tokens and no cost.
    say(&mut c, &id, "hello").await;
    let last = turn_results(&hub, &id)[3].clone();
    assert_eq!(spend(&last), json!({"inputTokens": 1, "outputTokens": 1}), "{last}");
    let totals = json!({"costUsd": 0.75, "inputTokens": 301, "outputTokens": 61,
                        "cacheReadTokens": 900, "cacheWriteTokens": 120});
    assert_eq!(saved(&hub, &id)["totals"], totals, "{}", saved(&hub, &id));
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["totals"], totals, "{info}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn turn_usage_of_a_fork_starts_its_own_totals() {
    let root = std::env::temp_dir().join(format!("acpmux-turn-usage-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(&mut c, &id, "cost-probe").await;

    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert!(saved(&hub, &fid).get("totals").is_none(), "{}", saved(&hub, &fid));
    assert_eq!(saved(&hub, &id)["totals"]["costUsd"], 0.25, "{}", saved(&hub, &id));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn turn_usage_of_a_harness_that_reports_none_is_absent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(&mut c, &id, "hi").await;

    let turns = turn_results(&hub, &id);
    assert_eq!(turns.len(), 1, "{turns:?}");
    assert_eq!(spend(&turns[0]), json!({}), "{}", turns[0]);
    assert!(saved(&hub, &id).get("totals").is_none(), "{}", saved(&hub, &id));
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert!(info["totals"].is_null(), "{info}");
}

#[test]
fn turn_usage_absent_from_an_old_session_json_still_loads() {
    let old: acpmux::store::SessionMeta = serde_json::from_value(json!({
        "schema": "acpmux.session.v1",
        "id": "old",
        "name": "old",
        "harness": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
        "turnCount": 4,
        "usage": {"used": 10, "size": 100},
    }))
    .unwrap();
    assert_eq!(old.turn_count, 4);
    let back = serde_json::to_value(&old).unwrap();
    assert!(back.get("totals").is_none(), "{back}");
}
