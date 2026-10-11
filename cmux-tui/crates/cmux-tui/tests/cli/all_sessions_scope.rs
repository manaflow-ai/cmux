//! `--all-sessions` at the CLI boundary (cx-4nar): two real headless
//! sessions share one runtime directory, as the tagged apps of one user do
//! on a shared host. A person's call lists both. An agent's call (an acpmux
//! session, a Chief turn) never reads another session: it gets
//! `origin.forbidden` and no records. A session owner an agent started,
//! detached (`server ensure`) or in the foreground (`--headless`), does not
//! pass the agent's variables to a person's terminal in it.

use super::*;

/// The variables that mark an agent caller; a test call starts without all of them.
const AGENT_MARKERS: &[&str] =
    &["ACPMUX_SESSION_ID", "CMUX_CHIEF_OWNER_SOCKET", "CMUX_AGENT_PRINCIPAL"];

/// The variables an acpmux agent or a Chief turn carries when it starts an
/// owner (`CMUX_CHIEF_OWNER_SOCKET` is added per owner: its own socket).
const AGENT_START_ENV: &[(&str, &str)] = &[
    ("ACPMUX_ENV", "1"),
    ("ACPMUX_SESSION_ID", "s_agent_owner"),
    ("ACPMUX_SESSION_NAME", "agent-owner"),
    ("CMUX_AGENT_PRINCIPAL", "agent_1a2b3c4d"),
];

/// Fields drop in order: both daemons stop (and close their resources over
/// their sockets) before [`BaseDir`] removes the directory.
struct TwoSessions {
    _alpha: HeadlessServer,
    _beta: HeadlessServer,
    base: BaseDir,
}

struct BaseDir(PathBuf);

impl Drop for BaseDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

impl TwoSessions {
    fn start() -> Self {
        let base = unique_temp_dir("all-sessions-scope");
        let runtime = cmux_tui_core::platform::runtime_dir_for_base(&base);
        fs::create_dir_all(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let alpha = Self::session(&base, &runtime, "alpha", &[]);
        let beta = Self::session(&base, &runtime, "beta", &[]);
        Self { _alpha: alpha, _beta: beta, base: BaseDir(base) }
    }

    fn runtime(&self) -> PathBuf {
        cmux_tui_core::platform::runtime_dir_for_base(&self.base.0)
    }

    /// A foreground headless owner `name` in `runtime`, started with only the
    /// `extra` caller variables, with one empty workspace.
    fn session(
        base: &std::path::Path,
        runtime: &std::path::Path,
        name: &str,
        extra: &[(&str, &std::ffi::OsStr)],
    ) -> HeadlessServer {
        let dir = base.join(format!("{name}-state"));
        fs::create_dir_all(&dir).unwrap();
        let socket = runtime.join(format!("{name}.sock"));
        let state = dir.join("state");
        let config = dir.join("config.json");
        let mut command = Command::new(bin());
        command
            .args(["--headless", "--session", name, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", &config);
        for key in AGENT_MARKERS {
            command.env_remove(key);
        }
        let child = command
            .envs(extra.iter().copied())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let server = HeadlessServer::adopt(child, socket, state, dir);
        server.wait_for_socket();
        // A bare headless daemon has no workspace; give each session one record to list.
        let created = Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&server.socket)
            .args(["workspace", "create", "--name", &format!("{name}-ws"), "--empty"])
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap();
        assert_success(&created);
        server
    }

    /// `cmux-tui --json workspace list --all-sessions` with this runtime
    /// directory and only the `extra` caller variables.
    fn list(&self, extra: &[(&str, &str)]) -> Output {
        let mut command = Command::new(bin());
        command
            .args(["--json", "workspace", "list", "--all-sessions"])
            .env("XDG_RUNTIME_DIR", &self.base.0)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        for key in AGENT_MARKERS {
            command.env_remove(key);
        }
        command.envs(extra.iter().copied());
        command.output().unwrap()
    }
}

/// A person types `--all-sessions` into terminal `terminal` of the owner at
/// `socket`. Returns what the shell's call printed and its exit status. The
/// shell writes the status into a FIFO; the test blocks on that FIFO, so it
/// waits on the shell's own completion and not on a timer.
fn person_lists_in_terminal(
    base: &std::path::Path,
    socket: &std::path::Path,
    terminal: &str,
    tag: &str,
) -> (String, String) {
    let out = base.join(format!("{tag}-list.json"));
    let fifo = base.join(format!("{tag}-list.status"));
    assert_success(&Command::new("mkfifo").arg(&fifo).output().unwrap());
    let (sender, receiver) = mpsc::channel();
    let reader_fifo = fifo.clone();
    std::thread::spawn(move || {
        let _ = sender.send(fs::read_to_string(&reader_fifo).unwrap_or_default());
    });
    let line = format!(
        "'{}' --json workspace list --all-sessions > '{}' 2>&1; echo $? > '{}'\n",
        bin(),
        out.display(),
        fifo.display()
    );
    let written = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(socket)
        .args(["terminal", terminal, "write", "--text", &line])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&written);
    let status = receiver.recv_timeout(Duration::from_secs(20)).unwrap_or_else(|_| {
        // Unblock the reader thread before failing; non-blocking, so a
        // reader that already left cannot hang this open.
        let _ = fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(&fifo);
        panic!("the shell in {terminal} did not finish its --all-sessions call");
    });
    (fs::read_to_string(&out).unwrap_or_default(), status)
}

/// The first terminal of the owner at `socket`, after creating a workspace there.
fn new_terminal(socket: &std::path::Path, workspace: &str) -> String {
    let cli = |args: &[&str]| {
        Command::new(bin())
            .args(["--json", "--socket"])
            .arg(socket)
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap()
    };
    assert_success(&cli(&["workspace", "create", "--name", workspace]));
    let terminals = json_output(&cli(&["terminal", "list"]));
    terminals[0]["id"].as_str().expect("the workspace has a terminal").to_owned()
}

fn assert_person_lists(listed: &str, status: &str, sessions: &[&str]) {
    for session in sessions {
        assert!(
            listed.contains(&format!("\"session\":\"{session}\"")),
            "a person's terminal in an agent-started owner must list {session} (exit {status}):\n{listed}"
        );
    }
    assert_eq!(status.trim(), "0", "{listed}");
}

fn names_session(output: &Output, session: &str) -> bool {
    String::from_utf8_lossy(&output.stdout).contains(&format!("\"session\":\"{session}\""))
}

#[test]
fn a_person_lists_every_own_session_and_an_agent_reads_no_other_session() {
    let sessions = TwoSessions::start();

    // A person (no agent marker) keeps today's behavior: both sessions.
    let person = sessions.list(&[]);
    assert_success(&person);
    assert!(
        names_session(&person, "alpha") && names_session(&person, "beta"),
        "a person's --all-sessions must list both sessions\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&person.stdout),
        String::from_utf8_lossy(&person.stderr)
    );

    // An acpmux agent, a Chief turn (its env names the owner daemon of
    // session alpha) and a tasks agent principal: refused, no records.
    let alpha_socket = cmux_tui_core::platform::runtime_dir_for_base(&sessions.base.0)
        .join("alpha.sock")
        .display()
        .to_string();
    for (key, value) in [
        ("ACPMUX_SESSION_ID", "s_chief_turn"),
        ("CMUX_CHIEF_OWNER_SOCKET", alpha_socket.as_str()),
        ("CMUX_AGENT_PRINCIPAL", "agent_1a2b3c4d"),
    ] {
        let agent = sessions.list(&[(key, value)]);
        assert!(
            !names_session(&agent, "alpha") && !names_session(&agent, "beta"),
            "{key}: an agent's --all-sessions must read no session\nstdout:\n{}",
            String::from_utf8_lossy(&agent.stdout)
        );
        assert_eq!(agent.status.code(), Some(1), "{key}: {agent:?}");
        let error = json_error(&agent);
        assert_eq!(error["code"], "origin.forbidden", "{key}: {error}");
        assert_eq!(error["details"]["reason"], "agent_caller", "{key}: {error}");
        assert_eq!(error["details"]["marker"], key, "{key}: {error}");
    }
}

/// A detached session owner that an agent started (`server ensure` with the
/// agent's variables). It stops at drop and ends its terminals.
struct AgentStartedOwner {
    socket: PathBuf,
    base: PathBuf,
}

impl AgentStartedOwner {
    fn ensure(base: &std::path::Path, name: &str) -> Self {
        let socket =
            cmux_tui_core::platform::runtime_dir_for_base(base).join(format!("{name}.sock"));
        let owner = Self { socket, base: base.to_path_buf() };
        let mut command = owner.server(name, "ensure");
        command.envs(AGENT_START_ENV.iter().copied()).env("CMUX_CHIEF_OWNER_SOCKET", &owner.socket);
        assert_success(&command.output().unwrap());
        owner
    }

    fn server(&self, name: &str, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", name, "--socket"])
            .arg(&self.socket)
            .env("XDG_RUNTIME_DIR", &self.base)
            .env("CMUX_TUI_STATE_DIR", self.base.join(format!("{name}-state")))
            .env("CMUX_TUI_CONFIG", self.base.join(format!("{name}-config.json")))
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        for key in AGENT_MARKERS {
            command.env_remove(key);
        }
        command
    }
}

impl Drop for AgentStartedOwner {
    fn drop(&mut self) {
        let _ = self.server("gamma", "stop").arg("--end-terminals").output();
    }
}

#[test]
fn a_person_terminal_in_an_owner_an_agent_started_lists_every_session() {
    let sessions = TwoSessions::start();
    let owner = AgentStartedOwner::ensure(&sessions.base.0, "gamma");

    // A person types in a terminal of that owner: its shell must not carry
    // the agent's variables, so --all-sessions lists every session.
    let terminal = new_terminal(&owner.socket, "gamma-ws");
    let (listed, status) =
        person_lists_in_terminal(&sessions.base.0, &owner.socket, &terminal, "detached");
    assert_person_lists(&listed, &status, &["alpha", "beta", "gamma"]);

    // An agent call still gets the refusal, now with three sessions there.
    let agent = sessions.list(&[("ACPMUX_SESSION_ID", "s_agent")]);
    assert_eq!(agent.status.code(), Some(1), "{agent:?}");
    assert_eq!(json_error(&agent)["code"], "origin.forbidden");
}

#[test]
fn a_person_terminal_in_a_foreground_owner_an_agent_started_lists_every_session() {
    let sessions = TwoSessions::start();
    // An agent runs `--headless` (the foreground owner `server start` also
    // runs) with its own variables; the Chief's names that owner's socket.
    let runtime = sessions.runtime();
    let socket = runtime.join("delta.sock");
    let mut agent_env: Vec<(&str, &std::ffi::OsStr)> =
        AGENT_START_ENV.iter().map(|(key, value)| (*key, std::ffi::OsStr::new(*value))).collect();
    agent_env.push(("CMUX_CHIEF_OWNER_SOCKET", socket.as_os_str()));
    // The shell's call finds the other sessions in this runtime directory.
    agent_env.push(("XDG_RUNTIME_DIR", sessions.base.0.as_os_str()));
    let _owner = TwoSessions::session(&sessions.base.0, &runtime, "delta", &agent_env);

    // A person's shell in that owner's terminal lists every session.
    let terminal = new_terminal(&socket, "delta-term");
    let (listed, status) =
        person_lists_in_terminal(&sessions.base.0, &socket, &terminal, "foreground");
    assert_person_lists(&listed, &status, &["alpha", "beta", "delta"]);

    // An agent call is still refused.
    let agent = sessions.list(&[("CMUX_AGENT_PRINCIPAL", "agent_1a2b3c4d")]);
    assert_eq!(agent.status.code(), Some(1), "{agent:?}");
    assert_eq!(json_error(&agent)["code"], "origin.forbidden");
}
