//! Real daemon RPC dispatch to the shared mesh sender; no HTTP credentials or agent processes.
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::Config;
use acpmux::hub::Hub;
use acpmux::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use futures::future::BoxFuture;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

#[derive(Default)]
struct FakeMesh(Mutex<Vec<OutMessage>>);

impl MeshHub for FakeMesh {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async { Ok(vec![]) })
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        Box::pin(async { Ok(HeartbeatReply { daemon_id: "sender".into(), ttl_seconds: 90 }) })
    }
    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            // Test the actual shared wire serialization, not ControlRequest on its own.
            let wire = serde_json::to_value(message).unwrap();
            assert!(matches!(wire["op"].as_str(), Some("start" | "resume" | "stop")));
            self.0.lock().unwrap().push(message.clone());
            Ok(serde_json::from_value(
                json!({"messageId": "msg_test", "state": "queued", "to": message.to}),
            )
            .unwrap())
        })
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async {
            Ok(serde_json::from_value(
                json!({"messageId": "msg_test", "state": "delivered", "detail": "session-created"}),
            )
            .unwrap())
        })
    }
}

struct Rpc(mpsc::Sender<String>, mpsc::Receiver<String>, i64);
impl Rpc {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, incoming) = mpsc::channel(8);
        let (out, rx) = mpsc::channel(128);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, out, origin));
        Self(tx, rx, 0)
    }
    async fn call(&mut self, name: &str, params: Value) -> Value {
        self.2 += 1;
        self.0.send(Message::request(self.2, name, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == self.2 {
                return reply;
            }
        }
    }
}

#[tokio::test]
async fn local_controls_use_shared_mesh_wire_and_keep_queued_distinct_from_executed() {
    let hub = Hub::new(Config::default(), Box::new(acpmux::store::MemoryStore::default()));
    let mesh = Arc::new(FakeMesh::default());
    assert!(hub.mesh.set(mesh.clone()).is_ok());
    let mut local = Rpc::new(&hub, Origin::Local);
    local.call(method::INITIALIZE, json!({})).await;
    for (op, to) in [
        ("start", json!({"host": "worker"})),
        ("resume", json!({"sessionId": "stable-id"})),
        ("stop", json!({"name": "review", "host": "worker"})),
    ] {
        let reply = local
            .call(
                method::MUX_MESH_CONTROL,
                json!({
                    "op": op, "to": to, "idempotencyKey": format!("test-{op}-1"),
                    "params": {"cwd": "/remote", "_meta": {"acpmux": {"policy": "ask"}}},
                    "from": {"daemonId": "forged", "user": "forged", "name": "forged"}
                }),
            )
            .await;
        assert_eq!(reply["result"]["state"], "queued", "{reply}");
        assert_eq!(reply["result"]["messageId"], "msg_test");
    }
    let sent = mesh.0.lock().unwrap().clone();
    assert_eq!(sent.len(), 3);
    for (message, op) in sent.iter().zip(["start", "resume", "stop"]) {
        assert_eq!(message.op.as_deref(), Some(op));
        assert!(message.from.daemon_id.is_none());
        assert!(message.from.user.is_none());
        assert!(message.from.name.is_none());
    }
    let body: Value = serde_json::from_str(&sent[0].body).unwrap();
    assert_eq!(body["params"]["_meta"]["acpmux"]["policy"], "ask");
    let receipt = local.call(method::MUX_MESH_CONTROL, json!({"receipt": "msg_test"})).await;
    assert_eq!(receipt["result"]["state"], "delivered");

    for origin in [Origin::Web, Origin::Peer, Origin::LocalApp] {
        let mut remote = Rpc::new(&hub, origin);
        remote.call(method::INITIALIZE, json!({})).await;
        let refused = remote
            .call(
                method::MUX_MESH_CONTROL,
                json!({"op": "stop", "to": {"name": "review"}, "idempotencyKey": "forged-control"}),
            )
            .await;
        assert!(refused["error"].is_object(), "{refused}");
    }
    assert_eq!(mesh.0.lock().unwrap().len(), 3, "remote callers borrowed daemon identity");
}

#[tokio::test]
async fn a_top_level_session_id_cannot_forward_mesh_enqueue_to_a_peer() {
    use tokio_tungstenite::tungstenite::Message as Ws;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let forwarded = Arc::new(AtomicUsize::new(0));
    let count = forwarded.clone();
    let server = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        while let Some(Ok(Ws::Text(text))) = ws.next().await {
            let Ok(Message::Request { id, method: name, .. }) = Message::parse(&text) else {
                continue;
            };
            let result = match name.as_str() {
                method::INITIALIZE => json!({"protocolVersion": 1,
                    "_meta": {"acpmux": {"origin": "peer", "features": []}}}),
                method::MUX_WATCH => {
                    json!({"sessions": [{"sessionId": "remote-id", "name": "remote"}]})
                }
                method::MUX_MESH_CONTROL => {
                    count.fetch_add(1, Ordering::SeqCst);
                    json!({"unexpectedPeerForward": true})
                }
                _ => json!({}),
            };
            if ws.send(Ws::Text(Message::ok(id, result).to_line().into())).await.is_err() {
                break;
            }
        }
    });
    let config = Config::default();
    let hub = Hub::new(config.clone(), Box::new(acpmux::store::MemoryStore::default()));
    let mesh = Arc::new(FakeMesh::default());
    assert!(hub.mesh.set(mesh.clone()).is_ok());
    // A lease keeps the fake peer out of the user's config and ends explicitly below.
    let (lease, mut settled) = hub
        .lease_peer("other", &format!("ws://{address}"), "test-token".into(), None, false, &config)
        .unwrap();
    tokio::time::timeout(Duration::from_secs(10), settled.changed()).await.unwrap().unwrap();
    assert!(hub.resolve_remote("other/remote").is_some());
    let mut local = Rpc::new(&hub, Origin::Local);
    local.call(method::INITIALIZE, json!({})).await;
    let reply = local
        .call(
            method::MUX_MESH_CONTROL,
            json!({
                "sessionId": "other/remote", "op": "stop", "to": {"name": "review"},
                "idempotencyKey": "local-mesh-only"
            }),
        )
        .await;
    hub.end_peer_lease(&lease);
    server.abort();
    let _ = server.await;
    assert_eq!(reply["result"]["state"], "queued", "{reply}");
    assert_eq!(mesh.0.lock().unwrap().len(), 1);
    assert_eq!(forwarded.load(Ordering::SeqCst), 0);
}
