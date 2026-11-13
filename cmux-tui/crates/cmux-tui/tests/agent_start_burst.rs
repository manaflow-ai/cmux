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
//! the list of the agents. A terminal's short request (a hook, a typed
//! command) is served while other terminals hold long connections.
//!
//! Each test starts a real headless daemon and runs the real command with
//! the environment that the daemon gives a terminal. The tests assert counts
//! and texts; every time limit here is a liveness bound of the test.
#![cfg(unix)]

use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

/// The sentence of a start text for a session with no other agent.
const NO_OTHER_AGENT: &str = "No other agent runs in this session now.";
/// The connections that the daemon serves for its terminals at one time
/// (`MAX_TERMINAL_CONNECTIONS`, `cmux-tui-core` `server/bounded_outbound.rs`).
const TERMINAL_LANE: usize = 48;
/// The connections of terminals that may hold a stream, a wait or a follow at
/// one time (`MAX_LONG_TERMINAL_CONNECTIONS`, the same file).
const LONG_BOUND: usize = 256;

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
        // macOS refuses the option on a socket that the daemon closed (it
        // refused the connection at its limit); a read there ends at once.
        let _ = stream.set_read_timeout(Some(test_timeout(Duration::from_secs(30))));
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

    /// How many requests named `name` the daemon handled (`server-stats`
    /// section `commands`), from each kind of client.
    fn handled(&mut self, name: &str) -> u64 {
        let stats = self.request(json!({"cmd": "server-stats", "include": ["commands"]}));
        let rows = stats["commands"]["rows"]
            .as_array()
            .unwrap_or_else(|| panic!("setup: server-stats has no commands.rows: {stats}"));
        rows.iter().filter(|row| row["name"] == name).filter_map(|row| row["count"].as_u64()).sum()
    }

    /// The connections that the daemon admitted and refused, by the kind of
    /// client that it saw (`server-stats` section `commands`).
    fn kinds(&mut self) -> String {
        let stats = self.request(json!({"cmd": "server-stats", "include": ["commands"]}));
        stats["commands"]["connections"].to_string()
    }

    /// A terminal in a new workspace that runs `script`.
    fn run_in_terminal(&mut self, name: &str, script: &str) {
        self.request(json!({
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": name,
        }));
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
    assert_eq!(
        after.came() - before.came(),
        1,
        "a refused context read must not ask the daemon for another connection"
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

/// A barrier for a terminal: it reads this FIFO to its end, and the end
/// comes when the test closes its own end.
struct Gate {
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
        // reader, and the terminal's open for reading does not wait either.
        let writer = fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
        Self { writer }
    }

    /// Lets the terminal behind the gate go on.
    fn open(self) {
        drop(self.writer);
    }
}

/// The program of a terminal that holds one long connection: the session's
/// event stream, as `cmux terminal wait`, an MCP watch and a nested cmux do.
/// It waits behind `gate` first, so the daemon knows the terminal before the
/// terminal's first connection (the accept loop then counts the connection
/// in the terminals' lane; see `Holders`).
fn long_holder_script(dir: &Path, index: usize, gate: &str) -> String {
    format!(
        "exec 3<'{dir}/held/{gate}'; : >'{dir}/held/{index}.ready'; /bin/cat <&3 >/dev/null; \
         exec '{tui}' --jsonl session current events >/dev/null 2>'{dir}/held/{index}.err'",
        tui = env!("CARGO_BIN_EXE_cmux-tui"),
        dir = dir.display(),
    )
}

/// Terminals that each hold one long connection.
///
/// The daemon's accept loop counts a connection in the terminals' lane when
/// it knows the peer's terminal, and it never waits for the state lock to
/// learn a new terminal. A holder that connects while the daemon still makes
/// the other terminals can thus be counted as an outside connection, and the
/// test would then not fill the lane. So each group of holders first waits
/// behind one gate until each of its terminals runs and the daemon is idle.
struct Holders;

impl Holders {
    /// Starts the holders `first..last`, each in its own terminal, and waits
    /// until the daemon opened `last` event streams in all, or until a
    /// holder of the group ended with an error. Returns the streams that the
    /// daemon opened in all.
    fn start(daemon: &Daemon, control: &mut Control, first: usize, last: usize) -> u64 {
        let held = daemon.dir.join("held");
        let gate_name = format!("gate-{first}");
        let gate = Gate::new(&held, &gate_name);
        for index in first..last {
            let script = long_holder_script(&daemon.dir, index, &gate_name);
            control.run_in_terminal(&format!("h{index}"), &script);
        }
        let ready = wait_until(test_timeout(Duration::from_secs(60)), || {
            (first..last).all(|index| held.join(format!("{index}.ready")).exists())
        });
        assert!(ready, "setup: the terminals of the holders {first}..{last} did not all start");
        gate.open();
        let wanted = u64::try_from(last).unwrap();
        wait_until(test_timeout(Duration::from_secs(60)), || {
            control.handled("session.events") >= wanted
                || Self::first_error(daemon, first, last).is_some()
        });
        control.handled("session.events")
    }

    /// What the first holder of `first..last` that ended with an error said.
    fn first_error(daemon: &Daemon, first: usize, last: usize) -> Option<String> {
        (first..last)
            .map(|index| daemon.dir.join("held").join(format!("{index}.err")))
            .filter_map(|path| fs::read_to_string(path).ok())
            .find(|error| !error.trim().is_empty())
    }
}

/// The program of the terminal that makes the three short requests of an
/// agent, each behind its own gate: the context hook of an agent start, the
/// hook of a prompt, and a typed command. It writes the time before and
/// after each one (`date +%s%N`; where `date` has no nanoseconds the test
/// takes the times of the two files).
fn probe_script(dir: &Path) -> String {
    let start = r#"{"hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}"#;
    let prompt = concat!(
        r#"{"hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"go on","#,
        r#""session_id":"00000000-0000-4000-8000-000000000049"}"#
    );
    format!(
        "D='{dir}/probe'; \
         mark() {{ date +%s%N >\"$D/$1.part\" 2>/dev/null; mv \"$D/$1.part\" \"$D/$1\"; }}; \
         exec 3<\"$D/gate-context\" 4<\"$D/gate-prompt\" 5<\"$D/gate-typed\"; \
         printf '%s' \"$CMUX_TUI_TERMINAL_ID\" >\"$D/terminal.part\"; \
         mv \"$D/terminal.part\" \"$D/terminal\"; \
         /bin/cat <&3 >/dev/null; mark context.start; \
         printf '%s' '{start}' | '{tui}' agent session-context \
            >\"$D/context.out\" 2>\"$D/context.err\"; echo $? >\"$D/context.rc\"; \
         mark context.end; \
         /bin/cat <&4 >/dev/null; mark prompt.start; \
         printf '%s' '{prompt}' | '{hook}' claude UserPromptSubmit \
            >\"$D/prompt.out\" 2>\"$D/prompt.err\"; echo $? >\"$D/prompt.rc\"; \
         mark prompt.end; \
         /bin/cat <&5 >/dev/null; mark typed.start; \
         '{tui}' --json terminal \"$CMUX_TUI_TERMINAL_ID\" show \
            >\"$D/typed.out\" 2>\"$D/typed.err\"; echo $? >\"$D/typed.rc\"; \
         mark typed.end; \
         exec /bin/cat",
        dir = dir.display(),
        tui = env!("CARGO_BIN_EXE_cmux-tui"),
        hook = env!("CARGO_BIN_EXE_cmux-tui-hook"),
    )
}

/// The moment that the probe's terminal wrote in `mark`.
fn marked_at(probe: &Path, mark: &str) -> Duration {
    let path = probe.join(mark);
    let written = fs::read_to_string(&path).unwrap_or_default();
    match written.trim().parse::<u64>() {
        Ok(nanoseconds) => Duration::from_nanos(nanoseconds),
        Err(_) => fs::metadata(&path)
            .and_then(|file| file.modified())
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .unwrap_or_else(|| panic!("setup: no time for {}", path.display())),
    }
}

/// What one short request of the probe's terminal gave.
struct Short {
    name: &'static str,
    /// From the moment before the command to the moment after it.
    wait: Duration,
    exit: Option<i32>,
    printed: String,
    error: String,
    /// The connections that the daemon admitted and refused in that time.
    admitted: u64,
    refused: u64,
}

impl Short {
    /// Opens `gate` and waits for the end of the request `name`.
    fn run(daemon: &Daemon, control: &mut Control, gate: Gate, name: &'static str) -> Self {
        let probe = daemon.dir.join("probe");
        let before = control.connections();
        gate.open();
        let end = format!("{name}.end");
        let ended = wait_until(test_timeout(Duration::from_secs(60)), || probe.join(&end).exists());
        let after = control.connections();
        let file = |suffix: &str| {
            fs::read_to_string(probe.join(format!("{name}.{suffix}"))).unwrap_or_default()
        };
        assert!(ended, "the {name} request did not end: stderr {:?}", file("err"));
        let wait =
            marked_at(&probe, &end).saturating_sub(marked_at(&probe, &format!("{name}.start")));
        let short = Self {
            name,
            wait,
            exit: file("rc").trim().parse().ok(),
            printed: file("out"),
            error: file("err"),
            admitted: after.accepted - before.accepted,
            refused: after.refused - before.refused,
        };
        eprintln!("agent start long holders: {}", short.shown());
        short
    }

    fn shown(&self) -> String {
        let cut = |text: &str| text.trim().chars().take(600).collect::<String>();
        format!(
            "{}: waited {:.1} ms, exit {:?}, the daemon admitted {} and refused {} connections; \
             printed {:?}; stderr {:?}",
            self.name,
            self.wait.as_secs_f64() * 1000.0,
            self.exit,
            self.admitted,
            self.refused,
            cut(&self.printed),
            cut(&self.error),
        )
    }
}

/// 48 terminals each hold one long connection (the session's event stream),
/// as agents do that wait for a terminal, watch through MCP or run a nested
/// cmux. A short request from another terminal must still be served: the
/// daemon counted a long connection in the same 48 places as a hook that ends
/// in milliseconds, so 48 long holders made every hook and every typed
/// command of every other terminal fail until one of them closed.
#[test]
fn agent_start_long_holders_leave_room_for_a_hook_and_a_typed_command() {
    let daemon = Daemon::start("long");
    let mut control = Control::open(&daemon.socket);
    for folder in ["held", "probe"] {
        fs::create_dir_all(daemon.dir.join(folder)).unwrap();
    }
    let probe = daemon.dir.join("probe");
    let context_gate = Gate::new(&probe, "gate-context");
    let prompt_gate = Gate::new(&probe, "gate-prompt");
    let typed_gate = Gate::new(&probe, "gate-typed");
    control.run_in_terminal("probe", &probe_script(&daemon.dir));
    let ready =
        wait_until(test_timeout(Duration::from_secs(30)), || probe.join("terminal").exists());
    assert!(ready, "setup: the probe's terminal did not start");
    let terminal = fs::read_to_string(probe.join("terminal")).unwrap();
    assert!(terminal.starts_with("term_"), "setup: the probe's terminal id is {terminal:?}");

    let wanted = u64::try_from(TERMINAL_LANE).unwrap();
    let streams = Holders::start(&daemon, &mut control, 0, TERMINAL_LANE);
    let first_error = Holders::first_error(&daemon, 0, TERMINAL_LANE).unwrap_or_default();
    assert_eq!(
        streams, wanted,
        "setup: the daemon opened {streams} of the {wanted} event streams; a holder said {first_error:?}"
    );
    let before = control.connections();
    eprintln!(
        "agent start long holders: {streams} event streams are open from {TERMINAL_LANE} \
         terminals; the daemon counts {} of {} connections; it refused {} so far; by kind {}",
        before.active,
        before.limit,
        before.refused,
        control.kinds()
    );
    assert_eq!(before.refused, 0, "setup: the daemon refused a holder: {first_error:?}");

    let context = Short::run(&daemon, &mut control, context_gate, "context");
    let prompt = Short::run(&daemon, &mut control, prompt_gate, "prompt");
    let typed = Short::run(&daemon, &mut control, typed_gate, "typed");

    // The holders still hold: no short request got its place from one that left.
    let still = control.connections();
    eprintln!(
        "agent start long holders: after the three requests the daemon counts {} of {} \
         connections and refused {}",
        still.active, still.limit, still.refused
    );
    let text = serde_json::from_str::<Value>(&context.printed)
        .ok()
        .and_then(|output| {
            output
                .pointer("/hookSpecificOutput/additionalContext")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_default();
    for short in [&context, &prompt, &typed] {
        assert_eq!(
            short.refused,
            0,
            "the daemon refused a short request of a terminal while {TERMINAL_LANE} other \
             terminals hold a long connection: {}",
            short.shown()
        );
        assert_eq!(short.exit, Some(0), "{}", short.shown());
        assert!(short.admitted >= 1, "setup: the request made no connection: {}", short.shown());
    }
    assert!(
        text.contains(&format!("terminal {terminal}."))
            && !text.contains("unknown")
            && !text.contains("not known"),
        "the start text must name each place and the other agents: {}",
        context.shown()
    );
    assert!(
        typed.printed.contains(&terminal),
        "the typed command must print its terminal: {}",
        typed.shown()
    );
    // The requests got in because the holders left the lane, not because the
    // daemon took the holders for outside connections (they would then stay
    // in the count of the short connections).
    assert!(
        still.active < u64::try_from(TERMINAL_LANE).unwrap(),
        "the holders must not be short connections: the daemon counts {} of them",
        still.active
    );
}

/// The daemon's thread count and descriptor count (Linux: `/proc`).
fn process_counts(daemon: &Daemon) -> String {
    let pid = daemon.child.id();
    let threads = fs::read_to_string(format!("/proc/{pid}/status")).ok().and_then(|status| {
        status
            .lines()
            .find_map(|line| line.strip_prefix("Threads:"))
            .map(|count| count.trim().to_owned())
    });
    let descriptors = fs::read_dir(format!("/proc/{pid}/fd")).ok().map(Iterator::count);
    match (threads, descriptors) {
        (Some(threads), Some(descriptors)) => {
            format!("the daemon has {threads} threads and {descriptors} descriptors")
        }
        _ => "the daemon's threads and descriptors are not counted on this system".to_owned(),
    }
}

/// The program of a terminal that asks for a long connection above the
/// bound, then makes a typed command. It keeps the exit code of each one.
fn over_the_bound_script(dir: &Path) -> String {
    format!(
        "D='{dir}/over'; \
         '{tui}' --jsonl session current events >\"$D/events.out\" 2>\"$D/events.err\"; \
         echo $? >\"$D/events.rc\"; \
         '{tui}' --json terminal \"$CMUX_TUI_TERMINAL_ID\" show \
            >\"$D/typed.out\" 2>\"$D/typed.err\"; \
         echo $? >\"$D/typed.rc.part\"; mv \"$D/typed.rc.part\" \"$D/typed.rc\"; \
         exec /bin/cat",
        dir = dir.display(),
        tui = env!("CARGO_BIN_EXE_cmux-tui"),
    )
}

/// The long connections of the terminals have a bound, because each one holds
/// a thread and a socket of the daemon until it ends. At the bound the daemon
/// refuses no connection: the request that asks for one more stream gets an
/// error that names the limit and what a person can do, and a typed command
/// of the same terminal is served.
#[test]
fn agent_start_long_holders_stop_at_their_bound_with_an_error_that_names_it() {
    let daemon = Daemon::start("bound");
    let mut control = Control::open(&daemon.socket);
    for folder in ["held", "over"] {
        fs::create_dir_all(daemon.dir.join(folder)).unwrap();
    }
    eprintln!("agent start long holders: with no terminal {}", process_counts(&daemon));

    // The holders start in groups smaller than the short lane: each one is a
    // short connection until its stream starts.
    let group = TERMINAL_LANE / 2;
    for first in (0..LONG_BOUND).step_by(group) {
        let last = (first + group).min(LONG_BOUND);
        let wanted = u64::try_from(last).unwrap();
        let streams = Holders::start(&daemon, &mut control, first, last);
        assert_eq!(
            streams,
            wanted,
            "the daemon opened {streams} of the first {wanted} event streams, each from its own \
             terminal: {LONG_BOUND} terminals must each get one; a holder said {:?}; by kind {}",
            Holders::first_error(&daemon, first, last).unwrap_or_default(),
            control.kinds()
        );
    }
    let full = control.connections();
    eprintln!(
        "agent start long holders: {LONG_BOUND} terminals each hold an event stream; the daemon \
         counts {} of {} short connections and refused {}; {}",
        full.active,
        full.limit,
        full.refused,
        process_counts(&daemon)
    );
    assert_eq!(full.refused, 0, "setup: the daemon refused a connection of a holder");
    let first_error = Holders::first_error(&daemon, 0, LONG_BOUND);
    assert_eq!(first_error, None, "setup: a holder below the bound got an error");
    assert!(
        full.active < u64::try_from(TERMINAL_LANE).unwrap(),
        "the holders must not be in the short lane: {} short connections are counted",
        full.active
    );

    let over = daemon.dir.join("over");
    control.run_in_terminal("over", &over_the_bound_script(&daemon.dir));
    let ended =
        wait_until(test_timeout(Duration::from_secs(60)), || over.join("typed.rc").exists());
    let file = |name: &str| fs::read_to_string(over.join(name)).unwrap_or_default();
    let said = format!("{} {}", file("events.out").trim(), file("events.err").trim());
    assert!(ended, "the terminal above the bound did not end its two commands: {said:?}");
    let after = control.connections();
    eprintln!(
        "agent start long holders: the stream above the bound: exit {:?}, it said {:?}; the typed \
         command after it: exit {:?}; the daemon admitted {} and refused {} connections; {}",
        file("events.rc").trim(),
        said.chars().take(600).collect::<String>(),
        file("typed.rc").trim(),
        after.accepted - full.accepted,
        after.refused - full.refused,
        process_counts(&daemon)
    );
    assert_ne!(file("events.rc").trim(), "0", "a stream above the bound must not start: {said:?}");
    assert!(
        said.contains(&format!("limit {LONG_BOUND}")) && said.contains("then try again"),
        "the error must name the limit and what a person can do: {said:?}"
    );
    assert_eq!(after.refused, 0, "the daemon must refuse no connection at the bound");
    assert_eq!(
        file("typed.rc").trim(),
        "0",
        "a typed command of the same terminal must be served: {:?}",
        file("typed.err")
    );
}
