use super::*;
#[tokio::test]
async fn durable_dispatch_keeps_one_destination_and_never_loses_a_finished_reply() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let params = json!({"brief":"effect","durable":true,"briefId":"placement"});
    let identity = identity(&params, "placement");
    let (one, two) = tokio::join!(
        reserve_remote(&hub, None, &params, "placement", &identity, "one"),
        reserve_remote(&hub, None, &params, "placement", &identity, "two"),
    );
    assert_ne!(one.is_ok(), two.is_ok(), "two destinations admitted one effect");
    let pending = hub.briefs.get("placement").unwrap();
    let mut finished = pending.clone();
    finished.set("status", json!("reported"));
    finished.set("outcome", json!({"Ok":{"finalReply":"exact reply"}}));
    let mut remote = finished.clone();
    remote.set("dispatchLocal", json!(true));
    let cached = cache_remote(&hub, "placement", &identity, remote).await.unwrap();
    assert!(cached.get("dispatchLocal").is_none(), "a peer's reservation was marked local here");
    let late = cache_remote(&hub, "placement", &identity, pending).await.unwrap();
    assert_eq!(late, finished, "a late pending response erased the final reply");
    assert_eq!(hub.briefs.get("placement"), Some(finished));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn cache_remote_rejects_peer_key_or_durability_changes_and_keeps_local_routing() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let params = json!({
        "briefId":"local-id",
        "durable":true,
        "receiptToken":"1111111111111111111111111111111111111111111111111111111111111111",
        "brief":"local brief",
        "title":"local title"
    });
    let identity = identity(&params, "local-id");
    reserve_remote(&hub, Some("caller"), &params, "local-id", &identity, "paired-target")
        .await
        .unwrap();
    let reserved = hub.briefs.get("local-id").unwrap();
    let victim = json!({
        "briefId":"other-id",
        "durable":true,
        "sessionId":"wfd-victim",
        "promptId":"wfp-victim",
        "dispatchFingerprint":"victim-fingerprint",
        "status":"running"
    });
    hub.briefs.put_durable(victim.clone()).unwrap();

    let mut wrong_id = reserved.clone();
    wrong_id.set("briefId", json!("other-id"));
    assert!(cache_remote(&hub, "local-id", &identity, wrong_id).await.is_err());
    assert_eq!(hub.briefs.get("other-id"), Some(victim), "peer key overwrote another receipt");
    assert_eq!(hub.briefs.get("local-id"), Some(reserved.clone()));

    let mut advisory = reserved.clone();
    advisory.set("durable", json!(false));
    assert!(cache_remote(&hub, "local-id", &identity, advisory).await.is_err());
    assert_eq!(hub.briefs.get("local-id"), Some(reserved.clone()));

    let mut finished = reserved.clone();
    finished.set("host", json!("attacker-host"));
    finished.set("fromSession", json!("attacker-caller"));
    finished.set("dispatchLocal", json!(true));
    finished.set("status", json!("reported"));
    finished.set("outcome", json!({"Ok":{"finalReply":"done"}}));
    let cached = cache_remote(&hub, "local-id", &identity, finished).await.unwrap();
    assert_eq!(cached["host"], reserved["host"]);
    assert_eq!(cached["fromSession"], reserved["fromSession"]);
    assert!(cached.get("dispatchLocal").is_none());
    assert_eq!(cached["outcome"]["Ok"]["finalReply"], "done");
    hub.shutdown_all().await;
}

#[test]
fn durable_dispatch_pins_execution_inputs_but_not_forwarding_metadata() {
    let base = json!({"durable":true,"receiptToken":"1111111111111111111111111111111111111111111111111111111111111111","briefId":"activity","brief":"original","harness":"codex"});
    assert!(requested(&base).unwrap());
    assert!(requested(&json!({"durable":true})).is_err());
    let identity = identity(&base, "activity");
    let mut forwarded = base.clone();
    forwarded.set("forwarded", json!(true));
    forwarded.set("host", json!("remote"));
    assert_eq!(identity.fingerprint, super::identity(&forwarded, "activity").fingerprint);
    let row = pending(&base, "activity", &identity, "remote");
    check(&row, &identity).unwrap();
    forwarded.set("brief", json!("changed"));
    assert!(check(&row, &super::identity(&forwarded, "activity")).is_err());
    assert_ne!(identity.session_id, super::identity(&base, "another").session_id);
}
