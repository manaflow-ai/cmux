//! The daemon's memory while a client reads a long chat log from its start (huge-blue,
//! 2026-10-21). The supervised daemon grew from 61 MB to 1 GB in 24 minutes with no peer
//! connected: its heap held a 31 MB chat log three and four times over as JSON trees, the
//! reply to one `_acpmux/events` read of the whole log. `acpmux session tail --since`
//! asks for 100,000 records in one page and gives no byte limit. The real daemon binary
//! runs here over a long Claude log, through its socket.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};

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

/// A Claude chat's log of about `mb` MB in 8 MB segments, shaped like huge-blue's: most
/// records are raw `claude.stream_event` lines (tool input deltas), then the translated
/// `session/update` records and the turn's raw `claude.user` line. Returns the records.
fn write_log(dir: &Path, mb: u64) -> u64 {
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
    let chunk = "word ".repeat(40);
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
        for k in 0..60u64 {
            let uuid = format!("{turns:08x}-{k:04x}-4000-8000-{seq:012x}");
            lines.push(("in", "claude.stream_event", json!({
                "api_message_id": format!("msg_{turns:024}"),
                "event": {"delta": {"partial_json": "mes no ", "type": "input_json_delta"}, "index": 0, "type": "content_block_delta"},
                "parent_tool_use_id": null, "session_id": "01a15c2a-ee79-7910-9d76-ef0536b9880d",
                "type": "stream_event", "uuid": uuid,
            })));
            if k % 8 == 0 {
                lines.push(("in", "agent_message_chunk", json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": {"sessionUpdate": "agent_message_chunk", "messageId": format!("m{turns}"), "content": {"type": "text", "text": chunk}}}})));
            }
        }
        lines.push(("in", "claude.user", json!({"type": "user", "message": {"content": [{"type": "tool_result", "content": result}]}})));
        lines.push((
            "mux",
            "turn_result",
            json!({"status": "completed", "stopReason": "end_turn", "turnId": format!("t{turns}")}),
        ));
        for (dir, kind, msg) in lines {
            seq += 1;
            let at = 1_792_500_000_000u64 + seq;
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
    seq
}

/// The daemon's peak resident KB since the last reset: Linux `VmHWM` (reset through
/// `clear_refs`), so a reply's peak counts even when the allocator gives pages back.
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
        let out = std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
    }
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
        // Few glibc arenas, so the peak tracks what a read holds, not the host's core count
        // (musl ignores it).
        .env("MALLOC_ARENA_MAX", "2")
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

/// Reading a long log from its start the way `acpmux session tail --since` does (one
/// `_acpmux/events` read of up to 100,000 records, no byte limit), then on through
/// `hasMore`, returns every record once, in order, and never grows the daemon by more
/// than `ACPMUX_PAGE_RSS_BUDGET_MB` (default 64) for a log of `ACPMUX_PAGE_LOG_MB`
/// (default 40). Before the fix one reply held the whole log as JSON trees.
#[test]
fn a_long_log_read_from_its_start_is_paged_within_a_memory_budget() {
    let mb = env_or("ACPMUX_PAGE_LOG_MB", 40);
    let budget_mb = env_or("ACPMUX_PAGE_RSS_BUDGET_MB", 64);
    let dir = std::env::temp_dir().join(format!("amx-pagemem-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    private_dir(&home);
    let id = "01a15c1e-83f9-78c2-bb80-000000000001";
    let session = home.join("sessions").join(id);
    private_dir(&session);
    let records = write_log(&session, mb);
    let meta = json!({"schema": "acpmux.session.v1", "id": id, "name": "activity-indicators", "harness": "claude",
                      "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": records, "eventCount": records});
    std::fs::write(session.join("session.json"), meta.to_string()).unwrap();
    set_private(&session.join("session.json"));

    let (mut child, socket) = start(&dir, &home);
    let mut rpc = Rpc::connect(&socket);
    assert_eq!(rpc.call("_acpmux/sessions", json!({}))["sessions"].as_array().unwrap().len(), 1);
    let loaded_mb = peak_kb(child.id(), true) / 1024;
    let (mut cursor, mut seen, mut pages) = (0u64, 0u64, 0u64);
    loop {
        let page = rpc
            .call("_acpmux/events", json!({"sessionId": id, "afterSeq": cursor, "limit": 100_000}));
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
    let grew_mb = (peak_kb(child.id(), false) / 1024).saturating_sub(loaded_mb);
    println!(
        "acpmux-page-memory: {}",
        json!({"log_mb": mb, "records": records, "pages": pages, "loaded_mb": loaded_mb, "page_rss_growth_mb": grew_mb})
    );
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(seen, records, "the pages did not return every record");
    assert!(
        grew_mb <= budget_mb,
        "reading the log grew the daemon by {grew_mb} MB (budget {budget_mb} MB)"
    );
}
