//! What the Cloud move journeys share: a machine (a headless cmux-tui
//! daemon with its own acpmux running the test agent), a JSON-RPC client of
//! its acpmux, and the Cloud records of a personal Cloud VM.
#![allow(dead_code)]

use std::fs;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

pub const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");

pub fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// Polls `probe` until it answers, for up to `secs` seconds.
pub fn wait_until<T>(secs: u64, what: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(found) = probe() {
            return found;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

pub fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=Journey", "-c", "user.email=journey@example.com"])
        .args(["-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap()
}

/// One machine: a headless daemon and its own acpmux running the test agent.
pub struct Machine {
    pub dir: PathBuf,
    pub socket: PathBuf,
    pub session: String,
    /// The VM's extra environment (empty on the Mac).
    pub env: Vec<(&'static str, String)>,
}

impl Machine {
    pub fn start(root: &Path, name: &str, env: Vec<(&'static str, String)>) -> Self {
        let dir = root.join(name);
        for sub in ["home/work", "acpmux", "state"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
        // Agent session ids as long as a real agent's: a guarded receive
        // refuses a short one.
        let fake = json!({"argv": ["python3", FAKE_AGENT], "family": "fake",
                          "env": {"FAKE_SESSION_PREFIX": "fake-session-"}});
        // The fake agent's `normal` mode asks: a chat moved back under the
        // Web's control must be in an asking mode.
        // `fake-approve` is the same agent under a profile that approves
        // everything: only the person's app may switch a chat to that, so a
        // test picks the profile when it starts the chat.
        let mut approving = fake.clone();
        approving["policy"] = json!("approve-all");
        let config = json!({"harnesses": {"fake": fake, "fake-approve": approving},
                            "defaultHarness": "fake",
                            "webAskingModes": {"fake": ["normal"]}});
        fs::write(dir.join("acpmux/config.json"), config.to_string()).unwrap();
        let machine = Self {
            socket: dir.join("mux.sock"),
            session: format!("cloud-move-journey-{name}"),
            dir,
            env,
        };
        let ensure = machine.server("ensure").output().unwrap();
        assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
        // acpmux runs on demand and a transfer does not start it: start it as
        // `cmux acp` does, with this machine's homes.
        let started = machine.command().args(["acp", "daemon", "start"]).output().unwrap();
        assert!(started.status.success(), "acp: {}", String::from_utf8_lossy(&started.stderr));
        machine
    }

    pub fn home(&self) -> PathBuf {
        self.dir.join("home")
    }

    /// This binary with the machine's environment.
    pub fn command(&self) -> Command {
        let mut command = Command::new(bin());
        command
            .env("HOME", self.home())
            .env("ACPMUX_HOME", self.dir.join("acpmux"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env_remove("ACPMUX_SOCKET")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_AGENT_START_HOST")
            .env_remove("CMUX_VM_ID")
            .env_remove("CMUX_CODEROUTER_URL")
            .env_remove("CMUX_TEST_CLOUD_ETC")
            .stdin(Stdio::null());
        for (key, value) in &self.env {
            command.env(key, value);
        }
        command
    }

    pub fn server(&self, action: &str) -> Command {
        let mut command = self.command();
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }

    /// One request on the daemon's socket, answered (events skipped).
    pub fn rpc(&self, request: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the daemon closed the connection");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message.get("event").is_none() {
                return message;
            }
        }
    }

    pub fn acpmux(&self) -> Acpmux {
        Acpmux::connect(&self.dir.join("acpmux/acpmux.sock"))
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = self.command().args(["acp", "daemon", "shutdown", "--end-agents"]).output();
    }
}

/// A JSON-RPC connection to a machine's acpmux socket.
pub struct Acpmux {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Acpmux {
    pub fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut acpmux = Self { reader: BufReader::new(stream), next: 1 };
        acpmux.call(
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "cloud-move-journey"}}),
        );
        acpmux
    }

    /// Sends a request and returns its id without waiting for the answer.
    pub fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        id
    }

    /// The answer to request `id` (notifications and other answers skipped).
    pub fn answer(&mut self, id: u64) -> Value {
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "acpmux closed the socket");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == json!(id) && message.get("method").is_none() {
                assert!(message.get("error").is_none(), "acpmux refused: {message}");
                return message["result"].clone();
            }
        }
    }

    pub fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        self.answer(id)
    }

    pub fn summary(&mut self, session: &str) -> Option<Value> {
        let sessions = self.call("_acpmux/sessions", json!({}));
        let list = sessions.get("sessions").unwrap_or(&sessions).as_array().cloned()?;
        list.into_iter().find(|s| s["sessionId"] == json!(session))
    }

    pub fn events(&mut self, session: &str) -> Vec<Value> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": session, "afterSeq": 0, "limit": 5000}));
        page["events"].as_array().cloned().unwrap_or_default()
    }
}

pub fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// How many `kind` records of `events` say `text` (at `pointer` of the record).
pub fn count(events: &[Value], kind: &str, pointer: &str, text: &str) -> usize {
    events
        .iter()
        .filter(|e| e["kind"] == kind && e["msg"].pointer(pointer) == Some(&json!(text)))
        .count()
}

pub const USER_TEXT: &str = "/text";
pub const AGENT_TEXT: &str = "/params/update/content/text";

/// A chat tab of `machine`'s store bound to acpmux chat `session`, as the app
/// files a chat of its own acpmux (`install:` host). A `registry:` tab is a
/// machine's own chat and binds only through agent-session-start (cx-k21v).
pub fn bound_agent_tab(machine: &Machine, session: &str) -> u64 {
    assert_eq!(machine.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let tab = machine.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": "install:cloud-move-journey", "session": session}}));
    assert_eq!(tab["ok"], true, "{tab}");
    let surface = tab["data"]["surface"].as_u64().unwrap();
    let source = machine.rpc(json!({"id": 4, "cmd": "agent-transfer-source", "surface": surface}));
    assert_eq!(source["data"]["session"], json!(session), "{source}");
    surface
}

/// The VM's Cloud records, as a Cloud image bake and a machine bind leave them.
pub fn cloud_etc(root: &Path) -> PathBuf {
    let etc = root.join("etc-cmux");
    fs::create_dir_all(&etc).unwrap();
    fs::write(etc.join("image-stamp"), "cmux-vm inputs=cloud-move-journey\n").unwrap();
    fs::write(etc.join("vm-kind"), "owner\n").unwrap();
    fs::set_permissions(&etc, fs::Permissions::from_mode(0o755)).unwrap();
    for file in ["image-stamp", "vm-kind"] {
        fs::set_permissions(etc.join(file), fs::Permissions::from_mode(0o644)).unwrap();
    }
    etc
}

pub fn run_json(command: &mut Command) -> (bool, Value) {
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().last().unwrap_or_default();
    let value = serde_json::from_str(line).unwrap_or_else(|_| {
        panic!("no JSON line: {stdout}{}", String::from_utf8_lossy(&output.stderr))
    });
    (output.status.success(), value)
}

/// Removes the journey's folder once both machines have stopped.
pub struct Cleanup(pub PathBuf);

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
