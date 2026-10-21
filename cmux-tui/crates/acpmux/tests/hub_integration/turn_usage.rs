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

    // A new Claude process whose running total started over (0.25, below 0.5): that turn's
    // share is unknown, so it records no cost rather than a guess; the next one is measured.
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    say(&mut c, &id, "cost-probe").await;
    say(&mut c, &id, "cost-probe").await;
    let turns = turn_results(&hub, &id);
    let tokens_only = json!({"inputTokens": 100, "outputTokens": 20,
                             "cacheReadTokens": 300, "cacheWriteTokens": 40});
    assert_eq!(spend(&turns[2]), tokens_only, "{turns:?}");
    assert_eq!(spend(&turns[3]), one, "{turns:?}");

    // A turn that reports tokens but no cost adds its tokens and no cost.
    say(&mut c, &id, "hello").await;
    let last = turn_results(&hub, &id)[4].clone();
    assert_eq!(spend(&last), json!({"inputTokens": 1, "outputTokens": 1}), "{last}");
    let totals = json!({"costUsd": 0.75, "inputTokens": 401, "outputTokens": 81,
                        "cacheReadTokens": 1200, "cacheWriteTokens": 160});
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
async fn turn_usage_counts_a_restored_total_once_and_ignores_a_zeroed_one() {
    let root = std::env::temp_dir().join(format!("acpmux-turn-usage-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(&mut c, &id, "cost-probe").await;
    say(&mut c, &id, "cost-probe").await;

    // A resumed Claude Code restores its running total (0.5) and adds this turn's 0.25.
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    say(&mut c, &id, "cost-restore 0.5").await;
    // A zeroed total (a crashed process's last result) is no restart: the next turn is
    // measured from 0.75, not from 0.
    say(&mut c, &id, "cost-zero").await;
    say(&mut c, &id, "cost-probe").await;
    let costs: Vec<Value> = turn_results(&hub, &id).iter().map(|t| t["costUsd"].clone()).collect();
    assert_eq!(costs, [json!(0.25), json!(0.25), json!(0.25), Value::Null, json!(0.25)]);
    assert_eq!(saved(&hub, &id)["totals"]["costUsd"], 1.0, "{}", saved(&hub, &id));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn turn_usage_of_a_fork_through_an_earlier_turn_does_not_count_its_history() {
    let root = std::env::temp_dir().join(format!("acpmux-turn-usage-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(&mut c, &id, "cost-probe").await;
    say(&mut c, &id, "cost-probe").await;
    let first = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .find(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .unwrap();

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": first})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    // The fork's Claude Code restores the total as of the cut (0.25), not the parent's 0.5:
    // the fork cannot tell that history from this turn, so it records no cost for it.
    say(&mut c, &fid, "cost-restore 0.25").await;
    say(&mut c, &fid, "cost-probe").await;
    let costs: Vec<Value> = turn_results(&hub, &fid).iter().map(|t| t["costUsd"].clone()).collect();
    // The copied first turn, then the fork's own two.
    assert_eq!(costs, [json!(0.25), Value::Null, json!(0.25)]);
    assert_eq!(saved(&hub, &fid)["totals"]["costUsd"], 0.25, "{}", saved(&hub, &fid));
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
