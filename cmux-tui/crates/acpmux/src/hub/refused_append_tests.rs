//! Rework stage 3, C3: an event the store refused is not broadcast, and the chat's `last_seq`
//! does not move past it. Viewers used to see an event no log held, which a later catch-up from
//! the log contradicted.

use crate::config::{Config, StoreMode};
use crate::store::REFUSE_APPENDS;
use serde_json::json;

#[tokio::test]
async fn an_event_the_store_refused_is_not_broadcast_and_moves_no_cursor() {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "refused", "name": "lane", "harness": "claude",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = super::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert("refused".to_owned(), session.clone());
    let mut events = hub.subscribe();
    let before = session.meta().last_seq;

    REFUSE_APPENDS.with(|r| r.set(true));
    let (_, stored) = hub.append_logged(&session, "mux", "note", json!({"n": 1}), None);
    REFUSE_APPENDS.with(|r| r.set(false));
    assert!(!stored);
    assert_eq!(session.meta().last_seq, before, "a refused record moves no cursor");
    while let Ok(ev) = events.try_recv() {
        assert!(
            !(ev.session_id == "refused" && ev.record.kind == "note"),
            "a refused record was broadcast: {:?}",
            ev.record
        );
    }

    let (record, stored) = hub.append_logged(&session, "mux", "note", json!({"n": 2}), None);
    assert!(stored);
    assert_eq!(session.meta().last_seq, record.seq);
    let mut heard = false;
    while let Ok(ev) = events.try_recv() {
        heard |= ev.session_id == "refused" && ev.record.kind == "note" && ev.record.msg["n"] == 2;
    }
    assert!(heard, "a stored record is broadcast");
}

/// A fork whose copy of the chat's history the journal refused fails, rather than reading as
/// whole with records missing (a refused copy is neither stored nor heard).
#[tokio::test(flavor = "current_thread")]
async fn a_fork_whose_copy_the_store_refused_fails() {
    use super::NewRequest;
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                     "titles": {"generate": false}});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = super::Hub::new(cfg, store);
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"first"})], "test", false).await.unwrap();
    {
        let mut meta = parent.meta.lock().unwrap();
        meta.status = crate::store::SessionStatus::Running;
        // No native fork: the fork copies the mux log.
        meta.agent_capabilities = Some(json!({}));
    }
    let chats = hub.sessions.lock().unwrap().len();

    REFUSE_APPENDS.with(|r| r.set(true));
    let fork = hub.fork(&parent, None, None, Default::default(), None, None, true).await;
    REFUSE_APPENDS.with(|r| r.set(false));
    let err = fork.err().expect("a fork with refused copies fails");
    assert_eq!(err.data.as_ref().and_then(|d| d["reason"].as_str()), Some("fork.incomplete"));
    // The failed fork is purged (`CreationGuard`, on its own task).
    let purged = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        while hub.sessions.lock().unwrap().len() != chats {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    });
    assert!(purged.await.is_ok(), "the failed fork is not listed");
}
