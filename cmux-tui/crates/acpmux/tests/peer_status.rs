//! `acpmux peer status` (`_acpmux/peer_status`): every peer's health read
//! live, so an agent asks instead of guessing from a timeout. B serves
//! WebSocket, A has B as a peer and a second peer nothing answers on.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

async fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

async fn client(h: Arc<Hub>) -> C {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    c
}

/// B's WebSocket listener with a peer token; returns its port and the token.
async fn listen(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("peer-status-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn row<'a>(reply: &'a Value, name: &str) -> &'a Value {
    reply["hosts"]
        .as_array()
        .and_then(|rows| rows.iter().find(|r| r["name"] == name))
        .unwrap_or_else(|| panic!("no row {name}: {reply}"))
}

#[tokio::test]
async fn peer_status_reads_each_peers_health_live_and_names_an_unreachable_one() {
    let b = hub().await;
    let (port, token) = listen(b.clone(), "live").await;
    let a = hub().await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    a.add_peer("gone", &format!("ws://127.0.0.1:{}", free_port()), None, None, true).await.unwrap();

    let mut ca = client(a.clone()).await;
    let reply = ca.call("_acpmux/peer_status", json!({})).await.unwrap();

    // This machine first, read the same way.
    let me = &reply["hosts"][0];
    assert_eq!(me["self"], true, "{reply}");
    assert_eq!(me["reachable"], true, "{reply}");

    let peer = row(&reply, "b");
    assert_eq!(peer["reachable"], true, "{reply}");
    assert!(peer["latencyMs"].is_u64(), "{reply}");
    assert!(peer["disk"]["freeBytes"].as_u64().is_some_and(|f| f > 0), "{reply}");
    assert!(peer["disk"]["totalBytes"].as_u64().is_some_and(|t| t > 0), "{reply}");
    assert_eq!(peer["load"].as_array().map(Vec::len), Some(3), "{reply}");
    assert!(peer["cpus"].as_u64().is_some_and(|n| n > 0), "{reply}");
    assert_eq!(peer["liveSessions"], 0, "{reply}");
    assert_eq!(peer["version"], acpmux::hub::VERSION, "{reply}");
    assert_eq!(peer["build"], acpmux::hub::BUILD, "{reply}");
    assert_eq!(peer["outdated"], false, "{reply}");

    // Nothing answers there: not reachable, with why and the next step, and no numbers.
    let gone = row(&reply, "gone");
    assert_eq!(gone["reachable"], false, "{reply}");
    assert!(gone["error"].is_string(), "{reply}");
    assert!(gone.get("disk").is_none(), "{reply}");

    // One name: that peer's row only.
    let one = ca.call("_acpmux/peer_status", json!({"name": "b"})).await.unwrap();
    let names: Vec<&str> =
        one["hosts"].as_array().unwrap().iter().filter_map(|r| r["name"].as_str()).collect();
    assert_eq!(names, ["b"], "{one}");
    let unknown = ca.call("_acpmux/peer_status", json!({"name": "nope"})).await;
    assert!(unknown.is_err_and(|e| e.contains("acpmux host ls")), "an unknown peer names host ls");
}
