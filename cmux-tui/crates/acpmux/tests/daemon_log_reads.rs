//! Reads of one long chat log (perf100, 2026-10-20). The Chief's logs reach 70 MB
//! (130,000 records, 75 % of them raw Claude stream events). `_acpmux/history` held the
//! whole log as records (+347 MB resident for a 70 MB log on rbx), and reading the log in
//! `_acpmux/events` pages of 10,000, as optchat-chief does, parsed every earlier record
//! again on each page. The real daemon binary, through its socket.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Instant;

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

/// A Chief-shaped log of about `mb` MB in 8 MB segments; returns (records, turns).
fn write_log(dir: &Path, mb: u64) -> (u64, u64) {
    let events = dir.join("events");
    private_dir(&events);
    let (mut seq, mut turns, mut written, mut segment, mut in_segment) =
        (0u64, 0u64, 0u64, 1u32, 0u64);
    let open = |n: u32| {
        let path = events.join(format!("{n:06}.ndjson"));
        let file = std::fs::File::create(&path).unwrap();
        set_private(&path);
        BufWriter::new(file)
    };
    let mut out = open(segment);
    let pad = "y".repeat(250);
    let chunk = "word ".repeat(40);
    let tool = "z".repeat(800);
    let result = "q".repeat(3500);
    while written < mb * 1_000_000 {
        turns += 1;
        let mut lines = vec![
            (
                "mux",
                "user_message",
                json!({"text": format!("prompt {turns}"), "promptId": format!("p{turns}")}),
            ),
            ("mux", "turn_started", json!({"turnId": format!("t{turns}")})),
        ];
        for k in 0..60 {
            lines.push(("in", "claude.stream_event", json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "word "}}, "pad": pad})));
            if k % 8 == 0 {
                lines.push(("in", "agent_message_chunk", json!({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}}}})));
            }
        }
        lines.push(("in", "tool_call", json!({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "tool_call", "toolCallId": format!("c{turns}"), "content": [{"type": "text", "text": tool}]}}})));
        lines.push(("in", "claude.user", json!({"type": "user", "message": {"content": [{"type": "tool_result", "content": result}]}})));
        lines.push((
            "mux",
            "turn_result",
            json!({"status": "completed", "stopReason": "end_turn", "turnId": format!("t{turns}")}),
        ));
        for (dir, kind, msg) in lines {
            seq += 1;
            // The daemon's field order (`EventRecord`): seq first, so a read can pass a
            // record on its header alone.
            let at = 1_791_000_000_000u64 + seq;
            let line =
                format!(r#"{{"seq":{seq},"at":{at},"dir":"{dir}","kind":"{kind}","msg":{msg}}}"#)
                    + "\n";
            if in_segment >= 8 * 1024 * 1024 {
                out.flush().unwrap();
                segment += 1;
                out = open(segment);
                in_segment = 0;
            }
            out.write_all(line.as_bytes()).unwrap();
            in_segment += line.len() as u64;
            written += line.len() as u64;
        }
    }
    out.flush().unwrap();
    (seq, turns)
}

/// The daemon's peak resident KB since the last reset: Linux `VmHWM` (reset through
/// `clear_refs`), so a request's peak counts even when the allocator gives pages back.
/// Elsewhere the resident size now.
fn peak_kb(pid: u32, reset: bool) -> u64 {
    #[cfg(target_os = "linux")]
    {
        if reset {
            std::fs::write(format!("/proc/{pid}/clear_refs"), "5").unwrap();
        }
        let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap();
        let line = status.lines().find(|l| l.starts_with("VmHWM:")).unwrap();
        line.split_whitespace().nth(1).unwrap().parse().unwrap()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = reset;
        rss_kb(pid)
    }
}

#[cfg_attr(target_os = "linux", allow(dead_code))]
fn rss_kb(pid: u32) -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
}

fn env_or(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn start(scratch: &Path, home: &Path) -> (Child, PathBuf) {
    let socket = scratch.join("s.sock");
    let mut child = daemon_env::acpmux(scratch)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", &socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines() {
        if serde_json::from_str::<Value>(&line.unwrap()).is_ok_and(|v| v["ready"] == true) {
            return (child, socket);
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("daemon exited without a readiness line");
}

/// History of a long log never holds the log, and the pages return every record once,
/// in order. Budget: `ACPMUX_HISTORY_RSS_BUDGET_MB` (default 48) of peak growth for a
/// log of `ACPMUX_LOG_READ_MB` (default 40). The pages' time is printed, not budgeted:
/// the prefix re-read was ~15 % of it (13 pages of a 70 MB log: 2.35 s before, 2.02 s
/// after, release on rbx); building each 10,000-record reply is the rest.
#[test]
fn a_long_log_is_summarized_and_paged_without_holding_or_rereading_it() {
    let mb = env_or("ACPMUX_LOG_READ_MB", 40);
    let rss_budget_mb = env_or("ACPMUX_HISTORY_RSS_BUDGET_MB", 48);
    let dir = std::env::temp_dir().join(format!("amx-logread-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    private_dir(&home);
    let id = "01a15903-0000-7000-8000-000000000001";
    let session = home.join("sessions").join(id);
    private_dir(&session);
    let (records, turns) = write_log(&session, mb);
    let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": "long", "harness": "claude", "cwd": "/tmp",
                      "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": records, "eventCount": records});
    std::fs::write(session.join("session.json"), meta.to_string()).unwrap();
    set_private(&session.join("session.json"));

    let (mut child, socket) = start(&dir, &home);
    let mut rpc = Rpc::connect(&socket);
    let before = peak_kb(child.id(), true);
    let history = rpc.call("_acpmux/history", json!({"sessionId": id, "limit": 1_000_000}));
    let grew_mb = peak_kb(child.id(), false).saturating_sub(before) / 1024;
    let listed = history["turns"].as_array().unwrap();
    assert_eq!(listed.len() as u64, turns, "history lost turns");
    assert_eq!(listed[0]["toolCalls"], 1);
    assert_eq!(listed[listed.len() - 1]["status"], "completed");

    let started = Instant::now();
    let (mut cursor, mut seen, mut pages) = (0u64, 0u64, 0u64);
    loop {
        let page = rpc
            .call("_acpmux/events", json!({"sessionId": id, "afterSeq": cursor, "limit": 10_000}));
        pages += 1;
        let events = page["events"].as_array().unwrap();
        for (i, e) in events.iter().enumerate() {
            assert_eq!(
                e["seq"].as_u64().unwrap(),
                cursor + 1 + i as u64,
                "a page skipped or repeated a record"
            );
        }
        seen += events.len() as u64;
        let Some(last) = events.last() else { break };
        cursor = last["seq"].as_u64().unwrap();
        if page["hasMore"] != true {
            break;
        }
    }
    let pages_ms = started.elapsed().as_millis();
    assert_eq!(seen, records, "the pages did not return every record");
    println!(
        "acpmux-log-reads: {}",
        json!({"log_mb": mb, "records": records, "history_rss_growth_mb": grew_mb, "pages": pages, "pages_ms": pages_ms})
    );
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        grew_mb <= rss_budget_mb,
        "history grew the daemon by {grew_mb} MB (budget {rss_budget_mb} MB)"
    );
}
