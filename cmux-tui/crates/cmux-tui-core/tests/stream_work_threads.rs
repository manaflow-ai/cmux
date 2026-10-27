#![cfg(unix)]
//! Journal reads, agent attaches and terminal waits hold no thread each
//! (p05-ipc-147): 5 `session.journal.subscribe` streams, 5
//! `agent-session-attach` attachments and 5 `terminal.wait` requests on one
//! connection of a real daemon socket add at most 2 threads to the process,
//! and every one of them still answers. Each used to hold a thread of its
//! own: `mux-resource-session-journal` blocked on the journal epoch,
//! `mux-acpmux-link` blocked on its acpmux socket and
//! `mux-resource-terminal-wait` blocked on the terminal's output.
//!
//! This file holds one test, so its process count is not shared with other
//! tests.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use support::{DaemonMuxOps, settled_threads};

const JOURNAL_STREAMS: usize = 5;
const AGENT_ATTACHES: usize = 5;
const WAITS: usize = 5;
const THREAD_BUDGET: usize = 2;
const SESSION: &str = "acp_session_threads";

struct Connection {
    reader: BufReader<UnixStream>,
    next_id: u64,
    /// Lines read while waiting for something else.
    held: Vec<Value>,
}

impl Connection {
    fn open(socket: &Path) -> Self {
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

    fn v2(&mut self, id: &str, operation: &str, params: Value) -> Value {
        self.send(&json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        }));
        let reply = self.take(|line| line["type"] == "response" && line["id"] == id);
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }

    fn open_journal(&mut self, stream_id: &str) {
        self.v2(
            &format!("journal-{stream_id}"),
            "session.journal.subscribe",
            json!({"machine": "current", "session": "current", "stream_id": stream_id}),
        );
    }

    fn start_wait(&mut self, index: usize, terminal: &str) {
        // A wait with no timeout and a pattern that never shows answers only
        // when the connection ends: it is pending for the whole count.
        self.send(&json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": format!("wait-{index}"),
            "operation": "terminal.wait",
            "params": {"machine": "current", "session": "current", "terminal": terminal,
                       "pattern": "cmux-pattern-that-never-matches"},
        }));
    }

    fn attach_agent(&mut self, pane: cmux_tui_core::PaneId) {
        let tab = self.rpc(json!({
            "cmd": "new-conversation-tab", "pane": pane,
            "agent_session": {"host": "install:brain", "session": SESSION, "harness": "claude"},
        }));
        let surface = tab["data"]["surface"].as_u64().expect("conversation tab surface");
        self.rpc(json!({"cmd": "agent-session-attach", "surface": surface, "limit": 10}));
    }
}

/// A fake acpmux on one thread started before the count: it answers each
/// link's attach and watch calls in turn, then keeps the link open.
fn fake_acpmux(socket: PathBuf) {
    let listener = UnixListener::bind(&socket).expect("bind fake acpmux");
    let spawned = std::thread::Builder::new().name("fake-acpmux".into()).spawn(move || {
        let mut held = Vec::new();
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let mut writer = stream.try_clone().expect("clone");
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
                let frame: Value = serde_json::from_str(&line).expect("frame");
                line.clear();
                let result = match frame["method"].as_str() {
                    Some("_acpmux/attach") => json!({
                        "session": {"sessionId": SESSION, "name": "threads", "status": "idle",
                                    "pending": []},
                        "events": [], "hasMore": false, "lastSeq": 0,
                    }),
                    Some("_acpmux/watch") => json!({"sessions": []}),
                    _ => continue,
                };
                let reply = json!({"jsonrpc": "2.0", "id": frame["id"], "result": result});
                writeln!(writer, "{reply}").expect("reply");
                if frame["method"] == "_acpmux/watch" {
                    break;
                }
            }
            held.push(reader);
        }
    });
    spawned.expect("fake acpmux thread");
}

fn stream_id(index: usize) -> String {
    format!("stream_{index:032x}")
}

#[test]
fn journal_reads_agent_attaches_and_waits_add_at_most_two_threads() {
    let directory = std::env::temp_dir().join(format!("cmux-stream-work-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("directory");
    let acpmux = directory.join("a.sock");
    fake_acpmux(acpmux.clone());
    let mux = Mux::new("stream-work-threads", SurfaceOptions::default());
    mux.set_acpmux_socket(Some(acpmux));
    let socket = directory.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    let mut connection = Connection::open(&socket);
    connection.rpc(json!({"cmd": "set-client-info", "capabilities": []}));
    let surface = mux.new_workspace(Some("waited".into()), Some((80, 24))).expect("workspace");
    let terminal = surface.terminal_public_id().expect("terminal id").as_str().to_owned();
    let pane = mux.with_state(|state| state.pane_of(surface.id)).expect("pane");

    // One of each first: whatever a first one starts once (a worker of
    // its lane, the shared reader) is not a per-request thread.
    connection.open_journal(&stream_id(0));
    connection.attach_agent(pane);
    connection.start_wait(0, &terminal);
    let before = settled_threads();

    for index in 1..JOURNAL_STREAMS {
        connection.open_journal(&stream_id(index));
    }
    for _ in 1..AGENT_ATTACHES {
        connection.attach_agent(pane);
    }
    for index in 1..WAITS {
        connection.start_wait(index, &terminal);
    }
    let after = settled_threads();
    assert!(
        after.saturating_sub(before) <= THREAD_BUDGET,
        "{} more journal reads, agent attaches and waits added {} threads ({before} -> {after})",
        JOURNAL_STREAMS + AGENT_ATTACHES + WAITS - 3,
        after.saturating_sub(before)
    );

    // Every journal stream still runs: one commit reaches each of them.
    mux.new_workspace(Some("woken".into()), Some((80, 24))).expect("workspace");
    for index in 0..JOURNAL_STREAMS {
        let id = stream_id(index);
        connection.take(|line| line["type"] == "stream_item" && line["stream_id"] == id);
    }
    drop(connection);
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&directory);
}
