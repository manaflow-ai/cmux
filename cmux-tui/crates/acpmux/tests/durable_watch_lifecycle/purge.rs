//! Hold reconciliation until after a permission was answered and its source purged.
use acpmux::{config::Config, hub::Hub, rpc::Message, server::Origin};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::sync::mpsc;

struct Connection(mpsc::Sender<String>, mpsc::Receiver<String>);
impl Connection {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, input) = mpsc::channel(64);
        let (output, rx) = mpsc::channel(64);
        tokio::spawn(acpmux::server::serve_connection_with(
            hub.clone(),
            input,
            output,
            Origin::Local,
        ));
        Self(tx, rx)
    }
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.0.send(Message::request(1, method, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let v: Value = serde_json::from_str(&self.1.recv().await.unwrap()).unwrap();
                if v["id"] == 1 {
                    assert!(v.get("error").is_none(), "{v}");
                    return v["result"].clone();
                }
            }
        })
        .await
        .unwrap()
    }
}
#[tokio::test]
async fn answered_permission_is_checkpointed_before_source_purge_without_a_worker() {
    let dir = cmux_unix_socket::short_test_dir("wp");
    let cfg: Config = serde_json::from_value(json!({"store": {"mode": "memory"},
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake", "permissionPolicy": "ask"})).unwrap();
    let store = acpmux::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg, store);
    let mut client = Connection::new(&hub);
    let source =
        client.call("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await["sessionId"]
            .clone();
    let sink =
        client.call("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await["sessionId"]
            .clone();
    let watch = client
        .call(
            "_acpmux/watch_add",
            json!({"to": sink, "sessions": [source], "until": ["permission"]}),
        )
        .await;
    let mut events = hub.subscribe();
    let mut sender = Connection::new(&hub);
    let id = source.clone();
    let turn = tokio::spawn(async move {
        sender
            .call(
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
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": source, "permissionId": permission}),
        )
        .await;
    turn.await.unwrap();
    assert_eq!(client.call("_acpmux/watch_ls", json!({})).await["deliveries"], json!([]));
    client.call("_acpmux/kill", json!({"sessionId": source, "purge": true})).await;
    assert!(hub.resolve(source.as_str().unwrap()).is_err());
    let saved = client.call("_acpmux/watch_ls", json!({})).await;
    assert_eq!(saved["deliveries"].as_array().unwrap().len(), 1);
    assert_eq!(saved["deliveries"][0]["target"], sink);
    assert_eq!(saved["watches"][0]["id"], watch["id"]);
    assert_eq!(saved["watches"][0]["active"], false);
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
}
