//! A Computer Use call for another machine reaches it with its tool name and arguments, whatever
//! its `session` names (`server/computer_use_relay.rs`). The call's `session` is the calling
//! agent's own Computer Use key and its `name` the tool: neither is a chat. A daemon that read
//! them as one forwarded the call whole to the peer that holds a chat by that key, with `session`
//! and `name` stripped (`peer_forward.rs`), and the far side refused `unknown Computer Use tool
//! ""` on every `machine:` call from a cmux_exec script (2026-11-26, cmux16 listed ready).
//!
//! A fake peer `studio` serves one chat, `remote-lane` named `lane`, and records every
//! `_acpmux/computer_use_call` it gets.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs no agent; the hub only links to the fake peer.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn hub() -> Arc<Hub> {
    let _ = HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A fake peer serving one chat: every `_acpmux/computer_use_call` is sent on as its params and
/// answered with a result naming the tool it got.
async fn fake_peer() -> (u16, mpsc::UnboundedReceiver<Value>) {
    use tokio_tungstenite::tungstenite::Message as Ws;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (calls, received) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let Ok(mut ws) = acpmux::server::accept_ws(tcp).await else { continue };
            let calls = calls.clone();
            tokio::spawn(async move {
                while let Some(Ok(frame)) = ws.next().await {
                    let Ws::Text(text) = frame else { continue };
                    let Ok(Message::Request { id, method: m, params }) = Message::parse(&text)
                    else {
                        continue;
                    };
                    let params = params.unwrap_or(Value::Null);
                    let session = json!({"sessionId": "remote-lane", "name": "lane",
                        "harness": "fake", "status": "running"});
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "fake", "origin": "peer", "features": []}}}),
                        method::MUX_WATCH => json!({"sessions": [session]}),
                        method::MUX_COMPUTER_USE_CALL => {
                            let _ = calls.send(params.clone());
                            json!({"result": {"is_error": false, "code": null,
                                "body": {"tool": params["name"]}, "png": null}})
                        }
                        _ => json!({}),
                    };
                    let line = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(line.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (port, received)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, Value> {
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
                    Some(e) => Err(serde_json::to_value(e).unwrap()),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

async fn until_mirrored(a: &Hub, key: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while a.resolve_remote(key).is_none() {
        assert!(tokio::time::Instant::now() < deadline, "{key} was never mirrored");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_computer_use_call_for_a_machine_reaches_it_with_its_tool_name() {
    let (port, mut calls) = fake_peer().await;
    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("studio", &url, Some("tok".into()), None, true).await.unwrap();
    until_mirrored(&a, "studio/lane").await;
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(a.clone(), in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
        .await
        .unwrap();

    // A session key this daemon has no chat for, the peer's chat by its key and by its id: each
    // is the caller's Computer Use key, never a chat to forward the call to.
    for (session, tool) in
        [("s-local", "click"), ("studio/lane", "click"), ("remote-lane", "screenshot")]
    {
        let arguments = json!({"window_id": "w1", "x": 3, "y": 4});
        let ask = json!({"machine": "studio", "name": tool, "arguments": arguments,
            "session": session, "label": "Claude Code", "call_id": format!("c-{session}"),
            "tag": ""});
        let reply = c
            .call(method::MUX_COMPUTER_USE_CALL, ask)
            .await
            .unwrap_or_else(|e| panic!("{session}/{tool} refused: {e}"));
        let got = tokio::time::timeout(Duration::from_secs(20), calls.recv())
            .await
            .expect("the call never reached the peer")
            .expect("the fake peer ended");
        assert_eq!(got["name"], tool, "the tool name was dropped on the way: {got}");
        assert_eq!(got["session"], session, "{got}");
        assert_eq!(got["arguments"], arguments, "{got}");
        assert_eq!(got["call_id"], format!("c-{session}"), "{got}");
        assert!(got.get("sessionId").is_none(), "forwarded as a chat's request: {got}");
        assert!(got.get("machine").is_none(), "the machine went on to the peer: {got}");
        assert_eq!(reply["result"]["body"]["tool"], tool, "{reply}");
    }
    // A call with no session whose tool name is the peer chat's: refused here (no catalog tool,
    // no session), never sent on to that chat's machine.
    let ask = json!({"machine": "studio", "name": "lane", "call_id": "c-lane"});
    let e = c.call(method::MUX_COMPUTER_USE_CALL, ask).await.expect_err("a bad call was answered");
    assert_eq!(e["data"]["code"], "unknown_tool", "{e}");
    assert!(calls.try_recv().is_err(), "a refused call reached the peer");
    a.shutdown_all().await;
}
