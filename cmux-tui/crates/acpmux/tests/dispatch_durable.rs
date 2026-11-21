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
        // A harness scopes session/cancel to the prompt it is running and ignores one while
        // idle (ACP; Claude Code's interrupt and Codex do). The stand-in otherwise keeps a cancel
        // that came while idle and stops its next prompt with it: a cancel acpmux sent for a
        // turn it fenced before the write then stopped `later-person` 12 times in 16.
        "harnesses": {"fake": {"argv": ["python3", FAKE], "env": {"FAKE_RESET_CANCEL_ON_PROMPT": "1"}}},
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
            let params=json!({"briefId":"workflow-activity","durable":true,"receiptToken":"1111111111111111111111111111111111111111111111111111111111111111","host":"local",
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
            let mut forbidden=params.clone();forbidden["briefId"]=json!("forbidden");forbidden["policy"]=json!("approve-all");
            assert!(call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,forbidden).await.unwrap_err().contains("person-approved preset"));
            let mut stolen = params.clone();
            stolen["briefId"] = json!("workflow-activity");
            stolen["policy"] = json!("ask");
            stolen["receiptToken"] = json!("2222222222222222222222222222222222222222222222222222222222222222");
            assert!(call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, stolen.clone()).await.is_err(),
                "a different caller read a durable receipt by knowing its id");
            let mut legacy = stolen.clone();
            legacy.as_object_mut().unwrap().remove("durable");
            assert!(call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, legacy).await.is_err(),
                "omitting durable bypassed receipt authorization");
            stolen["action"] = json!("cancel");
            assert!(call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, stolen).await.is_err(),
                "a different caller cancelled a durable dispatch by knowing its id");
            for origin in [None, Some(Origin::Peer)] {
                let listed = call(&hub, origin, method::MUX_BRIEFS, json!({})).await.unwrap();
                assert!(listed["briefs"].as_array().unwrap().is_empty(),
                    "legacy brief listing leaked a private durable receipt: {listed}");
                let tasks = call(&hub, origin, method::MUX_TASKS, json!({"all":true})).await.unwrap();
                assert!(tasks["tasks"].as_array().unwrap().is_empty(), "legacy task listing leaked durable activity");
                for operation in [method::MUX_STEER, method::MUX_REPORT] {
                    assert!(call(&hub, origin, operation, json!({"briefId":"workflow-activity", "text":"steal", "summary":"steal"})).await.is_err());
                }
            }
            hub.shutdown_all().await;
        });
}

#[test]
fn durable_cancel_fences_delayed_dispatch_and_only_its_exact_prompt() {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let hub = hub();
            let params = json!({"briefId":"before-start","durable":true,"receiptToken":"1111111111111111111111111111111111111111111111111111111111111111","host":"local",
                "title":"Workflow cancel fence","brief":"until-cancel","cwd":std::env::temp_dir(),
                "harness":"fake","policy":"ask","allowedTools":[]});
            let mut cancel = params.clone();
            cancel["action"] = json!("cancel");
            let tombstone =
                call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, cancel.clone()).await.unwrap();
            let sid = tombstone["brief"]["sessionId"].as_str().unwrap();
            assert!(hub.resolve(sid).is_err(), "pre-launch cancellation created a child");
            let mut late = params.clone();
            late["wait"] = json!(true);
            let late = call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, late).await.unwrap();
            assert_eq!(late["brief"]["dispatchCancelled"], true);
            assert!(hub.resolve(sid).is_err(), "late dispatch escaped its cancellation tombstone");
            // This races admission and cancellation. A destination that has not
            // accepted the prompt must never send it after the tombstone.
            let mut racing = params;
            racing["briefId"] = json!("race-start");
            let mut stop = racing.clone();
            stop["action"] = json!("cancel");
            let (start, stop) = tokio::join!(
                call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, racing.clone()),
                call(&hub, Some(Origin::Peer), method::MUX_DISPATCH, stop)
            );
            let start = start.unwrap();
            let stop = stop.unwrap();
            assert_eq!(start["brief"]["sessionId"], stop["brief"]["sessionId"]);
            assert_eq!(stop["brief"]["dispatchCancelled"], true);
            // Force a known admitted child, stop it, then send an unrelated
            // active turn. A stale workflow cancel must leave that turn alone.
            let mut admitted=racing.clone();admitted["briefId"]=json!("admitted-before-cancel");
            let started=call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,admitted.clone()).await.unwrap();
            let sid=started["brief"]["sessionId"].as_str().unwrap();
            let mut stale=admitted;stale["action"]=json!("cancel");
            call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,stale.clone()).await.unwrap();
            let session=hub.resolve(sid).unwrap();
            let mut events=hub.subscribe();
            let later=call(&hub,None,method::SESSION_PROMPT,
                json!({"sessionId":sid,"prompt":[{"type":"text","text":"slow"}],
                    "_meta":{"acpmux":{"promptId":"later-person"}}}));
            tokio::pin!(later);
            tokio::time::timeout(Duration::from_secs(20),async {
                loop {
                    if session.turn().is_some_and(|turn|turn.prompt_id=="later-person") {break;}
                    tokio::select! {
                        early=&mut later=>panic!("later turn ended before stale cancellation: {early:?}"),
                        _=events.recv()=>{},
                    }
                }
            }).await.unwrap();
            call(&hub,Some(Origin::Peer),method::MUX_DISPATCH,stale).await.unwrap();
            let reply=later.await.unwrap();
            assert_eq!(reply["stopReason"],"end_turn","stale workflow cancel stopped unrelated turn: {reply}");
            hub.shutdown_all().await;
        });
}

#[test]
fn durable_dispatch_crosses_a_real_peer_and_reattaches_by_its_pinned_alias() {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_stack_size(32 << 20)
        .enable_all().build().unwrap().block_on(async {
            use acpmux::server::{bind_ws,serve_ws_with,WsAuth};
            use acpmux::server::peer_auth::{PeerAuth,token_path};
            let root=tempfile::tempdir().unwrap();
            let local=hub();let remote=hub();
            let auth=PeerAuth::create(root.path()).unwrap();
            let peer_token=std::fs::read_to_string(token_path(root.path())).unwrap();
            let listener=bind_ws("127.0.0.1:0").await.unwrap();
            let port=listener.local_addr().unwrap().port();
            let server=tokio::spawn(serve_ws_with(remote.clone(),listener,"durable-peer-test".into(),
                WsAuth{local_app:None,peer:Some(Arc::new(auth))}));
            let added=local.add_peer("paired-target",&format!("ws://127.0.0.1:{port}"),
                Some("durable-peer-test".into()),Some(peer_token),true).await.unwrap();
            assert_eq!(added["peer"]["connected"],true,"{added}");
            let params=json!({"briefId":"cross-peer","durable":true,"receiptToken":"1111111111111111111111111111111111111111111111111111111111111111","host":"paired-target","wait":true,
                "brief":"cross-peer reply","title":"Peer workflow","cwd":std::env::temp_dir(),
                "harness":"fake","policy":"ask","allowedTools":[]});
            let first=call(&local,None,method::MUX_DISPATCH,params.clone()).await.unwrap();
            assert_eq!(first["brief"]["outcome"]["Ok"]["finalReply"],"echo: cross-peer reply","{first}");
            assert!(first["brief"].get("dispatchLocal").is_none(),"remote receipt was marked local at forwarding host");
            let replay=call(&local,None,method::MUX_DISPATCH,params.clone()).await.unwrap();
            assert_eq!(first["brief"]["sessionId"],replay["brief"]["sessionId"]);
            assert_eq!(first["brief"]["outcome"],replay["brief"]["outcome"]);
            let mut hidden=params.clone();hidden["host"]=json!("local");
            assert!(call(&local,Some(Origin::Peer),method::MUX_DISPATCH,hidden).await.is_err(),
                "peer caller learned a dispatch belonging to another peer");
            let mut before=params;before["briefId"]=json!("cancel-cross-peer");before["brief"]=json!("until-cancel");
            let mut stop=before.clone();stop["action"]=json!("cancel");stop["wait"]=json!(false);
            let cancelled=call(&local,None,method::MUX_DISPATCH,stop).await.unwrap();
            let sid=cancelled["brief"]["sessionId"].as_str().unwrap();
            assert!(remote.resolve(sid).is_err(),"remote cancellation created a child");
            let late=call(&local,None,method::MUX_DISPATCH,before).await.unwrap();
            assert_eq!(late["brief"]["dispatchCancelled"],true,"{late}");
            assert!(remote.resolve(sid).is_err(),"delayed send escaped a remote tombstone");
            local.remove_peer("paired-target").await.unwrap();
            local.shutdown_all().await;remote.shutdown_all().await;
            server.abort();
        });
}
