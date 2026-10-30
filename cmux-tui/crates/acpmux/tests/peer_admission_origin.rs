//! A create started past this host's lane cap is warned, and the warning names the connected
//! peer the placement engine would put it on instead (`suggestedHost`, `hub/admission.rs`). A
//! peer daemon's connection never learns this host's peers (`tests/peer_state_origin.rs`): its
//! warning names none, and says nothing of whether any of them has room. One test function:
//! the registry is read from this process's environment.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/), and its hub reads the
// registry the test writes.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("FLEET_REGISTRY", REGISTRY)]);
const REGISTRY: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/peer-admission-origin-registry.json");

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

/// One request on a new connection of `hub`'s: the unix socket (None) or as `origin`.
async fn call(hub: &Arc<Hub>, origin: Option<Origin>, m: &str, params: Value) -> Value {
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
            assert!(v.get("error").is_none(), "{m}: {v}");
            return v["result"].clone();
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
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "build": "older", "origin": "peer", "features": []}}}),
                        method::MUX_WATCH => json!({"sessions": []}),
                        "_acpmux/host_health" => json!({"cpus": 64, "load": [1.0, 1.0, 1.0],
                            "disk": {"freeBytes": 500_u64 << 30, "totalBytes": 1000_u64 << 30},
                            "liveSessions": 0}),
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

#[tokio::test]
async fn a_peer_connections_lane_cap_warning_names_none_of_this_hosts_peers() {
    let port = fake_peer().await;
    let a = hub();
    a.add_peer("far", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    // This host is at its cap of none; `far` has room for many.
    let here =
        call(&a, None, "_acpmux/host_health", json!({})).await["host"].as_str().unwrap().to_owned();
    let lanes = |max: u32| {
        json!({"lanes": {"reserved_gb": 0, "per_lane_gb": 0.1, "free_gb_floor": 0,
            "disk_per_lane_gb": 0.1, "cores_per_lane": 0.1, "max_lanes": max}})
    };
    let registry = json!({"machines": {here.clone(): lanes(0), "far": lanes(1000)}});
    std::fs::write(REGISTRY, registry.to_string()).unwrap();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "fake"}}});

    // The unix socket hears where to start it instead.
    let mine = call(&a, None, method::SESSION_NEW, new.clone()).await;
    let mine = &mine["_meta"]["acpmux"]["admission"];
    assert_eq!(mine["suggestedHost"], "far", "{mine}");
    assert!(mine["warning"].as_str().is_some_and(|w| w.contains("far")), "{mine}");

    // A peer's connection is warned too, of this host only.
    let theirs = call(&a, Some(Origin::Peer), method::SESSION_NEW, new).await;
    let theirs = &theirs["_meta"]["acpmux"]["admission"];
    let warning = theirs["warning"].as_str().unwrap_or_else(|| panic!("warned: {theirs}"));
    assert!(warning.contains("at its cap of 0"), "{warning}");
    assert!(theirs.get("suggestedHost").is_none(), "a peer was told of this host's peer: {theirs}");
    assert!(!warning.contains("far"), "a peer was told of this host's peer: {warning}");
    assert!(!warning.contains("connected host"), "nor whether any has room: {warning}");
    let _ = std::fs::remove_file(REGISTRY);
}
