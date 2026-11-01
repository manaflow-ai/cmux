//! Opening a long chat and scrolling it to its first message, as the agent pane does
//! (webviews direct.ts `attach` and `loadOlder`), through the real daemon's socket
//! (perf100 chat-load, 2026-10-21). Before: the three reads of an open each read the
//! newest 8 MB segment whole and parsed every record of it, the command list read the
//! log back to its start, and each older page read and parsed its whole segment again
//! (418 MB read to scroll a 14 MB log to the top). Every page must still return every
//! transcript record once, in order.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};

const ATTACH_KINDS: &[&str] = &[
    "transcript",
    "available_commands_update",
    "usage_update",
    "config_option_update",
    "bookmarks",
    "secret_request",
    "secret_decision",
    "queue_order",
    "queue_updated",
    "prompt_refused",
];

struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to daemon socket");
        s.set_read_timeout(Some(std::time::Duration::from_secs(120))).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "daemon closed the socket");
            let v: Value = serde_json::from_str(&text).unwrap();
            if v.get("id") == Some(&json!(self.next)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

fn private_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn set_private(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// What the log holds: its records, its bytes, and the seqs of its transcript records.
struct Log {
    records: u64,
    bytes: u64,
    transcript: Vec<u64>,
}

/// Appends records in the daemon's field order (`EventRecord`: seq first) to 8 MB segments.
struct Writer {
    events: PathBuf,
    out: BufWriter<std::fs::File>,
    segment: u32,
    in_segment: u64,
    log: Log,
}

impl Writer {
    fn open(events: &Path, n: u32) -> BufWriter<std::fs::File> {
        let path = events.join(format!("{n:06}.ndjson"));
        let file = std::fs::File::create(&path).unwrap();
        set_private(&path);
        BufWriter::new(file)
    }

    fn write(&mut self, dir: &str, kind: &str, msg: Value, transcript: bool) {
        self.log.records += 1;
        let seq = self.log.records;
        let at = 1_791_000_000_000u64 + seq;
        let line =
            format!(r#"{{"seq":{seq},"at":{at},"dir":"{dir}","kind":"{kind}","msg":{msg}}}"#)
                + "\n";
        if self.in_segment >= 8 * 1024 * 1024 {
            self.out.flush().unwrap();
            self.segment += 1;
            self.out = Self::open(&self.events, self.segment);
            self.in_segment = 0;
        }
        self.out.write_all(line.as_bytes()).unwrap();
        self.in_segment += line.len() as u64;
        self.log.bytes += line.len() as u64;
        if transcript {
            self.log.transcript.push(seq);
        }
    }
}

fn update(update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"update": update}})
}

/// A Chief-shaped log of about `mb` MB in 8 MB segments: the agent lists its commands once,
/// first, then each turn is a prompt, raw Claude stream events (not transcript), reply chunks,
/// a tool call, a raw tool result, a usage update and the turn's end.
fn write_log(dir: &Path, mb: u64) -> Log {
    let events = dir.join("events");
    private_dir(&events);
    let out = Writer::open(&events, 1);
    let mut w = Writer {
        events,
        out,
        segment: 1,
        in_segment: 0,
        log: Log { records: 0, bytes: 0, transcript: Vec::new() },
    };
    w.write(
        "in",
        "available_commands_update",
        update(json!({"sessionUpdate": "available_commands_update", "availableCommands": [{"name": "compact", "description": "Compact"}]})),
        false,
    );
    let pad = "y".repeat(250);
    let chunk = "word ".repeat(40);
    let tool = "z".repeat(800);
    let result = "q".repeat(3500);
    let mut turn = 0u64;
    while w.log.bytes < mb * 1_000_000 {
        turn += 1;
        w.write(
            "mux",
            "user_message",
            json!({"text": format!("prompt {turn}"), "promptId": format!("p{turn}")}),
            true,
        );
        w.write("mux", "turn_started", json!({"turnId": format!("t{turn}")}), true);
        for k in 0..60 {
            w.write("in", "claude.stream_event", json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "word "}}, "pad": pad}), false);
            if k % 8 == 0 {
                w.write("in", "agent_message_chunk", update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}})), true);
            }
        }
        w.write("in", "tool_call", update(json!({"sessionUpdate": "tool_call", "toolCallId": format!("c{turn}"), "content": [{"type": "text", "text": tool}]})), true);
        w.write("in", "claude.user", json!({"type": "user", "message": {"content": [{"type": "tool_result", "content": result}]}}), false);
        w.write(
            "in",
            "usage_update",
            update(json!({"sessionUpdate": "usage_update", "used": turn})),
            false,
        );
        w.write(
            "mux",
            "turn_result",
            json!({"status": "completed", "turnId": format!("t{turn}")}),
            true,
        );
    }
    w.out.flush().unwrap();
    w.log
}

/// Bytes the daemon has read from files and sockets (Linux `rchar`); 0 elsewhere.
fn read_bytes(pid: u32) -> u64 {
    #[cfg(target_os = "linux")]
    {
        let io = std::fs::read_to_string(format!("/proc/{pid}/io")).unwrap();
        let line = io.lines().find(|l| l.starts_with("rchar:")).unwrap();
        line.split_whitespace().nth(1).unwrap().parse().unwrap()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        0
    }
}

fn env_or(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Starts the daemon and returns once it has read its chat logs (`Hub::load_logs`, which a
/// daemon runs after its ready line and which reads each open chat's log): the reads measured
/// after it are the requests' own.
fn start(scratch: &Path, home: &Path) -> (Child, PathBuf) {
    let socket = scratch.join("s.sock");
    let mut child = daemon_env::acpmux(scratch)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "info"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    // The ready line and the daemon's log both go to stdout.
    let (events, seen) = std::sync::mpsc::channel();
    let stdout = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
                let _ = events.send("ready");
            } else if line.contains("loaded the chat logs") {
                let _ = events.send("loaded");
            }
        }
    });
    let wait = std::time::Duration::from_secs(120);
    if seen.recv_timeout(wait) == Ok("ready") && seen.recv_timeout(wait) == Ok("loaded") {
        return (child, socket);
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("daemon did not start and read its logs");
}

/// Stops the daemon however the test ends, a failed assert included.
struct Stop(Child);

impl Drop for Stop {
    fn drop(&mut self) {
        // SAFETY: the pid is this test's own child.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

fn seqs(page: &Value) -> Vec<u64> {
    page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

/// Opening a long chat reads only its newest page and names its commands from the session;
/// scrolling to the first message reads the log about once and returns every transcript
/// record once, in order. Budgets (Linux, bytes the daemon reads): an open at most
/// `ACPMUX_CHAT_OPEN_READ_MB` (default 4), the whole scroll at most
/// `ACPMUX_CHAT_SCROLL_READ_X` (default 2) times the log, for a log of `ACPMUX_CHAT_LOG_MB`
/// (default 40).
#[test]
fn a_long_chat_opens_on_its_newest_page_and_scrolls_to_its_first_message() {
    let mb = env_or("ACPMUX_CHAT_LOG_MB", 40);
    let open_budget = env_or("ACPMUX_CHAT_OPEN_READ_MB", 4) * 1_000_000;
    let scroll_x = env_or("ACPMUX_CHAT_SCROLL_READ_X", 2);
    let dir = std::env::temp_dir().join(format!("amx-chatopen-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    private_dir(&home);
    let id = "01a15903-0000-7000-8000-0000000000c1";
    let session = home.join("sessions").join(id);
    private_dir(&session);
    let log = write_log(&session, mb);
    let commands = json!({"sessionUpdate": "available_commands_update", "availableCommands": [{"name": "compact", "description": "Compact"}]});
    let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": "long", "harness": "claude", "cwd": "/tmp",
                      "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": log.records,
                      "eventCount": log.records, "availableCommands": commands});
    std::fs::write(session.join("session.json"), meta.to_string()).unwrap();
    set_private(&session.join("session.json"));

    let (child, socket) = start(&dir, &home);
    let pid = child.id();
    let daemon = Stop(child);
    let mut rpc = Rpc::connect(&socket);
    rpc.call("session/list", json!({}));
    // The restart's one read of this chat's log (its queue, a cut turn: `hub/log_load.rs`)
    // runs after the session index loads (#27328), so it is no part of an open: `info`
    // waits for it.
    rpc.call("_acpmux/info", json!({"sessionId": id}));

    // The pane's open: the newest page, then the open turn's prompt when the page starts mid-turn.
    let before_open = read_bytes(pid);
    let page = rpc.call(
        "_acpmux/attach",
        json!({"sessionId": id, "limit": 400, "maxBytes": 128 * 1024, "kinds": ATTACH_KINDS, "eventStream": true, "visible": true}),
    );
    let attach_read = read_bytes(pid) - before_open;
    let first = seqs(&page)[0];
    let opener = rpc.call(
        "_acpmux/events",
        json!({"sessionId": id, "beforeSeq": first, "limit": 16, "kinds": ["user_message"]}),
    );
    let open_read = read_bytes(pid) - before_open;
    assert_eq!(
        page["session"]["availableCommands"], commands,
        "the session does not name its commands"
    );
    assert_eq!(page["hasMore"], true);
    let page_transcript: Vec<u64> =
        seqs(&page).into_iter().filter(|seq| log.transcript.binary_search(seq).is_ok()).collect();
    let tail = &log.transcript[log.transcript.len() - page_transcript.len()..];
    assert_eq!(
        page_transcript, tail,
        "the open page is not the newest transcript records in order"
    );
    let prompts = seqs(&opener);
    assert!(
        !prompts.is_empty() && prompts.iter().all(|seq| *seq < first),
        "no prompt before the page"
    );

    // An older acpmux client finds the command list in the log: the first record.
    let listed = rpc.call(
        "_acpmux/events",
        json!({"sessionId": id, "beforeSeq": log.records + 1, "limit": 1, "kinds": ["available_commands_update"]}),
    );
    assert_eq!(seqs(&listed), vec![1], "the log's command list was not found");

    // Scroll to the first message, as loadOlder pages it.
    let before_scroll = read_bytes(pid);
    let (mut held, mut before, mut pages) = (seqs(&page), first, 0u64);
    loop {
        let older = rpc.call(
            "_acpmux/events",
            json!({"sessionId": id, "beforeSeq": before, "limit": 400, "maxBytes": 256 * 1024, "kinds": ["transcript"]}),
        );
        pages += 1;
        let got = seqs(&older);
        assert!(
            got.windows(2).all(|w| w[0] < w[1]) && got.last().is_none_or(|last| *last < before),
            "a page is out of order"
        );
        held.splice(0..0, got.iter().copied());
        if older["hasMore"] != true || got.is_empty() {
            break;
        }
        before = got[0];
    }
    let scroll_read = read_bytes(pid) - before_scroll;
    let transcript: Vec<u64> =
        held.into_iter().filter(|seq| log.transcript.binary_search(seq).is_ok()).collect();
    assert_eq!(
        transcript, log.transcript,
        "the scroll lost, repeated or reordered a transcript record"
    );
    println!(
        "acpmux-chat-open: {}",
        json!({"log_mb": mb, "records": log.records, "open_read_mb": open_read as f64 / 1e6, "attach_read_mb": attach_read as f64 / 1e6,
               "scroll_pages": pages, "scroll_read_mb": scroll_read as f64 / 1e6, "log_bytes_mb": log.bytes as f64 / 1e6})
    );
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
    if cfg!(target_os = "linux") {
        assert!(
            open_read <= open_budget,
            "opening the chat read {open_read} bytes (budget {open_budget})"
        );
        assert!(
            scroll_read <= scroll_x * log.bytes,
            "the scroll to the first message read {scroll_read} bytes, over {scroll_x}x the {}-byte log",
            log.bytes
        );
    }
}
