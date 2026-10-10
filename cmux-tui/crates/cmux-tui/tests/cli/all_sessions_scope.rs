//! `--all-sessions` at the CLI boundary (cx-4nar): two real headless
//! sessions share one runtime directory, as the tagged apps of one user do
//! on a shared host. A person's call lists both. An agent's call (an acpmux
//! session, a Chief turn) never reads another session: it gets
//! `origin.forbidden` and no records. A session owner an agent started
//! does not pass the agent's variables to a person's terminal in it.

use super::*;

/// The variables that mark an agent caller; a test call starts without all of them.
const AGENT_MARKERS: &[&str] =
    &["ACPMUX_SESSION_ID", "CMUX_CHIEF_OWNER_SOCKET", "CMUX_AGENT_PRINCIPAL"];

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
        let alpha = Self::session(&base, &runtime, "alpha");
        let beta = Self::session(&base, &runtime, "beta");
        Self { _alpha: alpha, _beta: beta, base: BaseDir(base) }
    }

    fn session(base: &std::path::Path, runtime: &std::path::Path, name: &str) -> HeadlessServer {
        let dir = base.join(format!("{name}-state"));
        fs::create_dir_all(&dir).unwrap();
        let socket = runtime.join(format!("{name}.sock"));
        let state = dir.join("state");
        let config = dir.join("config.json");
        let child = Command::new(bin())
            .args(["--headless", "--session", name, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", &config)
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
        command
            .env("ACPMUX_ENV", "1")
            .env("ACPMUX_SESSION_ID", "s_agent_owner")
            .env("ACPMUX_SESSION_NAME", "agent-owner")
            .env("CMUX_CHIEF_OWNER_SOCKET", &owner.socket)
            .env("CMUX_AGENT_PRINCIPAL", "agent_1a2b3c4d");
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

    fn cli(&self, args: &[&str]) -> Output {
        Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&self.socket)
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap()
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
    assert_success(&owner.cli(&["workspace", "create", "--name", "gamma-ws"]));
    let terminals = json_output(&owner.cli(&["terminal", "list"]));
    let terminal = terminals[0]["id"].as_str().expect("the workspace has a terminal").to_owned();
    let out = sessions.base.0.join("person-list.json");
    let done = sessions.base.0.join("person-list.done");
    let line = format!(
        "'{}' --json workspace list --all-sessions > '{}' 2>&1; echo $? > '{}.tmp' && mv '{}.tmp' '{}'\n",
        bin(),
        out.display(),
        done.display(),
        done.display(),
        done.display()
    );
    assert_success(&owner.cli(&["terminal", &terminal, "write", "--text", &line]));
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let listed = fs::read_to_string(&out).unwrap_or_default();
    let status = fs::read_to_string(&done).unwrap_or_default();
    for session in ["alpha", "beta", "gamma"] {
        assert!(
            listed.contains(&format!("\"session\":\"{session}\"")),
            "a person's terminal in an agent-started owner must list {session} (exit {status}):\n{listed}"
        );
    }
    assert_eq!(status.trim(), "0", "{listed}");

    // An agent call still gets the refusal, now with three sessions there.
    let agent = sessions.list(&[("ACPMUX_SESSION_ID", "s_agent")]);
    assert_eq!(agent.status.code(), Some(1), "{agent:?}");
    assert_eq!(json_error(&agent)["code"], "origin.forbidden");
}
