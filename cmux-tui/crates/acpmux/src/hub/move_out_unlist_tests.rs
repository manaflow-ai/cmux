//! A chat moved out leaves the hub's address book as its move commits, not at the next
//! heartbeat: else the hub lists the closed copy beside the one that runs (`mesh.ambiguous` for a
//! bare-id control, the offload roundtrip's purge after a move back home).

use super::*;
use crate::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use futures::future::BoxFuture;
use std::time::Duration;

/// Records each heartbeat's session ids; nothing else is called.
#[derive(Default)]
struct Beats(std::sync::Mutex<Vec<Vec<String>>>);

impl MeshHub for Beats {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(std::future::pending())
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }
    fn heartbeat<'a>(
        &'a self,
        beat: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        let ids = beat.sessions.iter().map(|r| r.session_id.clone()).collect();
        self.0.lock().unwrap().push(ids);
        Box::pin(async { Ok(HeartbeatReply { daemon_id: "inst_a".into(), ttl_seconds: 90 }) })
    }
    fn send<'a>(&'a self, _: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(std::future::pending())
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(std::future::pending())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_committed_move_out_unlists_the_chat_within_the_heartbeat_floor() {
    let mut config: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let id = uuid::Uuid::now_v7().to_string();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "roundtrip", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.clone(), session.clone());
    let fake = Arc::new(Beats::default());
    let control = Arc::new(crate::server::mesh_relay::MeshControlHook::new(vec![], None));
    let relay = crate::server::mesh_relay::MeshRelay::start(
        &hub,
        fake.clone(),
        control,
        crate::server::mesh_relay::RelayOptions {
            heartbeat_every: Duration::from_secs(60),
            ..Default::default()
        },
    );
    let first = async {
        while fake.0.lock().unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(10), first).await.expect("a first heartbeat");
    assert!(fake.0.lock().unwrap()[0].contains(&id), "the chat is listed before its move");
    let transfer = format!("tx-unlist-{}", uuid::Uuid::now_v7());
    *session.moving.lock().unwrap() = Some(transfer.clone());
    hub.transfer_commit_with_epoch(&session, &transfer, json!({}), None, None)
        .await
        .expect("the commit");
    // Within the heartbeat floor (2.5 s), far under the 30 s timed beat this test sets to 60 s.
    let unlisted = async {
        loop {
            if fake.0.lock().unwrap().last().is_some_and(|ids| !ids.contains(&id)) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    let sent = tokio::time::timeout(Duration::from_secs(6), unlisted).await;
    assert!(
        sent.is_ok(),
        "no heartbeat after the commit unlisted the moved chat: {:?}",
        fake.0.lock().unwrap()
    );
    drop(relay);
}
