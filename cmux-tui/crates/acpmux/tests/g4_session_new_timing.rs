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
def note(what): log.write(json.dumps({"t": time.time() * 1000, "pid": os.getpid(), "what": what}) + "\n")
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
