use super::*;
use crate::store::{MemoryStore, SessionMeta};

#[test]
fn unbounded_reply_keeps_long_reviewer_text() {
    let text = format!(r#"{{"winnerId":"c1","reason":"{}"}}"#, "x".repeat(4_480));
    let events = text
        .chars()
        .enumerate()
        .map(|(index, chunk)| crate::store::EventRecord {
            seq: u64::try_from(index + 1).unwrap(),
            at: 0,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({
                "method": method::SESSION_UPDATE,
                "params": {"update": {"content": {"text": chunk.to_string()}}}
            }),
            host_seq: None,
        })
        .collect::<Vec<_>>();
    let last = u64::try_from(events.len()).unwrap();
    assert!(events.len() > MAX_REPLY_CHARS);
    assert_eq!(masked_reply(&events, last, None).unwrap(), text);
    assert!(masked_reply(&events, last, Some(MAX_REPLY_CHARS)).unwrap().ends_with('…'));
}

#[test]
fn unbounded_reply_pages_past_four_thousand_stored_chunks() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(config, Box::new(MemoryStore::default()));
    let session: Arc<Session> = hub.insert_test_session(
        serde_json::from_value::<SessionMeta>(json!({
            "schema": crate::store::META_SCHEMA,
            "id": "race-review",
            "name": "race review",
            "harness": "codex",
            "cwd": "/tmp",
            "status": "running",
            "createdAt": 1,
            "updatedAt": 2
        }))
        .unwrap(),
    );
    hub.save_meta(&session);
    let mut chunk_id = 0u64;
    let mut update = |text: &str| {
        chunk_id += 1;
        hub.append(
            &session,
            "in",
            "agent_message_chunk",
            json!({
                "method": method::SESSION_UPDATE,
                "params": {"update": {"content": {"text": text}, "chunkId": chunk_id}}
            }),
        );
    };
    hub.append(&session, "mux", "turn_started", json!({"turnId": "old"}));
    update("old turn");
    hub.append(&session, "mux", "turn_started", json!({"turnId": "review"}));
    let expected = format!(r#"{{"winnerId":"c1","reason":"{}"}}"#, "x".repeat(4_480));
    for chunk in expected.chars() {
        update(&chunk.to_string());
    }

    let got = hub.last_reply_unbounded(&session).expect("review reply");
    assert_eq!(got, expected);
    assert!(got.len() > MAX_REPLY_CHARS);
    assert!(serde_json::from_str::<Value>(&got).is_ok());
}
