//! A host whose fleet-registry lanes say `last_resort` takes a dispatched capture or build, never
//! an agent lane (design/agent-dispatch.md), checked where the lane would start
//! (`server/place.rs` `here_refusal`, `server/requests.rs` `dispatch_brief`): `--host local`, a
//! peer's dispatch and `auto` placed here are refused alike. A replay of a brief this host took
//! before starts nothing and still answers, under `--host local`, this host's name or `auto`, and
//! a refused brief leaves no claim behind. One test function: the registry is read from this
//! process's environment.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/) and its hub reads the
// registry the test writes.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("FLEET_REGISTRY", REGISTRY)]);
const REGISTRY: &str = concat!(env!("CARGO_TARGET_TMPDIR"), "/dispatch-last-resort-registry.json");

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
        // A peer's dispatch runs only a harness with a reviewed asking mode (`remote_guard.rs`).
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

/// The dispatch handler's future is deeper than a debug build's 2 MiB worker stack: the
/// connections run on workers with room, as in `tests/peer_dispatch_origin.rs`.
#[test]
fn a_last_resort_host_refuses_a_new_agent_lane_and_still_answers_a_replay() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(last_resort_dispatch());
}

async fn last_resort_dispatch() {
    let a = hub();
    let here = call(&a, None, "_acpmux/host_health", json!({})).await.unwrap()["host"]
        .as_str()
        .unwrap()
        .to_owned();
    let registry = |last_resort: bool| {
        let lanes = json!({"lanes": {"reserved_gb": 0, "per_lane_gb": 0.1, "free_gb_floor": 0,
            "disk_per_lane_gb": 0.1, "cores_per_lane": 0.1, "max_lanes": 1000,
            "build": "fallback", "last_resort": last_resort}});
        std::fs::write(REGISTRY, json!({"machines": {here.clone(): lanes}}).to_string()).unwrap();
    };
    // Each brief's session takes its name from a title of its own.
    let dispatch = |brief: &str, host: &str, id: &str| {
        json!({"brief": brief, "title": format!("brief {}", uuid::Uuid::now_v7()), "host": host,
            "briefId": id, "cwd": std::env::temp_dir(), "harness": "fake"})
    };

    // Before the host was a last resort, it took an agent lane.
    registry(false);
    let old = call(&a, None, method::MUX_DISPATCH, dispatch("say hi", "local", "brief-old"))
        .await
        .unwrap();
    assert_eq!(old["brief"]["briefId"], "brief-old", "{old}");

    registry(true);
    // Its replay starts nothing, and answers as before.
    let replayed = call(&a, None, method::MUX_DISPATCH, dispatch("say hi", "local", "brief-old"))
        .await
        .unwrap();
    assert_eq!(replayed["replayed"], true, "{replayed}");
    // So does a retry that names this host, or asks `auto` (which now finds no host for an agent
    // lane): the placement rules a new lane meets come after the replay.
    for host in [here.as_str(), "auto"] {
        let replayed =
            call(&a, None, method::MUX_DISPATCH, dispatch("say hi", host, "brief-old")).await;
        let replayed = replayed.unwrap_or_else(|e| panic!("{host}: a replay was refused: {e}"));
        assert_eq!(replayed["replayed"], true, "{host}: {replayed}");
    }

    // A new agent lane here is refused, from the unix socket or a peer, local or auto.
    for (origin, host) in
        [(None, "local"), (Some(Origin::Peer), "local"), (Some(Origin::Peer), "auto")]
            .into_iter()
            .chain([(None, here.as_str()), (None, "auto")])
    {
        let refused =
            call(&a, origin, method::MUX_DISPATCH, dispatch("say hi", host, "brief-new")).await;
        let refused = refused.expect_err("an agent lane started on a last-resort host");
        assert!(refused.contains("a last-resort host (lanes.last_resort)"), "{host}: {refused}");
    }

    // A capture is taken.
    let capture =
        call(&a, None, method::MUX_DISPATCH, dispatch("capture the pane", "local", "brief-cap"))
            .await
            .unwrap();
    assert_eq!(capture["brief"]["briefId"], "brief-cap", "{capture}");

    // The refused brief left no claim: once the host takes agent lanes again, its id starts.
    registry(false);
    let again = call(&a, None, method::MUX_DISPATCH, dispatch("say hi", "local", "brief-new"))
        .await
        .unwrap();
    assert!(again.get("replayed").is_none(), "{again}");
    assert_eq!(again["brief"]["briefId"], "brief-new", "{again}");
    let _ = std::fs::remove_file(REGISTRY);
}
