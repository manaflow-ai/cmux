//! `agent.runtime.list` on a real headless daemon (RFC #20149 phase 1): an
//! agent started in a cmux terminal is verified to that terminal, the same
//! agent started outside cmux is unattributed, and arguments come back
//! redacted. An agent that left its terminal's session stays verified, from
//! the daemon's launch ledger, after the terminal closes.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-runtimes-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    fn line(&self, request: &Value) -> BufReader<Box<dyn transport::Stream>> {
        let stream = transport::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        writeln!(writer, "{request}").unwrap();
        BufReader::new(stream)
    }

    fn raw(&self, request: Value) -> Value {
        let mut line = String::new();
        self.line(&request).read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["ok"], true, "{request} failed: {reply}");
        reply["data"].clone()
    }

    fn runtimes(&self) -> Value {
        self.resource("agent.runtime.list")
    }

    /// A v2 read of the current session.
    fn resource(&self, operation: &str) -> Value {
        let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "1",
                             "operation": operation,
                             "params": {"machine": "current", "session": "current"}});
        let mut reader = self.line(&request);
        let mut line = String::new();
        loop {
            line.clear();
            assert!(reader.read_line(&mut line).unwrap() > 0, "connection closed");
            let reply: Value = serde_json::from_str(line.trim()).unwrap();
            if reply["id"] == "1" {
                assert_eq!(reply["ok"], true, "{reply}");
                return reply["result"].clone();
            }
        }
    }
}

impl Daemon {
    /// Close every workspace and end its terminals.
    fn close_all(&self) {
        let mut line = String::new();
        let request = json!({"cmd": "list-workspaces"});
        if self.line(&request).read_line(&mut line).is_ok()
            && let Ok(reply) = serde_json::from_str::<Value>(&line)
        {
            for workspace in reply["data"]["workspaces"].as_array().into_iter().flatten() {
                let close = json!({"cmd": "close-workspace", "key": workspace["key"],
                                   "end_terminals": true});
                let _ = self.line(&close).read_line(&mut String::new());
            }
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // End the terminal (and its host) before the daemon goes.
        self.close_all();
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn runtime_with_pid(inventory: &Value, pid: u64) -> Option<Value> {
    inventory["runtimes"].as_array()?.iter().find(|runtime| runtime["pid"] == pid).cloned()
}

/// Set in a stand-in agent's environment: [`stand_in_agent`] then waits.
const STAND_IN: &str = "CMUX_RUNTIMES_STAND_IN";
const STAND_IN_ARGS: &str = "stand_in_agent --exact";
/// Set to a file path in a stand-in agent's environment: the stand-in leaves
/// its terminal's session (`setsid`), as `nohup`/`setsid` launches and agent
/// daemons do, then writes `<pid> <ppid>` to that file before it waits.
const DETACH: &str = "CMUX_RUNTIMES_DETACH";
/// Set to a file path in a stand-in agent's environment: the stand-in lives
/// while that file exists, at most [`STAND_IN_MAX`].
const ALIVE: &str = "CMUX_RUNTIMES_ALIVE";
const STAND_IN_MAX: Duration = Duration::from_secs(300);

/// The body of a stand-in agent process; a no-op in a normal test run.
#[test]
fn stand_in_agent() {
    if std::env::var_os(STAND_IN).is_none() {
        return;
    }
    if let Some(ready) = std::env::var_os(DETACH) {
        // SAFETY: setsid takes no arguments and touches no memory.
        assert_ne!(unsafe { libc::setsid() }, -1, "setsid failed");
        let ready = PathBuf::from(ready);
        let partial = ready.with_extension("partial");
        let ids = format!("{} {}", std::process::id(), std::os::unix::process::parent_id());
        fs::write(&partial, ids).unwrap();
        fs::rename(&partial, &ready).unwrap();
    }
    let Some(alive) = std::env::var_os(ALIVE).map(PathBuf::from) else {
        std::thread::sleep(Duration::from_secs(60));
        return;
    };
    let deadline = Instant::now() + STAND_IN_MAX;
    while alive.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A detached stand-in agent. Closing its terminal no longer ends it; it
/// ends when this is dropped and its alive file goes (no signal, so a
/// reused pid is never hit).
struct DetachedAgent {
    pid: u32,
    /// Its parent when it started: the terminal's shell.
    ppid: u32,
    alive: PathBuf,
}

impl Drop for DetachedAgent {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.alive);
    }
}

/// Run a stand-in agent that detaches itself in a new cmux terminal, and
/// wait until it is ready.
fn start_detached_agent(daemon: &Daemon) -> DetachedAgent {
    let codex = daemon.dir.join("codex");
    fs::copy(std::env::current_exe().unwrap(), &codex).unwrap();
    let ready = daemon.dir.join("detached.ready");
    let alive = daemon.dir.join("detached.alive");
    fs::write(&alive, "").unwrap();
    let created = daemon.raw(json!({
        "cmd": "run",
        "argv": ["/bin/sh", "-c", format!("{STAND_IN}=1 {DETACH}={} {ALIVE}={} {} {STAND_IN_ARGS}; :",
                                          ready.display(), alive.display(), codex.display())],
        "new_workspace": true,
        "name": "detached",
    }));
    assert!(created["surface"].is_u64(), "{created}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        if let Ok(ids) = fs::read_to_string(&ready) {
            let ids: Vec<u32> = ids.split(' ').filter_map(|id| id.parse().ok()).collect();
            assert_eq!(ids.len(), 2, "bad ready file: {ids:?}");
            return DetachedAgent { pid: ids[0], ppid: ids[1], alive };
        }
        assert!(Instant::now() < deadline, "the detached stand-in never became ready");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The agent's runtime once its terminal's shell is gone and it was
/// reparented.
fn reparented_runtime(daemon: &Daemon, agent: &DetachedAgent) -> Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let inventory = daemon.runtimes();
        let runtime = runtime_with_pid(&inventory, u64::from(agent.pid))
            .unwrap_or_else(|| panic!("the detached stand-in is not listed: {inventory}"));
        if runtime["ppid"] != u64::from(agent.ppid) {
            return runtime;
        }
        assert!(Instant::now() < deadline, "the terminal's shell never ended: {runtime}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn cmux_next_agent_runtimes_keep_a_detached_agents_runtime_id_and_terminal_across_the_close() {
    let daemon = Daemon::start();
    let agent = start_detached_agent(&daemon);
    // Listed while its terminal lives: verified through the process tree.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let listed = loop {
        let inventory = daemon.runtimes();
        if let Some(runtime) = runtime_with_pid(&inventory, u64::from(agent.pid))
            && runtime["attribution"]["status"] == "verified"
        {
            break runtime;
        }
        assert!(Instant::now() < deadline, "the stand-in was never verified: {inventory}");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(listed["attribution"]["source"], "terminal_process_tree", "{listed}");
    let terminal = listed["attribution"]["terminal_id"].clone();
    assert!(terminal.as_str().is_some_and(|id| id.starts_with("term_")), "{listed}");

    daemon.close_all();
    let runtime = reparented_runtime(&daemon, &agent);
    assert_eq!(runtime["id"], listed["id"], "the same process generation");
    assert_eq!(runtime["attribution"]["status"], "verified", "{runtime}");
    assert_eq!(runtime["attribution"]["source"], "launch_ledger", "{runtime}");
    assert_eq!(runtime["attribution"]["terminal_id"], terminal, "{runtime}");
    assert_eq!(runtime["can_stop_safely"], false, "{runtime}");
}

#[test]
fn cmux_next_agent_runtimes_observe_a_detached_agent_when_its_terminal_closes() {
    let daemon = Daemon::start();
    let agent = start_detached_agent(&daemon);
    // Never listed before the close: the close itself records the agent.
    // The daemon's only terminal is the agent's.
    let terminals = daemon.resource("terminal.list");
    let terminals = terminals.as_array().cloned().unwrap_or_default();
    assert_eq!(terminals.len(), 1, "{terminals:?}");
    let terminal = terminals[0]["id"].clone();
    assert!(terminal.as_str().is_some_and(|id| id.starts_with("term_")), "{terminal}");
    daemon.close_all();
    let runtime = reparented_runtime(&daemon, &agent);
    assert_eq!(runtime["attribution"]["status"], "verified", "{runtime}");
    assert_eq!(runtime["attribution"]["source"], "launch_ledger", "{runtime}");
    assert_eq!(runtime["attribution"]["terminal_id"], terminal, "{runtime}");
    assert_eq!(runtime["can_stop_safely"], false, "{runtime}");
}

#[test]
fn cmux_next_agent_runtimes_attribute_a_terminal_agent_and_not_an_outside_one() {
    let daemon = Daemon::start();
    // A stand-in agent: this test binary under the name the Codex adapter
    // knows, running only `stand_in_agent`. A copied `/bin/sleep` is a
    // platform binary that newer macOS kills when it runs from /tmp.
    let codex = daemon.dir.join("codex");
    fs::copy(std::env::current_exe().unwrap(), &codex).unwrap();

    let created = daemon.raw(json!({
        "cmd": "run",
        "argv": ["/bin/sh", "-c", format!("{STAND_IN}=1 {} {STAND_IN_ARGS}; :", codex.display())],
        "new_workspace": true,
        "name": "runtimes",
    }));
    assert!(created["surface"].is_u64(), "{created}");
    let mut outside = Command::new(&codex)
        .args(STAND_IN_ARGS.split(' '))
        .env(STAND_IN, "1")
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    // macOS reports /tmp as /private/tmp, so match the unique directory.
    let own = format!("{}/codex", daemon.dir.file_name().unwrap().to_string_lossy());

    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let (inventory, inside) = loop {
        let inventory = daemon.runtimes();
        // The host may run real agents too; only this test's copy counts.
        let inside = inventory["runtimes"].as_array().into_iter().flatten().find(|runtime| {
            runtime["pid"] != u64::from(outside.id())
                && runtime["executable_path"].as_str().is_some_and(|path| path.ends_with(&own))
        });
        if let Some(inside) = inside.cloned()
            && runtime_with_pid(&inventory, u64::from(outside.id())).is_some()
        {
            break (inventory, inside);
        }
        assert!(Instant::now() < deadline, "the stand-in agents never appeared: {inventory}");
        std::thread::sleep(Duration::from_millis(50));
    };

    assert!(inventory["session_id"].as_str().is_some_and(|id| id.starts_with("session_")));
    assert!(inventory["scanned_processes"].as_u64().is_some_and(|count| count > 0));
    assert_eq!(inside["role"], "cli", "{inside}");
    assert_eq!(inside["attribution"]["status"], "verified", "{inside}");
    assert_eq!(inside["attribution"]["source"], "terminal_process_tree", "{inside}");
    let terminal = inside["attribution"]["terminal_id"].as_str().unwrap_or_default();
    assert!(terminal.starts_with("term_"), "{inside}");
    assert_eq!(inside["args"], json!(["codex", "<redacted>", "--exact"]), "{inside}");
    assert_eq!(inside["can_stop_safely"], false);
    assert!(
        inside["id"]
            .as_str()
            .is_some_and(|id| id.starts_with(&format!("local:{}:", inside["pid"]))),
        "{inside}"
    );

    let outside_runtime = runtime_with_pid(&inventory, u64::from(outside.id())).unwrap();
    assert_eq!(outside_runtime["attribution"]["status"], "unattributed", "{outside_runtime}");
    assert_eq!(outside_runtime["attribution"]["terminal_id"], Value::Null);

    let _ = outside.kill();
    let _ = outside.wait();
}
