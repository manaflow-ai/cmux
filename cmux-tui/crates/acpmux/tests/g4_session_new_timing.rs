//! Scratch probe for fuzz row g candidate g4 (not for a PR): where the time of a new daemon's
//! first `session/new` goes on a Mac.
//!
//! The stand-in agent runs through a wrapper that logs, in ms since the Unix epoch: the wrapper's
//! start (the spawn reached exec), the moment python3 was about to import fake_agent.py (its
//! interpreter start), and each JSON-RPC line the agent read or wrote (from the agent's own
//! stdin/stdout copies). The client logs when it sent `session/new` and when the answer came.
//! The daemon starts fresh for each round, as after a kill, and each round opens 4 chats.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()
}

const WRAPPER: &str = r#"
import os, sys, time, json, threading, runpy
log = open(os.environ["G4_LOG"], "a", buffering=1)
def note(what): log.write(json.dumps({"t": time.time() * 1000, "pid": os.getpid(), "cwd": os.getcwd(), "what": what}) + "\n")
note("wrapper-start")
real_in, real_out = sys.stdin, sys.stdout
class Tee:
    def __init__(self, inner, tag): self.inner, self.tag = inner, tag
    def readline(self, *a):
        line = self.inner.readline(*a)
        if line: note(self.tag + ":" + line[:120].strip())
        return line
    def __iter__(self):
        while True:
            line = self.readline()
            if not line: return
            yield line
    def write(self, s):
        if s.strip(): note(self.tag + ":" + s[:120].strip())
        return self.inner.write(s)
    def __getattr__(self, k): return getattr(self.inner, k)
sys.stdin, sys.stdout = Tee(real_in, "in"), Tee(real_out, "out")
note("import-agent")
sys.argv = [os.environ["G4_AGENT"]]
runpy.run_path(os.environ["G4_AGENT"], run_name="__main__")
"#;

struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: Option<Child>,
}

impl Daemon {
    fn start(home: &Path) -> (Self, u128, u128) {
        let socket = home.join("s.sock");
        let began = now_ms();
        let child = daemon_env::command(home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(home.join("p"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon did not listen");
            std::thread::sleep(Duration::from_millis(5));
        }
        let listening = now_ms();
        (Self { home: home.to_owned(), socket, child: Some(child) }, began, listening)
    }

    fn kill9(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SAFETY: the unreaped daemon child this test started.
            unsafe { libc::kill(child.id() as i32, libc::SIGKILL) };
            let _ = child.wait();
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.kill9();
    }
}

fn call(socket: &Path, method: &str, params: Value) -> (Value, u128, u128) {
    let stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let hello = json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}});
    writer.write_all(format!("{hello}\n").as_bytes()).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let sent = now_ms();
    let req = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    writer.write_all(format!("{req}\n").as_bytes()).unwrap();
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("method").is_none() && v["id"] == 1 {
            return (v, sent, now_ms());
        }
    }
}

#[test]
fn g4_probe_first_session_new_steps() {
    let _ = HERMETIC;
    use std::os::unix::fs::PermissionsExt;
    let home = PathBuf::from("/tmp").join(format!("amx-g4p-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("p")).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    let wrapper = home.join("g4_wrapper.py");
    std::fs::write(&wrapper, WRAPPER).unwrap();
    let log = home.join("g4.log");
    let agent = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({"harnesses": {"fake": {"argv": ["python3", wrapper],
                         "env": {"G4_LOG": log, "G4_AGENT": agent}}},
                        "defaultHarness": "fake", "permissionPolicy": "approve-all",
                        "agentInbox": false, "autoResumeDelaysMs": []});
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600))
        .unwrap();
    for round in 0..6 {
        let (mut daemon, began, listening) = Daemon::start(&home);
        println!("G4 round={round} daemon_start_to_listen_ms={}", listening - began);
        for chat in 0..4 {
            let _ = std::fs::remove_file(&log);
            let (answer, sent, got) = call(
                &daemon.socket,
                "session/new",
                json!({"cwd": home.join("p"), "mcpServers": []}),
            );
            assert!(answer.get("error").is_none(), "{answer}");
            let events: Vec<Value> = std::fs::read_to_string(&log)
                .unwrap_or_default()
                .lines()
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect();
            let at = |pred: &dyn Fn(&str) -> bool| {
                events
                    .iter()
                    .find(|e| pred(e["what"].as_str().unwrap_or("")))
                    .and_then(|e| e["t"].as_f64())
                    .map(|t| t as i64 - sent as i64)
            };
            println!(
                "G4 round={round} chat={chat} total_ms={} spawn_exec_ms={:?} python_ready_ms={:?} init_in_ms={:?} init_out_ms={:?} new_in_ms={:?} new_out_ms={:?}",
                got - sent,
                at(&|w| w == "wrapper-start"),
                at(&|w| w == "import-agent"),
                at(&|w| w.starts_with("in:") && w.contains("\"initialize\"")),
                at(&|w| w.starts_with("out:") && w.contains("\"protocolVersion\"")),
                at(&|w| w.starts_with("in:") && w.contains("session/new")),
                at(&|w| w.starts_with("out:") && w.contains("sessionId")),
            );
        }
        daemon.kill9();
    }
    let _ = std::fs::remove_dir_all(&home);
}

/// One chat's steps, in ms after its `session/new` was sent, from the wrapper lines logged in
/// its own folder.
fn steps(events: &[Value], cwd: &Path, sent: u128) -> String {
    let mine: Vec<&Value> = events.iter().filter(|e| e["cwd"].as_str() == cwd.to_str()).collect();
    let at = |pred: &dyn Fn(&str) -> bool| {
        mine.iter()
            .find(|e| pred(e["what"].as_str().unwrap_or("")))
            .and_then(|e| e["t"].as_f64())
            .map_or(-1, |t| t as i64 - sent as i64)
    };
    format!(
        "spawn_exec_ms={} init_in_ms={} new_in_ms={} new_out_ms={}",
        at(&|w| w == "wrapper-start"),
        at(&|w| w.starts_with("in:") && w.contains("\"initialize\"")),
        at(&|w| w.starts_with("in:") && w.contains("session/new")),
        at(&|w| w.starts_with("out:") && w.contains("sessionId")),
    )
}

/// Opens `n` chats at once (each in its own folder, one client each) and prints each one's
/// total wait and steps; returns the waits.
fn open_at_once(socket: &Path, home: &Path, log: &Path, tag: &str, n: usize) -> Vec<u128> {
    let dirs: Vec<PathBuf> = (0..n).map(|i| home.join("p").join(format!("{tag}-{i}"))).collect();
    for d in &dirs {
        std::fs::create_dir_all(d).unwrap();
    }
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(n));
    let threads: Vec<_> = dirs
        .iter()
        .cloned()
        .map(|d| {
            let (socket, barrier) = (socket.to_owned(), barrier.clone());
            std::thread::spawn(move || {
                barrier.wait();
                let (answer, sent, got) =
                    call(&socket, "session/new", json!({"cwd": d, "mcpServers": []}));
                assert!(answer.get("error").is_none(), "{answer}");
                (d, sent, got)
            })
        })
        .collect();
    let results: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    let events: Vec<Value> = std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let mut waits = Vec::new();
    for (i, (d, sent, got)) in results.iter().enumerate() {
        println!("G4C {tag} chat={i} total_ms={} {}", got - sent, steps(&events, d, *sent));
        waits.push(got - sent);
    }
    waits
}

fn probe_home(tag: &str) -> (PathBuf, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let home = PathBuf::from("/tmp").join(format!("amx-g4c-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("p")).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    let wrapper = home.join("g4_wrapper.py");
    std::fs::write(&wrapper, WRAPPER).unwrap();
    let log = home.join("g4.log");
    let agent = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({"harnesses": {"fake": {"argv": ["python3", wrapper],
                         "env": {"G4_LOG": log, "G4_AGENT": agent}}},
                        "defaultHarness": "fake", "permissionPolicy": "ask",
                        "agentInbox": false, "autoResumeDelaysMs": []});
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600))
        .unwrap();
    (home, log)
}

fn summary(tag: &str, waits: &mut [u128]) {
    waits.sort_unstable();
    println!(
        "G4C-SUMMARY {tag} n={} p50_ms={} max_ms={} over_2s={}",
        waits.len(),
        waits[waits.len() / 2],
        waits[waits.len() - 1],
        waits.iter().filter(|w| **w > 2000).count()
    );
}

/// After each restart, N chats open at once (N = 1, 3, 6, 12), 3 rounds each.
#[test]
fn g4_probe_concurrent_session_new() {
    let _ = HERMETIC;
    let (home, log) = probe_home("n");
    for n in [1usize, 3, 6, 12] {
        let mut all = Vec::new();
        for round in 0..3 {
            let (mut daemon, _, _) = Daemon::start(&home);
            all.extend(open_at_once(&daemon.socket, &home, &log, &format!("n{n}-r{round}"), n));
            daemon.kill9();
        }
        summary(&format!("n={n}"), &mut all);
    }
    let _ = std::fs::remove_dir_all(&home);
}

/// As row g after a restart: 6 chats from before the restart get their waiting-turn prompt
/// ("until-cancel" for 3, "ask: fuzz" for 3, sent and not waited for), and at once 3 new chats
/// open. 3 rounds.
#[test]
fn g4_probe_session_new_beside_rearm() {
    let _ = HERMETIC;
    let (home, log) = probe_home("rearm");
    let (mut daemon, _, _) = Daemon::start(&home);
    let mut old = Vec::new();
    for i in 0..6 {
        let d = home.join("p").join(format!("old-{i}"));
        std::fs::create_dir_all(&d).unwrap();
        let (answer, _, _) =
            call(&daemon.socket, "session/new", json!({"cwd": d, "mcpServers": []}));
        old.push(answer["result"]["sessionId"].as_str().unwrap().to_owned());
    }
    daemon.kill9();
    let mut all = Vec::new();
    for round in 0..3 {
        let (mut daemon, _, _) = Daemon::start(&home);
        let stream = UnixStream::connect(&daemon.socket).unwrap();
        let mut w = stream.try_clone().unwrap();
        let hello = json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": 1}});
        w.write_all(format!("{hello}\n").as_bytes()).unwrap();
        for (i, id) in old.iter().enumerate() {
            let text = if i < 3 { "until-cancel" } else { "ask: fuzz" };
            let req = json!({"jsonrpc": "2.0", "id": 100 + i, "method": "session/prompt",
                             "params": {"sessionId": id, "prompt": [{"type": "text", "text": text}],
                                        "_meta": {"acpmux": {"promptId": format!("rearm-{round}-{i}")}}}});
            w.write_all(format!("{req}\n").as_bytes()).unwrap();
        }
        all.extend(open_at_once(&daemon.socket, &home, &log, &format!("rearm-r{round}"), 3));
        drop(stream);
        daemon.kill9();
    }
    summary("rearm6+new3", &mut all);
    let _ = std::fs::remove_dir_all(&home);
}
