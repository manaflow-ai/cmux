#![cfg(unix)]
//! Resource streams hold no thread per stream (p01-process-204): 24
//! `terminal.attach` views, two `session.events` and two
//! `session.journal.subscribe` subscriptions and four `terminal.wait`s on one
//! connection of a real daemon socket add no daemon thread, and every
//! stream still delivers. As threads (`mux-resource-terminal-attach`,
//! `-session-events`, `-session-journal`, `-terminal-wait`) they added 32.
//!
//! One stream of each kind runs before the baseline, so the lazily started
//! threads (the pool's first worker of each priority) are in it. On Linux
//! the test then reads every thread's name: no thread outside the pool is
//! added, no `mux-resource-*` thread exists, and each priority the streams
//! use keeps at most its fixed workers, whatever the stream count. Where
//! names cannot be read (macOS), the total may grow only by the second
//! worker of the three priorities the streams use.
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
/// The pool workers the streams run on, with each priority's fixed count
/// (`PoolConfig::for_cores`): views on input, `session.events` and waits on
/// visible, journal replays on utility. A control worker serves the
/// requests that open them, a burst of which may start more of those.
const STREAM_WORKERS: [(&str, usize); 3] =
    [("mux-seq-input", 2), ("mux-seq-visible", 2), ("mux-seq-utility", 2)];
/// The names of the per-stream threads these streams used to hold (Linux
/// truncates a thread name to 15 bytes).
#[cfg(target_os = "linux")]
const PER_STREAM_THREADS: [&str; 3] = ["mux-resource-", "mux-snapshot-at", "mux-attach-noti"];

/// The names of this process's threads, sorted.
#[cfg(target_os = "linux")]
fn thread_names() -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir("/proc/self/task")
        .expect("/proc/self/task")
        .filter_map(|task| std::fs::read_to_string(task.ok()?.path().join("comm")).ok())
        .map(|name| name.trim_end().to_owned())
        .collect();
    names.sort();
    names
}

/// The names in `names` that are not sequenced-pool workers.
#[cfg(target_os = "linux")]
fn outside_pool(names: &[String]) -> Vec<String> {
    names.iter().filter(|name| !name.starts_with("mux-seq-")).cloned().collect()
}

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
    // One stream of each kind first: the threads they start lazily are in
    // the baseline. Its terminal is not one of the measured views.
    let warm_terminal = mux
        .new_workspace_as(&Actor::Daemon, None, Some((80, 24)))
        .expect("terminal")
        .terminal_public_id()
        .expect("terminal id")
        .to_string();
    let warm_streams = [
        ("warm-attach", "terminal.attach", json!({"terminal": warm_terminal})),
        ("warm-events", "session.events", json!({})),
        (
            "warm-journal",
            "session.journal.subscribe",
            json!({"filter": {"kinds": ["workspace.*"]}}),
        ),
    ];
    for (offset, (id, operation, extra)) in warm_streams.iter().enumerate() {
        let extra = with(extra.clone(), json!({"stream_id": stream_id(900 + offset)}));
        connection.request(id, operation, with(session(), extra));
        let response = connection.response(id);
        assert_eq!(response["ok"], true, "{response}");
    }
    connection.item(&stream_id(900), "snapshot");
    connection.item(&stream_id(901), "snapshot");
    let warm_wait = with(session(), json!({"terminal": warm_terminal, "pattern": "never-printed"}));
    connection.request("warm-wait", "terminal.wait", warm_wait);
    let before = settled_threads();
    #[cfg(target_os = "linux")]
    let names_before = thread_names();

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
    #[cfg(target_os = "linux")]
    {
        let names = thread_names();
        eprintln!(
            "pool workers: {:?}",
            names.iter().filter(|name| name.starts_with("mux-seq-")).collect::<Vec<_>>()
        );
        assert_eq!(
            outside_pool(&names),
            outside_pool(&names_before),
            "{VIEWS} views, {SUBSCRIPTIONS} subscriptions and {WAITS} waits added threads \
             outside the sequenced pool"
        );
        for prefix in PER_STREAM_THREADS {
            assert!(
                !names.iter().any(|name| name.starts_with(prefix)),
                "a per-stream {prefix}* thread runs: {names:?}"
            );
        }
        for (worker, fixed) in STREAM_WORKERS {
            let count = names.iter().filter(|name| *name == worker).count();
            assert!(count <= fixed, "{count} {worker} threads, over its {fixed} fixed workers");
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        // Each priority the streams use may start its second worker.
        let budget = STREAM_WORKERS.iter().map(|(_, fixed)| fixed - 1).sum::<usize>();
        assert!(
            after.saturating_sub(before) <= budget,
            "{VIEWS} views, {SUBSCRIPTIONS} subscriptions and {WAITS} waits added {} threads \
             ({before} -> {after})",
            after.saturating_sub(before)
        );
    }

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
