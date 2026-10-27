#![cfg(unix)]
//! Attach streams hold no thread per view (p05-ipc-079): 50 byte views, 50
//! render views and 50 snapshot views attached as client-minted streams
//! (attach-streams-v1) on one connection of a real daemon socket add at most
//! 2 threads to the process, and every view still gets its live output. A
//! legacy view holds an output thread and a notification thread of its own.
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

    /// The first item of stream `stream` that `matches`, kept or read.
    fn item_of(&mut self, stream: u16, matches: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) =
            self.events.iter().position(|item| item["stream"] == stream && matches(item))
        {
            return self.events.remove(index);
        }
        loop {
            let item = self.read();
            if item["stream"] == stream && matches(&item) {
                return item;
            }
        }
    }
}

#[test]
fn fifty_stream_attaches_add_at_most_two_threads() {
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
    let before = settled_threads();

    let snapshot_version = ghostty_vt::snapshot_version();
    let mut ids = Vec::new();
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
        ids.extend(views.into_iter().map(|view| connection.send(view)));
    }
    for id in ids {
        let reply = connection.reply(id);
        assert_eq!(reply["ok"], true, "{reply}");
    }
    let after = settled_threads();
    assert!(
        after.saturating_sub(before) <= THREAD_BUDGET,
        "{} stream attaches added {} threads ({before} -> {after})",
        VIEWS * 3,
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
    drop(connection);
    mux.shutdown();
}
