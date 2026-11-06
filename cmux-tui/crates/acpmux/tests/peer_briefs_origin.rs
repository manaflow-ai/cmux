//! A peer daemon's connection (paired devices included) never learns this host's peers
//! (`tests/peer_dispatch_origin.rs`, `tests/peer_state_origin.rs`). `_acpmux/briefs` lists it the
//! briefs this host ran and asks no peer; `_acpmux/steer` and `_acpmux/report` of a brief a peer
//! ran answer it as of a brief that does not exist, idempotent replays included. The unix socket
//! keeps the briefs of this host's peers.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The peer's name, and a brief only it knows of (an id with no name in it: refusals echo ids).
const PEER: &str = "elsewhere";
const PEERS_OWN: &str = "brief-only-the-peer-knows";

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
/// result, or its whole error object.
async fn call(
    hub: &Arc<Hub>,
    origin: Option<Origin>,
    m: &str,
    params: Value,
) -> Result<Value, Value> {
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
                Some(e) => Err(e.clone()),
                None => Ok(v["result"].clone()),
            };
        }
    }
}

/// A fake peer daemon. Every brief row it answers names it (`host`, `target`, `to`), as a brief
/// that ran there does; `_acpmux/briefs` adds one only it knows of.
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
                    let row = |id: &Value, status: &str| {
                        json!({"briefId": id, "host": PEER, "target": PEER, "to": PEER,
                            "sessionId": "remote-session", "status": status})
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "build": "older", "origin": "peer", "features": []}}}),
                        method::MUX_WATCH => json!({"sessions": []}),
                        method::MUX_DISPATCH => json!({"brief": row(&p["briefId"], "running")}),
                        method::MUX_BRIEFS => {
                            json!({"briefs": [row(&json!(PEERS_OWN), "running")]})
                        }
                        method::MUX_STEER => {
                            let mut brief = row(&p["briefId"], "running");
                            brief["lastSteerKey"] = p["idempotencyKey"].clone();
                            json!({"brief": brief})
                        }
                        method::MUX_REPORT => {
                            let mut brief = row(&p["briefId"], "reported");
                            brief["lastReportKey"] = p["idempotencyKey"].clone();
                            brief["report"] = p["summary"].clone();
                            json!({"brief": brief})
                        }
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

/// The request handler's future is deeper than a debug build's 2 MiB worker stack: the
/// connections run on workers with room, as in `tests/inherit_start.rs`.
#[test]
fn a_peer_connections_briefs_steer_and_report_name_none_of_this_hosts_peers() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(peer_briefs_name_no_peer());
}

async fn peer_briefs_name_no_peer() {
    let port = fake_peer().await;
    let a = hub();
    a.add_peer(PEER, &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let dispatch = |host: &str| {
        json!({"brief": "say hi", "title": format!("brief {}", uuid::Uuid::now_v7()), "host": host,
            "cwd": std::env::temp_dir(), "harness": "fake"})
    };
    let id_of = |reply: &Value| reply["brief"]["briefId"].as_str().unwrap().to_owned();
    // A brief this host ran, and one it sent to its peer.
    let here = call(&a, None, method::MUX_DISPATCH, dispatch("local")).await.unwrap();
    let here = id_of(&here);
    let sent = call(&a, None, method::MUX_DISPATCH, dispatch(PEER)).await.unwrap();
    assert_eq!(sent["brief"]["host"], PEER, "{sent}");
    let sent = id_of(&sent);
    // The unix socket steers and reports the peer's brief there, with keys a replay would name.
    let steer = json!({"briefId": sent, "text": "go on", "idempotencyKey": "steer-1"});
    let steered = call(&a, None, method::MUX_STEER, steer).await.unwrap();
    assert_eq!(steered["brief"]["host"], PEER, "{steered}");
    let report = json!({"briefId": sent, "summary": "done", "idempotencyKey": "report-1"});
    let reported = call(&a, None, method::MUX_REPORT, report).await.unwrap();
    assert_eq!(reported["brief"]["host"], PEER, "{reported}");

    // The unix socket lists every brief, its peer's included.
    let all = call(&a, None, method::MUX_BRIEFS, json!({})).await.unwrap();
    let ids = |list: &Value| -> Vec<String> {
        list["briefs"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|row| row["briefId"].as_str().map(str::to_owned))
            .collect()
    };
    for id in [&here, &sent, &PEERS_OWN.to_owned()] {
        assert!(ids(&all).contains(id), "the unix socket lists {id}: {all}");
    }

    // A peer's connection is listed the brief this host ran, and none a peer ran.
    for params in [json!({}), json!({"status": "running"}), json!({"limit": 500})] {
        let theirs = call(&a, Some(Origin::Peer), method::MUX_BRIEFS, params).await.unwrap();
        assert!(ids(&theirs).iter().all(|id| *id == here), "{theirs}");
        assert!(
            !theirs.to_string().contains(PEER),
            "a peer was told of this host's peer: {theirs}"
        );
    }
    let theirs = call(&a, Some(Origin::Peer), method::MUX_BRIEFS, json!({})).await.unwrap();
    assert_eq!(ids(&theirs), std::slice::from_ref(&here), "{theirs}");
    // Nor does `_acpmux/tasks` list a peer's connection the ledger's briefs a peer ran.
    let tasks = call(&a, None, method::MUX_TASKS, json!({"all": true})).await.unwrap();
    assert!(tasks.to_string().contains(PEER), "the unix socket lists them: {tasks}");
    let tasks = call(&a, Some(Origin::Peer), method::MUX_TASKS, json!({"all": true})).await;
    let tasks = tasks.unwrap();
    assert!(!tasks.to_string().contains(PEER), "a peer was told of this host's peer: {tasks}");

    // Steer and report of a brief a peer ran answer as of a brief that does not exist, replays
    // included: one answer, which names no peer.
    let none = |m: &str, params: Value| {
        let a = a.clone();
        let m = m.to_owned();
        async move {
            let ghost = "brief-that-never-was";
            let mut absent = params.clone();
            absent["briefId"] = json!(ghost);
            let want = call(&a, Some(Origin::Peer), &m, absent).await.expect_err("no such brief");
            let got = call(&a, Some(Origin::Peer), &m, params.clone()).await;
            let got = got.expect_err(&format!("{m} {params}: a peer reached a peer's brief"));
            let id = params["briefId"].as_str().unwrap();
            assert_eq!(
                got.to_string().replace(id, ghost),
                want.to_string(),
                "{m} {params}: a peer could tell a peer's brief from none"
            );
            assert!(!got.to_string().contains(PEER), "{m}: {got}");
        }
    };
    none(method::MUX_STEER, json!({"briefId": sent, "text": "go on", "idempotencyKey": "steer-1"}))
        .await;
    none(method::MUX_STEER, json!({"briefId": sent, "text": "go on"})).await;
    none(
        method::MUX_REPORT,
        json!({"briefId": sent, "summary": "done", "idempotencyKey": "report-1"}),
    )
    .await;
    none(method::MUX_REPORT, json!({"briefId": sent, "summary": "done"})).await;
    // A brief only the peer knows of, kept here from the unix socket's list.
    none(method::MUX_STEER, json!({"briefId": PEERS_OWN, "text": "go on"})).await;
    none(method::MUX_REPORT, json!({"briefId": PEERS_OWN, "summary": "done"})).await;

    // A peer's connection still reports the brief this host ran.
    let report = json!({"briefId": here, "summary": "done here", "idempotencyKey": "report-2"});
    let mine = call(&a, Some(Origin::Peer), method::MUX_REPORT, report.clone()).await.unwrap();
    assert_eq!(mine["brief"]["status"], "reported", "{mine}");
    assert!(!mine.to_string().contains(PEER), "{mine}");
    let replayed = call(&a, Some(Origin::Peer), method::MUX_REPORT, report).await.unwrap();
    assert_eq!(replayed["replayed"], true, "{replayed}");
}
