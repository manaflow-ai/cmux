//! A send's `sender_claim` (`sender_harness.rs`): written only once its prompt is kept, and read
//! by a chat client through the daemon's transcript filter (attach and history pages).

use super::*;
use crate::sender_harness::{RECORD_KIND, on_kept};

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

fn claims(hub: &Hub, id: &str) -> Vec<Value> {
    let filter = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
    let page = hub.events_page(id, 0, None, 100, None, false, &filter).unwrap();
    page.events
        .into_iter()
        .filter(|r| r.dir == "mux" && r.kind == RECORD_KIND)
        .map(|r| r.msg)
        .collect()
}

fn accept_with_claim(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    claim: &Value,
) -> Box<dyn FnOnce(Value) + Send> {
    let (hub, s) = (hub.clone(), s.clone());
    let write = move |claim: Value| {
        hub.append(&s, "mux", RECORD_KIND, claim);
    };
    on_kept(claim.clone(), write, None).unwrap()
}

#[test]
fn a_claim_is_written_only_once_its_prompt_is_kept() {
    let (hub, s) = hub_with_chat("a");
    let claim = json!({"promptId": "p-1", "claimed": {"harness": "codex", "selfReported": true}});
    let accept = accept_with_claim(&hub, &s, &claim);
    assert!(claims(&hub, "a").is_empty(), "nothing is written before the prompt is kept");
    accept(json!({"sessionId": "a", "promptId": "p-1", "queued": false}));
    assert_eq!(claims(&hub, "a"), vec![claim]);
}

#[test]
fn a_duplicate_or_refused_prompt_writes_no_claim() {
    let (hub, s) = hub_with_chat("a");
    let claim = json!({"promptId": "p-1", "claimed": {"harness": "codex", "selfReported": true}});
    accept_with_claim(&hub, &s, &claim)(json!({"promptId": "p-1", "duplicate": true}));
    // A refused prompt never calls its acceptance.
    drop(accept_with_claim(&hub, &s, &claim));
    assert!(claims(&hub, "a").is_empty());
}
