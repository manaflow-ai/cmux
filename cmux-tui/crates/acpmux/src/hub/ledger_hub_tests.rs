//! The cost ledger fed by the hub's own append path (`hub/ledger`): a turn's records reach it
//! from `append_record_locked`, and a read answers from its index.

use super::*;
use crate::hub::ledger::LedgerQuery;
use crate::store::{MemoryStore, SessionMeta};

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "ledger chat", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        "workspaceId": "ws-9", "gitBranch": "topic", "claudeProfile": "work",
    }))
    .unwrap()
}

#[tokio::test]
async fn appended_turns_reach_the_ledger_and_a_pull_request_names_the_repo() {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    let session = hub.insert_test_session(meta("chat"));
    hub.append(&session, "mux", "user_message", json!({"text": "go"}));
    hub.append(&session, "mux", "turn_started", json!({}));
    hub.append(&session, "in", "tool_call", json!({}));
    hub.append(&session, "in", "tool_call", json!({}));
    hub.ledger.note_pull_request("chat", "https://github.com/acme/widgets/pull/3");
    hub.append(
        &session,
        "mux",
        "turn_result",
        json!({"status": "completed", "model": "claude-opus-5-5", "costUsd": 0.75,
               "inputTokens": 10, "outputTokens": 20}),
    );
    let now = crate::store::now_ms();
    let q = LedgerQuery::from_params(&json!({"since": now - 60_000, "until": now + 60_000}), now)
        .unwrap();
    let reply = serde_json::to_value(hub.ledger.query(&q)).unwrap();
    assert_eq!(reply["totals"]["turns"], 1);
    assert_eq!(reply["totals"]["toolCalls"], 2);
    assert_eq!(reply["totals"]["harnessCostUsd"], 0.75);
    let row = &reply["rows"][0];
    assert_eq!(row["sessionId"], "chat");
    assert_eq!(row["vendor"], "anthropic");
    assert_eq!(row["workspaceId"], "ws-9");
    assert_eq!(row["branch"], "topic");
    assert_eq!(row["account"], "work");
    assert_eq!(row["repo"], "acme/widgets");
    assert_eq!(reply["rollups"]["pr"][0]["label"], "acme/widgets#3");
}

/// A fork's meta counts the parent's turns it copied; its first-start seed counts only the turns
/// after its `forked` record, the ones its own totals paid for.
#[tokio::test]
async fn a_forks_seed_counts_only_its_own_turns() {
    use crate::store::{EventRecord, Store as _};
    let store = MemoryStore::default();
    let mut m = meta("fork");
    m.parent_id = Some("parent".into());
    m.turn_count = 4;
    m.totals = Some(crate::store::TurnUsage { cost_usd: Some(2.0), ..Default::default() });
    store.save(&m).unwrap();
    let kinds = ["turn_result", "turn_result", "turn_result", "forked", "turn_result"];
    for (i, kind) in kinds.into_iter().enumerate() {
        let rec = EventRecord {
            seq: i as u64 + 1,
            at: 10,
            dir: "mux".into(),
            kind: kind.into(),
            msg: json!({}),
            host_seq: None,
        };
        store.append("fork", &rec).unwrap();
    }
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(store));
    assert_eq!(hub.fork_own_turns(&m), Some(1));
    assert_eq!(ledger::Seed::of(&m, hub.fork_own_turns(&m)).turns, 1);
    // Not a fork: the meta's own count.
    assert_eq!(hub.fork_own_turns(&meta("plain")), None);
    assert_eq!(ledger::Seed::of(&m, None).turns, 4);
}
