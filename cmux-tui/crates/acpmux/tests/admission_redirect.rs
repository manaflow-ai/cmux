//! A create this lane host has no room for starts on the peer the placement engine picks,
//! when its client asks (`_meta.acpmux.placeRedirect`, `hub/admission_redirect.rs`), and
//! every other create starts here, warned, as before. A fake fleet: this host at a cap of
//! none, one fake peer `far` with room for many (`tests/peer_admission_origin.rs`). The
//! lockstep both ways: an old client (no opt-in) gets today's local start and warning from
//! this daemon, and an old daemon (one that ignores the opt-in) answers with no `placedOn`,
//! which the new CLI reads as a start here (`cli/run/standard.rs` tests). One test function:
//! the registry is read from this process's environment.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/), and its hub reads the
// registry the test writes.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("FLEET_REGISTRY", REGISTRY)]);
const REGISTRY: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/admission-redirect-registry.json");

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, RpcError, method};
use acpmux::server::{Origin, serve_connection, serve_connection_with};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
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

/// The `session/new` requests the fake peer was sent.
type Seen = Arc<Mutex<Vec<Value>>>;

/// A fake peer daemon with room for many lanes (`placement.rs`): it answers `session/new`
/// with a session of its own, or refuses one named `refuse-me`, records each, lists no
/// session and answers `{}` to the rest.
async fn fake_peer(seen: Seen) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let seen = seen.clone();
            tokio::spawn(async move {
                let Ok(mut ws) = acpmux::server::accept_ws(tcp).await else { return };
                // Non-text frames (the client's pings, #38015) are not requests: skip them.
                while let Some(Ok(frame)) = ws.next().await {
                    let Ws::Text(text) = frame else { continue };
                    let Ok(Message::Request { id, method: m, params }) = Message::parse(&text)
                    else {
                        continue;
                    };
                    let params = params.unwrap_or_default();
                    let reply = match m.as_str() {
                        method::SESSION_NEW => {
                            let name = params.pointer("/_meta/acpmux/name").and_then(Value::as_str);
                            let n = {
                                let mut seen = seen.lock().unwrap();
                                seen.push(params.clone());
                                seen.len()
                            };
                            if name == Some("refuse-me") {
                                Message::err(id, RpcError::internal("far is shutting down"))
                            } else {
                                Message::ok(
                                    id,
                                    json!({"sessionId": format!("far-s{n}"),
                                    "_meta": {"acpmux": {"name": name}}}),
                                )
                            }
                        }
                        // A dated build, not older than this one: an undated or older one is
                        // `outdated` (`build_info::lags`), which placement passes over.
                        method::INITIALIZE => Message::ok(
                            id,
                            json!({"protocolVersion": 1, "_meta": {"acpmux": {
                                "build": "newer 2099-12-31", "origin": "peer", "features": []}}}),
                        ),
                        method::MUX_WATCH => Message::ok(id, json!({"sessions": []})),
                        "_acpmux/host_health" => Message::ok(
                            id,
                            json!({"cpus": 64, "load": [1.0, 1.0, 1.0],
                                "disk": {"freeBytes": 500_u64 << 30, "totalBytes": 1000_u64 << 30},
                                "liveSessions": 0}),
                        ),
                        _ => Message::ok(id, json!({})),
                    };
                    if ws
                        .send(Ws::Text(reply.to_line().trim_end().to_owned().into()))
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
            });
        }
    });
    port
}

fn lanes(max: u32) -> Value {
    json!({"lanes": {"reserved_gb": 0, "per_lane_gb": 0.1, "free_gb_floor": 0,
        "disk_per_lane_gb": 0.1, "cores_per_lane": 0.1, "max_lanes": max}})
}

/// A create as the CLI sends it: `asks` adds the opt-in a new CLI sends to a daemon that
/// lists `place-redirect-v1`.
fn new(name: &str, asks: bool) -> Value {
    let mut mux = json!({"harness": "fake", "name": name, "createKey": name});
    if asks {
        mux["placeRedirect"] = json!(1);
    }
    json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": mux}})
}

fn placed_on(v: &Value) -> Option<&str> {
    v.pointer("/_meta/acpmux/placedOn").and_then(Value::as_str)
}

/// The peer health reading arrives over the link a moment after `add_peer`.
async fn until_far_has_room(a: &Arc<Hub>) {
    for _ in 0..200 {
        let far = a.peers().into_iter().find(|p| p["name"] == "far");
        if far.is_some_and(|p| p.get("health").is_some_and(|h| h.get("cpus").is_some())) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("far's health reading never arrived: {:?}", a.peers());
}

#[tokio::test]
async fn a_create_past_the_cap_starts_on_the_picked_peer_only_when_its_client_asks() {
    let seen: Seen = Arc::default();
    let port = fake_peer(seen.clone()).await;
    let a = hub();
    a.add_peer("far", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    // This host is at its cap of none; `far` has room for many.
    let here =
        call(&a, None, "_acpmux/host_health", json!({})).await["host"].as_str().unwrap().to_owned();
    let registry = json!({"machines": {here.clone(): lanes(0), "far": lanes(1000)}});
    std::fs::write(REGISTRY, registry.to_string()).unwrap();
    until_far_has_room(&a).await;

    // Before: today's client sends no opt-in, and every create past the cap starts here.
    let (mut before_local, mut after_local, mut after_placed) = (0, 0, 0);
    for i in 0..3 {
        let old = call(&a, None, method::SESSION_NEW, new(&format!("old-{i}"), false)).await;
        assert_eq!(placed_on(&old), None, "an old client's create moved: {old}");
        assert!(old.get("peer").is_none(), "{old}");
        let admission = &old["_meta"]["acpmux"]["admission"];
        assert_eq!(
            admission["suggestedHost"],
            "far",
            "warned as before: {admission}; peers: {:?}",
            a.peers()
        );
        before_local += 1;
    }
    assert!(seen.lock().unwrap().is_empty(), "an old client's create reached the peer");

    // After: a new client's create past the cap starts on `far`, answered with its route.
    for i in 0..3 {
        let v = call(&a, None, method::SESSION_NEW, new(&format!("new-{i}"), true)).await;
        match placed_on(&v) {
            Some(on) => {
                assert_eq!(on, "far", "{v}");
                assert_eq!(v["peer"], "far", "it routes to far: {v}");
                assert!(v["sessionId"].as_str().is_some_and(|id| id.starts_with("far-s")), "{v}");
                let placement = &v["_meta"]["acpmux"]["placement"];
                assert_eq!(placement["version"], 1, "{placement}");
                assert_eq!(placement["reason"], "over-cap", "{placement}");
                assert_eq!(placement["maxLanes"], 0, "{placement}");
                after_placed += 1;
            }
            None => after_local += 1,
        }
    }
    eprintln!(
        "admission-redirect fake fleet: before {before_local} of 3 past the cap started here; \
         after {after_placed} of 3 placed on far, {after_local} here"
    );
    assert_eq!((after_placed, after_local), (3, 0));
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 3);
        for p in seen.iter() {
            assert!(p.get("cwd").is_none(), "this host's folder went to the peer: {p}");
            let mux = &p["_meta"]["acpmux"];
            assert!(mux.get("placeRedirect").is_none(), "{mux}");
            assert!(mux.get("peer").is_none(), "{mux}");
            assert_eq!(mux["ifNameTaken"], "suffix", "a taken name is suffixed there: {mux}");
        }
    }

    // A peer daemon's connection never moves a create, nor learns this host's peers.
    let theirs = call(&a, Some(Origin::Peer), method::SESSION_NEW, new("via-peer", true)).await;
    assert_eq!(placed_on(&theirs), None, "{theirs}");
    assert!(!theirs.to_string().contains("far"), "a peer learned this host's peer: {theirs}");

    // A create tied to this machine (a worktree, env, an ephemeral run) starts here.
    let mut tied = new("tied", true);
    tied["_meta"]["acpmux"]["ephemeral"] = json!(true);
    let tied = call(&a, None, method::SESSION_NEW, tied).await;
    assert_eq!(placed_on(&tied), None, "{tied}");

    // A start that fails there starts here, warned: none is dropped for a cap (C1).
    let before = seen.lock().unwrap().len();
    let failed = call(&a, None, method::SESSION_NEW, new("refuse-me", true)).await;
    assert_eq!(seen.lock().unwrap().len(), before + 1, "it was tried on far");
    assert_eq!(placed_on(&failed), None, "{failed}");
    assert!(failed.get("peer").is_none(), "{failed}");
    let admission = &failed["_meta"]["acpmux"]["admission"];
    assert_eq!(admission["placeFailed"], "far", "{admission}");
    assert!(
        admission["warning"].as_str().is_some_and(|w| w.contains("started here")),
        "{admission}"
    );

    // Off: every create starts here as before.
    // SAFETY: this file's only test, and it reads the variable on this thread's requests.
    unsafe { std::env::set_var("ACPMUX_PLACE_REDIRECT", "0") };
    let off = call(&a, None, method::SESSION_NEW, new("off", true)).await;
    // SAFETY: as above.
    unsafe { std::env::remove_var("ACPMUX_PLACE_REDIRECT") };
    assert_eq!(placed_on(&off), None, "{off}");

    // A filler's room (`filler=true`, idle_feeder's work) is a real start's: it starts here,
    // never moved, and the filler is hibernated.
    let mut filler = new("filler", false);
    filler["_meta"]["acpmux"]["tags"] = json!({"filler": "true"});
    let filler = call(&a, None, method::SESSION_NEW, filler).await;
    let filler_id = filler["sessionId"].as_str().unwrap().to_owned();
    let before = seen.lock().unwrap().len();
    let real = call(&a, None, method::SESSION_NEW, new("real", true)).await;
    assert_eq!(placed_on(&real), None, "a start moved past a filler's room: {real}");
    assert!(real.get("peer").is_none(), "{real}");
    assert_eq!(seen.lock().unwrap().len(), before, "a start with a filler's room reached far");
    let mut hibernated = false;
    for _ in 0..200 {
        if a.resolve(&filler_id).unwrap().meta().hibernated_ms != 0 {
            hibernated = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(hibernated, "the filler whose room the start took was not hibernated");

    // With no peer that has room it starts here, warned, as before.
    let lone = hub();
    let lone_new = call(&lone, None, method::SESSION_NEW, new("lone", true)).await;
    assert_eq!(placed_on(&lone_new), None, "{lone_new}");
    let admission = &lone_new["_meta"]["acpmux"]["admission"];
    assert!(
        admission["warning"].as_str().is_some_and(|w| w.contains("at its cap of 0")),
        "{admission}"
    );
    assert!(admission.get("suggestedHost").is_none(), "{admission}");
    let _ = std::fs::remove_file(REGISTRY);
}
