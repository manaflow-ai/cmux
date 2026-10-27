//! Idle harness reclamation: an attachment is not work; a request is.
use super::*;

async fn until(mut condition: impl FnMut() -> bool) {
    let end = tokio::time::Instant::now() + Duration::from_secs(20);
    while !condition() {
        assert!(tokio::time::Instant::now() < end, "hibernation condition timed out");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn hibernation_attached_idle_chat_wakes_on_send_in_the_same_session() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(2)));
    let made =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap();
    let session = hub.resolve(id).unwrap();
    let agent = session.meta().agent_session_id;
    clock.advance(Duration::from_secs(3));
    until(|| session.meta().status == acpmux::store::SessionStatus::Idle).await;
    let reply = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "after sleep"}]}),
        )
        .await
        .unwrap();
    assert_eq!(reply["stopReason"], "end_turn");
    assert_eq!(session.meta().agent_session_id, agent);
    let records = hub.events(id, 0, 1000).unwrap();
    assert!(records.iter().any(|e| e.kind == "hibernated"));
    let resumed = records.iter().position(|e| e.kind == "resumed").unwrap();
    let prompt =
        records.iter().position(|e| e.dir == "out" && e.kind == method::SESSION_PROMPT).unwrap();
    assert!(resumed < prompt, "the message must wait for resume");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn hibernation_never_kills_a_config_request_waiting_for_its_reply() {
    let (hub, mut c) = setup_env(
        PermissionPolicy::ApproveAll,
        BTreeMap::from([("FAKE_SET_MODE_DELAY_MS".into(), "1500".into())]),
    )
    .await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(2)));
    let made =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let before = session.meta().last_seq;
    let changing = {
        let hub = hub.clone();
        let session = session.clone();
        tokio::spawn(async move {
            hub.forward(&session, method::SESSION_SET_MODE, json!({"modeId": "ask"})).await
        })
    };
    until(|| {
        hub.events(&id, before, 1000)
            .unwrap()
            .iter()
            .any(|e| e.dir == "out" && e.kind == method::SESSION_SET_MODE)
    })
    .await;
    clock.advance(Duration::from_secs(3));
    assert!(changing.await.unwrap().is_ok(), "idle reclamation killed a config request");
    hub.shutdown_all().await;
}
