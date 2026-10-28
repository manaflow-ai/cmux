#![cfg(unix)]
//! p05-ipc-156's acceptance: 50 stream attaches (client-minted streams,
//! attach-streams-v1, on one app connection) and 20 CLI connections to a real
//! daemon socket keep the daemon's threads within +-2. The IO reactor writes
//! every connection, so no connection holds a writer thread; each still
//! holds its `mux-conn` reader until p05-ipc-155 moves the reads onto the
//! reactor, so the test is ignored until then (today +22 on the Linux VM:
//! a reader for each of the 21 connections, and one more).
//!
//! This file holds one test, so its process count is not shared with other
//! tests.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use support::DaemonMuxOps;

const ATTACHES: usize = 50;
const CLI_CONNECTIONS: usize = 20;
/// The acceptance's bound, either way.
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

/// One client connection: requests out, the reply with their id back.
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
}

#[test]
#[ignore = "blocked on p05-ipc-155: each connection still holds its mux-conn reader thread"]
fn fifty_attaches_and_twenty_cli_connections_keep_threads_within_two() {
    let mux = Mux::new(
        "connection-threads",
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    );
    let socket = std::env::temp_dir()
        .join(format!("cmux-connection-threads-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).expect("serve");
    let surfaces: Vec<_> = (0..ATTACHES)
        .map(|_| mux.new_workspace(None, Some((80, 24))).expect("terminal").id)
        .collect();
    // The first connection starts the daemon's shared threads (the reactor,
    // the pool's workers); the count starts after it.
    let mut warm = Connection::open(&socket);
    warm.rpc(json!({"cmd": "ping"}));
    let before = settled_threads();

    let mut app = Connection::open(&socket);
    app.rpc(json!({"cmd": "set-client-info", "capabilities": ["attach-streams-v1"]}));
    for (index, surface) in surfaces.iter().enumerate() {
        app.rpc(json!({"cmd": "attach-surface", "surface": surface, "stream": index + 1}));
    }
    let mut connections = vec![app];
    for _ in 0..CLI_CONNECTIONS {
        let mut cli = Connection::open(&socket);
        cli.rpc(json!({"cmd": "ping"}));
        connections.push(cli);
    }
    let after = settled_threads();
    assert!(
        after.abs_diff(before) <= THREAD_BUDGET,
        "{ATTACHES} stream attaches and {CLI_CONNECTIONS} CLI connections moved the thread \
         count by {} ({before} -> {after})",
        after as isize - before as isize
    );
    drop(connections);
    drop(warm);
    mux.shutdown();
}
