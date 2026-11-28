//! Real daemon RPC dispatch to the shared mesh sender; no HTTP credentials or agent processes.
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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
    hub.mesh.set(mesh.clone());
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
        let mut ws = acpmux::server::accept_ws(tcp).await.unwrap();
        // Non-text frames (the client's pings, #38015) are not requests: skip them.
        while let Some(Ok(frame)) = ws.next().await {
            let Ws::Text(text) = frame else { continue };
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
    hub.mesh.set(mesh.clone());
    // A lease keeps the fake peer out of the user's config and ends explicitly below.
    let (lease, mut settled) = hub
        .lease_peer(
            "other",
            &format!("ws://{address}"),
            "test-token".into(),
            None,
            false,
            None,
            &config,
        )
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

/// A start through the mesh hub (`cmux chat --on MACHINE`, `acpmux session start --machine`)
/// carries the person's start level as a start through an ssh peer does: full access as
/// approve-all, `standard` and `ask` with no policy (the machine starts it asking); a start that
/// names its own policy or a mode keeps it (hq#11835 row 4).
#[tokio::test]
async fn a_mesh_start_carries_the_persons_start_level() {
    let _ = &HERMETIC;
    for (level, want) in
        [("fullAccess", json!("approve-all")), ("standard", Value::Null), ("ask", Value::Null)]
    {
        let config: Config =
            serde_json::from_value(json!({"defaultPermissionMode": level})).unwrap();
        let hub = Hub::new(config, Box::new(acpmux::store::MemoryStore::default()));
        let mesh = Arc::new(FakeMesh::default());
        hub.mesh.set(mesh.clone());
        let mut local = Rpc::new(&hub, Origin::Local);
        local.call(method::INITIALIZE, json!({})).await;
        for (key, meta, want) in [
            ("plain", json!({"harness": "claude"}), want.clone()),
            ("named", json!({"harness": "claude", "policy": "ask"}), json!("ask")),
            ("mode", json!({"harness": "claude", "mode": "default"}), Value::Null),
        ] {
            let reply = local
                .call(
                    method::MUX_MESH_CONTROL,
                    json!({
                        "op": "start", "to": {"host": "worker"},
                        "idempotencyKey": format!("level-{level}-{key}"),
                        "params": {"cwd": "/remote", "_meta": {"acpmux": meta}},
                    }),
                )
                .await;
            assert_eq!(reply["result"]["state"], "queued", "{level} {key}: {reply}");
            let sent = mesh.0.lock().unwrap().last().cloned().unwrap();
            let body: Value = serde_json::from_str(&sent.body).unwrap();
            assert_eq!(body["params"]["_meta"]["acpmux"]["policy"], want, "{level} {key}");
        }
    }
}

#[tokio::test]
async fn a_mesh_start_cannot_widen_an_asking_callers_policy() {
    let _ = &HERMETIC;
    let config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {
            "argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")],
            "env": {"FAKE_FULL_ACCESS": "1"}
        }},
        "defaultHarness": "fake", "permissionPolicy": "ask",
        "defaultPermissionMode": "standard", "store": {"mode": "memory"}
    }))
    .unwrap();
    let hub = Hub::new(config, Box::new(acpmux::store::MemoryStore::default()));
    let mesh = Arc::new(FakeMesh::default());
    hub.mesh.set(mesh.clone());
    let mut app = Rpc::new(&hub, Origin::LocalApp);
    app.call(method::INITIALIZE, json!({})).await;
    for (own, mode, may_widen) in [("ask", "strict", false), ("approve-all", "full-access", true)] {
        let created = app
            .call(
                method::SESSION_NEW,
                json!({
                    "cwd": std::env::temp_dir(), "mcpServers": [],
                    "_meta": {"acpmux": {"policy": own}}
                }),
            )
            .await;
        let id = created["result"]["sessionId"].as_str().expect("starter created");
        let changed = app.call(method::SESSION_PROMPT, json!({
            "sessionId": id, "prompt": [{"type": "text", "text": format!("set-mode: {mode}")}]
        })).await;
        assert!(changed["error"].is_null(), "{changed}");
        let mut agent = Rpc::new(&hub, Origin::Local);
        let token = acpmux::hub::person::caller_token(id);
        agent
            .call(
                method::INITIALIZE,
                json!({"_meta": {"acpmux": {
                    "callerSession": {"sessionId": id, "token": token}
                }}}),
            )
            .await;
        for nested in [
            json!({"policy": "approve-all"}),
            json!({"_meta": {"acpmux": {"policy": "approve-all"}}}),
        ] {
            let before = mesh.0.lock().unwrap().len();
            let reply = agent
                .call(
                    method::MUX_MESH_CONTROL,
                    json!({
                        "op": "start", "to": {"host": "worker"},
                        "idempotencyKey": format!("width-{own}-{before}"), "params": nested
                    }),
                )
                .await;
            if may_widen {
                assert_eq!(reply["result"]["state"], "queued", "{reply}");
                assert_eq!(mesh.0.lock().unwrap().len(), before + 1);
            } else {
                assert_eq!(
                    reply["error"]["data"]["reason"], "permission.person_required",
                    "{reply}"
                );
                assert_eq!(mesh.0.lock().unwrap().len(), before, "refused start reached the mesh");
            }
        }
    }
    hub.shutdown_all().await;
}
