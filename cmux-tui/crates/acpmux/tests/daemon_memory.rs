//! The daemon's memory over a Chief home (perf100, 2026-10-20). On Lawrence's Mac the
//! Chief's acpmux held 8,285 sessions: 7,885 were purged compactor and turn sessions
//! whose record a late save had written back (closed, no log), and every record kept
//! its harness's config options as a JSON tree. The daemon reached 2.0 GB RSS in 40
//! minutes and 2.9 GB 31 s after a restart. The real daemon binary runs here over
//! such a home, through its socket.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().keep(BENCH_VARS);
/// The benchmarks' bounds and sizes: numbers, no credential. The hermetic re-start
/// keeps only these, so `env_or` refuses any other name.
const BENCH_VARS: &[&str] = &[
    "ACPMUX_MEMORY_BENCH_LEFTOVERS",
    "ACPMUX_MEMORY_BENCH_CHATS",
    "ACPMUX_MEMORY_BUDGET_MB",
    "ACPMUX_WAIT_BENCH_SECS",
    "ACPMUX_PEER_SNAPSHOT_PEAK_MB",
    "ACPMUX_PEER_SNAPSHOT_CPU_MS",
];

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
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
        s.set_read_timeout(Some(std::time::Duration::from_secs(60))).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.call_timed(method, params).0
    }

    /// Reply wait includes server work/pacing and transport; decoding is measured separately.
    fn call_timed(&mut self, method: &str, params: Value) -> (Value, u128, u128) {
        let started = std::time::Instant::now();
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "daemon closed the socket");
            let received = std::time::Instant::now();
            let v: Value = serde_json::from_str(&text).unwrap();
            if v.get("id") == Some(&json!(self.next)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                let result = v["result"].clone();
                return (
                    result,
                    received.duration_since(started).as_micros(),
                    received.elapsed().as_micros(),
                );
            }
        }
    }
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    listen: Option<String>,
    reaped: bool,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path) -> Self {
        Self::start_inner(scratch, home, None, false)
    }

    /// Only the Linux allocation benchmark logs its daemon.
    #[cfg(target_os = "linux")]
    fn start_logged(scratch: &Path, home: &Path, log: Option<&Path>) -> Self {
        Self::start_inner(scratch, home, log, false)
    }

    fn start_with_peer_listener(scratch: &Path, home: &Path) -> Self {
        Self::start_inner(scratch, home, None, true)
    }

    fn start_inner(scratch: &Path, home: &Path, log: Option<&Path>, peer_listener: bool) -> Self {
        let socket = scratch.join("s.sock");
        let level = if log.is_some() { "warn,acpmux::list_cost=debug" } else { "warn" };
        let mut child = daemon_env::acpmux(scratch)
            .args(["daemon", "run", "--ready-fd", "1", "--log", level])
            .args(
                peer_listener
                    .then_some("--listen")
                    .into_iter()
                    .chain(peer_listener.then_some("127.0.0.1:0")),
            )
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(log.map_or_else(Stdio::null, |p| std::fs::File::create(p).unwrap().into()))
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        for line in BufReader::new(stdout).lines() {
            let line = line.unwrap();
            if let Ok(v) = serde_json::from_str::<Value>(&line)
                && v["ready"] == true
            {
                let listen = v["listen"].as_str().map(str::to_owned);
                return Self { child, socket, listen, reaped: false };
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        panic!("daemon exited without a readiness line");
    }

    /// Resident bytes of the daemon process (not its children).
    fn rss_bytes(&self) -> u64 {
        let out = std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &self.child.id().to_string()])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().parse::<u64>().unwrap() * 1024
    }

    /// Peak resident bytes over the daemon's whole life, from `wait4`'s rusage. This
    /// kills the daemon (SIGKILL, so no shutdown work moves the peak) and reaps it.
    /// `ru_maxrss` is KiB on Linux and bytes on macOS.
    fn stop_peak_rss_bytes(&mut self) -> u64 {
        let pid = self.child.id() as i32;
        let mut status = 0;
        // SAFETY: rusage is plain integers, for which all zeroes is a valid value.
        let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        // SAFETY: both pointers are to live locals that wait4 fills in.
        let reaped = unsafe { libc::wait4(pid, &mut status, 0, &mut usage) };
        assert_eq!(reaped, pid, "wait4 on the daemon");
        self.reaped = true;
        let unit = if cfg!(target_os = "macos") { 1 } else { 1024 };
        usage.ru_maxrss as u64 * unit
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.reaped {
            return;
        }
        // SAFETY: the pid is this test's own child.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }
}

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn private_dir(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn private_file(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// A session record shaped like the Chief home's: Claude Code's config options (5
/// selects of 21 choices), modes, tools, a preview and the last turn.
fn chief_meta(id: &str, status: &str, at: u64) -> Value {
    let options: Vec<Value> = (0..5)
        .map(|o| {
            json!({"category": if o == 0 { "model" } else { "other" }, "currentValue": "claude-opus-5-5",
                   "id": format!("opt{o}"), "name": format!("Option {o}"), "type": "select",
                   "options": (0..21).map(|c| json!({"name": format!("Choice {c} of option {o}"), "value": format!("v{o}-{c}")})).collect::<Vec<_>>()})
        })
        .collect();
    json!({
        "schema": "acpmux.session.v1", "id": id, "name": format!("optchat-compact-{id}"), "harness": "claude",
        "harnessArgv": ["claude"], "cwd": "/tmp", "agentSessionId": format!("agent-{id}"), "status": status,
        "createdAt": at, "updatedAt": at + 5000, "lastSeq": 12, "eventCount": 12, "turnCount": 1,
        "agentInfo": {"name": "claude-stdio", "title": "Claude Code", "version": null},
        "agentCapabilities": {"loadSession": true, "promptCapabilities": {"embeddedContext": true, "image": true}},
        "modes": {"availableModes": [{"id": "default", "name": "Default"}, {"id": "plan", "name": "Plan"}], "currentModeId": "default"},
        "configOptions": options,
        "title": "Compact the node", "lastPrompt": "x".repeat(200), "preview": "y".repeat(600),
        "usage": {"sessionUpdate": "usage_update", "size": 200000, "used": 41234},
        "tags": {"cmux.chief": {"value": "2e448bc2"}, "cmux.chief.role": {"value": "compactor"}},
        "lastTurn": {"endedAt": at + 5000, "status": "completed", "stopReason": "end_turn", "turnId": format!("t-{id}")},
        "tools": {"rows": (0..4).map(|i| json!({"id": format!("mcp__cmux__tool_{i}"), "name": format!("tool_{i}"), "kind": "mcp", "source": "server", "enabled": true, "canToggle": true})).collect::<Vec<_>>(), "mutable": true},
    })
}

fn write_session(home: &Path, id: &str, status: &str, with_log: bool) {
    let dir = home.join("sessions").join(id);
    private_dir(&dir);
    private_file(&dir.join("session.json"), &chief_meta(id, status, 1_791_000_000_000).to_string());
    if with_log {
        private_dir(&dir.join("events"));
        let line = json!({"seq": 1, "at": 1_791_000_000_000u64, "dir": "mux", "kind": "created", "msg": {"harness": "claude"}});
        private_file(&dir.join("events").join("000001.ndjson"), &format!("{line}\n"));
    }
}

/// An object-heavy transcript fixture used by the peer snapshot benchmark. It keeps
/// the shape fixed across all saturation sizes so RSS/HWM and CPU deltas compare
/// the snapshot accounting rather than a changing payload.
fn peer_event(id: &str, seq: u64) -> Value {
    let objects: Vec<Value> = (0..32)
        .map(|i| json!({
            "key": format!("peer-{seq}-{i}"),
            "value": {"text": "object-heavy-peer-snapshot-payload", "flags": {"a": true, "b": false, "n": i},
                       "nested": {"session": id, "seq": seq, "labels": ["peer", "retained", "cache"]}}
        }))
        .collect();
    json!({
        "seq": seq, "at": 1_791_000_000_000u64 + seq, "dir": "in",
        "kind": "agent_message_chunk",
        "msg": {"method": "session/update", "params": {"sessionId": id,
                "update": {"sessionUpdate": "agent_message_chunk", "content": objects,
                "metadata": {"attempt": seq, "labels": ["peer", "retained", "cache"]}}}}
    })
}

/// Writes a retained peer session with a deterministic transcript. Closed sessions
/// with a log are retained by the daemon; closed sessions without one model purged
/// late-save leftovers and are intentionally excluded from this fixture.
fn write_peer_session(home: &Path, id: &str, status: &str, records: u64) {
    let dir = home.join("sessions").join(id);
    private_dir(&dir);
    let mut metadata = chief_meta(id, status, 1_791_000_000_000);
    metadata["lastSeq"] = json!(records);
    metadata["eventCount"] = json!(records);
    metadata["turnCount"] = json!(records);
    private_file(&dir.join("session.json"), &metadata.to_string());
    private_dir(&dir.join("events"));
    let mut text = String::new();
    for seq in 1..=records {
        text.push_str(&peer_event(id, seq).to_string());
        text.push('\n');
    }
    private_file(&dir.join("events").join("000001.ndjson"), &text);
}

fn websocket_token(home: &Path) -> String {
    let config = std::fs::read_to_string(home.join("config.json")).unwrap();
    serde_json::from_str::<Value>(&config).unwrap()["websocket"]["token"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn listed(rpc: &mut Rpc) -> Vec<String> {
    let mut ids: Vec<String> = rpc.call("_acpmux/sessions", json!({}))["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["sessionId"].as_str().unwrap().to_owned())
        .collect();
    ids.sort();
    ids
}

/// A closed session with no log is a purged one that a late save wrote back: the daemon
/// does not load it. A closed chat with its log, and an open one without a log, stay;
/// the next start finds the same list.
#[test]
fn a_start_skips_purged_sessions_a_late_save_wrote_back_and_keeps_every_chat() {
    let dir = scratch("purged");
    let home = dir.join("home");
    private_dir(&home);
    private_dir(&home.join("sessions"));
    write_session(&home, "01a15900-0000-7000-8000-000000000001", "closed", false);
    write_session(&home, "01a15900-0000-7000-8000-000000000002", "closed", true);
    write_session(&home, "01a15900-0000-7000-8000-000000000003", "idle", false);
    let kept = vec![
        "01a15900-0000-7000-8000-000000000002".to_owned(),
        "01a15900-0000-7000-8000-000000000003".to_owned(),
    ];
    {
        let daemon = Daemon::start(&dir, &home);
        let mut rpc = Rpc::connect(&daemon.socket);
        assert_eq!(listed(&mut rpc), kept);
    }
    let daemon = Daemon::start(&dir, &home);
    let mut rpc = Rpc::connect(&daemon.socket);
    assert_eq!(listed(&mut rpc), kept);
    let _ = std::fs::remove_dir_all(&dir);
}

fn env_or(name: &str, default: u64) -> u64 {
    assert!(
        BENCH_VARS.contains(&name),
        "{name} is not in BENCH_VARS, so the hermetic re-start drops it"
    );
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Budget guard: a daemon over a Chief home of 7,500 purged leftovers and 400 chats
/// stays under `ACPMUX_MEMORY_BUDGET_MB` (default 166) resident after it lists them.
/// Before the fix the same home took 1,068 MB (rbx, 2026-10-20, 78aaa620aa5e). The list
/// guard keeps the list it just sent, serialized, for its window (`hub/list_guard.rs`):
/// about 1 MB of text, which reads as 160-164 MB here where the daemon held 158-160 MB
/// without it (five runs each, one job).
#[test]
fn a_chief_home_of_purged_leftovers_and_chats_stays_within_the_memory_budget() {
    let leftovers = env_or("ACPMUX_MEMORY_BENCH_LEFTOVERS", 7_500);
    let chats = env_or("ACPMUX_MEMORY_BENCH_CHATS", 400);
    let budget_mb = env_or("ACPMUX_MEMORY_BUDGET_MB", 166);
    let dir = scratch("membudget");
    let home = dir.join("home");
    private_dir(&home);
    private_dir(&home.join("sessions"));
    for i in 0..leftovers {
        write_session(&home, &format!("01a15901-0000-7000-8000-{i:012}"), "closed", false);
    }
    for i in 0..chats {
        write_session(&home, &format!("01a15902-0000-7000-8000-{i:012}"), "idle", true);
    }
    let daemon = Daemon::start(&dir, &home);
    let mut rpc = Rpc::connect(&daemon.socket);
    assert_eq!(listed(&mut rpc).len() as u64, chats);
    let rss_mb = daemon.rss_bytes() / (1024 * 1024);
    println!(
        "acpmux-memory: {}",
        json!({"leftovers": leftovers, "chats": chats, "rss_mb": rss_mb, "budget_mb": budget_mb})
    );
    assert!(rss_mb <= budget_mb, "the daemon holds {rss_mb} MB (budget {budget_mb} MB)");
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
}

/// CPU time the process `pid` has used, in ms: `/proc/<pid>/stat` on Linux, `ps` elsewhere.
fn cpu_ms(pid: u32) -> u64 {
    if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        let fields: Vec<&str> = stat.rsplit(')').next().unwrap().split_whitespace().collect();
        let ticks: u64 = fields[11].parse::<u64>().unwrap() + fields[12].parse::<u64>().unwrap();
        // SAFETY: sysconf reads the clock tick rate and takes no pointers.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        assert!(hz > 0);
        return ticks * 1000 / hz as u64;
    }
    // macOS: `[[dd-]hh:]mm:ss.cc`.
    let out = std::process::Command::new("ps")
        .args(["-o", "time=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    let (days, clock) = text.trim().split_once('-').unwrap_or(("0", text.trim()));
    let secs = clock.split(':').fold(0.0, |acc, part| acc * 60.0 + part.parse::<f64>().unwrap());
    ((days.parse::<f64>().unwrap() * 86_400.0 + secs) * 1000.0) as u64
}

/// Whether `w` has had no reply yet: its request (a wait) is still open.
fn still_open(w: &mut Rpc) -> bool {
    w.writer.set_nonblocking(true).unwrap();
    let open = matches!(w.reader.fill_buf(), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock);
    w.writer.set_nonblocking(false).unwrap();
    open
}

/// What the daemon spends while records land on one chat for `secs`, with one client in
/// `acpmux wait` on each of `waiting_on`: (records, CPU ms, RSS growth MB, the waits).
/// Each wait is open before the first record and after the last; `release` ends them.
fn under_waiters(
    daemon: &Daemon,
    chat: &str,
    waiting_on: &[String],
    secs: u64,
) -> (u64, u64, i64, Vec<(String, Rpc)>) {
    let mut waits = Vec::new();
    for id in waiting_on {
        let mut w = Rpc::connect(&daemon.socket);
        w.next += 1;
        // Its own deadline is only a watchdog: `release` closes the chat it waits on.
        let line = json!({"jsonrpc": "2.0", "id": w.next, "method": "_acpmux/wait",
                          "params": {"sessions": [id], "until": ["closed"], "timeoutMs": secs * 1000 + 120_000}});
        w.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        waits.push((id.clone(), w));
    }
    let mut rpc = Rpc::connect(&daemon.socket);
    // Every wait has subscribed to the daemon's records before the first one lands.
    let open = std::time::Instant::now();
    while rpc.call("_acpmux/status", json!({}))["openWaits"] != waits.len() {
        assert!(open.elapsed().as_secs() < 30, "the waits did not all open in 30 s");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    rpc.call("_acpmux/tag", json!({"sessionId": chat, "set": {"warm": "1"}}));
    for (id, w) in &mut waits {
        assert!(still_open(w), "the wait on {id} answered before the records began");
    }
    let rss0 = daemon.rss_bytes() as i64;
    let cpu0 = cpu_ms(daemon.child.id());
    let start = std::time::Instant::now();
    let mut records = 0u64;
    while start.elapsed().as_secs() < secs {
        rpc.call("_acpmux/tag", json!({"sessionId": chat, "set": {"step": format!("{records}")}}));
        records += 1;
    }
    let cpu = cpu_ms(daemon.child.id()) - cpu0;
    let grew = (daemon.rss_bytes() as i64 - rss0) / (1024 * 1024);
    for (id, w) in &mut waits {
        assert!(still_open(w), "the wait on {id} answered before the records ended");
    }
    assert_eq!(rpc.call("_acpmux/status", json!({}))["openWaits"], waits.len());
    (records, cpu, grew, waits)
}

/// Close each waited chat: its wait, open through every other chat's records, answers
/// that it closed.
fn release(daemon: &Daemon, waits: Vec<(String, Rpc)>) {
    let mut rpc = Rpc::connect(&daemon.socket);
    for (id, _) in &waits {
        rpc.call("_acpmux/kill", json!({"sessionId": id}));
    }
    for (id, mut w) in waits {
        let mut text = String::new();
        w.reader.read_line(&mut text).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["result"]["timedOut"], false, "the wait on {id} missed its chat closing: {v}");
        assert_eq!(v["result"]["resolved"][0]["status"], "closed", "{v}");
    }
    assert_eq!(
        rpc.call("_acpmux/status", json!({}))["openWaits"],
        0,
        "an answered wait still counts"
    );
}

/// huge-blue, 2026-10-22: 13 `acpmux wait` clients on a daemon with 460 chats and 40
/// running turns. Each wait summarized every chat on every record any chat logged, so
/// the waits used 6 to 8 cores between them and the daemon grew about 65 MB a minute
/// to 4.5 GB in 66 minutes, when acpmux-rss-guard restarted it. A wait now reads only
/// the chats it waits on: the records cost about what they cost with no wait open.
#[test]
fn waits_on_some_chats_cost_nothing_extra_while_other_chats_log_records() {
    // At least the 13 chats waited on plus the one that logs, and a second of records.
    let chats = env_or("ACPMUX_MEMORY_BENCH_CHATS", 400).max(14);
    let secs = env_or("ACPMUX_WAIT_BENCH_SECS", 8).max(1);
    let dir = scratch("waits");
    let home = dir.join("home");
    private_dir(&home);
    private_dir(&home.join("sessions"));
    let id = |i: u64| format!("01a15903-0000-7000-8000-{i:012}");
    for i in 0..chats {
        write_session(&home, &id(i), "idle", true);
    }
    let daemon = Daemon::start(&dir, &home);
    let mut rpc = Rpc::connect(&daemon.socket);
    assert_eq!(listed(&mut rpc).len() as u64, chats);
    let (n0, cpu0, grew0, _) = under_waiters(&daemon, &id(0), &[], secs);
    let waiting_on: Vec<String> = (1..=13).map(id).collect();
    let (n1, cpu1, grew1, waits) = under_waiters(&daemon, &id(0), &waiting_on, secs);
    assert!(n0 > 0 && n1 > 0, "no records landed ({n0} alone, {n1} with waits)");
    // CPU per record, so a slower machine or a busier daemon compares like with like.
    let per0 = cpu0 as f64 / n0.max(1) as f64;
    let per1 = cpu1 as f64 / n1.max(1) as f64;
    println!(
        "acpmux-wait-cost: {}",
        json!({"chats": chats, "secs": secs, "alone": {"records": n0, "cpu_ms": cpu0, "rss_grew_mb": grew0},
               "waits13": {"records": n1, "cpu_ms": cpu1, "rss_grew_mb": grew1}})
    );
    assert!(
        per1 <= per0 * 3.0 + 1.0,
        "13 waits made each record cost {per1:.1} ms of daemon CPU (alone {per0:.1} ms)"
    );
    assert!(
        grew1 <= grew0 + 16,
        "the daemon grew {grew1} MB with 13 waits open (alone {grew0} MB)"
    );
    release(&daemon, waits);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Two keys for one chat, its name and its id, are two rows of the same chat: neither
/// reads as a missing, closed one, so `--all` resolves and `closed` does not.
#[test]
fn a_wait_on_one_chat_by_name_and_by_id_reads_it_twice() {
    let dir = scratch("waitdup");
    let home = dir.join("home");
    private_dir(&home);
    private_dir(&home.join("sessions"));
    let id = "01a15904-0000-7000-8000-000000000001";
    write_session(&home, id, "idle", true);
    let daemon = Daemon::start(&dir, &home);
    let mut rpc = Rpc::connect(&daemon.socket);
    let name = format!("optchat-compact-{id}");
    let ready = rpc.call(
        "_acpmux/wait",
        json!({"sessions": [name, id], "until": ["ready"], "all": true, "timeoutMs": 5_000}),
    );
    assert_eq!(ready["timedOut"], false, "{ready}");
    assert_eq!(ready["resolved"].as_array().unwrap().len(), 2, "{ready}");
    let closed = rpc.call(
        "_acpmux/wait",
        json!({"sessions": [name, id], "until": ["closed"], "timeoutMs": 1_500}),
    );
    assert_eq!(closed["timedOut"], true, "{closed}");
    assert!(
        closed["sessions"].as_array().unwrap().iter().all(|s| s["missing"].is_null()),
        "{closed}"
    );
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Opt-in allocation experiment; the ordinary 400-chat/166 MiB guard stays unchanged.
/// Run this exact workload on base and fix with --ignored --nocapture --test-threads=1.
#[cfg(target_os = "linux")]
#[test]
#[ignore = "same-host allocation benchmark; run explicitly on hosted Linux"]
fn retained_session_list_allocation_benchmark() {
    fn memory(pid: u32) -> (u64, u64) {
        let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap();
        let kb = |key: &str| {
            status
                .lines()
                .find(|l| l.starts_with(key))
                .unwrap()
                .split_whitespace()
                .nth(1)
                .unwrap()
                .parse::<u64>()
                .unwrap()
        };
        (kb("VmRSS:"), kb("VmHWM:"))
    }
    for chats in [0u64, 288, 1000] {
        let dir = scratch(&format!("list-alloc-{chats}"));
        let home = dir.join("home");
        private_dir(&home);
        private_dir(&home.join("sessions"));
        let id = |i: u64| format!("01a15905-0000-7000-8000-{i:012}");
        for i in 0..chats {
            let status = if i % 3 == 0 { "idle" } else { "closed" };
            write_session(&home, &id(i), status, true);
            let mut meta = chief_meta(&id(i), status, 1_791_000_000_000);
            // Many small fields exercise JSON-tree amplification, not one giant string.
            meta["tools"]["rows"] = json!((0..24).map(|t| json!({
                "id": format!("mcp__fixture__tool_{t}"), "name": format!("fixture_tool_{t}"),
                "kind": "mcp", "source": "fixture", "enabled": true, "canToggle": true
            })).collect::<Vec<_>>());
            meta["lastPrompt"] = json!("retained prompt ".repeat(64));
            private_file(
                &home.join("sessions").join(id(i)).join("session.json"),
                &meta.to_string(),
            );
        }
        let log = dir.join("list-cost.log");
        let daemon = Daemon::start_logged(&dir, &home, Some(&log));
        let pid = daemon.child.id();
        let mut rpc = Rpc::connect(&daemon.socket);
        let (ready_rss_kb, startup_peak_kb) = memory(pid);
        let ready_cpu_ms = cpu_ms(pid);
        // Ready precedes deferred log loading. Wait for every fixture log through the
        // supported info request before measuring lists; no full list is built here.
        for i in 0..chats {
            assert_eq!(rpc.call("_acpmux/info", json!({"sessionId": id(i)}))["logsLoading"], false);
        }
        let (before_rss_kb, prepared_peak_kb) = memory(pid);
        let prepared_cpu_ms = cpu_ms(pid);
        std::fs::write(format!("/proc/{pid}/clear_refs"), "5").unwrap();
        let cpu0 = cpu_ms(pid);
        let started = std::time::Instant::now();
        let mut samples = Vec::new();
        for request in 0..3 {
            let tag_started = std::time::Instant::now();
            if request > 0 && chats > 0 {
                // Invalidate the shared snapshot, without omitting any inventory fields.
                rpc.call(
                    "_acpmux/tag",
                    json!({"sessionId": id(0), "set": {"bench": request.to_string()}}),
                );
            }
            let tag_us = tag_started.elapsed().as_micros();
            let (list, reply_us, decode_us) = rpc.call_timed("_acpmux/sessions", json!({}));
            let validate_started = std::time::Instant::now();
            let rows = list["sessions"].as_array().unwrap();
            assert_eq!(rows.len() as u64, chats);
            let mut seen = std::collections::BTreeSet::new();
            let mut closed = 0u64;
            for row in rows {
                let sid = row["sessionId"].as_str().unwrap();
                assert!(seen.insert(sid.to_owned()), "duplicate {sid}");
                let i: u64 = sid.rsplit('-').next().unwrap().parse().unwrap();
                assert!(i < chats && sid == id(i), "unexpected session {sid}");
                let expected = if i.is_multiple_of(3) { "idle" } else { "closed" };
                assert_eq!(row["status"], expected, "status of {sid}");
                closed += u64::from(expected == "closed");
                assert_eq!(row["tools"].as_array().unwrap().len(), 24, "tools of {sid}");
                assert_eq!(row["tools"][23]["id"], "mcp__fixture__tool_23");
                assert_eq!(row["lastPrompt"], "retained prompt ".repeat(64));
            }
            assert_eq!(closed, chats - chats.div_ceil(3));
            let result_json_bytes = list.to_string().len();
            let validate_us = validate_started.elapsed().as_micros();
            let (rss_kb, peak_kb) = memory(pid);
            samples.push(json!({"request": request, "rss_kb": rss_kb, "peak_kb": peak_kb,
                "cpu_ms": cpu_ms(pid).saturating_sub(cpu0), "result_json_bytes": result_json_bytes,
                "tag_us": tag_us, "reply_us": reply_us, "decode_us": decode_us, "validate_us": validate_us}));
        }
        let list_cpu_ms = cpu_ms(pid).saturating_sub(cpu0);
        let list_wall_ms = started.elapsed().as_millis();
        let (after_rss_kb, list_peak_kb) = memory(pid);
        // ListGuard's maximum snapshot lifetime is 15 s. One bounded observation
        // after expiry distinguishes live snapshots from allocator-retained pages.
        std::thread::sleep(std::time::Duration::from_secs(16));
        let (settled_rss_kb, _) = memory(pid);
        println!(
            "acpmux-list-allocation: {}",
            json!({
                "chats": chats, "closed": chats - chats.div_ceil(3), "tools_per_chat": 24,
                "ready_rss_kb": ready_rss_kb, "startup_peak_kb": startup_peak_kb,
                "ready_cpu_ms": ready_cpu_ms, "prepared_peak_kb": prepared_peak_kb,
                "preparation_cpu_ms": prepared_cpu_ms.saturating_sub(ready_cpu_ms),
                "before_rss_kb": before_rss_kb, "after_rss_kb": after_rss_kb,
                "list_peak_kb": list_peak_kb, "settled_rss_kb": settled_rss_kb,
                "list_cpu_ms": list_cpu_ms, "list_wall_ms": list_wall_ms, "samples": samples
            })
        );
        drop(rpc);
        drop(daemon);
        for line in std::fs::read_to_string(&log).unwrap().lines() {
            if line.contains("list_snapshot_build") || line.contains("list_reply_reservation") {
                println!("acpmux-list-cost chats={chats}: {line}");
            }
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

/// A fixed remote peer cache workload plus N retained sessions. The six runs
/// exercise both idle and closed rows at the cache sizes used by the Chief
/// home, while ten retained closed peer chats keep N=0 meaningful.
fn peer_memory_case(closed: bool, fillers: u64) -> (u64, u64) {
    let dir = scratch(if closed { "peer-closed" } else { "peer-idle" });
    let remote = dir.join("remote");
    let local = dir.join("local");
    private_dir(&remote);
    private_dir(&remote.join("sessions"));
    private_dir(&local);
    private_dir(&local.join("sessions"));

    // Ten retained closed chats are the fixed peer workload. Their rows and
    // 400 object-heavy transcript records are identical in every case and
    // saturate the peer snapshot memory budget even when N is zero.
    const FIXED_PEERS: u64 = 10;
    for i in 0..FIXED_PEERS {
        write_peer_session(&remote, &format!("01a15910-0000-7000-8000-{i:012}"), "closed", 400);
    }
    // N fillers are retained sessions on the measured daemon, matching the
    // Chief home states while the remote peer workload remains constant.
    let status = if closed { "closed" } else { "idle" };
    for i in 0..fillers {
        write_peer_session(&local, &format!("01a15911-0000-7000-8000-{i:012}"), status, 1);
    }

    private_dir(&dir.join("remote-run"));
    private_dir(&dir.join("local-run"));
    let remote_daemon = Daemon::start_with_peer_listener(&dir.join("remote-run"), &remote);
    let listen = remote_daemon.listen.clone().expect("peer listener address");
    let peer_token = std::fs::read_to_string(remote.join("run").join("peer.token")).unwrap();
    let token = websocket_token(&remote);
    let mut local_daemon = Daemon::start(&dir.join("local-run"), &local);
    let mut rpc = Rpc::connect(&local_daemon.socket);
    rpc.call(
        "_acpmux/peer_add",
        json!({"name": "bench", "url": format!("ws://{listen}"), "token": token,
               "peerToken": peer_token, "wait": true}),
    );

    // `wait: true` above settles the initial listing; the rows include the
    // local fillers and every fixed remote session before capture starts.
    let rows = rpc.call("_acpmux/sessions", json!({}));
    assert!(
        rows["sessions"].as_array().is_some_and(|v| v.len() >= (FIXED_PEERS + fillers) as usize),
        "peer list did not settle: {rows}"
    );
    let cpu0 = cpu_ms(local_daemon.child.id());
    // Repeat each exact page to exercise replacement and removed-record accounting.
    for _pass in 0..2 {
        for i in 0..FIXED_PEERS {
            let id = format!("01a15910-0000-7000-8000-{i:012}");
            rpc.call(
                "_acpmux/attach",
                json!({"sessionId": format!("bench/{id}"), "visible": false,
                       "kinds": ["transcript"], "limit": 400, "maxBytes": 4 * 1024 * 1024}),
            );
            let snapshot = rpc.call(
                "_acpmux/peer_snapshot",
                json!({"sessionId": format!("bench/{id}"), "limit": 400,
                       "maxBytes": 4 * 1024 * 1024}),
            );
            let events = snapshot.get("events").and_then(Value::as_array).expect("snapshot events");
            assert!(
                !events.is_empty() && snapshot["lastSeq"] == 400,
                "snapshot lost records: {snapshot}"
            );
        }
    }
    let cpu_ms = cpu_ms(local_daemon.child.id()) - cpu0;
    let rss_kib = local_daemon.rss_bytes() / 1024;
    let peak_kib = local_daemon.stop_peak_rss_bytes() / 1024;
    println!(
        "acpmux-peer-snapshot-memory: {}",
        serde_json::to_string(&json!({
            "closed": closed, "fillers": fillers, "rss_kib": rss_kib,
            "peak_rss_kib": peak_kib, "cpu_ms": cpu_ms, "fixed_retained": FIXED_PEERS,
            "records_per_fixed": 400, "payload": "object-heavy-nested"
        }))
        .unwrap()
    );
    drop(local_daemon);
    drop(remote_daemon);
    let _ = std::fs::remove_dir_all(&dir);
    (peak_kib, cpu_ms)
}

/// Bounds for the peer snapshot benchmark below: the worst case of three paired
/// base/head rounds in the dev profile on a 32-vCPU Linux runner (1,124 MiB peak,
/// 9,540 ms CPU; run 41012834259), plus about 25% headroom.
const PEAK_MB: u64 = 1_400;
const CPU_MS: u64 = 12_000;

/// Hermetic exact-daemon saturation cost of peer snapshots. The fixed retained
/// workload exercises removed-record accounting and the N fillers drive the cache
/// through 0, 288 and 1000 sessions in both statuses. Each case's lifetime peak RSS
/// and snapshot CPU must stay within `ACPMUX_PEER_SNAPSHOT_PEAK_MB` and
/// `ACPMUX_PEER_SNAPSHOT_CPU_MS`; the defaults are the worst case measured on the
/// fleet's Linux runner plus headroom. Opt-in like the list benchmark:
/// run with --ignored --test-threads=1 on base and head on one host.
#[test]
#[ignore = "same-host peer snapshot benchmark; run explicitly with --ignored"]
fn peer_snapshot_cache_saturation_stays_within_its_recorded_cost() {
    let peak_mb = env_or("ACPMUX_PEER_SNAPSHOT_PEAK_MB", PEAK_MB);
    let cpu_budget_ms = env_or("ACPMUX_PEER_SNAPSHOT_CPU_MS", CPU_MS);
    let mut over = Vec::new();
    for &closed in &[false, true] {
        for &fillers in &[0, 288, 1000] {
            let (peak_kib, cpu_ms) = peer_memory_case(closed, fillers);
            if peak_kib > peak_mb * 1024 || cpu_ms > cpu_budget_ms {
                over.push(json!({"closed": closed, "fillers": fillers,
                                 "peak_rss_kib": peak_kib, "cpu_ms": cpu_ms}));
            }
        }
    }
    assert!(
        over.is_empty(),
        "peer snapshots cost more than {peak_mb} MB peak or {cpu_budget_ms} ms CPU: {over:?}"
    );
}
