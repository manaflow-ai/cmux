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
