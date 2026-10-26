//! Watch RPC authority and actionable validation, through real connection dispatch.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
use acpmux::{config::Config, hub::Hub, rpc::Message, server::Origin};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::sync::mpsc;

struct Connection(mpsc::Sender<String>, mpsc::Receiver<String>);
impl Connection {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, input) = mpsc::channel(64);
        let (output, rx) = mpsc::channel(64);
        tokio::spawn(acpmux::server::serve_connection_with(hub.clone(), input, output, origin));
        Self(tx, rx)
    }
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.0.send(Message::request(1, method, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let v: Value = serde_json::from_str(&self.1.recv().await.unwrap()).unwrap();
                if v["id"] == 1 {
                    return v;
                }
            }
        })
        .await
        .unwrap()
    }
}

#[tokio::test]
async fn watch_rpc_refuses_remote_origins_self_and_invalid_parameters() {
    let dir = cmux_unix_socket::short_test_dir("watch-rpc");
    let cfg: Config = serde_json::from_value(json!({"store": {"mode": "memory"},
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake"})).unwrap();
    let store = acpmux::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg, store);
    let mut local = Connection::new(&hub, Origin::Local);
    let chat = local.call("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await;
    let id = chat["result"]["sessionId"].as_str().expect("session created");
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = Connection::new(&hub, origin);
        for (method, params) in [
            ("_acpmux/watch_add", json!({"to": id, "sessions": [id]})),
            ("_acpmux/watch_ls", json!({})),
            ("_acpmux/watch_rm", json!({"id": "missing"})),
        ] {
            let reply = remote.call(method, params).await;
            assert!(reply["error"].is_object(), "{origin:?} {method}: {reply}");
        }
    }
    for (params, expected) in [
        (
            json!({"to": id, "sessions": [id], "once": false}),
            "recurring watches are not supported yet",
        ),
        (json!({"to": id, "sessions": [id]}), "cannot watch itself"),
        (json!({"to": id, "sessions": []}), "at least one session"),
        (json!({"sessions": [id]}), "to is required"),
        (json!({"to": id, "sessions": [id], "until": ["oops"]}), "until accepts"),
    ] {
        let reply = local.call("_acpmux/watch_add", params).await;
        assert!(reply["error"]["message"].as_str().unwrap().contains(expected), "{reply}");
    }
    let missing = local.call("_acpmux/watch_rm", json!({"id": "missing"})).await;
    assert!(missing["error"]["message"].as_str().unwrap().contains("_acpmux/watch_ls"));
    let list = local.call("_acpmux/watch_ls", json!({})).await;
    assert_eq!(list["result"]["watches"], json!([]));
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
}
