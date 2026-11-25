use super::*;
use crate::rpc::method;
use crate::server::{Origin, serve_connection_with};
use std::time::Duration;
use tokio::sync::mpsc;

fn hub(peers: bool) -> Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    if peers {
        let (index, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
        let surfaces = ["list", "peers"].into_iter().map(str::to_owned).collect();
        hub.link_v2
            .install(Arc::new(acpmux_core::life::V2::with_surfaces(index, writer, surfaces)));
    }
    hub
}

struct Wire {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    task: tokio::task::JoinHandle<()>,
    id: u64,
}
impl Drop for Wire {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Wire {
    fn new(hub: Arc<Hub>, origin: Origin) -> Self {
        let (input, incoming) = mpsc::channel(16);
        let (output, outgoing) = mpsc::channel(16);
        let task = tokio::spawn(serve_connection_with(hub, incoming, output, origin));
        Self { input, output: outgoing, task, id: 0 }
    }
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.id += 1;
        self.input.send(Message::request(self.id, method, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let text = self.output.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&text).unwrap();
                if reply["id"] == self.id {
                    return reply;
                }
            }
        })
        .await
        .expect("request answered")
    }
    async fn init(&mut self) -> Value {
        self.call(
            method::INITIALIZE,
            json!({"protocolVersion": 1,
            "clientInfo": {"name": crate::peer::CLIENT_NAME, "version": "0"}}),
        )
        .await
    }
}

#[tokio::test]
async fn controls_only_offered_to_owner_peers_with_peers_enabled() {
    for (peers, origin, offered) in [
        (false, Origin::Peer, false),
        (true, Origin::Peer, true),
        (true, Origin::Local, false),
        (true, Origin::Web, false),
    ] {
        let mut wire = Wire::new(hub(peers), origin);
        let hello = wire.init().await;
        let features = hello.pointer("/result/_meta/acpmux/features").unwrap().as_array().unwrap();
        assert_eq!(features.iter().any(|f| f == FEATURE), offered);
        let reply = wire.call(METHOD, json!({"kinds": ["asks", "ready"]})).await;
        assert_eq!(reply.get("error").is_none(), offered, "{reply}");
    }
}

#[tokio::test]
async fn controls_snapshot_is_committed_before_live_and_never_stops_watch() {
    let mut wire = Wire::new(hub(true), Origin::Peer);
    wire.init().await;
    let watch = wire.call(method::MUX_WATCH, json!({"enabled": true})).await;
    assert!(watch.get("error").is_none(), "{watch}");
    let first = wire.call(METHOD, json!({"kinds": ["asks", "ready"]})).await;
    let page = &first["result"];
    assert_eq!(page["phase"], "snapshot");
    assert!(page["next"].is_null());
    assert_eq!(page["entries"][0]["kind"], "ready");
    assert_eq!(page["entries"][0]["value"]["githubLink"], true);
    let id = page["stream"].clone();
    let stale = wire.call(METHOD, json!({"stream": "not-this-stream", "live": true})).await;
    assert_eq!(stale["error"]["data"]["reason"], "controls.resync");
    let live = wire.call(METHOD, json!({"stream": id, "live": true})).await;
    assert_eq!(live["result"]["phase"], "live");
    let repeat = wire.call(METHOD, json!({"stream": id, "live": true})).await;
    assert_eq!(repeat["error"]["data"]["reason"], "controls.resync");
    let watch = wire.call(method::MUX_WATCH, json!({"enabled": true})).await;
    assert!(watch.get("error").is_none(), "{watch}");
}

#[tokio::test]
async fn controls_refuses_unknown_kinds_and_cursor_shapes() {
    let mut wire = Wire::new(hub(true), Origin::Peer);
    wire.init().await;
    for params in [
        json!({"kinds": ["sessions"]}),
        json!({"kinds": []}),
        json!({"kinds": ["asks"], "live": true}),
    ] {
        let reply = wire.call(METHOD, params).await;
        assert_eq!(reply["error"]["code"], -32602, "{reply}");
    }
}

#[tokio::test]
async fn controls_ignore_fields_a_newer_peer_adds() {
    let mut wire = Wire::new(hub(true), Origin::Peer);
    wire.init().await;
    let reply = wire.call(METHOD, json!({"kinds": ["asks", "ready"], "extra": 1})).await;
    assert_eq!(reply["result"]["phase"], "snapshot", "{reply}");
}

#[tokio::test]
async fn controls_budget_covers_transport_until_reader_consumes_it() {
    let scope = cmux_scope::Scope::new("controls-budget-test");
    let (transport, mut reader) = mpsc::channel(8);
    let (out, _) = crate::server::outbound::start_bounded(&scope, None, transport, 64 << 20);
    let budget = Arc::new(Budget::default());
    let text = "x".repeat(BOUND - RESERVE);
    let ticket = budget.take(text.len(), false).unwrap();
    out.push_control(Line { text, ticket: Some(ticket), ..Line::default() });
    assert!(budget.take(1, false).is_none());
    let line = tokio::time::timeout(Duration::from_secs(5), reader.recv()).await.unwrap().unwrap();
    assert_eq!(line.len(), BOUND - RESERVE);
    out.settle();
    assert_eq!(budget.0.load(Ordering::Acquire), 0);
    assert!(budget.take(BOUND - RESERVE, false).is_some());
}

#[test]
fn controls_reserves_room_for_resync_and_reclaims_staged_bytes() {
    let budget = Arc::new(Budget::default());
    let staged = budget.take(BOUND - RESERVE, false).unwrap();
    assert!(budget.take(1, false).is_none());
    let terminal = budget.take(RESERVE, true).unwrap();
    assert_eq!(budget.0.load(Ordering::Acquire), BOUND);
    assert!(budget.take(1, true).is_none());
    drop(staged);
    assert_eq!(budget.0.load(Ordering::Acquire), RESERVE);
    drop(terminal);
    assert_eq!(budget.0.load(Ordering::Acquire), 0);
}
