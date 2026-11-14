use super::*;

#[test]
fn only_a_steer_with_a_fallback_runs_next() {
    assert!(runs_next(&json!({"text": "a tell", "steer": true, "client": "acpmux"})));
    assert!(!runs_next(&json!({"text": "x", "steer": true, "steerOnly": true})));
    assert!(!runs_next(&json!({"text": "x", "steer": true, "client": "workflow"})));
    let cap = json!({"kind": super::super::turn_cap::NOTICE_KIND});
    assert!(!runs_next(&json!({"text": "x", "steer": true, "_meta": {"provenance": cap}})));
    let inbox = json!({"kind": super::super::inbox::NOTICE_KIND});
    assert!(!runs_next(&json!({"text": "x", "steer": true, "_meta": {"provenance": inbox}})));
}

/// A hub whose chat logged one steer, `p-1`, into turn `t-1`.
fn hub_with_a_steer() -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": "s-1", "name": "s-1",
            "harness": "claude", "family": "claude", "cwd": "/nonexistent", "status": "running",
            "createdAt": 1, "updatedAt": 1});
    let session = hub.insert_test_session(serde_json::from_value(meta).unwrap());
    hub.save_meta(&session);
    let steer = json!({"text": "a tell", "steer": true, "client": "acpmux", "promptId": "p-1",
            "turnId": "t-1", "control": "local", "trustGate": false});
    hub.append(&session, "mux", "user_message", steer);
    (hub, session)
}

/// The `queued` records of steer `p-1`.
fn queued(hub: &Hub, session: &Session) -> usize {
    let records = hub.events(&session.id, 0, 1_000_000).unwrap();
    let own = |r: &&EventRecord| r.kind == "queued" && r.msg["promptId"] == "p-1";
    records.iter().filter(own).count()
}

/// A shutdown or an update cancels the hub's scope while the watch of a recovered steer's
/// answer waits: it writes nothing (the steer is not half put back), the recovered turn's
/// wait sees the answer gone, and the next daemon, which finds the answer in the host's log,
/// puts the steer back once.
#[tokio::test]
async fn a_cancelled_watch_leaves_the_steer_for_the_next_daemon() {
    let (hub, session) = hub_with_a_steer();
    let (agent, answer) = tokio::sync::oneshot::channel();
    let watched = hub.unread_steer_runs_next(&session, Some("p-1".into()), answer);
    hub.scope.token().cancel();
    assert!(watched.await.is_err(), "the cancelled watch still passed an answer on");
    let unread = Err(RpcError::invalid_params(crate::claude_stdio::STEER_NO_TURN));
    let _ = agent.send(unread);
    tokio::task::yield_now().await;
    assert_eq!(queued(&hub, &session), 0, "the cancelled watch put the steer back");

    let logged = json!({"jsonrpc": "2.0", "id": 7,
            "error": {"code": -32602, "message": crate::claude_stdio::STEER_NO_TURN}});
    hub.steer_answered_unread(&session, Some("p-1"), &logged);
    assert_eq!(queued(&hub, &session), 1, "the logged answer did not put the steer back");
    hub.steer_answered_unread(&session, Some("p-1"), &logged);
    assert_eq!(queued(&hub, &session), 1, "the steer was put back twice");
    let steered = json!({"jsonrpc": "2.0", "id": 8, "result": {"stopReason": "steered"}});
    hub.steer_answered_unread(&session, Some("p-1"), &steered);
    assert_eq!(queued(&hub, &session), 1);
}
