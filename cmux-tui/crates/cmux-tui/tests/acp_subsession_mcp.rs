//! The sub-session tools (`cmux-subsessions`) of a chat whose acpmux daemon
//! runs from the cmux-tui binary, as on a cloud VM: the image ships only
//! `cmux-tui` (also linked as `cmux` and `acpmux`), and on Linux
//! `current_exe` resolves a link to `cmux-tui`. The daemon then writes the
//! MCP command as `<cmux-tui> acp subsession-mcp`; without `acp`, cmux-tui
//! never reaches acpmux and the agent's server fails to start.
//!
//! Each case starts a real daemon, starts a chat with the stand-in agent,
//! reads the `mcpServers` the agent got, then runs that command the way the
//! agent would and lists and calls its tools.
#![cfg(unix)]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::ffi::OsStr;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");

fn cmux_tui() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_cmux-tui"))
}

/// The binary a server command names, links and `..` resolved.
fn real(path: &str) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// A scratch machine: a home, an acpmux home with the stand-in agent as its
/// only harness, a trusted work folder and an empty agent tools bin folder
/// (no `cmux` server, so the sub-session server is listed on its own).
struct Machine {
    dir: PathBuf,
    /// The program and arguments before an acpmux command (`daemon start`).
    launcher: Vec<PathBuf>,
}

impl Machine {
    fn new(name: &str, launcher: impl FnOnce(&Path) -> Vec<PathBuf>) -> Self {
        let stamp =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        // Under /tmp: the daemon's socket path must stay short.
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-sub-{name}-{}-{stamp}", std::process::id()));
        for sub in ["home", "acpmux", "work", "no-bin"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
        let config = json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE_AGENT], "family": "fake"}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        });
        fs::write(dir.join("acpmux/config.json"), config.to_string()).unwrap();
        let work = fs::canonicalize(dir.join("work")).unwrap();
        let trust = json!({work.to_str().unwrap(): "trusted"});
        fs::write(dir.join("acpmux/trust.json"), trust.to_string()).unwrap();
        let launcher = launcher(&dir);
        Self { dir, launcher }
    }

    /// The hermetic environment of this machine's processes.
    fn env(&self, command: &mut Command) {
        daemon_env::apply(command, &self.dir, daemon_env::Agents::StandIn, &[]);
        command
            .env("HOME", self.dir.join("home"))
            .env("ACPMUX_HOME", self.dir.join("acpmux"))
            .env("CMUX_AGENT_TOOLS_BIN_DIR", self.dir.join("no-bin"));
    }

    /// `<launcher> <args>`, its output.
    fn acp(&self, args: &[&str]) -> std::process::Output {
        let mut command = Command::new(&self.launcher[0]);
        command.args(&self.launcher[1..]).args(args).stdin(Stdio::null());
        self.env(&mut command);
        command.output().unwrap()
    }

    /// Starts the daemon, starts a chat with the stand-in agent and returns
    /// the `mcpServers` its agent got.
    fn chat_servers(&self) -> Value {
        let started = self.acp(&["daemon", "start"]);
        assert!(
            started.status.success(),
            "daemon start: {}",
            String::from_utf8_lossy(&started.stderr)
        );
        let stream = UnixStream::connect(self.dir.join("acpmux/acpmux.sock")).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut acp = Rpc { reader: BufReader::new(stream), next: 1 };
        acp.call("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}}));
        let work = fs::canonicalize(self.dir.join("work")).unwrap();
        let created = acp.call(
            "session/new",
            json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}),
        );
        let session = created["result"]["sessionId"]
            .as_str()
            .unwrap_or_else(|| panic!("no chat: {created}"))
            .to_owned();
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "mcp"}]});
        let (reply, text) = acp.call_text("session/prompt", prompt);
        assert!(reply.get("error").is_none(), "{reply}");
        serde_json::from_str(&text).unwrap_or_else(|_| panic!("not a server list: {text}"))
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.acp(&["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// A line-delimited JSON-RPC connection (the daemon's socket or an MCP
/// server's stdio).
struct Rpc<R: std::io::Read + Write> {
    reader: BufReader<R>,
    next: u64,
}

impl<R: std::io::Read + Write> Rpc<R> {
    fn call(&mut self, method: &str, params: Value) -> Value {
        self.call_text(method, params).0
    }

    /// The answer to `method`, and the agent text streamed before it.
    fn call_text(&mut self, method: &str, params: Value) -> (Value, String) {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        let mut text = String::new();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "closed before {method}");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                return (message, text);
            }
            if let Some(t) = message.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                text.push_str(t);
            }
        }
    }
}

/// The child's stdin and stdout as one stream.
struct ChildPipes(std::process::ChildStdin, std::process::ChildStdout);

impl std::io::Read for ChildPipes {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.1.read(buf)
    }
}

impl Write for ChildPipes {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

/// Runs the chat's `cmux-subsessions` server as its agent would (only the
/// server's own env on top of the machine's), and checks it serves its tools
/// as that chat: `tools/list` has `start_session`, and `list_sessions`
/// reaches the daemon.
fn assert_subsession_server_runs(machine: &Machine, server: &Value) {
    let program = server["command"].as_str().unwrap();
    let args: Vec<&str> =
        server["args"].as_array().unwrap().iter().map(|a| a.as_str().unwrap()).collect();
    let mut command = Command::new(program);
    command.args(&args);
    machine.env(&mut command);
    for pair in server["env"].as_array().unwrap() {
        command.env(pair["name"].as_str().unwrap(), pair["value"].as_str().unwrap());
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| panic!("start {program} {args:?}: {e}"));
    let io = ChildPipes(child.stdin.take().unwrap(), child.stdout.take().unwrap());
    let mut mcp = Rpc { reader: BufReader::new(io), next: 1 };
    let init = mcp.call(
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {},
               "clientInfo": {"name": "test", "version": "0"}}),
    );
    assert_eq!(init["result"]["serverInfo"]["name"], "cmux-subsessions", "{init}");
    let listed = mcp.call("tools/list", json!({}));
    let names: Vec<&str> = listed["result"]["tools"]
        .as_array()
        .unwrap_or_else(|| panic!("{listed}"))
        .iter()
        .filter_map(|t| t["name"].as_str())
        .collect();
    assert!(names.contains(&"start_session"), "{names:?}");
    let call = mcp.call("tools/call", json!({"name": "list_sessions", "arguments": {}}));
    assert_eq!(call["result"]["isError"], false, "{call}");
    drop(mcp);
    let _ = child.kill();
    let _ = child.wait();
}

fn subsession_server(servers: &Value) -> Value {
    servers
        .as_array()
        .unwrap_or_else(|| panic!("{servers}"))
        .iter()
        .find(|s| s["name"] == "cmux-subsessions")
        .unwrap_or_else(|| panic!("no cmux-subsessions server: {servers}"))
        .clone()
}

/// `cmux-tui acp daemon start`: the daemon runs from cmux-tui under `acp`,
/// and so does its sub-session server.
#[test]
fn cmux_tui_daemon_gives_chats_a_subsession_server_that_starts() {
    let machine = Machine::new("acp", |_| vec![cmux_tui().to_owned(), PathBuf::from("acp")]);
    let server = subsession_server(&machine.chat_servers());
    let command = server["command"].as_str().unwrap();
    assert_eq!(real(command), real(cmux_tui().to_str().unwrap()), "{server}");
    assert_eq!(server["args"], json!(["acp", "subsession-mcp"]), "{server}");
    assert_subsession_server_runs(&machine, &server);
}

/// `acpmux daemon start` through a link named `acpmux`, as a cloud VM runs
/// it. On Linux the link resolves to cmux-tui, which needs `acp`; elsewhere
/// the link itself is the command and needs none.
#[test]
fn acpmux_link_daemon_gives_chats_a_subsession_server_that_starts() {
    let machine = Machine::new("link", |dir| {
        let link = dir.join("link-bin/acpmux");
        fs::create_dir_all(dir.join("link-bin")).unwrap();
        symlink(cmux_tui(), &link).unwrap();
        vec![link]
    });
    let server = subsession_server(&machine.chat_servers());
    let command = Path::new(server["command"].as_str().unwrap());
    let binary = real(cmux_tui().to_str().unwrap());
    if command.file_name() == Some(OsStr::new("acpmux")) {
        assert_eq!(server["args"], json!(["subsession-mcp"]), "{server}");
    } else {
        assert_eq!(real(command.to_str().unwrap()), binary, "{server}");
        assert_eq!(server["args"], json!(["acp", "subsession-mcp"]), "{server}");
    }
    #[cfg(target_os = "linux")]
    assert_eq!(command, binary, "Linux resolves the link: {server}");
    assert_subsession_server_runs(&machine, &server);
}
