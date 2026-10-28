#![cfg(unix)]
//! Views hold no thread: 50 byte views, 50
//! render views and 50 snapshot views attached as client-minted streams
//! (attach-streams-v1) on one connection of a real daemon socket, and the
//! same views (10 of the render views) as legacy attaches (no stream id) on
//! a second connection, add
//! at most 2 threads to the process, and every view still gets its live
//! output. Each view is a stream of its connection's bounded outbound queue,
//! fed by a drain on the sequenced pool's input workers.
//!
//! This file holds one test, so its process count is not shared with other
//! tests.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use support::DaemonMuxOps;

const VIEWS: usize = 50;
/// Render views take streams `RENDER + 1..`, snapshot views `SNAPSHOT + 1..`.
const RENDER: usize = 100;
const SNAPSHOT: usize = 200;
/// Legacy render views: the daemon holds at most 64 render attachments
/// (`RENDER_ATTACHMENT_LIMIT`), and the stream views hold 50 of them.
const LEGACY_RENDER_VIEWS: usize = 10;
/// The sequenced pool's input workers.
const THREAD_BUDGET: usize = 2;

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

/// The thread count once it held still for 300 ms (threads that start or
/// exit after a step settle first).
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
    next_id: u64,
    /// Events read while waiting for a reply.
    events: Vec<Value>,
}

impl Connection {
    fn open(socket: &PathBuf) -> Self {
        let stream = UnixStream::connect(socket).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Self { reader: BufReader::new(stream), next_id: 1, events: Vec::new() }
    }

    fn send(&mut self, mut request: Value) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        writeln!(self.reader.get_mut(), "{request}").expect("write");
        id
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        assert_ne!(self.reader.read_line(&mut line).expect("read"), 0, "daemon closed");
        serde_json::from_str(&line).expect("JSON line")
    }

    fn reply(&mut self, id: u64) -> Value {
        loop {
            let message = self.read();
            if message["id"] == id {
                return message;
            }
            self.events.push(message);
        }
    }

    fn rpc(&mut self, request: Value) -> Value {
        let id = self.send(request);
        let reply = self.reply(id);
        assert_eq!(reply["ok"], true, "{reply}");
        reply
    }

    /// The first item that `matches`, kept or read.
    /// Items it passes over are kept: the streams interleave, so a later
    /// look for another stream's item finds it.
    fn item(&mut self, matches: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.events.iter().position(&matches) {
            return self.events.remove(index);
        }
        loop {
            let item = self.read();
            if matches(&item) {
                return item;
            }
            self.events.push(item);
        }
    }

    /// The first item of stream `stream` that `matches`, kept or read.
    fn item_of(&mut self, stream: u16, matches: impl Fn(&Value) -> bool) -> Value {
        self.item(|item| item["stream"] == stream && matches(item))
    }

    /// Sends every request, then checks every reply.
    fn rpc_all(&mut self, requests: Vec<Value>) {
        let sent: Vec<_> =
            requests.into_iter().map(|request| (self.send(request.clone()), request)).collect();
        for (id, request) in sent {
            let reply = self.reply(id);
            assert_eq!(reply["ok"], true, "{request} -> {reply}");
        }
    }
}

#[test]
fn fifty_stream_and_fifty_legacy_attaches_add_at_most_two_threads() {
    let mux = Mux::new(
        "attach-threads",
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    );
    let socket = std::env::temp_dir()
        .join(format!("cmux-attach-threads-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    let surfaces: Vec<_> =
        (0..VIEWS).map(|_| mux.new_workspace(None, Some((80, 24))).expect("terminal").id).collect();
    let mut connection = Connection::open(&socket);
    connection.rpc(json!({"cmd": "set-client-info", "capabilities": ["attach-streams-v1"]}));
    let mut legacy = Connection::open(&socket);
    legacy.rpc(json!({"cmd": "ping"}));
    let before = settled_threads();

    let snapshot_version = ghostty_vt::snapshot_version();
    let mut streams = Vec::new();
    let mut legacy_views = Vec::new();
    for (index, surface) in surfaces.iter().enumerate() {
        let stream = index + 1;
        let views = [
            json!({"cmd": "attach-surface", "surface": surface, "stream": stream}),
            json!({
                "cmd": "attach-surface", "surface": surface, "stream": RENDER + stream,
                "mode": "render",
            }),
            json!({
                "cmd": "attach-surface", "surface": surface, "stream": SNAPSHOT + stream,
                "snapshot": "ghostsnp", "snapshot_version": snapshot_version,
            }),
        ];
        for view in views {
            // The same view with no stream id is a legacy attach.
            let mut legacy_view = view.clone();
            legacy_view.as_object_mut().expect("request").remove("stream");
            if legacy_view["mode"] != "render" || index < LEGACY_RENDER_VIEWS {
                legacy_views.push(legacy_view);
            }
            streams.push(view);
        }
    }
    let (stream_count, legacy_count) = (streams.len(), legacy_views.len());
    connection.rpc_all(streams);
    legacy.rpc_all(legacy_views);
    let after = settled_threads();
    assert!(
        after.saturating_sub(before) <= THREAD_BUDGET,
        "{stream_count} stream and {legacy_count} legacy attaches added {} threads \
         ({before} -> {after})",
        after.saturating_sub(before)
    );

    // Every view still runs: the last one's terminal echoes on its stream.
    let last = VIEWS as u16;
    connection.item_of(last, |item| item["event"] == "vt-state");
    connection.rpc(json!({"cmd": "send", "surface": surfaces[VIEWS - 1], "text": "ping\n"}));
    let output = connection.item_of(last, |item| item["event"] == "output");
    assert_eq!(output["surface"], json!(surfaces[VIEWS - 1]), "{output}");
    // Its snapshot viewer gets the same output.
    let snapshot = SNAPSHOT as u16 + last;
    connection.item_of(snapshot, |item| item["event"] == "output");
    // The legacy views of that terminal get it too.
    let last_surface = json!(surfaces[VIEWS - 1]);
    legacy.item(|item| item["event"] == "output" && item["surface"] == last_surface);
    drop(legacy);
    drop(connection);
    mux.shutdown();
}
