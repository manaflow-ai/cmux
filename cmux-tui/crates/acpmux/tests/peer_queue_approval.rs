//! A prompt that waits for the owner (`_meta.acpmux.author.approval`, hq#4766) goes to a peer's
//! chat only when that peer holds it: an older build ignores `approval` and would run it
//! unapproved. To a peer that does not list `queueApproval` the prompt, and the owner's approve
//! and decline, are refused `queue.approval_unsupported` and nothing is forwarded; to one that
//! lists it the prompt goes with its approval (review of #26747). `_acpmux/queue_get` goes only to
//! a peer that lists `queueGet`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as Ws;

/// A peer daemon that lists `features` at its handshake and one session, `far-1`, and records
/// every session request it gets (method, params).
async fn fake_peer(features: Value) -> (u16, Arc<Mutex<Vec<(String, Value)>>>) {
    let got = Arc::new(Mutex::new(Vec::new()));
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let seen = got.clone();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let (seen, features) = (seen.clone(), features.clone());
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, params }) = Message::parse(&text)
                    else {
                        continue;
                    };
                    let params = params.unwrap_or(Value::Null);
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "build": "peer-build", "origin": "peer", "features": features}}}),
                        method::MUX_WATCH => json!({"sessions": [{"sessionId": "far-1"}]}),
                        _ => {
                            if params.get("sessionId").is_some() {
                                seen.lock().unwrap().push((m.clone(), params));
                            }
                            json!({"stopReason": "end_turn"})
                        }
                    };
                    let reply = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (port, got)
}

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The reply to one request on a new unix-socket connection.
async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> Value {
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(256);
    tokio::spawn(serve_connection_with(hub.clone(), rx, out_tx, Origin::Local));
    tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), out.recv()).await;
        let value: Value = serde_json::from_str(&line.unwrap().unwrap()).unwrap();
        if value["id"] == 1 {
            return value;
        }
    }
}

fn prompt(id: &str, approval: Option<&str>) -> Value {
    let mut author = json!({"id": "user_42", "name": "Bo"});
    if let Some(approval) = approval {
        author["approval"] = json!(approval);
    }
    json!({"sessionId": "far-1", "prompt": [{"type": "text", "text": "hi"}],
           "_meta": {"acpmux": {"promptId": id, "author": author}}})
}

/// The prompts and queue answers a fake peer got (it also gets the attach a prompt makes).
fn prompts(got: &Mutex<Vec<(String, Value)>>) -> Vec<Value> {
    let asks = [
        method::SESSION_PROMPT,
        method::MUX_QUEUE_APPROVE,
        method::MUX_QUEUE_DECLINE,
        method::MUX_QUEUE_GET,
    ];
    let got = got.lock().unwrap();
    got.iter().filter(|(m, _)| asks.contains(&m.as_str())).map(|(_, p)| p.clone()).collect()
}

fn reason(v: &Value) -> &Value {
    v.pointer("/error/data/reason").unwrap_or(&Value::Null)
}

#[tokio::test]
async fn a_held_prompt_goes_only_to_a_peer_that_holds_it() {
    let (old_port, old_got) = fake_peer(json!(["trustGate", "filePut"])).await;
    let old = hub();
    old.add_peer("old", &format!("ws://127.0.0.1:{old_port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let refused = call(&old, method::SESSION_PROMPT, prompt("g-1", Some("owner"))).await;
    assert_eq!(reason(&refused), "queue.approval_unsupported", "{refused}");
    assert!(refused["error"]["message"].as_str().unwrap().contains("acpmux host update old"));
    for m in [method::MUX_QUEUE_APPROVE, method::MUX_QUEUE_DECLINE, method::MUX_QUEUE_GET] {
        let answer = json!({"sessionId": "far-1", "promptId": "g-1", "revision": 0});
        let refused = call(&old, m, answer).await;
        assert_eq!(reason(&refused), "queue.approval_unsupported", "{m}: {refused}");
    }
    assert!(prompts(&old_got).is_empty(), "forwarded: {:?}", old_got.lock().unwrap());
    // A person's prompt that waits for no one still goes.
    let plain = call(&old, method::SESSION_PROMPT, prompt("p-1", None)).await;
    assert!(plain.get("error").is_none(), "{plain}");
    assert_eq!(prompts(&old_got).len(), 1, "{:?}", old_got.lock().unwrap());

    let (new_port, new_got) = fake_peer(json!(["trustGate", "queueApproval"])).await;
    let new = hub();
    new.add_peer("new", &format!("ws://127.0.0.1:{new_port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let sent = call(&new, method::SESSION_PROMPT, prompt("g-2", Some("owner"))).await;
    assert!(sent.get("error").is_none(), "{sent}");
    let got = prompts(&new_got);
    assert_eq!(got.len(), 1, "{:?}", new_got.lock().unwrap());
    let author = &got[0]["_meta"]["acpmux"]["author"];
    assert_eq!(author["approval"], "owner", "it lost its hold on the way: {author}");
    // `_acpmux/queue_get` needs its own feature (`queueGet`), which this peer does not list.
    let get = json!({"sessionId": "far-1", "promptId": "g-2"});
    let refused = call(&new, method::MUX_QUEUE_GET, get.clone()).await;
    assert_eq!(reason(&refused), "queue.approval_unsupported", "{refused}");
    assert_eq!(prompts(&new_got).len(), 1);

    let (get_port, get_got) = fake_peer(json!(["queueApproval", "queueGet"])).await;
    let reads = hub();
    reads
        .add_peer("reads", &format!("ws://127.0.0.1:{get_port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let read = call(&reads, method::MUX_QUEUE_GET, get).await;
    assert!(read.get("error").is_none(), "{read}");
    assert_eq!(prompts(&get_got).len(), 1, "{:?}", get_got.lock().unwrap());
}

/// A link guest's prompt waits for the owner with `approval` left off (`author.rs`, hq#5528): it
/// goes only to a peer that holds it, and names its hold there, so a peer that reads only
/// `approval` holds it too.
#[tokio::test]
async fn an_unmarked_guest_prompt_goes_held_and_only_to_a_peer_that_holds_it() {
    let unmarked = |id: &str| {
        let mut p = prompt(id, None);
        p["_meta"]["acpmux"]["author"] = json!({"id": "guest:share.guest", "name": "Theo"});
        p
    };
    let (old_port, old_got) = fake_peer(json!(["trustGate", "filePut"])).await;
    let old = hub();
    old.add_peer("old", &format!("ws://127.0.0.1:{old_port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let refused = call(&old, method::SESSION_PROMPT, unmarked("g-1")).await;
    assert_eq!(reason(&refused), "queue.approval_unsupported", "{refused}");
    assert!(prompts(&old_got).is_empty(), "forwarded: {:?}", old_got.lock().unwrap());

    let (new_port, new_got) = fake_peer(json!(["trustGate", "queueApproval"])).await;
    let new = hub();
    new.add_peer("new", &format!("ws://127.0.0.1:{new_port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let sent = call(&new, method::SESSION_PROMPT, unmarked("g-2")).await;
    assert!(sent.get("error").is_none(), "{sent}");
    let got = prompts(&new_got);
    assert_eq!(got.len(), 1, "{:?}", new_got.lock().unwrap());
    let author = &got[0]["_meta"]["acpmux"]["author"];
    assert_eq!(author["approval"], "owner", "it went without its hold: {author}");
    assert_eq!(author["id"], "guest:share.guest", "{author}");
}
