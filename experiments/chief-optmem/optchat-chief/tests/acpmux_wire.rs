//! The real acpmux port against a fake acpmux daemon on a Unix socket: the
//! link connects, routes notifications, and one turn runs over the wire.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent, SessionSpec};
use optchat_chief::prompt::turn_blocks;
use optchat_chief::turn::{self, TurnStart};
use serde_json::{Value, json};

/// The events one prompt records, in the shapes acpmux stores them.
fn turn_events(prompt_id: &str) -> Vec<Value> {
    let update = |kind: &str, mut u: Value| {
        u["sessionUpdate"] = json!(kind);
        (
            kind.to_owned(),
            "in",
            json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "agent-1", "update": u}}),
        )
    };
    let raw = vec![
        (
            "user_message".to_owned(),
            "mux",
            json!({"promptId": prompt_id, "text": "..."}),
        ),
        (
            "turn_started".to_owned(),
            "mux",
            json!({"promptId": prompt_id}),
        ),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "Reading."}}),
        ),
        update(
            "agent_thought_chunk",
            json!({"content": {"type": "text", "text": "hmm"}}),
        ),
        update(
            "tool_call",
            json!({"toolCallId": "tc1", "title": "Read x", "status": "in_progress", "rawInput": {"path": "x"}, "_meta": {"claude": {"tool": "Read"}}}),
        ),
        update(
            "tool_call_update",
            json!({"toolCallId": "tc1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "x holds 1"}}]}),
        ),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": "x is 1."}}),
        ),
        (
            "turn_end".to_owned(),
            "mux",
            json!({"stopReason": "end_turn"}),
        ),
    ];
    raw.into_iter()
        .enumerate()
        .map(|(i, (kind, dir, msg))| json!({"seq": i + 1, "at": 1, "dir": dir, "kind": kind, "msg": msg}))
        .collect()
}

fn serve(listener: UnixListener, requests: Arc<Mutex<Vec<Value>>>) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let requests = requests.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                let mut events: Vec<Value> = Vec::new();
                let mut send = |v: Value| writeln!(out, "{v}").unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    let id = req["id"].clone();
                    let reply =
                        |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
                    match req["method"].as_str().unwrap() {
                        "_acpmux/watch" => {
                            send(reply(json!({})));
                            send(
                                json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": {"sessionId": "c9", "session": {"sessionId": "c9", "name": "kid", "status": "running", "tags": {"mux.parent": "optchat-chief"}}}}),
                            );
                        }
                        "_acpmux/sessions" => send(reply(
                            json!({"sessions": [{"sessionId": "old", "name": "x", "status": "idle"}]}),
                        )),
                        "session/new" => send(reply(json!({"sessionId": "s-1"}))),
                        "session/prompt" => {
                            let prompt_id = req["params"]["_meta"]["acpmux"]["promptId"]
                                .as_str()
                                .unwrap()
                                .to_owned();
                            events = turn_events(&prompt_id);
                            for e in &events {
                                if e["dir"] == "in" {
                                    let mut params = e["msg"]["params"].clone();
                                    params["sessionId"] = json!("s-1");
                                    params["_meta"] =
                                        json!({"acpmux": {"seq": e["seq"], "kind": e["kind"]}});
                                    send(
                                        json!({"jsonrpc": "2.0", "method": "session/update", "params": params}),
                                    );
                                } else {
                                    let mut ev = e.clone();
                                    ev["sessionId"] = json!("s-1");
                                    send(
                                        json!({"jsonrpc": "2.0", "method": "_acpmux/event", "params": ev}),
                                    );
                                }
                            }
                            send(reply(json!({"stopReason": "end_turn"})));
                        }
                        "_acpmux/events" => {
                            let after = req["params"]["afterSeq"].as_u64().unwrap();
                            let page: Vec<Value> = events
                                .iter()
                                .filter(|e| e["seq"].as_u64().unwrap() > after)
                                .cloned()
                                .collect();
                            send(reply(json!({"events": page})));
                        }
                        _ => send(reply(json!({}))),
                    }
                }
            });
        }
    });
}

#[test]
fn a_turn_over_the_acpmux_wire() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(UnixListener::bind(&socket).unwrap(), requests.clone());

    let acpmux = Acpmux::new(socket);
    let (tx, rx) = channel();
    let sink_tx = Mutex::new(tx);
    acpmux.spawn_link(
        Arc::new(move |e| sink_tx.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    let mut seen = Vec::new();
    while !seen.iter().any(|e| matches!(e, AgentEvent::Up(_))) {
        seen.push(rx.recv_timeout(common::WAIT).unwrap());
    }
    assert!(
        seen.iter()
            .any(|e| matches!(e, AgentEvent::SessionChanged(s) if s.session_id == "c9")),
        "session_changed reaches the brain"
    );
    assert!(seen.iter().any(
        |e| matches!(e, AgentEvent::Up(list) if list.len() == 1 && list[0].session_id == "old")
    ));

    let chat = common::open_chat(&dir.path().join("chat"));
    let start = TurnStart {
        key: "turn:optchat:0".into(),
        prompt_id: "optchat:0".into(),
        session: SessionSpec {
            name: "optchat-0".into(),
            cwd: dir.path().join("session"),
            harness: "claude-sr".into(),
            policy: "approve-all".into(),
            model: None,
        },
        blocks: turn_blocks("<chat>\n</chat>", &["what is x?".into()]),
    };
    let outcome = turn::run(&*acpmux, &chat, &start, &|_| {});
    assert_eq!(outcome.reply.as_deref(), Some("x is 1."));
    assert_eq!(outcome.error, None);
    let log: Vec<(String, String)> = (0..chat.status().messages)
        .map(|i| {
            let (k, t) = chat.message(i).unwrap();
            (k.as_str().to_owned(), t)
        })
        .collect();
    assert_eq!(
        log,
        vec![
            ("talk".to_string(), "Reading.".to_string()),
            ("tool".to_string(), "Read {\"path\":\"x\"}".to_string()),
            ("echo".to_string(), "x holds 1".to_string()),
            ("talk".to_string(), "x is 1.".to_string()),
        ]
    );
    let requests = requests.lock().unwrap();
    let find = |m: &str| requests.iter().find(|r| r["method"] == m).cloned().unwrap();
    let new = find("session/new");
    assert_eq!(new["params"]["cwd"], json!(dir.path().join("session")));
    assert_eq!(
        new["params"]["_meta"]["acpmux"],
        json!({"name": "optchat-0", "harness": "claude-sr", "policy": "approve-all"})
    );
    let prompt = find("session/prompt");
    assert_eq!(prompt["params"]["sessionId"], "s-1");
    assert_eq!(prompt["params"]["_meta"]["acpmux"]["promptId"], "optchat:0");
    assert_eq!(prompt["params"]["prompt"][1]["text"], "what is x?");
    assert_eq!(
        find("_acpmux/kill")["params"],
        json!({"sessionId": "s-1", "purge": true})
    );
}
