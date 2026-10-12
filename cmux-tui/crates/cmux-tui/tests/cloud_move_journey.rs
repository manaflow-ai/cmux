//! Move to Cloud, end to end on one Linux box with real processes: a dirty
//! working copy and an agent chat go from a "Mac" daemon to a daemon shaped
//! like a personal Cloud VM.
//!
//! - The Mac: a headless cmux-tui daemon whose own acpmux runs the test
//!   agent (`acpmux/tests/fake_agent.py`), with a chat that has a finished
//!   turn, a turn running, a queued prompt and a draft, bound to an agent tab
//!   of the daemon's store.
//! - The Cloud VM: a second headless daemon with its own acpmux, a HOME with
//!   `~/work`, the Cloud model plane identity (`CMUX_VM_ID`,
//!   `CMUX_CODEROUTER_URL`) and the Cloud records (image stamp, vm-kind
//!   `owner`) in a folder named by the debug-only `CMUX_TEST_CLOUD_ETC` seam
//!   (link/cloud_fs.rs, agent_start_host.rs), which stands in for the
//!   root-owned `/etc/cmux`.
//!
//! The journey runs the real CLI: `cmux link sync push` copies the folder with
//! its git state through the VM daemon's `fs-v1`, then `cmux link agent move`
//! pumps the chat between the two daemons' `agent-transfer-v1` verbs. Both
//! commands are given the VM daemon's own Unix socket, as the trusted local
//! client the Cloud link's `remote connect` bridge makes the app on the VM.
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

use std::fs;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");
const HISTORY: &str = "hello from the mac";
const QUEUED: &str = "queued for the cloud";
const QUEUED_ID: &str = "p-journey-queued";
const DRAFT: &str = "an unsent thought";

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// Polls `probe` until it answers, for up to `secs` seconds.
fn wait_until<T>(secs: u64, what: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(found) = probe() {
            return found;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
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

/// A working copy with a commit, an uncommitted change and an untracked file.
fn dirty_repo(at: &Path) -> PathBuf {
    let repo = at.join("app");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    fs::write(repo.join("src/lib.txt"), "committed\nuncommitted change\n").unwrap();
    fs::write(repo.join("notes.txt"), "untracked\n").unwrap();
    repo
}

/// One machine: a headless daemon and its own acpmux running the test agent.
struct Machine {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    /// The VM's extra environment (empty on the Mac).
    env: Vec<(&'static str, String)>,
}

impl Machine {
    fn start(root: &Path, name: &str, env: Vec<(&'static str, String)>) -> Self {
        let dir = root.join(name);
        for sub in ["home/work", "acpmux", "state"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
        // Agent session ids as long as a real agent's: a guarded receive
        // refuses a short one.
        let fake = json!({"argv": ["python3", FAKE_AGENT], "family": "fake",
                          "env": {"FAKE_SESSION_PREFIX": "fake-session-"}});
        let config = json!({"harnesses": {"fake": fake}, "defaultHarness": "fake"});
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

    fn home(&self) -> PathBuf {
        self.dir.join("home")
    }

    /// This binary with the machine's environment.
    fn command(&self) -> Command {
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

    fn server(&self, action: &str) -> Command {
        let mut command = self.command();
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }

    /// One request on the daemon's socket, answered (events skipped).
    fn rpc(&self, request: Value) -> Value {
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

    fn acpmux(&self) -> Acpmux {
        Acpmux::connect(&self.dir.join("acpmux/acpmux.sock"))
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = self.command().args(["acp", "daemon", "shutdown"]).output();
    }
}

/// A JSON-RPC connection to a machine's acpmux socket.
struct Acpmux {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Acpmux {
    fn connect(socket: &Path) -> Self {
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
    fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        id
    }

    /// The answer to request `id` (notifications and other answers skipped).
    fn answer(&mut self, id: u64) -> Value {
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

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        self.answer(id)
    }

    fn summary(&mut self, session: &str) -> Option<Value> {
        let sessions = self.call("_acpmux/sessions", json!({}));
        let list = sessions.get("sessions").unwrap_or(&sessions).as_array().cloned()?;
        list.into_iter().find(|s| s["sessionId"] == json!(session))
    }

    fn events(&mut self, session: &str) -> Vec<Value> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": session, "afterSeq": 0, "limit": 5000}));
        page["events"].as_array().cloned().unwrap_or_default()
    }
}

fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// How many `kind` records of `events` say `text` (at `pointer` of the record).
fn count(events: &[Value], kind: &str, pointer: &str, text: &str) -> usize {
    events
        .iter()
        .filter(|e| e["kind"] == kind && e["msg"].pointer(pointer) == Some(&json!(text)))
        .count()
}

const USER_TEXT: &str = "/text";
const AGENT_TEXT: &str = "/params/update/content/text";

/// The Mac's chat: a finished turn, a turn that waits for a cancel, a
/// prompt queued behind it and a draft. Answers its acpmux session id; the
/// connection stays open (the queued prompt's sender).
fn chat_with_history_draft_and_queue(acpmux: &mut Acpmux, cwd: &Path) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, HISTORY, "p-journey-history"));
    // A running turn keeps the next prompt in the queue until the move.
    acpmux.send("session/prompt", prompt(&session, "until-cancel", "p-journey-running"));
    wait_until(20, "the running turn", || {
        acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    acpmux.send("session/prompt", prompt(&session, QUEUED, QUEUED_ID));
    wait_until(20, "the queued prompt", || {
        acpmux.summary(&session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
    });
    acpmux.call("_acpmux/draft_set", json!({"sessionId": session, "text": DRAFT}));
    session
}

/// A Mac chat tab of `machine`'s store bound to acpmux chat `session`, as the
/// app files a chat of its own acpmux (`install:` host). A `registry:` tab is
/// a machine's own chat and binds only through agent-session-start (cx-k21v).
fn bound_agent_tab(machine: &Machine, session: &str) -> u64 {
    assert_eq!(machine.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let tab = machine.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": "install:cloud-move-journey", "session": session}}));
    assert_eq!(tab["ok"], true, "{tab}");
    let surface = tab["data"]["surface"].as_u64().unwrap();
    let source = machine.rpc(json!({"id": 4, "cmd": "agent-transfer-source", "surface": surface}));
    assert_eq!(source["data"]["session"], json!(session), "{source}");
    surface
}

/// The store id a `registry:` host names: `identify`'s `session_id`.
fn store_id(machine: &Machine) -> String {
    let identity = machine.rpc(json!({"id": 1, "cmd": "identify"}));
    identity["data"]["session_id"].as_str().unwrap().to_owned()
}

/// Move to Cloud's show on the machine the chat landed on: a tab of its own
/// store (`registry:` host) that names the moved session, created with
/// `new-conversation-tab`, whose `agent-transfer-source` names that session.
fn moved_chat_tab(machine: &Machine, session: &str) {
    let store = store_id(machine);
    assert_eq!(machine.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let tab = machine.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": format!("registry:{store}"), "session": session,
                          "harness": "fake"}}));
    assert_eq!(tab["ok"], true, "{tab}");
    let surface = tab["data"]["surface"].as_u64().unwrap();
    let source = machine.rpc(json!({"id": 4, "cmd": "agent-transfer-source", "surface": surface}));
    assert_eq!(source["data"]["session"], json!(session), "{source}");
}

/// The VM's Cloud records, as a Cloud image bake and a machine bind leave them.
fn cloud_etc(root: &Path) -> PathBuf {
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

fn run_json(command: &mut Command) -> (bool, Value) {
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().last().unwrap_or_default();
    let value = serde_json::from_str(line).unwrap_or_else(|_| {
        panic!("no JSON line: {stdout}{}", String::from_utf8_lossy(&output.stderr))
    });
    (output.status.success(), value)
}

#[test]
fn cloud_move_journey_moves_a_dirty_folder_and_its_chat_to_a_personal_cloud_vm() {
    // A socket path must stay under SUN_LEN: a short folder under /tmp.
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmj-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-cloud-move-journey".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );

    // 1. The dirty folder goes to the VM's ~/work with its git state.
    let repo = dirty_repo(&mac.home());
    let synced = vm.home().join("work/app");
    let (ok, summary) = run_json(
        Command::new(bin())
            .args(["link", "sync", "push", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && summary["ok"] == json!(true), "sync push: {summary}");
    assert!(synced.join(".git").is_dir(), "no repository on the VM");
    assert_eq!(
        fs::read_to_string(synced.join("src/lib.txt")).unwrap(),
        "committed\nuncommitted change\n"
    );
    assert_eq!(fs::read_to_string(synced.join("notes.txt")).unwrap(), "untracked\n");
    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&synced, &status), git(&repo, &status), "git status differs on the VM");
    assert_eq!(git(&synced, &["rev-parse", "HEAD"]), git(&repo, &["rev-parse", "HEAD"]));

    // 2. The chat moves, its running turn stopped for the move.
    let mut mac_acpmux = mac.acpmux();
    let session = chat_with_history_draft_and_queue(&mut mac_acpmux, &repo);
    let surface = bound_agent_tab(&mac, &session);
    let (ok, moved) = run_json(
        Command::new(bin())
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&vm.socket)
            .arg("--cwd")
            .arg(&synced)
            .arg("--interrupt")
            .arg("--state-dir")
            .arg(root.join("pump")),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved}");
    assert_eq!(moved["session_id"], json!(session), "{moved}");

    // 3. On the VM: the chat with its history and draft, in the synced
    // folder, and its queued prompt ran there exactly once.
    let mut vm_acpmux = vm.acpmux();
    let landed = wait_until(30, "the queued prompt's turn on the VM", || {
        let events = vm_acpmux.events(&session);
        let done =
            events.iter().any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID);
        done.then_some(events)
    });
    assert_eq!(count(&landed, "user_message", USER_TEXT, HISTORY), 1, "history: {landed:?}");
    assert_eq!(count(&landed, "agent_message_chunk", AGENT_TEXT, &format!("echo: {HISTORY}")), 1);
    // A second look later: nothing ran it again.
    std::thread::sleep(Duration::from_secs(2));
    let events = vm_acpmux.events(&session);
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 1, "{events:?}");
    assert_eq!(count(&events, "agent_message_chunk", AGENT_TEXT, &format!("echo: {QUEUED}")), 1);
    let runs = events
        .iter()
        .filter(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID)
        .count();
    assert_eq!(runs, 1, "the queued prompt's turns: {events:?}");
    let draft = vm_acpmux.call("_acpmux/draft_get", json!({"sessionId": session}));
    assert_eq!(draft["draft"], json!(DRAFT), "{draft}");
    let there = vm_acpmux.summary(&session).expect("the chat is on the VM");
    assert_eq!(there["cwd"], json!(fs::canonicalize(&synced).unwrap()), "{there}");
    assert_eq!(there["queued"].as_u64(), Some(0), "{there}");

    // 3b. The app's last step: the moved chat opens in a tab of the VM's
    // own store (`registry:<store id>`), which the VM daemon allows because
    // its own finish landed that chat.
    moved_chat_tab(&vm, &session);
    let foreign = vm.rpc(json!({"id": 5, "cmd": "new-conversation-tab",
        "agent_session": {"host": format!("registry:{}", store_id(&vm)),
                          "session": "fake-session-not-landed-here"}}));
    assert_eq!(foreign["error_code"], "conversation_tab.machine_mismatch", "{foreign}");

    // 4. On the Mac: the chat moved away, and its queued prompt never ran here.
    let left = mac_acpmux.summary(&session);
    assert!(left.as_ref().is_none_or(|s| s["status"] == "closed"), "still open: {left:?}");
    let events = mac_acpmux.events(&session);
    assert!(events.iter().any(|e| e["kind"] == "transferred"), "no transferred record");
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 0, "ran on the Mac too");
}

/// Removes the journey's folder once both machines have stopped.
struct Cleanup(PathBuf);

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
