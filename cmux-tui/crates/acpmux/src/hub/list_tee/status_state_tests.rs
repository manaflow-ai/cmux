use super::*;
use serde_json::{Value, json};

async fn fixture() -> (Arc<Hub>, Arc<Session>) {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.wait_store().await;
    let session = hub.insert_test_session(
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat",
            "title": "token ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234",
            "harness": "fake", "cwd": "/tmp", "status": "running",
            "createdAt": 1, "updatedAt": crate::store::now_ms()
        }))
        .unwrap(),
    );
    (hub, session)
}

fn make_stuck(hub: &Hub, session: &Session) {
    hub.edit_test_meta(session, |meta| {
        let base = meta.harness_failures.through_seq;
        for offset in 1..=3 {
            meta.harness_failures.observe(
                &json!({"status": "failed", "errorText": "HTTP 503"}),
                base + offset,
                offset * 10,
            );
        }
    });
}

fn assert_status_state(summary: &Summary, expected: &Value) {
    let converted = acpmux_client::v1_row(summary, OriginState::Connected, None);
    assert_eq!(summary.state, expected["state"]);
    assert_eq!(converted["status"], expected["status"]);
    assert_eq!(converted["state"], expected["state"]);
    let extra: Value = serde_json::from_str(summary.extra.get()).unwrap();
    if expected["status"] == expected["state"] {
        assert!(extra.get("status").is_none(), "ordinary rows carry no redundant status");
    } else {
        assert_eq!(extra["status"], expected["status"]);
    }
}

#[tokio::test]
async fn v1_status_state_roundtrip_local_remote_and_masked_rows() {
    for state in ["running", "stuck", "stopping"] {
        let (hub, session) = fixture().await;
        if state == "stuck" {
            make_stuck(&hub, &session);
        } else if state == "stopping" {
            *session.turn.lock().unwrap() =
                Some(TurnInfo::prompted("fake", "chat", "turn", "prompt", Control::Local));
            *session.stopping.lock().unwrap() = Some("turn".into());
        }
        let expected = hub.session_list_summary(&session);
        assert_eq!(expected["status"], "running");
        assert_eq!(expected["state"], state);
        let local = summary_from_session(&hub, &session).unwrap();
        assert_status_state(&local, &expected);
        let masked: Summary =
            serde_json::from_str(local.peer_form.as_ref().unwrap().get()).unwrap();
        assert_status_state(&masked, &expected);
        let remote = summary_from_remote("peer", &PeerRow::new(&expected)).unwrap();
        assert_status_state(&remote, &expected);
    }
}

#[test]
fn v1_status_state_old_peer_without_state_uses_status_without_extra() {
    let old = json!({"sessionId": "old", "harness": "fake", "status": "waiting"});
    let summary = summary_from_remote("peer", &PeerRow::new(&old)).unwrap();
    assert_status_state(&summary, &json!({"status": "waiting", "state": "waiting"}));
}

#[tokio::test]
async fn v1_status_state_leaving_stuck_drops_extra_status_in_one_submit() {
    let (v1, session) = fixture().await;
    make_stuck(&v1, &session);
    let initial = summary_from_session(&v1, &session).unwrap();
    assert_status_state(&initial, &v1.session_list_summary(&session));
    let index = acpmux_book::index::SummaryIndex::new().apply(1, initial.clone());
    let (hub, writer) = acpmux_core::hub::Hub::new(index);
    let v2 = V2::new(hub, writer);
    let subscription = v2.hub.subscribe(&acpmux_core::wire::Sub::new("test", "list")).unwrap();
    let state = Arc::new(TeeState::default());
    v1.install_v2_tee(Arc::new(TeeHandle { state: state.clone() }));
    v1.edit_test_meta(&session, |meta| {
        meta.harness_failures.observe(
            &json!({"status": "completed"}),
            meta.harness_failures.through_seq + 1,
            crate::store::now_ms(),
        );
    });
    assert_eq!(state.marks.load(Ordering::Relaxed), 1);
    drain_marks(&v1, &v2, &state, &mut Expiries::default());
    v2.hub.close();
    v2.take_writer().unwrap().run().await.unwrap();
    let Some(acpmux_core::hub::ListItem::Summary(event)) = subscription.receiver.try_next() else {
        panic!("recovery must submit a summary");
    };
    assert!(!event.summary.same_content(&initial));
    assert_status_state(&event.summary, &v1.session_list_summary(&session));
    assert_eq!(event.summary.state, "running");
    assert!(subscription.receiver.try_next().is_none(), "recovery submits exactly once");
}
