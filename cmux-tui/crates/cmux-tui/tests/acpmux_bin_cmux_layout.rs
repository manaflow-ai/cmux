//! `ACPMUX_BIN` in the cmux layout (review 2 of #39020, B1). Under cmux the acpmux daemon runs
//! as `<cmux> acp daemon run`, and the app ships `bin/acpmux` as a link to `bin/cmux`. Each
//! agent gets `ACPMUX_BIN` so that it runs the daemon's own acpmux CLI, not an older `acpmux` on
//! its PATH; the old-client refusal and the guide tell it to run `"$ACPMUX_BIN" send ...`. The
//! value must be one path that runs acpmux's CLI: `<cmux> send` is cmux's own (classic) verb and
//! fails.
//!
//! Each case starts a real daemon from the cmux-tui binary, starts a chat with the stand-in
//! agent, reads the `ACPMUX_BIN` its agent got, and runs `"$ACPMUX_BIN" send --help`.
#![cfg(unix)]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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

/// A scratch machine: a home and an acpmux home with the stand-in agent as its only harness.
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
            PathBuf::from("/tmp").join(format!("cmux-bin-{name}-{}-{stamp}", std::process::id()));
        for sub in ["home", "acpmux", "work"] {
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
        command.env("HOME", self.dir.join("home")).env("ACPMUX_HOME", self.dir.join("acpmux"));
    }

    /// `<launcher> <args>`, its output.
    fn acp(&self, args: &[&str]) -> std::process::Output {
        let mut command = Command::new(&self.launcher[0]);
        command.args(&self.launcher[1..]).args(args).stdin(Stdio::null());
        self.env(&mut command);
        command.output().unwrap()
    }

    /// Starts the daemon and a chat with the stand-in agent; the `ACPMUX_BIN` its agent got.
    fn agents_bin(&self) -> String {
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
        let prompt =
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "envs: ACPMUX_BIN"}]});
        let (reply, text) = acp.call_text("session/prompt", prompt);
        assert!(reply.get("error").is_none(), "{reply}");
        let env: Value =
            serde_json::from_str(&text).unwrap_or_else(|_| panic!("no environment: {text}"));
        let bin = env["ACPMUX_BIN"].as_str().unwrap_or_default().to_owned();
        assert!(!bin.is_empty(), "the agent has no ACPMUX_BIN: {env}");
        bin
    }

    /// Runs `"$ACPMUX_BIN" <args>` as an agent's shell does, with `ACPMUX_BIN` = `bin`.
    fn run_as_agent(&self, bin: &str, args: &[&str]) -> std::process::Output {
        let mut command = Command::new(bin);
        command.args(args).stdin(Stdio::null());
        self.env(&mut command);
        command.env("ACPMUX_BIN", bin).output().unwrap()
    }

    /// Where the daemon writes the wrapper script it names when no alias fits.
    fn wrapper(&self) -> PathBuf {
        self.dir.join("acpmux/bin/acpmux")
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.acp(&["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// A line-delimited JSON-RPC connection to the daemon's socket.
struct Rpc {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Rpc {
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

/// `ACPMUX_BIN` runs acpmux's own `send`: its help names the verb's own options.
fn assert_runs_acpmux_send(machine: &Machine, bin: &str) {
    let out = machine.run_as_agent(bin, &["send", "--help"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && stdout.contains("--no-wait"),
        "ACPMUX_BIN={bin} did not run acpmux send ({:?})\nstdout:\n{stdout}\nstderr:\n{}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// `cmux-tui acp daemon start`: the daemon runs from cmux-tui under `acp`, with no `acpmux`
/// alias of the same file beside it.
#[test]
fn w5s_acpmux_bin_runs_acpmux_when_the_daemon_runs_under_acp() {
    let machine = Machine::new("acp", |_| vec![cmux_tui().to_owned(), PathBuf::from("acp")]);
    let bin = machine.agents_bin();
    assert_runs_acpmux_send(&machine, &bin);
    // No `acpmux` beside cmux-tui is the same file: the daemon's own wrapper script.
    assert_eq!(Path::new(&bin), machine.wrapper(), "ACPMUX_BIN={bin}");
}

/// The app's layout: `bin/cmux`, and `bin/acpmux` a relative link to it
/// (`scripts/cmux-next/bundle-acpmux.sh`); the daemon runs as `bin/cmux acp daemon run`.
#[test]
fn w5s_acpmux_bin_runs_acpmux_in_the_apps_bin_layout() {
    let machine = Machine::new("app", |dir| {
        let bin = dir.join("app/bin");
        fs::create_dir_all(&bin).unwrap();
        symlink(cmux_tui(), bin.join("cmux")).unwrap();
        symlink("cmux", bin.join("acpmux")).unwrap();
        vec![bin.join("cmux"), PathBuf::from("acp")]
    });
    let bin = machine.agents_bin();
    assert_runs_acpmux_send(&machine, &bin);
    // The alias itself where the daemon's executable is the link (macOS); the wrapper where
    // `current_exe` resolved the link to cmux-tui (Linux).
    let alias = machine.dir.join("app/bin/acpmux");
    let bin = Path::new(&bin);
    assert!(bin == alias || bin == machine.wrapper(), "ACPMUX_BIN={}", bin.display());
}
