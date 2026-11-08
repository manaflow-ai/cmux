//! A send's `sender_claim` (`sender_harness.rs`), read by a chat client through the daemon's
//! transcript filter (attach and history pages).

use super::*;
use crate::sender_harness::RECORD_KIND;

fn hub_with_chat(id: &str) -> (Arc<Hub>, Arc<Session>) {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/w",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    (hub, session)
}

#[test]
fn a_sender_claim_reaches_a_chat_client_through_the_transcript_filter() {
    let (hub, s) = hub_with_chat("a");
    let claim = json!({"promptId": "p-1", "claimed": {"harness": "codex", "selfReported": true}});
    hub.append(&s, "mux", RECORD_KIND, claim.clone());
    let filter = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
    let page = hub.events_page("a", 0, None, 100, None, false, &filter).unwrap();
    let claims: Vec<Value> = page
        .events
        .into_iter()
        .filter(|r| r.dir == "mux" && r.kind == RECORD_KIND)
        .map(|r| r.msg)
        .collect();
    assert_eq!(claims, vec![claim]);
}
