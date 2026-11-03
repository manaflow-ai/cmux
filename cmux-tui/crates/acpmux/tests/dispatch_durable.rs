//! Durable workflow dispatch preserves peer permission checks and stable child identities.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/) and its hub reads the
// registry the test writes.
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

#[test]
fn durable_peer_dispatch_replays_the_same_child_and_exact_reply() {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_stack_size(32 << 20)
        .enable_all().build().unwrap().block_on(async {
            let hub=hub();
            let params=json!({"briefId":"workflow-activity","durable":true,"host":"local",
                "title":"Workflow remote check","brief":"exact workflow reply","cwd":std::env::temp_dir(),
                "harness":"fake","policy":"ask","allowedTools":[]});
            let (first,replay)=tokio::join!(
                call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,params.clone()),
                call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,params.clone()));
            let first=first.unwrap();let replay=replay.unwrap();
            assert_eq!(first["brief"]["sessionId"],replay["brief"]["sessionId"]);
            assert_eq!(first["brief"]["promptId"],replay["brief"]["promptId"]);
            let mut wait=params.clone();wait["wait"]=json!(true);
            let finished=call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,wait).await.unwrap();
            assert_eq!(finished["brief"]["outcome"]["Ok"]["finalReply"],"echo: exact workflow reply","{finished}");
            let sid=first["brief"]["sessionId"].as_str().unwrap();
            let pid=first["brief"]["promptId"].as_str().unwrap();
            let mut count=0;
            hub.scan_events(sid,0,&mut |record| {
                if record.dir=="mux" && record.kind=="turn_started" && record.msg["promptId"]==pid {count+=1;}
                true
            }).unwrap();
            assert_eq!(count,1,"concurrent retries dispatched more than one prompt");
            let mut changed=params.clone();changed["brief"]=json!("different effect");
            assert!(call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,changed).await.unwrap_err().contains("pins different inputs"));
            let mut forbidden=params;forbidden["briefId"]=json!("forbidden");forbidden["policy"]=json!("approve-all");
            assert!(call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,forbidden).await.unwrap_err().contains("person-approved preset"));
            hub.shutdown_all().await;
        });
}
