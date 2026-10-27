#![cfg(unix)]
//! Resource streams hold no thread per stream (p01-process-204): 24
//! `terminal.attach` views, two `session.events` and two
//! `session.journal.subscribe` subscriptions and four `terminal.wait`s on one
//! connection of a real daemon socket add no more threads than the
//! sequenced pool's workers, and every stream still delivers. As threads
//! (`mux-resource-terminal-attach`, `-session-events`, `-session-journal`,
//! `-terminal-wait`) they added 32.
//!
//! This file holds one test, so its process count is not shared with other
//! tests.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use cmux_tui_core::{Actor, Mux, SurfaceOptions, server};
use serde_json::{Value, json};

const VIEWS: usize = 24;
const SUBSCRIPTIONS: usize = 4;
const WAITS: usize = 4;
/// The pool's workers the streams can start: input (2) and utility (2),
/// plus control workers a burst of requests can start.
const THREAD_BUDGET: usize = 6;

/// Threads of this process.
#[cfg(target_os = "linux")]
fn process_threads() -> usize {
    std::fs::read_dir("/proc/self/task").expect("/proc/self/task").count()
}

/// Threads of this process.
#[cfg(target_os = "macos")]
fn process_threads() -> usize {
    // SAFETY: proc_taskinfo is plain integers; all zeroes is a valid value.
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: `info` is a proc_taskinfo, the layout of PROC_PIDTASKINFO.
    let read = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDTASKINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    assert_eq!(read, size, "proc_pidinfo");
    info.pti_threadnum as usize
}

/// The thread count once it held still for 300 ms.
fn settled_threads() -> usize {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = process_threads();
    let mut since = Instant::now();
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
        let now = process_threads();
        if now != last {
            (last, since) = (now, Instant::now());
        } else if since.elapsed() >= Duration::from_millis(300) {
            break;
        }
    }
    last
}

struct Connection {
    reader: BufReader<UnixStream>,
    /// Messages read while waiting for another.
    held: Vec<Value>,
}

impl Connection {
    fn open(socket: &std::path::Path) -> Self {
        let stream = UnixStream::connect(socket).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Self { reader: BufReader::new(stream), held: Vec::new() }
    }

    fn request(&mut self, id: &str, operation: &str, params: Value) {
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        // A mutation carries its idempotency key.
        if operation.ends_with(".write") {
            request["idempotency_key"] = json!(format!("resource-threads-{id}"));
        }
        writeln!(self.reader.get_mut(), "{request}").expect("write");
    }

    /// The first message that `matches`, held or read.
    fn take(&mut self, matches: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.held.iter().position(&matches) {
            return self.held.remove(index);
        }
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).expect("read"), 0, "daemon closed");
            let message: Value = serde_json::from_str(&line).expect("JSON line");
            if matches(&message) {
                return message;
            }
            self.held.push(message);
        }
    }

    fn response(&mut self, id: &str) -> Value {
        self.take(|message| message["type"] == "response" && message["id"] == id)
    }

    fn item(&mut self, stream: &str, kind: &str) -> Value {
        self.take(|message| {
            message["type"] == "stream_item"
                && message["stream_id"] == stream
                && message["item"]["kind"] == kind
        })
    }
}

fn stream_id(index: usize) -> String {
    format!("stream_{:032x}", index + 1)
}

fn session() -> Value {
    json!({"machine": "current", "session": "current"})
}

fn with(mut params: Value, extra: Value) -> Value {
    for (key, value) in extra.as_object().unwrap() {
        params[key] = value.clone();
    }
    params
}

#[test]
fn resource_streams_and_waits_add_no_thread_each() {
    let mux = Mux::new(
        "resource-stream-threads",
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    );
    let socket = std::env::temp_dir()
        .join(format!("cmux-resource-threads-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    let terminals: Vec<String> = (0..VIEWS)
        .map(|_| {
            let surface =
                mux.new_workspace_as(&Actor::Daemon, None, Some((80, 24))).expect("terminal");
            surface.terminal_public_id().expect("terminal id").to_string()
        })
        .collect();
    let mut connection = Connection::open(&socket);
    connection.request(
        "warm",
        "session.events",
        with(session(), json!({"stream_id": stream_id(999)})),
    );
    let warm = connection.response("warm");
    assert_eq!(warm["ok"], true, "{warm}");
    connection.item(&stream_id(999), "snapshot");
    let before = settled_threads();

    for (index, terminal) in terminals.iter().enumerate() {
        let params = with(session(), json!({"terminal": terminal, "stream_id": stream_id(index)}));
        connection.request(&format!("attach-{index}"), "terminal.attach", params);
    }
    for index in 0..SUBSCRIPTIONS {
        let stream = stream_id(VIEWS + index);
        let (operation, extra) = if index % 2 == 0 {
            ("session.events", json!({"stream_id": stream}))
        } else {
            (
                "session.journal.subscribe",
                json!({"stream_id": stream, "filter": {"kinds": ["workspace.*"]}}),
            )
        };
        connection.request(&format!("subscribe-{index}"), operation, with(session(), extra));
    }
    for (index, terminal) in terminals.iter().take(WAITS).enumerate() {
        let params = with(session(), json!({"terminal": terminal, "pattern": "never-printed"}));
        connection.request(&format!("wait-{index}"), "terminal.wait", params);
    }
    for index in 0..VIEWS {
        let response = connection.response(&format!("attach-{index}"));
        assert_eq!(response["ok"], true, "{response}");
        connection.item(&stream_id(index), "snapshot");
    }
    for index in 0..SUBSCRIPTIONS {
        let response = connection.response(&format!("subscribe-{index}"));
        assert_eq!(response["ok"], true, "{response}");
    }
    let after = settled_threads();
    eprintln!("resource streams: {before} -> {after} threads");
    assert!(
        after.saturating_sub(before) <= THREAD_BUDGET,
        "{VIEWS} views, {SUBSCRIPTIONS} subscriptions and {WAITS} waits added {} threads \
         ({before} -> {after})",
        after.saturating_sub(before)
    );

    // Every stream still runs: the last view's terminal echoes as a patch,
    // a new workspace reaches the session event streams, and a wait sees
    // its pattern.
    let last = VIEWS - 1;
    let input = with(session(), json!({"terminal": terminals[last], "text": "ping\r"}));
    connection.request("input", "terminal.input.write", input);
    let written = connection.response("input");
    assert_eq!(written["ok"], true, "{written}");
    connection.item(&stream_id(last), "patch");
    mux.new_workspace_as(&Actor::Daemon, Some("delta".into()), Some((80, 24))).expect("workspace");
    connection.item(&stream_id(VIEWS), "delta");
    let input = with(session(), json!({"terminal": terminals[0], "text": "never-printed\r"}));
    connection.request("match", "terminal.input.write", input);
    let matched = connection.response("wait-0");
    assert_eq!(matched["ok"], true, "{matched}");
    assert_eq!(matched["result"]["matched"], true, "{matched}");

    drop(connection);
    mux.shutdown();
    server::cleanup(&socket);
}
