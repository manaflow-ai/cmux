//! Hold reconciliation until after a permission was answered and its source purged.
use acpmux::{config::Config, hub::Hub, server::Origin};
use serde_json::json;
use std::time::Duration;

#[path = "connection.rs"]
mod connection;
use connection::Connection;
#[tokio::test]
async fn answered_permission_is_checkpointed_before_source_purge_without_a_worker() {
    let dir = cmux_unix_socket::short_test_dir("wp");
    let cfg: Config = serde_json::from_value(json!({"store": {"mode": "memory"},
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake", "permissionPolicy": "ask"})).unwrap();
    let store = acpmux::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg, store);
    let mut client = Connection::new(&hub, Origin::Local);
    let source =
        client.result("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await["sessionId"]
            .clone();
    let sink =
        client.result("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await["sessionId"]
            .clone();
    let watch = client
        .result(
            "_acpmux/watch_add",
            json!({"to": sink, "sessions": [source], "until": ["permission"]}),
        )
        .await;
    let mut events = hub.subscribe();
    let mut sender = Connection::new(&hub, Origin::Local);
    let id = source.clone();
    let turn = tokio::spawn(async move {
        sender
            .result(
                "session/prompt",
                json!({"sessionId": id,
        "prompt": [{"type": "text", "text": "permission-batch: single"}]}),
            )
            .await
    });
    let permission = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let e = events.recv().await.unwrap();
            if e.record.kind == "permission_request" {
                break e.record.msg["permissionId"].clone();
            }
        }
    })
    .await
    .unwrap();
    client
        .result(
            "_acpmux/permission_respond",
            json!({"sessionId": source, "permissionId": permission}),
        )
        .await;
    turn.await.unwrap();
    assert_eq!(client.result("_acpmux/watch_ls", json!({})).await["deliveries"], json!([]));
    client.result("_acpmux/kill", json!({"sessionId": source, "purge": true})).await;
    assert!(hub.resolve(source.as_str().unwrap()).is_err());
    let saved = client.result("_acpmux/watch_ls", json!({})).await;
    assert_eq!(saved["deliveries"].as_array().unwrap().len(), 1);
    assert_eq!(saved["deliveries"][0]["target"], sink);
    assert_eq!(saved["watches"][0]["id"], watch["id"]);
    assert_eq!(saved["watches"][0]["active"], false);
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
}
