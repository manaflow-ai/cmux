//! Agents that start in a burst must each get their start text and report
//! their start.
//!
//! When Claude Code starts in a cmux terminal it runs two `SessionStart`
//! hook commands at one time: the installed hook
//! (`cmux-tui-hook claude SessionStart`), which reports the start to the
//! session's journal, and the context hook (`cmux-tui agent
//! session-context`), which prints the text that tells the model where it
//! runs and which other agents run in the session. On a Mac with some
//! hundreds of workspaces, about 170 agents start at one time and the daemon
//! is at its connection limit.
//!
//! Wanted, at the limit also: the start text names the session, workspace,
//! screen, pane, tab and terminal (never the word `unknown`) and the other
//! agents, both hook commands exit 0, and the daemon lists the agent with no
//! second hook of that agent.
//!
//! Each test starts a real headless daemon in a private folder (as the app's
//! socket folder is, so the hook's queue file is in use) and runs the two
//! real commands inside terminals of the session, with the environment that
//! the daemon gives a terminal. The tests assert counts and states. Every
//! time limit here is a liveness bound of the test, except the moment at
//! which the first test frees the daemon (see `HOLD`).
#![cfg(unix)]

use std::collections::HashSet;
use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

/// The agents of one burst.
const AGENTS: usize = 170;
/// The words that start the list of the other agents in a start text.
const PEERS: &str = "Other agents in this session:";
/// The longest time the first test keeps the daemon at its limit after it
/// lets the agent start. The context hook gives its whole read 1500 ms
/// (`session_context.rs` `DEADLINE`); the daemon is free again well inside
/// that. The test frees the daemon sooner when the context hook has ended.
const HOLD: Duration = Duration::from_millis(700);

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
        // Private, as the app's runtime socket folder is: the hook keeps its
        // queue file only beside a socket in a private folder.
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        for folder in ["ready", "term", "out", "done"] {
            fs::create_dir_all(dir.join(folder)).unwrap();
        }
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
}

/// The daemon's open descriptors and its own limit of them, read from `/proc`
/// (Linux only; a count for the report, no assertion).
fn descriptors(daemon: &Daemon) -> String {
    let pid = daemon.child.id();
    let open = fs::read_dir(format!("/proc/{pid}/fd")).map(Iterator::count);
    let limit = fs::read_to_string(format!("/proc/{pid}/limits")).ok().and_then(|limits| {
        limits
            .lines()
            .find(|line| line.starts_with("Max open files"))
            .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
    });
    match (open, limit) {
        (Ok(open), Some(limit)) => format!("{open} open descriptors; {limit}"),
        _ => "descriptors not counted on this system".to_string(),
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
    peak: u64,
    limit: u64,
    accepted: u64,
    refused: u64,
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

    fn stats(&mut self, include: &[&str]) -> Value {
        self.request(json!({"cmd": "server-stats", "include": include}))
    }

    fn connections(&mut self) -> Connections {
        let stats = self.stats(&[]);
        let count = |name: &str| {
            stats["connections"][name]
                .as_u64()
                .unwrap_or_else(|| panic!("setup: server-stats has no connections.{name}: {stats}"))
        };
        Connections {
            active: count("active"),
            peak: count("peak"),
            limit: count("limit"),
            accepted: count("accepted"),
            refused: count("refused"),
        }
    }

    /// A terminal in a new workspace that waits behind `gate` and then makes
    /// the calls of one agent start.
    fn start_agent_terminal(&mut self, dir: &Path, index: usize, gate: &Gate) {
        self.request(json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", agent_script(dir, index, &gate.name)],
            "new_workspace": true,
            "name": format!("a{index}"),
        }));
    }
}

/// A barrier for terminals: each one reads this FIFO to its end, and the end
/// comes for all of them at one time, when the test closes its own end.
struct Gate {
    name: String,
    writer: fs::File,
}

impl Gate {
    fn new(dir: &Path, name: &str) -> Self {
        let path = dir.join(name);
        let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: `c_path` is a valid C string that lives across the call.
        let made = unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) };
        assert_eq!(made, 0, "setup: mkfifo {}: {}", path.display(), io::Error::last_os_error());
        // Open for reading and writing: this open does not wait for a
        // reader, and a terminal's open for reading does not wait either.
        let writer = fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
        Self { name: name.to_owned(), writer }
    }

    /// Lets every terminal behind the gate go on.
    fn open(self) {
        drop(self.writer);
    }
}

/// The program of an agent's terminal. It says that it is ready, waits for
/// its gate, then runs the two `SessionStart` hook commands of a Claude Code
/// start at one time, as Claude Code does, and keeps their output and exit
/// codes. Then the terminal stays open.
fn agent_script(dir: &Path, index: usize, gate: &str) -> String {
    let dir = dir.display();
    let hook = env!("CARGO_BIN_EXE_cmux-tui-hook");
    let tui = env!("CARGO_BIN_EXE_cmux-tui");
    let payload = format!(
        "{{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\
         \"session_id\":\"00000000-0000-4000-8000-{index:012}\",\"cwd\":\"/tmp\"}}"
    );
    format!(
        "D='{dir}'; I={index}; P='{payload}'; \
         exec 3<\"$D/{gate}\"; \
         printf '%s' \"$CMUX_TUI_TERMINAL_ID\" >\"$D/term/$I\"; \
         : >\"$D/ready/$I\"; \
         /bin/cat <&3 >/dev/null; \
         exec 3<&-; \
         (printf '%s' \"$P\" | '{hook}' claude SessionStart \
            >\"$D/out/$I.hook\" 2>\"$D/out/$I.hook.err\"; echo $? >\"$D/out/$I.hook.rc\") & \
         (printf '%s' \"$P\" | '{tui}' agent session-context \
            >\"$D/out/$I.ctx\" 2>\"$D/out/$I.ctx.err\"; echo $? >\"$D/out/$I.ctx.rc\") & \
         wait; \
         : >\"$D/done/$I\"; \
         exec /bin/cat"
    )
}

fn marked(dir: &Path, folder: &str, index: usize) -> bool {
    dir.join(folder).join(index.to_string()).exists()
}

/// How many of `indexes` have their mark in `folder`.
fn marks(dir: &Path, folder: &str, indexes: std::ops::RangeInclusive<usize>) -> usize {
    indexes.filter(|index| marked(dir, folder, *index)).count()
}

/// What one agent start gave.
struct Start {
    index: usize,
    terminal: String,
    hook_exit: Option<i32>,
    hook_error: String,
    context_exit: Option<i32>,
    /// The text for the model (`hookSpecificOutput.additionalContext`).
    text: Option<String>,
    printed: String,
}

impl Start {
    fn read(dir: &Path, index: usize) -> Self {
        let file = |name: String| fs::read_to_string(dir.join(name)).unwrap_or_default();
        let exit = |name: String| file(name).trim().parse::<i32>().ok();
        let printed = file(format!("out/{index}.ctx"));
        let text = serde_json::from_str::<Value>(&printed).ok().and_then(|output| {
            output
                .pointer("/hookSpecificOutput/additionalContext")
                .and_then(Value::as_str)
                .map(str::to_owned)
        });
        Self {
            index,
            terminal: file(format!("term/{index}")),
            hook_exit: exit(format!("out/{index}.hook.rc")),
            hook_error: file(format!("out/{index}.hook.err")),
            context_exit: exit(format!("out/{index}.ctx.rc")),
            text,
            printed,
        }
    }

    fn hook_failed(&self) -> bool {
        self.hook_exit != Some(0)
    }

    fn context_failed(&self) -> bool {
        self.context_exit != Some(0)
    }

    /// The text names a place by the word `unknown`, or not this terminal.
    fn unknown_place(&self) -> bool {
        self.text.as_deref().is_some_and(|text| {
            text.contains("unknown") || !text.contains(&format!("terminal {}.", self.terminal))
        })
    }

    fn no_other_agent(&self) -> bool {
        self.text.as_deref().is_some_and(|text| !text.contains(PEERS))
    }

    /// One line for a failure message.
    fn shown(&self) -> String {
        let cut = |text: &str| text.chars().take(420).collect::<String>();
        format!(
            "agent {} ({}): hook exit {:?} {:?}; context exit {:?}; printed {:?}",
            self.index,
            self.terminal,
            self.hook_exit,
            cut(self.hook_error.trim()),
            self.context_exit,
            cut(self.printed.trim()),
        )
    }
}

/// One `cmux.protocol/2` read on its own connection.
fn read_v2(socket: &Path, operation: &str) -> Result<Value, String> {
    let request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("asb-{operation}"),
        "operation": operation,
        "params": {"machine": "current", "session": "current"},
    });
    let stream = transport::connect(socket).map_err(|error| format!("connect: {error}"))?;
    stream
        .set_read_timeout(Some(test_timeout(Duration::from_secs(20))))
        .map_err(|error| format!("read timeout: {error}"))?;
    let mut writer = stream.try_clone_box().map_err(|error| format!("clone: {error}"))?;
    writeln!(writer, "{request}").map_err(|error| format!("write: {error}"))?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).map_err(|error| format!("read: {error}"))?;
    let response: Value =
        serde_json::from_str(&line).map_err(|error| format!("reply {line:?}: {error}"))?;
    if response["ok"] == true { Ok(response["result"].clone()) } else { Err(response.to_string()) }
}

/// The terminals of the agents that the daemon lists (`agent.list`).
fn listed_agents(socket: &Path) -> Result<HashSet<String>, String> {
    let agents = read_v2(socket, "agent.list")?;
    let agents = agents.as_array().ok_or_else(|| format!("agent.list is no list: {agents}"))?;
    Ok(agents.iter().filter_map(|agent| agent["terminal_id"].as_str()).map(str::to_owned).collect())
}

/// Waits until the daemon lists an agent for each terminal of `wanted`;
/// returns the wanted terminals that it does not list when `timeout` passes.
fn not_listed(socket: &Path, wanted: &[String], timeout: Duration) -> Vec<String> {
    let mut last = Err("agent.list was not read".to_owned());
    let missing = |listed: &Result<HashSet<String>, String>| -> Vec<String> {
        match listed {
            Ok(listed) => wanted.iter().filter(|id| !listed.contains(*id)).cloned().collect(),
            Err(_) => wanted.to_vec(),
        }
    };
    wait_until(timeout, || {
        last = listed_agents(socket);
        missing(&last).is_empty()
    });
    if let Err(error) = &last {
        eprintln!("agent start burst: the last agent.list read failed: {error}");
    }
    missing(&last)
}

/// Runs the start of the first agent (index 0) with a free daemon and checks
/// that it is whole: the other starts of the test then have one other agent
/// to name. Returns its terminal.
fn first_agent_started(daemon: &Daemon, gate: Gate) -> String {
    gate.open();
    let ended =
        wait_until(test_timeout(Duration::from_secs(30)), || marked(&daemon.dir, "done", 0));
    let first = Start::read(&daemon.dir, 0);
    assert!(ended, "setup: the first agent's start did not end: {}", first.shown());
    assert!(
        !first.hook_failed()
            && !first.context_failed()
            && first.text.is_some()
            && !first.unknown_place()
            && first.terminal.starts_with("term_"),
        "setup: with a free daemon the first agent's start is not whole: {}",
        first.shown()
    );
    let missing = not_listed(
        &daemon.socket,
        std::slice::from_ref(&first.terminal),
        test_timeout(Duration::from_secs(20)),
    );
    assert!(missing.is_empty(), "setup: the daemon does not list the first agent");
    first.terminal
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

/// One agent starts while the daemon is at its connection limit; the limit
/// ends inside the time that the context hook gives its read. The agent must
/// start as it does with a free daemon.
#[test]
fn start_burst_one_agent_at_the_connection_limit_gets_its_place_and_the_other_agents() {
    let daemon = Daemon::start("held");
    let mut control = Control::open(&daemon.socket);
    let first_gate = Gate::new(&daemon.dir, "go-first");
    let gate = Gate::new(&daemon.dir, "go");
    control.start_agent_terminal(&daemon.dir, 0, &first_gate);
    control.start_agent_terminal(&daemon.dir, 1, &gate);
    let ready = wait_until(test_timeout(Duration::from_secs(30)), || {
        marks(&daemon.dir, "ready", 0..=1) == 2
    });
    assert!(ready, "setup: the two terminals did not start");
    first_agent_started(&daemon, first_gate);

    let held = hold_at_limit(&daemon.socket, &mut control);
    let at_limit = control.connections();

    gate.open();
    let opened = Instant::now();
    // The daemon stays at its limit until the context hook has ended (today
    // it ends at once: each of its requests is refused) or until `HOLD`.
    let context_ended = daemon.dir.join("out/1.ctx.rc");
    while !context_ended.exists() && opened.elapsed() < HOLD {
        std::thread::sleep(Duration::from_millis(1));
    }
    let ended_at_the_limit = context_ended.exists();
    let refused_at_the_limit = control.connections().refused - at_limit.refused;
    let held_for = opened.elapsed();
    drop(held);

    let ended =
        wait_until(test_timeout(Duration::from_secs(30)), || marked(&daemon.dir, "done", 1));
    let start = Start::read(&daemon.dir, 1);
    let missing = not_listed(
        &daemon.socket,
        std::slice::from_ref(&start.terminal),
        test_timeout(Duration::from_secs(20)),
    );
    let facts = format!(
        "limit {}; the daemon refused {refused_at_the_limit} connection(s) of the start, and \
         the context hook had ended: {ended_at_the_limit}, when the test freed the daemon {} ms \
         after the start; {}",
        at_limit.limit,
        held_for.as_millis(),
        start.shown()
    );
    eprintln!("agent start at the limit: {facts}");
    let mut faults = Vec::new();
    if !ended {
        faults.push("the start did not end");
    }
    if start.hook_failed() {
        faults.push("the installed hook did not exit 0");
    }
    if start.context_failed() {
        faults.push("the context hook did not exit 0");
    }
    if start.text.is_none() {
        faults.push("the context hook printed no start text");
    }
    if start.unknown_place() {
        faults.push("the start text has an unknown id");
    }
    if start.no_other_agent() {
        faults.push("the start text names no other agent");
    }
    if !missing.is_empty() {
        faults.push("the daemon does not list the agent");
    }
    assert!(faults.is_empty(), "an agent start at the connection limit: {faults:?}; {facts}");
}

/// 170 agents start at one time, each in its own terminal and workspace.
#[test]
fn start_burst_of_170_agents_gets_each_place_each_other_agent_and_each_report() {
    let began = Instant::now();
    let daemon = Daemon::start("burst");
    let mut control = Control::open(&daemon.socket);
    eprintln!("agent start burst: the daemon with no terminal: {}", descriptors(&daemon));
    let first_gate = Gate::new(&daemon.dir, "go-first");
    let gate = Gate::new(&daemon.dir, "go");
    control.start_agent_terminal(&daemon.dir, 0, &first_gate);
    for index in 1..=AGENTS {
        control.start_agent_terminal(&daemon.dir, index, &gate);
    }
    let ready = wait_until(test_timeout(Duration::from_secs(40)), || {
        marks(&daemon.dir, "ready", 0..=AGENTS) == AGENTS + 1
    });
    assert!(
        ready,
        "setup: {} of {} terminals started",
        marks(&daemon.dir, "ready", 0..=AGENTS),
        AGENTS + 1
    );
    first_agent_started(&daemon, first_gate);
    let before = control.connections();
    eprintln!(
        "agent start burst: setup of {} terminals took {} ms; limit {}",
        AGENTS + 1,
        began.elapsed().as_millis(),
        before.limit
    );
    eprintln!(
        "agent start burst: the daemon with {} terminals: {}",
        AGENTS + 1,
        descriptors(&daemon)
    );

    gate.open();
    let opened = Instant::now();
    let all_ended = wait_until(test_timeout(Duration::from_secs(30)), || {
        marks(&daemon.dir, "done", 1..=AGENTS) == AGENTS
    });
    let ended = marks(&daemon.dir, "done", 1..=AGENTS);
    let burst_ms = opened.elapsed().as_millis();
    let after = control.connections();
    eprintln!("agent start burst: the daemon after the burst: {}", descriptors(&daemon));
    eprintln!(
        "agent start burst: {ended} of {AGENTS} starts ended (all: {all_ended}) in {burst_ms} \
         ms; connections accepted {}, refused {}, peak {} of {}",
        after.accepted - before.accepted,
        after.refused - before.refused,
        after.peak,
        after.limit
    );

    let starts: Vec<Start> = (1..=AGENTS).map(|index| Start::read(&daemon.dir, index)).collect();
    let terminals: Vec<String> = starts.iter().map(|start| start.terminal.clone()).collect();
    // No agent runs a second hook in this test: an agent that the daemon
    // does not list here has no state from its start.
    let listed_at_the_last_exit =
        AGENTS - not_listed(&daemon.socket, &terminals, Duration::ZERO).len();
    let missing = not_listed(&daemon.socket, &terminals, test_timeout(Duration::from_secs(20)));
    let queue = control.stats(&["hook_queue"])["hook_queue"].clone();
    let last = control.connections();

    let count = |fault: fn(&Start) -> bool| starts.iter().filter(|start| fault(start)).count();
    let hook_failed = count(Start::hook_failed);
    let context_failed = count(Start::context_failed);
    let no_text = count(|start| start.text.is_none());
    let unknown_place = count(Start::unknown_place);
    let no_other_agent = count(Start::no_other_agent);
    let facts = format!(
        "of {AGENTS} agent starts: {hook_failed} with an installed hook that did not exit 0, \
         {context_failed} with a context hook that did not exit 0, {no_text} with no start \
         text, {unknown_place} with an unknown id in the start text, {no_other_agent} with no \
         other agent in the start text, {} that the daemon does not list with no second hook \
         ({listed_at_the_last_exit} listed when the last hook ended); connections refused {} of \
         {} that came, peak {} of {}; hook queue {queue}",
        missing.len(),
        last.refused - before.refused,
        (last.accepted + last.refused) - (before.accepted + before.refused),
        last.peak,
        last.limit
    );
    eprintln!("agent start burst: {facts}");
    let faulty: Vec<String> = starts
        .iter()
        .filter(|start| {
            start.hook_failed()
                || start.context_failed()
                || start.text.is_none()
                || start.unknown_place()
                || start.no_other_agent()
                || missing.contains(&start.terminal)
        })
        .take(3)
        .map(Start::shown)
        .collect();
    assert!(
        hook_failed + context_failed + no_text + unknown_place + no_other_agent + missing.len()
            == 0,
        "a burst {facts}; the first faulty starts: {faulty:#?}"
    );
}
