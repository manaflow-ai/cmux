//! `_acpmux/host_notice` (`server/host_notice.rs`): the line lands in every live chat's journal,
//! as a transcript record a chat client reads, and never in a closed chat.

use super::*;
use crate::server::host_notice::{KIND, append_all};

fn hub_with(chats: &[(&str, &str)]) -> Arc<Hub> {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    for (id, status) in chats {
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/w",
            "status": status, "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert((*id).to_owned(), session);
    }
    hub
}

fn notices(hub: &Hub, id: &str, kinds: Value) -> Vec<Value> {
    let filter = EventFilter::parse(Some(&kinds)).unwrap();
    let page = hub.events_page(id, 0, None, 100, None, false, &filter).unwrap();
    page.events.into_iter().filter(|r| r.dir == "mux" && r.kind == KIND).map(|r| r.msg).collect()
}

#[test]
fn a_host_notice_lands_in_every_live_chat_as_a_transcript_record() {
    let hub = hub_with(&[("a", "idle"), ("b", "running"), ("gone", "closed")]);
    let text = "Machine grew to 4 vCPU / 8 GiB (it ran out of memory)";
    assert_eq!(append_all(&hub, text), 2);
    let want = vec![json!({"text": text, "source": "cloud"})];
    for id in ["a", "b"] {
        assert_eq!(notices(&hub, id, json!(["transcript"])), want, "{id}");
    }
    assert!(notices(&hub, "gone", json!(["all"])).is_empty(), "a closed chat is left alone");
    assert!(paging::TRANSCRIPT_MUX_KINDS.contains(&KIND));
}
