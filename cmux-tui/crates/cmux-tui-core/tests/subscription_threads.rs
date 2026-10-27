#![cfg(unix)]
//! Subscriptions hold no thread each (p05-ipc-146): 10 subscriptions on one
//! connection of a real daemon socket (4 `subscribe`, 3 `session.events`, 3
//! `conversation.events`) add at most 1 thread to the process, and every
//! stream still gets the next change. Each used to hold a thread of its own
//! (`mux-events-out`, `mux-resource-session-events`,
//! `mux-resource-conversation-events`) blocked on its source.
//!
//! This file holds one test, so its process count is not shared with other
//! tests.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use support::{DaemonMuxOps, settled_threads};

const SUBSCRIBES: usize = 4;
const SESSION_STREAMS: usize = 3;
const CONVERSATION_STREAMS: usize = 3;
const THREAD_BUDGET: usize = 1;

struct Connection {
    reader: BufReader<UnixStream>,
    next_id: u64,
    /// Lines read while waiting for something else.
    held: Vec<Value>,
}

impl Connection {
    fn open(socket: &PathBuf) -> Self {
        let stream = UnixStream::connect(socket).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Self { reader: BufReader::new(stream), next_id: 1, held: Vec::new() }
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        assert_ne!(self.reader.read_line(&mut line).expect("read"), 0, "daemon closed");
        serde_json::from_str(&line).expect("JSON line")
    }

    fn send(&mut self, request: &Value) {
        writeln!(self.reader.get_mut(), "{request}").expect("write");
    }

    /// The first line that `matches`, held or read.
    fn take(&mut self, matches: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.held.iter().position(&matches) {
            return self.held.remove(index);
        }
        loop {
            let line = self.read();
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
        let reply = self.take(|line| line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }

    /// Sends one `cmux.protocol/2` request and returns its response.
    fn v2(&mut self, operation: &str, mut params: Value, key: Option<&str>) -> Value {
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
        let reply = self.take(|line| line["type"] == "response" && line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }

    /// Opens a v2 event stream and takes its snapshot item.
    fn open_stream(&mut self, operation: &str, mut params: Value, stream_id: &str) -> Value {
        params["stream_id"] = json!(stream_id);
        self.v2(operation, params, None);
        self.take(|line| line["type"] == "stream_item" && line["stream_id"] == stream_id)
    }
}

fn stream_id(index: usize) -> String {
    format!("stream_{index:032x}")
}

#[test]
fn ten_subscriptions_add_at_most_one_thread() {
    let mux = Mux::new("subscription-threads", SurfaceOptions::default());
    let socket = std::env::temp_dir()
        .join(format!("cmux-subscription-threads-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    let mut connection = Connection::open(&socket);
    connection.rpc(json!({"cmd": "set-client-info", "capabilities": ["browser-runtime-v1"]}));
    let created = connection.rpc(json!({
        "cmd": "conversation-create",
        "idempotency_key": "threads",
        "actor": "user_local",
        "title": "threads",
        "participants": [{"id": "user_local", "kind": "human", "display_name": "Me"}],
    }));
    let conversation = created["data"]["conversation"]["id"].as_str().expect("id").to_owned();
    // The drains run on the Files lane. An unrelated Files-lane item (the
    // browser runtime status read) starts that lane's foreground worker, so
    // the baseline is taken before the first subscription.
    connection.rpc(json!({"cmd": "browser-runtime-status"}));
    let before = settled_threads();

    for _ in 0..SUBSCRIBES {
        connection.rpc(json!({"cmd": "subscribe"}));
    }
    let session = (0..SESSION_STREAMS).map(stream_id).collect::<Vec<_>>();
    for id in &session {
        let snapshot = connection.open_stream("session.events", json!({}), id);
        assert_eq!(snapshot["item"]["kind"], "snapshot", "{snapshot}");
    }
    let conversations = (SESSION_STREAMS..SESSION_STREAMS + CONVERSATION_STREAMS)
        .map(stream_id)
        .collect::<Vec<_>>();
    for id in &conversations {
        let params = json!({"conversation": conversation});
        let snapshot = connection.open_stream("conversation.events", params, id);
        assert_eq!(snapshot["item"]["type"], "snapshot", "{snapshot}");
    }
    let after = settled_threads();
    let subscriptions = SUBSCRIBES + session.len() + conversations.len();
    assert_eq!(subscriptions, 10);
    assert!(
        after.saturating_sub(before) <= THREAD_BUDGET,
        "{subscriptions} subscriptions added {} threads ({before} -> {after})",
        after.saturating_sub(before)
    );

    // Every stream still runs: one change reaches each of them.
    mux.new_workspace(Some("woken".into()), Some((80, 24))).expect("workspace");
    for _ in 0..SUBSCRIBES {
        connection.take(|line| line["event"] == "tree-changed");
    }
    for id in &session {
        let delta = connection.take(|line| {
            line["type"] == "stream_item"
                && line["stream_id"] == *id
                && line["item"]["kind"] == "delta"
        });
        assert_eq!(delta["sequence"], "1", "{delta}");
    }
    let params = json!({"conversation": conversation, "text": "woken"});
    connection.v2("conversation.send", params, Some("woken"));
    for id in &conversations {
        let message = connection.take(|line| {
            line["type"] == "stream_item"
                && line["stream_id"] == *id
                && line["item"]["type"] == "message"
        });
        assert_eq!(message["item"]["message"]["parts"][0]["text"], "woken", "{message}");
    }
    drop(connection);
    mux.shutdown();
}
