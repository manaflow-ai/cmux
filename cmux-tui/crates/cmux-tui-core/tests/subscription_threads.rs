#![cfg(unix)]
//! Subscriptions hold no thread each (p05-ipc-146): 5 `subscribe` streams
//! and 5 `session.events` streams on one connection of a real daemon socket
//! add at most 1 thread to the process, and every stream still gets the
//! next change. Each used to hold a thread of its own (`mux-events-out`,
//! `mux-resource-session-events`) blocked on its source.
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

const SUBSCRIBES: usize = 5;
const SESSION_STREAMS: usize = 5;
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

    fn open_session_events(&mut self, stream_id: &str) {
        let id = format!("events-{stream_id}");
        self.send(&json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": "session.events",
            "params": {"machine": "current", "session": "current", "stream_id": stream_id},
        }));
        let reply = self.take(|line| line["type"] == "response" && line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
        let snapshot =
            self.take(|line| line["type"] == "stream_item" && line["stream_id"] == stream_id);
        assert_eq!(snapshot["item"]["kind"], "snapshot", "{snapshot}");
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
    connection.rpc(json!({"cmd": "set-client-info", "capabilities": []}));
    // One of each first: whatever a first stream starts once (a pool
    // worker of its priority) is not a per-subscription thread.
    connection.rpc(json!({"cmd": "subscribe"}));
    connection.open_session_events(&stream_id(0));
    let before = settled_threads();

    for _ in 1..SUBSCRIBES {
        connection.rpc(json!({"cmd": "subscribe"}));
    }
    for index in 1..SESSION_STREAMS {
        connection.open_session_events(&stream_id(index));
    }
    let after = settled_threads();
    assert!(
        after.saturating_sub(before) <= THREAD_BUDGET,
        "{} more subscriptions added {} threads ({before} -> {after})",
        SUBSCRIBES + SESSION_STREAMS - 2,
        after.saturating_sub(before)
    );

    // Every stream still runs: one change reaches each of them.
    mux.new_workspace(Some("woken".into()), Some((80, 24))).expect("workspace");
    for _ in 0..SUBSCRIBES {
        connection.take(|line| line["event"] == "tree-changed");
    }
    for index in 0..SESSION_STREAMS {
        let id = stream_id(index);
        let delta = connection.take(|line| {
            line["type"] == "stream_item"
                && line["stream_id"] == id
                && line["item"]["kind"] == "delta"
        });
        assert_eq!(delta["sequence"], "1", "{delta}");
    }
    drop(connection);
    mux.shutdown();
}
