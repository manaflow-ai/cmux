//! `_acpmux/events` after a hard stop: the log holds records the saved session does not count.

use super::*;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};

/// A chat whose `session.json` was last saved at seq 2 while its log went on to seq 5, as a hard
/// stop leaves it, in a daemon that started without reading chat logs yet (`new_deferred`).
fn hard_stopped() -> Arc<Hub> {
    let store = MemoryStore::default();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "chat", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": 2, "eventCount": 2,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    for seq in 1..=5 {
        let record = EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({"text": format!("part {seq}")}),
            host_seq: None,
        };
        store.append("c", &record).unwrap();
    }
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    Hub::new_deferred(config, Box::new(store), crate::mailbox::Mailbox::memory())
}

fn seqs(page: &Value) -> Vec<u64> {
    page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

/// A client that saw seq 3 before the stop (a lag's resync, a reconnect reading its own cursor)
/// reads what came after it, not `cursor_future`, before the chat's log is loaded.
#[test]
fn a_read_past_the_saved_last_seq_gets_the_logs_tail_before_the_log_loads() {
    let hub = hard_stopped();
    let page = handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "afterSeq": 3}), None)
        .expect("the log holds seq 4 and 5: the read is not past the last event");
    assert_eq!(seqs(&page), [4, 5]);
    assert_eq!(page["lastSeq"], 5);
    assert_eq!(page["pageThrough"], 5);

    // A read from inside the saved run says the log's end too, so a cursor moves past it.
    let hub = hard_stopped();
    let page = handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "afterSeq": 1}), None)
        .unwrap();
    assert_eq!(seqs(&page), [2, 3, 4, 5]);
    assert_eq!(page["lastSeq"], 5);

    // One truly past the log is still refused.
    let hub = hard_stopped();
    let past = handle(&hub, method::MUX_EVENTS, &json!({"sessionId": "c", "afterSeq": 9}), None)
        .unwrap_err();
    assert!(past.message.contains("cursor_future"), "{}", past.message);
}
