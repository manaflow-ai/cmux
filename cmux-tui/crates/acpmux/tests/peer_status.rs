//! `acpmux peer status` (`_acpmux/peer_status`): every peer's health read
//! live, so an agent asks instead of guessing from a timeout. B serves
//! WebSocket, A has B as a peer and a second peer nothing answers on.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/), and its
// hubs read the machine health file `hub()` writes once (`health_file`).
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("ACPMUX_MACHINE_HEALTH_FILE", HEALTH_FILE)]);
const HEALTH_FILE: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/peer-status-machine-health.json");

/// The machine health loop's file every hub here reads: written once, before
/// the first hub, and never changed, so tests running at once read the same
/// one (`tests/machine_health.rs` changes its own in its own process).
fn health_file() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
        let file = json!({"schema": 1, "checkedAt": rfc3339(now.as_secs()), "problems": [
            {"check": "dns", "detail": "DNS: github.com does not resolve",
             "since": rfc3339(now.as_secs() - 600)},
            {"check": "disk"},
        ], "fixed": []});
        std::fs::write(HEALTH_FILE, file.to_string()).unwrap();
    });
}

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
    health_file();
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
    client_as(h, None).await
}

/// A client of `h` over the local socket, or as `origin` (a Web caller).
async fn client_as(h: Arc<Hub>, origin: Option<acpmux::server::Origin>) -> C {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    match origin {
        None => drop(tokio::spawn(serve_connection(h, in_rx, out_tx))),
        Some(o) => drop(tokio::spawn(acpmux::server::serve_connection_with(h, in_rx, out_tx, o))),
    }
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
    assert!(peer["ram"]["totalBytes"].as_u64().is_some_and(|t| t > 0), "{reply}");
    // The budget verdict rides along, without the formula or session names.
    assert!(peer["pressure"].is_object(), "{reply}");
    assert!(peer["pressure"].get("top").is_none(), "{reply}");
    assert!(peer["pressure"].get("formula").is_none(), "{reply}");
    // `warning` names the host: a peer or Web caller never gets it.
    assert!(peer["pressure"].get("warning").is_none(), "{reply}");
    assert_eq!(peer["liveSessions"], 0, "{reply}");
    assert_eq!(peer["version"], acpmux::hub::VERSION, "{reply}");
    assert_eq!(peer["build"], acpmux::hub::build(), "{reply}");
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

    // A Web caller learns that b answered and on which build, not b's numbers.
    let mut web = client_as(a.clone(), Some(acpmux::server::Origin::Web)).await;
    let reply = web.call("_acpmux/peer_status", json!({})).await.unwrap();
    let peer = row(&reply, "b");
    assert_eq!(peer["reachable"], true, "{reply}");
    assert!(peer["latencyMs"].is_u64(), "{reply}");
    assert_eq!(peer["build"], acpmux::hub::build(), "{reply}");
    for key in [
        "cpus",
        "load",
        "ram",
        "swap",
        "disk",
        "pressure",
        "liveSessions",
        "uptimeSecs",
        "problems",
    ] {
        assert!(peer.get(key).is_none(), "{key} reached the web: {reply}");
    }
    // Its own machine's row is `_acpmux/host_health`'s, without the host name.
    let me = &reply["hosts"][0];
    assert_eq!(me["self"], true, "{reply}");
    assert!(me["ram"].is_object() && me.get("host").is_none(), "{reply}");
    // One peer by name: the same row.
    let one = web.call("_acpmux/peer_status", json!({"name": "b"})).await.unwrap();
    let peer = row(&one, "b");
    assert_eq!(peer["reachable"], true, "{one}");
    assert!(peer.get("ram").is_none() && peer.get("load").is_none(), "{one}");
    // The local app's WebSocket is off the unix socket too: no peer's numbers.
    // It runs on this machine, so its own row may name it.
    let mut app = client_as(a.clone(), Some(acpmux::server::Origin::LocalApp)).await;
    let reply = app.call("_acpmux/peer_status", json!({})).await.unwrap();
    let peer = row(&reply, "b");
    assert!(peer["latencyMs"].is_u64(), "{reply}");
    assert!(peer.get("ram").is_none() && peer.get("disk").is_none(), "{reply}");
    // A peer's connection gets this machine's row only, unnamed.
    let mut via = client_as(a.clone(), Some(acpmux::server::Origin::Peer)).await;
    let reply = via.call("_acpmux/peer_status", json!({})).await.unwrap();
    let hosts = reply["hosts"].as_array().unwrap();
    assert_eq!(hosts.len(), 1, "{reply}");
    assert!(hosts[0]["self"] == true && hosts[0].get("host").is_none(), "{reply}");
}

#[tokio::test]
async fn peer_status_rides_on_the_peer_row_read_after_connect() {
    let b = hub().await;
    let (port, token) = listen(b.clone(), "row").await;
    let a = hub().await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    // Asked once the handshake is done, then on every third ping (`peer_health.rs`).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let peer = loop {
        let peers = a.peers();
        let p = peers.into_iter().find(|p| p["name"] == "b").expect("peer b");
        if p["health"].is_object() || tokio::time::Instant::now() >= deadline {
            break p;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert!(peer["healthAt"].is_u64(), "{peer}");
    let h = &peer["health"];
    assert!(h["ram"]["totalBytes"].as_u64().is_some_and(|t| t > 0), "{peer}");
    assert!(h["swap"]["totalBytes"].is_u64(), "{peer}");
    assert!(h["disk"]["freeBytes"].as_u64().is_some_and(|f| f > 0), "{peer}");
    assert_eq!(h["liveSessions"], 0, "{peer}");
    assert!(h["pressure"].is_object(), "{peer}");
    // The row names no host and carries no build twice.
    assert!(h.get("host").is_none() && h.get("build").is_none(), "{peer}");

    // A Web caller gets the links, not the machines' resources.
    let mut web = client_as(a.clone(), Some(acpmux::server::Origin::Web)).await;
    let rows = web.call("_acpmux/peers", json!({})).await.unwrap();
    let row = rows["peers"].as_array().and_then(|r| r.iter().find(|p| p["name"] == "b")).cloned();
    let row = row.expect("peer b for the web");
    assert!(row.get("health").is_none() && row.get("healthAt").is_none(), "{row}");
    // Nor in the status reply's peers.
    let status = web.call("_acpmux/status", json!({})).await.expect("status for the web");
    let b = status["peers"].as_array().and_then(|r| r.iter().find(|p| p["name"] == "b"));
    let b = b.unwrap_or_else(|| panic!("peer b in the web's status: {status}"));
    assert!(b.get("health").is_none() && b.get("healthAt").is_none(), "{status}");
}

/// `_acpmux/place` names every machine and its numbers: never to a Web caller.
#[tokio::test]
async fn place_answers_only_on_the_unix_socket() {
    let a = hub().await;
    let mut local = client(a.clone()).await;
    let v = local.call("_acpmux/place", json!({})).await.unwrap();
    assert!(v["hosts"].is_array(), "{v}");
    let mut web = client_as(a, Some(acpmux::server::Origin::Web)).await;
    let refused = web.call("_acpmux/place", json!({})).await;
    assert!(refused.is_err_and(|e| e.contains("unix socket")), "the web gets no placement");
}

/// RFC 3339 for `secs` since the epoch (UTC), as the health loop writes it.
fn rfc3339(secs: u64) -> String {
    let (days, rem) = ((secs / 86_400) as i64 + 719_468, secs % 86_400);
    let (era, doe) = (days.div_euclid(146_097), days.rem_euclid(146_097));
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let (d, m) = (doy - (153 * mp + 2) / 5 + 1, if mp < 10 { mp + 3 } else { mp - 9 });
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

/// The machine health loop's problems (`/run/cmux/machine-health.json`, here
/// `HEALTH_FILE`) ride on `host_health`, the peer row and `peer_status`; a
/// Web caller gets them for its own machine only, like the resources.
#[tokio::test]
async fn the_health_loops_problems_ride_along_and_stay_off_the_web_for_peers() {
    let b = hub().await;
    let (port, token) = listen(b.clone(), "problems").await;
    let a = hub().await;
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();

    let mut local = client(a.clone()).await;
    let health = local.call("_acpmux/host_health", json!({})).await.unwrap();
    let problems = health["problems"].as_array().unwrap_or_else(|| panic!("{health}"));
    // The entry without a detail is skipped, never made up.
    assert_eq!(problems.len(), 1, "{health}");
    assert_eq!(problems[0]["check"], "dns", "{health}");
    assert_eq!(problems[0]["detail"], "DNS: github.com does not resolve", "{health}");
    assert!(problems[0]["since"].is_string(), "{health}");

    let reply = local.call("_acpmux/peer_status", json!({})).await.unwrap();
    assert_eq!(reply["hosts"][0]["problems"], health["problems"], "{reply}");
    assert_eq!(row(&reply, "b")["problems"], health["problems"], "{reply}");

    // The peer row keeps them from the link's own health reading.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let peer = loop {
        let p = a.peers().into_iter().find(|p| p["name"] == "b").expect("peer b");
        if p["health"].is_object() || tokio::time::Instant::now() >= deadline {
            break p;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(peer["health"]["problems"], health["problems"], "{peer}");

    // A Web caller: its own machine's problems, not a peer's.
    let mut web = client_as(a.clone(), Some(acpmux::server::Origin::Web)).await;
    let reply = web.call("_acpmux/peer_status", json!({})).await.unwrap();
    assert_eq!(reply["hosts"][0]["problems"], health["problems"], "{reply}");
    let peer = row(&reply, "b");
    assert!(peer.get("problems").is_none(), "a peer's problems reached the web: {reply}");
}
