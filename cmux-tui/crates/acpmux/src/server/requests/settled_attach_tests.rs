//! `_acpmux/attach` with `settled: true` over a store on disk (cmuxterm-hq#9655 stage 1): the
//! first open answers as before and writes the view; the next answers the view, then the records
//! logged since, as one contiguous page; a restart's queue comes from the view.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::store::{LocalStore, SessionMeta, Store};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const ID: &str = "settled-chat";

fn hub(sessions: &std::path::Path) -> Arc<crate::hub::Hub> {
    let writer = LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "settled", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap();
    writer.save(&meta).unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    crate::hub::Hub::new(
        config,
        Box::new(LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap()),
    )
}

fn turn(hub: &crate::hub::Hub, n: u64) {
    let s = hub.resolve(ID).unwrap();
    hub.append(&s, "mux", "user_message", json!({"text": format!("prompt {n}")}));
    hub.append(
        &s,
        "in",
        "session/update",
        json!({"method": "session/update", "params": {"sessionId": ID, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {n}")}}}}),
    );
    hub.append(
        &s,
        "mux",
        "turn_result",
        json!({"status": "completed", "turnId": format!("t{n}"), "turnSeq": n}),
    );
}

/// The pane's open (`direct.ts` `sendAttach`), with `settled`.
fn open(settled: bool) -> Value {
    json!({"sessionId": ID, "waitLogs": false, "limit": 400, "maxBytes": 131072,
        "kinds": ["transcript"], "eventStream": true, "settled": settled})
}

/// One connection's `initialize` result and attach reply.
async fn attach(hub: &Arc<crate::hub::Hub>, params: Value) -> (Value, Value) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(4096);
    tokio::spawn(super::super::serve_connection_with(
        hub.clone(),
        incoming,
        output,
        super::super::Origin::Local,
    ));
    let hello =
        json!({"protocolVersion": 1, "clientInfo": {"name": "settled-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    input.send(Message::request(2, method::MUX_ATTACH, params).to_line()).await.unwrap();
    // The two replies may come in either order: wait for both.
    let (mut init, mut attached) = (None, None);
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let line = outgoing.recv().await.unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == 1 {
                assert!(reply.get("error").is_none(), "{reply}");
                init = Some(reply["result"].clone());
            }
            if reply["id"] == 2 {
                assert!(reply.get("error").is_none(), "{reply}");
                attached = Some(reply["result"].clone());
            }
            if let (Some(init), Some(attached)) = (&init, &attached) {
                return (init.clone(), attached.clone());
            }
        }
    })
    .await
    .expect("the attach answers")
}

async fn view_written(hub: &crate::hub::Hub, through: u64) {
    let s = hub.resolve(ID).unwrap();
    tokio::time::timeout(Duration::from_secs(20), async {
        while hub.settled_view(&s).is_none_or(|v| v.last_seq < through) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the view is written");
}

fn seqs(reply: &Value) -> Vec<u64> {
    reply["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_settled_open_answers_the_view_then_what_was_logged_since() {
    let dir = std::env::temp_dir().join(format!("acpmux-settled-attach-{}", uuid::Uuid::now_v7()));
    let hub = hub(&dir.join("sessions"));
    for n in 1..=3 {
        turn(&hub, n);
    }
    let first_last = hub.resolve(ID).unwrap().meta().last_seq;

    // The daemon says it serves it.
    let (init, plain) = attach(&hub, open(false)).await;
    let caps = init.pointer("/_meta/acpmux/capabilities").unwrap().as_array().unwrap();
    assert!(caps.iter().any(|c| c == crate::capabilities::SETTLED_ATTACH), "{caps:?}");
    assert!(plain.get("settled").is_none(), "an open that does not ask gets none: {plain}");

    // No view yet: the open answers as before, says so, and writes one for the next open.
    let (_, first) = attach(&hub, open(true)).await;
    assert_eq!(first["settled"], Value::Null);
    assert_eq!(seqs(&first), seqs(&plain));
    view_written(&hub, first_last).await;

    // Logged since the view: its records first, then those, as one page through the log's end.
    turn(&hub, 4);
    let last = hub.resolve(ID).unwrap().meta().last_seq;
    let (_, second) = attach(&hub, open(true)).await;
    let settled = &second["settled"];
    assert_eq!(settled["lastSeq"], first_last, "{second}");
    assert_eq!(settled["forkSeqs"].as_array().unwrap().len(), 3);
    assert_eq!(settled["logLoaded"], true);
    assert_eq!(second["lastSeq"], last);
    assert_eq!(second["pageThrough"], last);
    assert_eq!(second["hasMore"], false);
    let got = seqs(&second);
    assert!(got.windows(2).all(|w| w[0] < w[1]), "{got:?}");
    assert_eq!(*got.last().unwrap(), last);
    // The same records a plain open reads now.
    let (_, now) = attach(&hub, open(false)).await;
    assert_eq!(got, seqs(&now));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn before_a_restart_reads_the_log_the_queue_is_the_views() {
    let dir = std::env::temp_dir().join(format!("acpmux-settled-queue-{}", uuid::Uuid::now_v7()));
    let hub = hub(&dir.join("sessions"));
    turn(&hub, 1);
    let s = hub.resolve(ID).unwrap();
    let key = crate::hub::settled_view::SettledKey::of_attach(&open(true)).unwrap();
    assert!(hub.write_settled_view(&s, &key));
    // The view saved a queue of two prompts; this daemon has not read the chat's log yet.
    let path = dir.join("sessions").join(ID).join(crate::hub::settled_view::FILE);
    let mut saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    saved["queue"] =
        json!([{"promptId": "p1", "prompt": "one"}, {"promptId": "p2", "prompt": "two"}]);
    saved["queued"] = json!(2);
    std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
    hub.mark_log_unread_for_test(&s);

    let (_, reply) = attach(&hub, open(true)).await;
    assert_eq!(reply["settled"]["logLoaded"], false, "{reply}");
    assert_eq!(reply["session"]["queueFrom"], "settled");
    assert_eq!(reply["session"]["queued"], 2);
    assert_eq!(reply["session"]["queue"].as_array().unwrap().len(), 2);
}
