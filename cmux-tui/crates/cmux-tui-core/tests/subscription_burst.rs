#![cfg(unix)]
//! A burst reaches the end of every event stream (p05-ipc-146). A stream's
//! drain stops when its stream holds its backpressure cap (2 items) and the
//! connection's writer (`mux-line-out`, which takes items in batches) wakes
//! it when it takes them. Here more than 2 items per stream arrive at once
//! on a real daemon socket, and nothing happens after them, so the last
//! items arrive only if the writer's batches wake the drains.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use cmux_tui_core::{Mux, MuxEvent, SurfaceOptions, server};
use serde_json::{Value, json};
use support::DaemonMuxOps;

const BURST: usize = 20;
const WORKSPACES: usize = 4;

struct Connection {
    reader: BufReader<UnixStream>,
    next_id: u64,
    /// Lines read while waiting for something else.
    held: Vec<Value>,
}

impl Connection {
    fn open(socket: &PathBuf) -> Self {
        let stream = UnixStream::connect(socket).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        Self { reader: BufReader::new(stream), next_id: 1, held: Vec::new() }
    }

    fn read(&mut self, waiting_for: &str) -> Value {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line);
        assert!(
            matches!(read, Ok(1..)),
            "no line within 10 s while waiting for {waiting_for}: the stream stalled ({read:?})"
        );
        serde_json::from_str(&line).expect("JSON line")
    }

    fn send(&mut self, request: &Value) {
        writeln!(self.reader.get_mut(), "{request}").expect("write");
    }

    /// The first line that `matches`, held or read.
    fn take(&mut self, waiting_for: &str, matches: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.held.iter().position(&matches) {
            return self.held.remove(index);
        }
        loop {
            let line = self.read(waiting_for);
            if matches(&line) {
                return line;
            }
            self.held.push(line);
        }
    }

    fn rpc(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        self.send(&request);
        let reply = self.take("a reply", |line| line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }

    /// Sends one `cmux.protocol/2` request; its response is read later.
    fn send_v2(&mut self, operation: &str, mut params: Value, key: Option<&str>) -> String {
        let id = format!("v2-{}", self.next_id);
        self.next_id += 1;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        self.send(&request);
        id
    }

    fn v2(&mut self, operation: &str, params: Value, key: Option<&str>) -> Value {
        let id = self.send_v2(operation, params, key);
        let reply =
            self.take("a v2 response", |line| line["type"] == "response" && line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }

    /// Opens a v2 event stream and returns its snapshot item line.
    fn open_stream(&mut self, operation: &str, mut params: Value, stream_id: &str) -> Value {
        params["stream_id"] = json!(stream_id);
        self.v2(operation, params, None);
        self.take("a snapshot", |line| {
            line["type"] == "stream_item" && line["stream_id"] == stream_id
        })
    }
}

fn revision(line: &Value) -> u64 {
    line["cursor"]["revision"].as_str().and_then(|r| r.parse().ok()).unwrap_or_else(|| {
        panic!("no cursor revision in {line}");
    })
}

#[test]
fn a_burst_reaches_the_end_of_every_event_stream() {
    let mux = Mux::new("subscription-burst", SurfaceOptions::default());
    let socket = std::env::temp_dir()
        .join(format!("cmux-subscription-burst-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    let mut connection = Connection::open(&socket);
    connection.rpc(json!({"cmd": "set-client-info", "capabilities": []}));
    let created = connection.rpc(json!({
        "cmd": "conversation-create",
        "idempotency_key": "burst",
        "actor": "user_local",
        "title": "burst",
        "participants": [{"id": "user_local", "kind": "human", "display_name": "Me"}],
    }));
    let conversation = created["data"]["conversation"]["id"].as_str().expect("id").to_owned();

    connection.rpc(json!({"cmd": "subscribe"}));
    let session = "stream_00000000000000000000000000000001";
    let snapshot = connection.open_stream("session.events", json!({}), session);
    assert_eq!(snapshot["item"]["kind"], "snapshot", "{snapshot}");
    let chat = "stream_00000000000000000000000000000002";
    let snapshot =
        connection.open_stream("conversation.events", json!({"conversation": conversation}), chat);
    assert_eq!(snapshot["item"]["type"], "snapshot", "{snapshot}");
    let chat_start = revision(&snapshot);

    // `subscribe`: BURST status events at once, then nothing.
    for index in 0..BURST {
        mux.emit(MuxEvent::Status(format!("burst-{index}")));
    }
    for index in 0..BURST {
        let message = format!("burst-{index}");
        connection.take(&format!("subscribe {message}"), |line| {
            line["event"] == "status" && line["message"] == message.as_str()
        });
    }

    // `conversation.events`: BURST sends queued at once.
    let sends = (0..BURST)
        .map(|index| {
            let params = json!({"conversation": conversation, "text": format!("burst-{index}")});
            connection.send_v2("conversation.send", params, Some(&format!("burst-{index}")))
        })
        .collect::<Vec<_>>();
    for id in sends {
        let reply =
            connection.take("a send", |line| line["type"] == "response" && line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
    }
    let chat_head = chat_start + BURST as u64;
    connection.take(&format!("conversation.events revision {chat_head}"), |line| {
        line["type"] == "stream_item" && line["stream_id"] == chat && revision(line) == chat_head
    });

    // `session.events`: WORKSPACES workspaces at once; the stream reaches the
    // head revision a fresh stream opens at.
    for index in 0..WORKSPACES {
        mux.new_workspace(Some(format!("burst-{index}")), Some((80, 24))).expect("workspace");
    }
    let fresh = "stream_00000000000000000000000000000003";
    let head = revision(&connection.open_stream("session.events", json!({}), fresh));
    connection.take(&format!("session.events revision {head}"), |line| {
        line["type"] == "stream_item" && line["stream_id"] == session && revision(line) >= head
    });

    drop(connection);
    mux.shutdown();
}
