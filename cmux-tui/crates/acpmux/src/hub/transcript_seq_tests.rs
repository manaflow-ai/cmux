//! A chat's summary names its newest transcript record (`transcriptSeq`), which bookkeeping
//! never moves. The app's agent pane re-reads a chat it keeps ahead (webviews `direct.ts`
//! `readAhead`, up to 128 KiB a chat) when this passes the value it read at: `updatedAt` moved
//! with every record, `agent_start_waiting` every 10 s among them, and kept the pane re-reading
//! chats whose transcript never changed.

use super::*;
use crate::store::{MemoryStore, SessionMeta};

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "waiting chat", "harness": "codex",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

fn transcript_seq(hub: &Hub, session: &Session) -> u64 {
    hub.session_summary(session)["transcriptSeq"].as_u64().expect("transcriptSeq")
}

#[tokio::test]
async fn bookkeeping_never_moves_transcript_seq_and_a_transcript_record_does() {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    let session = hub.insert_test_session(meta("chat"));
    let prompt = hub.append(&session, "mux", "user_message", json!({"text": "hi"}));
    assert_eq!(transcript_seq(&hub, &session), prompt.seq);
    let reply = hub.append(
        &session,
        "in",
        "agent_message_chunk",
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "n",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello"}}}}),
    );
    assert_eq!(transcript_seq(&hub, &session), reply.seq);
    let updated = session.meta().updated_at;
    for waited in 1..=6u64 {
        hub.append(&session, "mux", "agent_start_waiting", json!({"waitedMs": waited * 10_000}));
        hub.append(&session, "mux", "usage_stats", json!({}));
        hub.append(&session, "mux", "git", json!({"branch": "main"}));
        hub.append(
            &session,
            "in",
            "usage_update",
            json!({"jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "n", "update": {"sessionUpdate": "usage_update"}}}),
        );
    }
    assert!(session.meta().last_seq > reply.seq);
    assert!(session.meta().updated_at >= updated);
    assert_eq!(transcript_seq(&hub, &session), reply.seq, "bookkeeping moved transcriptSeq");
    let next = hub.append(&session, "mux", "user_message", json!({"text": "again"}));
    assert_eq!(transcript_seq(&hub, &session), next.seq);
}
