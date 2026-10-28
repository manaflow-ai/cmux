#![cfg(unix)]
//! A connection holds no thread: idle CLI connections on a
//! real daemon socket, each of which pinged and subscribed, add at most 2
//! threads to the process. Before, each held a reader (`mux-conn`), a writer
//! (`mux-line-out`) and, once subscribed, an event writer
//! (`mux-events-out`): 3 threads a connection.
//!
//! The daemon admits 64 connections at once (`server.busy` past it), so the
//! test holds 60 of them.
//!
//! This file holds one test, so its process count is not shared with other
//! tests.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};

const CONNECTIONS: usize = 60;
/// The mux-io loop and one pool worker of slack.
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
    next_id: u64,
}

impl Connection {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Self { reader: BufReader::new(stream), next_id: 1 }
    }

    /// Sends `request` and returns its reply, events skipped.
    fn rpc(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        writeln!(self.reader.get_mut(), "{request}").expect("write");
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).expect("read"), 0, "daemon closed");
            let message: Value = serde_json::from_str(&line).expect("JSON line");
            if message["id"] == id {
                assert_eq!(message["ok"], true, "{message}");
                return message;
            }
        }
    }

    /// An idle CLI connection: identified, subscribed, waiting.
    fn settle_in(&mut self) {
        self.rpc(json!({"cmd": "ping"}));
        self.rpc(json!({"cmd": "subscribe"}));
    }
}

#[test]
fn sixty_idle_connections_add_at_most_two_threads() {
    let mux = Mux::new("connection-threads", SurfaceOptions::default());
    let socket = std::env::temp_dir()
        .join(format!("cmux-connection-threads-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    // The first connection starts the mux-io loop and the pool's first
    // workers; they are the baseline.
    let mut connections = vec![Connection::open(&socket)];
    connections[0].settle_in();
    let before = settled_threads();

    for _ in 1..CONNECTIONS {
        let mut connection = Connection::open(&socket);
        connection.settle_in();
        connections.push(connection);
    }
    let after = settled_threads();
    assert!(
        after <= before + THREAD_BUDGET,
        "{CONNECTIONS} idle connections took {} threads ({before} -> {after})",
        after.saturating_sub(before)
    );

    // Every connection is still served.
    for connection in &mut connections {
        connection.rpc(json!({"cmd": "ping"}));
    }
    drop(connections);
    mux.shutdown();
}
