//! The start text of an agent when many agents start at one time.
//!
//! When Claude Code starts in a cmux terminal, its `SessionStart` hook
//! `cmux-tui agent session-context` prints the text that tells the model
//! where it runs (session, workspace, screen, pane, tab, terminal) and which
//! other agents run in the session. On a Mac with some hundreds of
//! workspaces about 170 agents start at one time, and the daemon is at its
//! connection limit.
//!
//! Wanted: one context read is ONE connection to the daemon, and a start
//! text never says that no other agent runs when the daemon did not answer
//! the list of the agents.
//!
//! Each test starts a real headless daemon and runs the real command with
//! the environment that the daemon gives a terminal. The tests assert counts
//! and texts; every time limit here is a liveness bound of the test.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

/// The sentence of a start text for a session with no other agent.
const NO_OTHER_AGENT: &str = "No other agent runs in this session now.";

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

/// Polls `done` until it is true; false when `timeout` passes first.
fn wait_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if done() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-asb-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let settings = dir.join("cmux-next.json");
        fs::write(&settings, "{}\n").unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let started = wait_until(test_timeout(Duration::from_secs(15)), || {
            transport::connect(&socket).is_ok()
        });
        assert!(started, "setup: the daemon did not create {}", socket.display());
        Self { child, socket, state, dir }
    }

    fn host_pids(&self) -> Vec<u32> {
        let root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&self.state, "main");
        fs::read_dir(root)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .filter_map(|entry| fs::read(entry.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .filter_map(|record| record["host_pid"].as_u64())
            .filter_map(|pid| u32::try_from(pid).ok())
            .collect()
    }

    /// The start text that `cmux-tui agent session-context` prints for the
    /// terminal `terminal` of this daemon's session, and the command's exit
    /// code.
    fn start_text(&self, terminal: &str) -> (String, Option<i32>) {
        let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["agent", "session-context"])
            .env("CMUX_TUI_SOCKET", &self.socket)
            .env("CMUX_TUI_TERMINAL_ID", terminal)
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_CLI")
            .env_remove("CMUX_TUI_CLAUDE_HOOKS_DISABLED")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let payload =
            json!({"hook_event_name": "SessionStart", "source": "startup", "cwd": "/tmp"});
        // The command reads the payload to its end, then prints.
        child.stdin.take().unwrap().write_all(payload.to_string().as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        let printed = String::from_utf8_lossy(&output.stdout).into_owned();
        let text = serde_json::from_str::<Value>(&printed)
            .ok()
            .and_then(|output| {
                output
                    .pointer("/hookSpecificOutput/additionalContext")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| panic!("the command printed no start text: {printed:?}"));
        (text, output.status.code())
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        for pid in self.host_pids() {
            // SAFETY: signal zero only checks that the process exists.
            let exists = unsafe { libc::kill(pid as libc::pid_t, 0) == 0 };
            if exists {
                // SAFETY: the pid came from this test's own host records.
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The daemon's connection counters (`server-stats` `connections`).
#[derive(Clone, Copy)]
struct Connections {
    active: u64,
    limit: u64,
    accepted: u64,
    refused: u64,
}

impl Connections {
    /// Each connection that came to the daemon, admitted or refused.
    fn came(self) -> u64 {
        self.accepted + self.refused
    }
}

/// One connection that the test keeps for its own requests, so that the
/// test can ask the daemon while the daemon is at its connection limit.
struct Control {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    sent: u64,
}

impl Control {
    fn open(socket: &Path) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(test_timeout(Duration::from_secs(30)))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { writer, reader: BufReader::new(stream), sent: 0 }
    }

    /// A connection that the daemon admitted: it answered a request on it.
    /// `None` when the daemon refused the connection.
    fn admitted(socket: &Path) -> Option<Self> {
        let mut connection = Self::open(socket);
        writeln!(connection.writer, "{}", json!({"id": 0, "cmd": "server-stats"})).ok()?;
        let mut line = String::new();
        connection.reader.read_line(&mut line).ok()?;
        let reply: Value = serde_json::from_str(&line).ok()?;
        (reply["ok"] == true).then_some(connection)
    }

    /// One legacy request; its `data`.
    fn request(&mut self, mut value: Value) -> Value {
        self.sent += 1;
        let id = json!(self.sent);
        value["id"] = id.clone();
        writeln!(self.writer, "{value}").unwrap();
        loop {
            let mut line = String::new();
            let read = self
                .reader
                .read_line(&mut line)
                .unwrap_or_else(|error| panic!("setup: no reply to {value}: {error}"));
            assert!(read > 0, "setup: the daemon closed the test's connection at {value}");
            let Ok(response) = serde_json::from_str::<Value>(&line) else { continue };
            if response["id"] != id {
                continue;
            }
            assert_eq!(response["ok"], true, "setup: {value} failed: {response}");
            return response["data"].clone();
        }
    }

    fn connections(&mut self) -> Connections {
        let stats = self.request(json!({"cmd": "server-stats", "include": []}));
        let count = |name: &str| {
            stats["connections"][name]
                .as_u64()
                .unwrap_or_else(|| panic!("setup: server-stats has no connections.{name}: {stats}"))
        };
        Connections {
            active: count("active"),
            limit: count("limit"),
            accepted: count("accepted"),
            refused: count("refused"),
        }
    }

    /// A terminal in a new workspace that stays open; its id.
    fn start_terminal(&mut self, dir: &Path) -> String {
        let id_file = dir.join("terminal-id");
        let script = format!(
            "printf '%s' \"$CMUX_TUI_TERMINAL_ID\" >'{0}.part'; mv '{0}.part' '{0}'; exec /bin/cat",
            id_file.display()
        );
        self.request(json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": "agent",
        }));
        let written = wait_until(test_timeout(Duration::from_secs(30)), || id_file.exists());
        assert!(written, "setup: the terminal did not write its id");
        let terminal = fs::read_to_string(&id_file).unwrap();
        assert!(terminal.starts_with("term_"), "setup: the terminal id is {terminal:?}");
        terminal
    }
}

/// Opens connections and keeps them until the test itself holds every
/// connection of the daemon's limit (its control connection is one of them).
/// The daemon answered a request on each one, so each one holds a slot; the
/// daemon is then at its limit whatever another client does, and it stays
/// there until the test drops what this returns.
fn hold_at_limit(socket: &Path, control: &mut Control) -> Vec<Control> {
    let limit = usize::try_from(control.connections().limit).unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    let mut held = Vec::new();
    while held.len() + 1 < limit {
        assert!(
            Instant::now() < deadline,
            "setup: the daemon admitted {} of the {limit} connections that the test holds",
            held.len() + 1
        );
        match Control::admitted(socket) {
            Some(connection) => held.push(connection),
            // A connection of the setup still ends in the daemon.
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    }
    let now = control.connections();
    assert!(now.active >= now.limit, "setup: {} of {} slots are held", now.active, now.limit);
    assert!(
        Control::admitted(socket).is_none(),
        "setup: the daemon admitted a connection above its limit of {limit}"
    );
    held
}

/// One context read is one connection: the daemon serves many requests on
/// a connection, and a connection for each of the eight requests made 170
/// agent starts ask for up to 1360 connections of a daemon that has 64.
#[test]
fn agent_start_context_read_is_one_connection() {
    let daemon = Daemon::start("one");
    let mut control = Control::open(&daemon.socket);
    let terminal = control.start_terminal(&daemon.dir);
    // The connections of the setup are counted before the read starts.
    let before = control.connections();

    let (text, exit) = daemon.start_text(&terminal);

    let after = control.connections();
    let came = after.came() - before.came();
    eprintln!(
        "agent start context: one context read came to the daemon as {came} connections \
         ({} admitted, {} refused)",
        after.accepted - before.accepted,
        after.refused - before.refused
    );
    assert_eq!(exit, Some(0), "the context hook must exit 0: {text}");
    assert!(
        text.contains(&format!("terminal {terminal}.")) && !text.contains("unknown"),
        "with a free daemon the start text must name each place: {text}"
    );
    assert!(
        text.contains(NO_OTHER_AGENT),
        "the daemon answered the list of the agents, and no other agent runs: {text}"
    );
    assert_eq!(came, 1, "one context read must be one connection to the daemon");
}

/// The daemon refuses the context read when it is at its connection limit.
/// The start text must then say that the other agents are not known; it said
/// that no other agent runs, which is false in a session with other agents.
#[test]
fn agent_start_context_refused_list_is_not_known_and_never_no_other_agent() {
    let daemon = Daemon::start("refused");
    let mut control = Control::open(&daemon.socket);
    let terminal = control.start_terminal(&daemon.dir);
    let held = hold_at_limit(&daemon.socket, &mut control);
    let before = control.connections();

    let (text, exit) = daemon.start_text(&terminal);

    let after = control.connections();
    eprintln!(
        "agent start context at the limit: the test held {} of {} connections; the daemon \
         refused {} of the {} connections of the context read",
        held.len() + 1,
        after.limit,
        after.refused - before.refused,
        after.came() - before.came()
    );
    assert!(
        after.refused > before.refused && after.accepted == before.accepted,
        "setup: the daemon must refuse the context read (admitted {}, refused {})",
        after.accepted - before.accepted,
        after.refused - before.refused
    );
    assert_eq!(exit, Some(0), "the context hook must exit 0: {text}");
    assert!(text.contains(&format!("terminal {terminal}.")), "the terminal is named: {text}");
    assert!(
        !text.contains(NO_OTHER_AGENT),
        "the daemon did not answer the list of the agents, but the text says that no other \
         agent runs: {text}"
    );
    assert!(
        text.contains("not known"),
        "the text must say that the other agents are not known: {text}"
    );
    drop(held);
}
