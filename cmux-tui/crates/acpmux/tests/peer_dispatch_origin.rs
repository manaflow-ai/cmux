//! A brief dispatched while this host is over its CPU/RAM budget (`host_pressure.rs`) is warned,
//! and the reply names the connected peer the placement engine would put the next one on
//! (`suggestedHost`, `server/requests.rs` `dispatch_brief`). A peer daemon's connection never
//! learns this host's peers (`tests/peer_state_origin.rs`, `tests/peer_admission_origin.rs`): its
//! brief runs here, its warning is of this host only, and a host it names that is not this one is
//! refused with one answer whether this host has such a peer or not. One test function: the
//! budget and the registry are read from this process's environment.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/). Its hub reads the registry
// the test writes, and a budget this host is always over: any load, and less than all its RAM free.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in()
    .with_env(&[("FLEET_REGISTRY", REGISTRY), ("ACPMUX_HOST_BUDGET", BUDGET)]);
const REGISTRY: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/peer-dispatch-origin-registry.json");
const BUDGET: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/peer-dispatch-origin-budget.json");

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "webRoots": [std::env::temp_dir()],
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One request on a new connection of `hub`'s, the unix socket (None) or as `origin`: its
/// result, or its error's message.
async fn call(
    hub: &Arc<Hub>,
    origin: Option<Origin>,
    m: &str,
    params: Value,
) -> Result<Value, String> {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    match origin {
        None => drop(tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx))),
        Some(o) => drop(tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, o))),
    }
    in_tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(30), out_rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return match v.get("error") {
                Some(e) => Err(e["message"].as_str().unwrap_or_default().to_owned()),
                None => Ok(v["result"].clone()),
            };
        }
    }
}

/// A fake peer daemon whose `_acpmux/host_health` reading is fixed, with room for many lanes
/// whatever this machine runs (`placement.rs`): it lists no session and answers `{}` to the rest.
async fn fake_peer() -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            tokio::spawn(async move {
                let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { return };
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, params }) = Message::parse(&text)
                    else {
                        continue;
                    };
                    let p = params.unwrap_or_default();
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "build": "older", "origin": "peer", "features": []}}}),
                        method::MUX_WATCH => json!({"sessions": []}),
                        "_acpmux/host_health" => json!({"cpus": 64, "load": [1.0, 1.0, 1.0],
                            "disk": {"freeBytes": 500_u64 << 30, "totalBytes": 1000_u64 << 30},
                            "liveSessions": 0}),
                        // The brief runs here: the row it answers names this peer.
                        method::MUX_DISPATCH => json!({"brief": {"briefId": p["briefId"],
                            "host": p["host"], "target": p["host"], "to": p["host"],
                            "sessionId": "remote-session", "status": "running"}}),
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

/// The dispatch handler's future is deeper than a debug build's 2 MiB worker stack: the
/// connections run on workers with room, as in `tests/inherit_start.rs`.
#[test]
fn a_peer_connections_dispatch_names_none_of_this_hosts_peers() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(peer_dispatch_names_no_peer());
}

async fn peer_dispatch_names_no_peer() {
    // Over budget at any load, and with less than all its RAM free; a verdict kept for the test.
    let budget = json!({"formula": {"load1_per_core": 0.000001,
        "min_available_ram_fraction": 1.0, "sample_seconds": 3600}});
    std::fs::write(BUDGET, budget.to_string()).unwrap();
    let port = fake_peer().await;
    let a = hub();
    a.add_peer("elsewhere", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let here = call(&a, None, "_acpmux/host_health", json!({})).await.unwrap()["host"]
        .as_str()
        .unwrap()
        .to_owned();
    let lanes = json!({"lanes": {"reserved_gb": 0, "per_lane_gb": 0.1, "free_gb_floor": 0,
        "disk_per_lane_gb": 0.1, "cores_per_lane": 0.1, "max_lanes": 1000}});
    let registry = json!({"machines": {here.clone(): lanes.clone(), "elsewhere": lanes}});
    std::fs::write(REGISTRY, registry.to_string()).unwrap();
    // This host's first verdict, over budget (a sample is taken on a blocking thread).
    let mut over = false;
    for _ in 0..50 {
        let status = call(&a, None, method::MUX_STATUS, json!({})).await.unwrap();
        if status.pointer("/host_pressure/ok") == Some(&json!(false)) {
            over = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(over, "this host is over its budget");
    // Each brief's session takes its name from a title of its own.
    let dispatch = |host: &str| {
        json!({"brief": "say hi", "title": format!("brief {}", uuid::Uuid::now_v7()), "host": host,
            "cwd": std::env::temp_dir(), "harness": "fake"})
    };

    // The unix socket hears that this host is over its budget, and where to dispatch next.
    let mine = call(&a, None, method::MUX_DISPATCH, dispatch("local")).await.unwrap();
    assert!(
        mine["warning"].as_str().is_some_and(|w| w.contains("over its CPU/RAM budget")),
        "{mine}"
    );
    assert_eq!(mine["suggestedHost"], "elsewhere", "{mine}");
    assert_eq!(mine["brief"]["suggestedHost"], "elsewhere", "{mine}");

    // A peer's connection hears that this host is over its budget, and of no other host.
    for host in ["local", "auto"] {
        let theirs = call(&a, Some(Origin::Peer), method::MUX_DISPATCH, dispatch(host)).await;
        let theirs = theirs.unwrap_or_else(|e| panic!("{host}: {e}"));
        assert!(theirs["warning"].as_str().is_some_and(|w| w.contains(&here)), "{theirs}");
        assert!(theirs["suggestedHost"].is_null(), "a peer was told of this host's peer: {theirs}");
        assert_eq!(theirs["brief"]["host"], "local", "{host}: it runs here: {theirs}");
        assert!(theirs["brief"].get("suggestedHost").is_none(), "{theirs}");
        assert!(
            !theirs.to_string().contains("elsewhere"),
            "a peer was told of this host's peer: {theirs}"
        );
    }

    // A replay of the brief the unix socket dispatched names no peer of this host either.
    let id = mine["brief"]["briefId"].as_str().unwrap();
    let mut replay = dispatch("local");
    replay["briefId"] = json!(id);
    let replayed = call(&a, Some(Origin::Peer), method::MUX_DISPATCH, replay).await.unwrap();
    assert_eq!(replayed["replayed"], true, "{replayed}");
    assert!(
        !replayed.to_string().contains("elsewhere"),
        "a replay named this host's peer: {replayed}"
    );

    // Nor does a replay of a brief the unix socket dispatched to the peer: its id is taken.
    let sent = call(&a, None, method::MUX_DISPATCH, dispatch("elsewhere")).await.unwrap();
    assert_eq!(sent["brief"]["host"], "elsewhere", "{sent}");
    let mut replay = dispatch("local");
    replay["briefId"] = sent["brief"]["briefId"].clone();
    let replayed = call(&a, Some(Origin::Peer), method::MUX_DISPATCH, replay).await;
    let taken = replayed.expect_err("a peer was given the row of a brief this host's peer ran");
    assert!(taken.contains("another brief has this briefId"), "{taken}");
    assert!(!taken.contains("elsewhere"), "{taken}");

    // A host that is not this one gets one answer: a peer of this host, or no such peer.
    let far = call(&a, Some(Origin::Peer), method::MUX_DISPATCH, dispatch("elsewhere")).await;
    let nosuch = call(&a, Some(Origin::Peer), method::MUX_DISPATCH, dispatch("nosuch-peer")).await;
    let far = far.expect_err("a peer's dispatch was sent on to this host's peer");
    assert_eq!(far, nosuch.expect_err("refused").replace("nosuch-peer", "elsewhere"), "{far}");
    assert!(far.contains("runs on this host only"), "{far}");
    let _ = std::fs::remove_file(REGISTRY);
    let _ = std::fs::remove_file(BUDGET);
}
