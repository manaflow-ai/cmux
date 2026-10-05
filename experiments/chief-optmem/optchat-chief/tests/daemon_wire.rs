//! The real daemon link (cmux-sdk) against a fake conversation owner on a
//! Unix socket: find the app's Chief conversation (create it with the app's
//! exact request only when none exists), bind as agent_mux, subscribe, write
//! as agent_mux, and reconnect after the subscription ends.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_conversation::{Change, Op};
use optchat_chief::daemon::{DaemonEvent, LinkConfig, spawn_link};
use serde_json::{Value, json};

fn summary() -> Value {
    summary_at("conv_x", "2026-10-03T00:00:00.000Z")
}

fn summary_at(id: &str, created: &str) -> Value {
    json!({
        "id": id, "owner": "local", "title": "mux", "last_seq": 0, "rev": 1,
        "created_at": created, "updated_at": "2026-10-03T00:00:00.000Z",
        "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Ada"},
            {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux", "acp_session": "mux"}
        ],
        "read_cursors": {}
    })
}

/// The fake owner; `subscribers` keeps each subscription's stream so the test can push events.
fn serve(
    listener: UnixListener,
    requests: Arc<Mutex<Vec<Value>>>,
    subscribers: Arc<Mutex<Vec<UnixStream>>>,
    listed: Arc<Mutex<Vec<Value>>>,
) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let (requests, subscribers, listed) =
                (requests.clone(), subscribers.clone(), listed.clone());
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn.try_clone().unwrap()).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    let data = match req["cmd"].as_str().unwrap() {
                        "identify" => {
                            json!({"app": "cmux", "version": "test", "protocol": 12, "capabilities": ["local-conversations-v1"]})
                        }
                        "conversation-list" => {
                            json!({"conversations": listed.lock().unwrap().clone()})
                        }
                        "conversation-create" => {
                            json!({"conversation": summary(), "replayed": true})
                        }
                        "conversation-op" => {
                            json!({"rev": 2, "replayed": false, "change": {"kind": "read-cursor", "participant": "agent_mux", "seq": 1}})
                        }
                        // The typed SDK reads conversation-bind's result.
                        "conversation-bind" => json!({"participant": req["participant"]}),
                        "subscribe" => {
                            subscribers.lock().unwrap().push(conn.try_clone().unwrap());
                            json!({})
                        }
                        _ => json!({}),
                    };
                    let _ = writeln!(
                        out,
                        "{}",
                        json!({"id": req["id"], "ok": true, "data": data})
                    );
                }
            });
        }
    });
}

#[test]
fn the_link_creates_binds_subscribes_and_reconnects() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let token = dir.path().join("agent-token");
    std::fs::write(&token, "tok-1\n").unwrap();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let subscribers = Arc::new(Mutex::new(Vec::new()));
    let listed = Arc::new(Mutex::new(Vec::new()));
    serve(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        subscribers.clone(),
        listed.clone(),
    );

    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    spawn_link(
        LinkConfig {
            socket,
            token_file: Some(token),
            display_name: "Ada".into(),
            title: "Chief".into(),
        },
        Arc::new(move |e| tx.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    let wait = Duration::from_secs(30);
    let Ok(DaemonEvent::Up {
        mut port,
        conversation,
        ..
    }) = rx.recv_timeout(wait)
    else {
        panic!("no Up")
    };
    assert_eq!(conversation.id, "conv_x");
    {
        let requests = requests.lock().unwrap();
        let create = requests
            .iter()
            .find(|r| r["cmd"] == "conversation-create")
            .unwrap();
        // The app's create request (HomeChiefName.createRequest): same key,
        // title and participants, so the owner replays one conversation.
        assert_eq!(create["idempotency_key"], "home-chief");
        assert_eq!(create["actor"], "user_local");
        assert_eq!(create["title"], "Chief");
        assert_eq!(create["participants"], summary()["participants"]);
        let bind = requests
            .iter()
            .find(|r| r["cmd"] == "conversation-bind")
            .unwrap();
        assert_eq!(
            (bind["participant"].as_str(), bind["token"].as_str()),
            (Some("agent_mux"), Some("tok-1"))
        );
        let order: Vec<&str> = requests
            .iter()
            .map(|r| r["cmd"].as_str().unwrap())
            .collect();
        assert_eq!(
            order,
            vec![
                "identify",
                "conversation-list",
                "conversation-create",
                "conversation-bind",
                "subscribe"
            ]
        );
    }
    let change = port
        .op(
            "conv_x",
            "cursor:agent_mux:1",
            &Op::ReadCursorSet { seq: 1 },
        )
        .unwrap();
    assert!(matches!(change, Some(Change::ReadCursor { seq: 1, .. })));
    port.typing("conv_x", true).unwrap();
    {
        let requests = requests.lock().unwrap();
        let op = requests
            .iter()
            .find(|r| r["cmd"] == "conversation-op")
            .unwrap();
        assert_eq!(op["actor"], "agent_mux");
        assert_eq!(op["op"], json!({"kind": "read_cursor.set", "seq": 1}));
        let typing = requests
            .iter()
            .find(|r| r["cmd"] == "conversation-typing")
            .unwrap();
        assert_eq!(
            (typing["actor"].as_str(), typing["on"].as_bool()),
            (Some("agent_mux"), Some(true))
        );
    }

    // An event on the subscription reaches the brain.
    let mut sub = subscribers.lock().unwrap()[0].try_clone().unwrap();
    let message = json!({"id": "msg_1", "conversation": "conv_x", "seq": 1, "client_msg_id": "c1", "author": "user_local",
        "parts": [{"type": "text", "text": "hi"}], "created_at": "2026-10-03T00:00:00.000Z", "reactions": []});
    writeln!(sub, "{}", json!({"event": "conversation-changed", "conversation": "conv_x", "rev": 3, "transaction": null, "change": {"kind": "message", "message": message}})).unwrap();
    match rx.recv_timeout(wait).unwrap() {
        DaemonEvent::Changed {
            conversation,
            change: Change::Message { message },
        } => {
            assert_eq!((conversation.as_str(), message.seq), ("conv_x", 1));
        }
        _ => panic!("expected the message"),
    }

    // The app's Chief conversation exists now, with a newer one beside it.
    *listed.lock().unwrap() = vec![
        summary_at("conv_newer", "2026-10-04T00:00:00.000Z"),
        summary(),
    ];
    // The subscription ends: Down, then the link connects (and binds) again.
    sub.shutdown(std::net::Shutdown::Both).unwrap();
    assert!(matches!(rx.recv_timeout(wait).unwrap(), DaemonEvent::Down));
    match rx.recv_timeout(wait).unwrap() {
        // The oldest conversation with agent_mux, whatever the list order.
        DaemonEvent::Up { conversation, .. } => assert_eq!(conversation.id, "conv_x"),
        _ => panic!("expected Up"),
    }
    let creates = requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["cmd"] == "conversation-create")
        .count();
    assert_eq!(creates, 1, "an existing Chief conversation is found, not created");
    let binds = requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["cmd"] == "conversation-bind")
        .count();
    assert_eq!(binds, 2);
}
