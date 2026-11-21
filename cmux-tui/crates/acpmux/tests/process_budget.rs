//! A chat costs a small, fixed number of processes, and none outlives it. Leo, 2026-11-21: "if it
//! has tons of processes tbats a prkduct bug" and "there are thoudands of processes you
//! absolutley need to clean".
//!
//! A real daemon on its own home runs the stand-in agent (`fake_agent.py`). It opens [`CHATS`]
//! chats and prompts each once; each chat's processes (its agent host, from the host record the
//! daemon writes, and everything under it) are held to [`PER_CHAT`]. Then every chat is stopped
//! through the daemon's API (`_acpmux/kill`, what `acpmux session stop` sends), and within
//! [`CLEANUP`] every process the daemon started must be gone: its process tree, plus any that
//! left the tree but carry this test's scratch path in their environment (a reparented agent
//! host). That covers the daemon's own one-shots too (startup model probes, version reads), which
//! belong to no chat. A process still there names its argv and parent chain.
//!
//! The detector for the class "a process outlives its chat" (`#48374` holds the MCP servers per
//! chat; this one holds every process).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The daemon this test starts runs tests/fake_agent.py only.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

/// Chats opened, each prompted once.
const CHATS: usize = 4;
/// New processes one chat may add while it is open:
/// 1. its agent host (`acpmux __agent-host`), which holds the harness across daemon restarts;
/// 2. its harness, here `python3 fake_agent.py` (Claude Code or codex for a person).
///
/// Its MCP servers are not processes of their own: the daemon serves them (`mcp_gateway.rs`).
const PER_CHAT: usize = 2;
/// How long, after the chats stop, every process the daemon started may take to end: a stopped
/// chat's host and harness end at once, but a startup model probe (each ACP harness the daemon
/// found, here `fake`, and `chief` as `cmux-tui chief acp` where a `cmux-tui` binary sits beside
/// acpmux, as in a Cargo target folder) is killed only by its own 60 s bound
/// (`hub/model_probe.rs`) when the harness never answers.
const CLEANUP: Duration = Duration::from_secs(75);
/// How often the test looks while it waits.
const POLL: Duration = Duration::from_millis(50);

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// One process: parent, state and argv.
#[derive(Clone, Debug)]
struct Proc {
    ppid: u32,
    state: String,
    argv: String,
}

#[cfg(target_os = "linux")]
fn table() -> BTreeMap<u32, Proc> {
    let mut out = BTreeMap::new();
    for entry in fs::read_dir("/proc").unwrap().flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
            continue;
        };
        let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else { continue };
        let Some(at) = stat.rfind(')') else { continue };
        let mut fields = stat[at + 2..].split(' ');
        let state = fields.next().unwrap_or("?").to_owned();
        let Some(ppid) = fields.next().and_then(|p| p.parse().ok()) else { continue };
        let argv = fs::read(format!("/proc/{pid}/cmdline"))
            .map(|b| String::from_utf8_lossy(&b).trim_end_matches('\0').replace('\0', " "))
            .unwrap_or_default();
        out.insert(pid, Proc { ppid, state, argv });
    }
    out
}

#[cfg(not(target_os = "linux"))]
fn table() -> BTreeMap<u32, Proc> {
    let out = std::process::Command::new("ps")
        .args(["-A", "-ww", "-o", "pid=,ppid=,stat=,command="])
        .output()
        .expect("run ps");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse().ok()?;
            let ppid = fields.next()?.parse().ok()?;
            let state = fields.next()?.to_owned();
            Some((pid, Proc { ppid, state, argv: fields.collect::<Vec<_>>().join(" ") }))
        })
        .collect()
}

/// Whether `pid`'s environment holds `needle` (this user's processes only).
fn environment_has(pid: u32, needle: &str) -> bool {
    #[cfg(target_os = "linux")]
    {
        fs::read(format!("/proc/{pid}/environ"))
            .is_ok_and(|env| String::from_utf8_lossy(&env).contains(needle))
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::process::Command::new("ps")
            .args(["-E", "-ww", "-o", "command=", "-p", &pid.to_string()])
            .output()
            .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).contains(needle))
    }
}

/// Every process the daemon started and that still runs: its tree, and those outside it whose
/// environment names this test's scratch folder (a host whose parent ended). Not the daemon.
fn started(daemon: u32, scratch: &Path) -> BTreeMap<u32, Proc> {
    let rows = table();
    let mut ours = BTreeSet::from([daemon]);
    loop {
        let before = ours.len();
        for (pid, p) in &rows {
            if ours.contains(&p.ppid) {
                ours.insert(*pid);
            }
        }
        if ours.len() == before {
            break;
        }
    }
    let needle = scratch.to_string_lossy().into_owned();
    let me = std::process::id();
    for (pid, p) in &rows {
        if !ours.contains(pid)
            && *pid != me
            && p.ppid != me
            && (p.argv.contains("acpmux") || p.argv.contains("fake_agent"))
            && environment_has(*pid, &needle)
        {
            ours.insert(*pid);
        }
    }
    ours.remove(&daemon);
    rows.into_iter().filter(|(pid, _)| ours.contains(pid)).collect()
}

/// `pid`, its argv and state, then its parents up to the daemon (or up to pid 1 for a process
/// that left the daemon's tree).
fn chain(pid: u32, rows: &BTreeMap<u32, Proc>, daemon: u32) -> String {
    let mut lines = Vec::new();
    let mut at = pid;
    for depth in 0..16 {
        let pad = "  ".repeat(depth + 1);
        if at == daemon && depth > 0 {
            lines.push(format!("{pad}{at} the daemon"));
            break;
        }
        let Some(p) = rows.get(&at) else {
            lines.push(format!("{pad}{at} (gone)"));
            break;
        };
        lines.push(format!("{pad}{at} [{}] {:.160}", p.state, p.argv));
        if at <= 1 {
            break;
        }
        at = p.ppid;
    }
    lines.join("\n")
}

fn report(procs: &BTreeMap<u32, Proc>, daemon: u32) -> String {
    let rows = table();
    procs.keys().map(|pid| chain(*pid, &rows, daemon)).collect::<Vec<_>>().join("\n")
}

/// The agent host of `session`, from the record the daemon keeps for it (`hosts/<id>.json`).
fn host_pid(home: &Path, session: &str) -> u32 {
    let path = home.join("hosts").join(format!("{session}.json"));
    let record: Value = serde_json::from_slice(
        &fs::read(&path).unwrap_or_else(|e| panic!("host record {}: {e}", path.display())),
    )
    .unwrap();
    record["host_pid"].as_u64().unwrap_or_else(|| panic!("no host_pid in {record}")) as u32
}

/// `root` and every process under it.
fn subtree(root: u32, rows: &BTreeMap<u32, Proc>) -> BTreeMap<u32, Proc> {
    let mut ours = BTreeSet::from([root]);
    loop {
        let before = ours.len();
        for (pid, p) in rows {
            if ours.contains(&p.ppid) {
                ours.insert(*pid);
            }
        }
        if ours.len() == before {
            break;
        }
    }
    rows.iter().filter(|(pid, _)| ours.contains(pid)).map(|(k, v)| (*k, v.clone())).collect()
}

struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon socket");
        s.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "the daemon closed the socket");
            let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
            if v.get("id") == Some(&json!(self.next)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

/// The daemon and everything it started end with the test, passed or failed: the daemon's own
/// shutdown with its agents first, then a SIGKILL by pid for the daemon and for each process the
/// test saw it start that still runs the same argv.
struct Daemon {
    child: Child,
    scratch: PathBuf,
    home: PathBuf,
    socket: PathBuf,
    seen: BTreeMap<u32, String>,
}

impl Daemon {
    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn look(&mut self) -> BTreeMap<u32, Proc> {
        let procs = started(self.pid(), &self.scratch);
        for (pid, p) in &procs {
            self.seen.entry(*pid).or_insert_with(|| p.argv.clone());
        }
        procs
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = daemon_env::command(&self.scratch, daemon_env::Agents::Deny, &[])
            .args(["daemon", "shutdown", "--end-agents"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = self.child.kill();
        let _ = self.child.wait();
        let rows = table();
        for (pid, argv) in &self.seen {
            if rows.get(pid).is_some_and(|p| &p.argv == argv) {
                // SAFETY: kill only signals; the pid still runs the argv this test saw it start.
                unsafe { libc::kill(*pid as i32, libc::SIGKILL) };
            }
        }
    }
}

fn start(scratch: &Path) -> Daemon {
    let home = scratch.join("acpmux");
    fs::create_dir_all(&home).unwrap();
    let config = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    });
    fs::write(home.join("config.json"), config.to_string()).unwrap();
    let socket = scratch.join("s.sock");
    let mut child = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        // No catalog fetch and no login shell: nothing reaches the network or the host's shell.
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start the daemon");
    let mut stdout = child.stdout.take().unwrap();
    let daemon = Daemon { child, scratch: scratch.to_owned(), home, socket, seen: BTreeMap::new() };
    // The daemon's log shares stdout; it goes on to stderr after the readiness line.
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(&mut stdout);
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                let _ = ready_tx.send(false);
                return;
            }
            if line.contains("\"ready\":true") {
                let _ = ready_tx.send(true);
                break;
            }
            eprint!("daemon before ready: {line}");
        }
        let mut rest = String::new();
        let _ = reader.read_to_string(&mut rest);
        eprint!("{rest}");
    });
    let ready = ready_rx.recv_timeout(Duration::from_secs(60)).unwrap_or(false);
    assert!(ready, "the daemon was not ready in 60 s");
    daemon
}

#[test]
fn every_chat_runs_within_its_process_budget_and_leaves_none_behind() {
    // Short: the socket path must stay under the macOS limit.
    let scratch = daemon_env::Scratch::new("amx-pbud");
    let work = scratch.join("work");
    fs::create_dir_all(&work).unwrap();
    let mut daemon = start(&scratch);
    let baseline = daemon.look();
    eprintln!(
        "before any chat, the daemon started {}:\n{}",
        baseline.len(),
        report(&baseline, daemon.pid())
    );

    let mut rpc = Rpc::connect(&daemon.socket);
    rpc.call("initialize", json!({"protocolVersion": 1}));
    let mut ids = Vec::new();
    for i in 0..CHATS {
        let made = rpc.call("session/new", json!({"cwd": work, "mcpServers": []}));
        let id = made["sessionId"].as_str().expect("session/new gave no sessionId").to_owned();
        let ended = rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("chat {i}")}]}),
        );
        assert!(ended.get("stopReason").is_some(), "the turn of chat {i} did not end: {ended}");
        let all = daemon.look();
        let host = host_pid(&daemon.home, &id);
        let chat: BTreeMap<u32, Proc> = subtree(host, &table());
        eprintln!(
            "chat {i} ({id}) runs {} processes:\n{}\nall the daemon started, {}:\n{}",
            chat.len(),
            report(&chat, daemon.pid()),
            all.len(),
            report(&all, daemon.pid())
        );
        assert!(
            chat.len() <= PER_CHAT,
            "chat {i} runs {} processes (budget {PER_CHAT}):\n{}",
            chat.len(),
            report(&chat, daemon.pid())
        );
        ids.push(id);
    }

    for id in &ids {
        rpc.call("_acpmux/kill", json!({"sessionId": id}));
    }
    let deadline = Instant::now() + CLEANUP;
    let left = loop {
        let left = daemon.look();
        if left.is_empty() || Instant::now() >= deadline {
            break left;
        }
        std::thread::sleep(POLL);
    };
    assert!(
        left.is_empty(),
        "{} processes the daemon started outlived their stopped chats by {CLEANUP:?} (pid [state] argv, then its parents):\n{}",
        left.len(),
        report(&left, daemon.pid())
    );
}
