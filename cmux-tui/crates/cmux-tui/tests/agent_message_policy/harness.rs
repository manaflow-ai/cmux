//! A real headless daemon for the agent message tests: its own socket and
//! state folder, a fake acpmux that names sessions' workspaces the way
//! acpmux's `_acpmux/info` does (`sessionEnv.CMUX_WORKSPACE_ID`, unix socket
//! only), takes prompts for those sessions (`session/prompt`, answered with
//! `_acpmux/prompt_accepted`, or held at a gate a test opens) and answers
//! `_acpmux/prompt_withdraw` as a test sets it (or holds it), and a clock file the daemon's debug build adds to its agent
//! message clock, so a test moves time instead of waiting.
// Shared by several test binaries; each uses a part of it.
#![allow(dead_code)]

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

/// The install key an owner daemon gets on `server ensure`, so one
/// connection can prove itself the cmux app (the `frontend` actor).
const KEY_HEX: &str = "4b1d2c3e5f60718293a4b5c6d7e8f901122334455667788990aabbccddeeff00";
const INSTALL: &str = "inst_agent_message_app";

static NEXT: AtomicU64 = AtomicU64::new(1);

fn unique(prefix: &str) -> String {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    format!("{prefix}-{}-{stamp}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Session id -> the `CMUX_WORKSPACE_ID` the fake acpmux reports for it.
type Sessions = Arc<Mutex<HashMap<String, String>>>;

/// What the fake acpmux was asked and how it answers a withdraw.
#[derive(Default)]
struct FakeAcpmux {
    /// `_acpmux/info` requests answered.
    lookups: AtomicU64,
    /// The session id of every `_acpmux/info` request, in order.
    looked_up: Mutex<Vec<String>>,
    /// The params of every `session/prompt`, in order.
    prompts: Mutex<Vec<Value>>,
    /// The params of every `_acpmux/prompt_withdraw`, in order.
    withdrawals: Mutex<Vec<Value>>,
    /// Session id -> the withdraw outcome it answers (`unsent`,
    /// `retracted`, `too_late`), `refuse:<reason>` for a refusal, or
    /// `hang-up` to close the connection unanswered; a session without one
    /// answers `withdraw.not_found`, and one the fake does not run (or a
    /// peer runs) answers, as acpmux does, `no session matches …`.
    outcomes: Mutex<HashMap<String, String>>,
    /// Sessions whose prompts wait, unanswered, until their gate opens.
    gates: Mutex<std::collections::HashSet<String>>,
    gate_opened: Condvar,
    /// Session id -> how many more prompts it refuses as moving
    /// (`transfer.moving`).
    moving: Mutex<HashMap<String, u32>>,
    /// Session id -> how many more prompts it takes without a word (never
    /// accepted, never answered).
    silent: Mutex<HashMap<String, u32>>,
    /// Sessions a peer daemon runs: `_acpmux/info` and prompts reach them,
    /// but a withdraw is answered on this daemon only (`no session matches …`).
    peers: Mutex<std::collections::HashSet<String>>,
    /// Peer sessions whose peer daemon is unreachable: after one prompt went
    /// out, a forwarded `_acpmux/info` fails (-32603).
    unreachable_peers: Mutex<std::collections::HashSet<String>>,
    /// Sessions whose withdraws wait, unanswered, until released.
    withdraw_gates: Mutex<std::collections::HashSet<String>>,
    withdraw_gate_opened: Condvar,
    /// acpmux still reads its chat logs after a restart: an `_acpmux/info`
    /// that waits for them (any without `waitLogs: false`) gets no answer, as
    /// on a large log store that takes longer than its caller waits.
    reading_logs: std::sync::atomic::AtomicBool,
}

pub struct Daemon {
    child: Option<Child>,
    /// The session name of a daemon `server ensure` started with an install
    /// key; `None` for a plain `--headless` daemon.
    owner: Option<String>,
    pub socket: PathBuf,
    pub state: PathBuf,
    pub dir: PathBuf,
    clock: PathBuf,
    env: Vec<(String, String)>,
    sessions: Sessions,
    fake: Arc<FakeAcpmux>,
}

impl Daemon {
    /// A daemon with a fake acpmux and `env` (for example the
    /// cross-workspace setting).
    pub fn start(name: &str, env: &[(&str, &str)]) -> Self {
        Self::start_with(name, env, true)
    }

    /// A daemon whose acpmux socket has nobody listening.
    pub fn start_without_acpmux(name: &str, env: &[(&str, &str)]) -> Self {
        Self::start_with(name, env, false)
    }

    /// A daemon `server ensure` starts with an install key, so [`Self::app`]
    /// can prove a connection as the cmux app. No acpmux listens.
    pub fn start_owner(name: &str) -> Self {
        Self::start_owner_with(name, &[], false)
    }

    /// [`Self::start_owner`] with a fake acpmux.
    pub fn start_owner_with_acpmux(name: &str) -> Self {
        Self::start_owner_with(name, &[], true)
    }

    /// [`Self::start_owner`] with `env` and, when `acpmux`, a fake acpmux:
    /// a daemon on which [`Self::acp_credential`] can mint.
    pub fn start_owner_with(name: &str, env: &[(&str, &str)], acpmux: bool) -> Self {
        let mut daemon = Self::prepare(name, env, acpmux);
        daemon.owner = Some(unique("amp-owner"));
        daemon.spawn();
        daemon
    }

    fn start_with(name: &str, env: &[(&str, &str)], acpmux: bool) -> Self {
        let mut daemon = Self::prepare(name, env, acpmux);
        daemon.spawn();
        daemon
    }

    fn prepare(name: &str, env: &[(&str, &str)], acpmux: bool) -> Self {
        let dir = PathBuf::from("/tmp").join(unique(&format!("cmux-amp-{name}")));
        fs::create_dir_all(&dir).unwrap();
        let clock = dir.join("clock");
        fs::write(&clock, "0").unwrap();
        let sessions: Sessions = Arc::default();
        let fake = Arc::new(FakeAcpmux::default());
        if acpmux {
            serve_fake_acpmux(&dir.join("acpmux.sock"), sessions.clone(), fake.clone());
        }
        Self {
            child: None,
            owner: None,
            socket: dir.join("mux.sock"),
            state: dir.join("state"),
            clock,
            env: env.iter().map(|(key, value)| ((*key).to_owned(), (*value).to_owned())).collect(),
            sessions,
            fake,
            dir,
        }
    }

    fn spawn(&mut self) {
        let _ = fs::remove_file(&self.socket);
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        match &self.owner {
            Some(session) => {
                command
                    .args(["server", "ensure", "--json", "--install-key-stdin", "--session"])
                    .arg(session)
                    .arg("--socket")
                    .arg(&self.socket)
                    .env("CMUX_TUI_STATE_DIR", &self.state);
            }
            None => {
                command
                    .args(["--headless", "--socket"])
                    .arg(&self.socket)
                    .arg("--state")
                    .arg(&self.state);
            }
        }
        command
            .env("HOME", &self.dir)
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("ACPMUX_SOCKET", self.dir.join("acpmux.sock"))
            .env("CMUX_TUI_TEST_AGENT_MESSAGE_CLOCK_FILE", &self.clock)
            .env_remove("CMUX_AGENT_MESSAGE_CROSS_WORKSPACE")
            .env_remove("CMUX_LAUNCH_CREDENTIAL")
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env_remove("SSH_TTY")
            .envs(self.env.iter().map(|(key, value)| (key.as_str(), value.as_str())))
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if self.owner.is_some() {
            let mut child = command.stdin(Stdio::piped()).spawn().unwrap();
            let key = format!("cmuxik1 {INSTALL} {KEY_HEX}\n");
            child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
            assert!(child.wait().unwrap().success(), "server ensure failed");
        } else {
            self.child = Some(command.spawn().unwrap());
        }
        let deadline = Instant::now() + Duration::from_secs(20);
        while UnixStream::connect(&self.socket).is_err() {
            assert!(
                Instant::now() < deadline,
                "the daemon made no socket {}",
                self.socket.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// Stops the daemon (SIGKILL: no shutdown path runs) and starts a new
    /// one on the same state, clock and fake acpmux.
    pub fn restart(&mut self) {
        self.stop();
        self.spawn();
    }

    /// Ends the daemon process this test started.
    pub fn stop(&mut self) {
        if let Some(session) = &self.owner {
            let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
                .args(["server", "stop", "--json", "--session", session, "--socket"])
                .arg(&self.socket)
                .env("CMUX_TUI_STATE_DIR", &self.state)
                .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
                .output();
        }
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Moves the daemon's agent message clock `ms` milliseconds ahead of now.
    pub fn set_clock_offset(&self, ms: i64) {
        fs::write(&self.clock, ms.to_string()).unwrap();
    }

    /// The fake acpmux reports `session` as running in `workspace_key`.
    pub fn place_session(&self, session: &str, workspace_key: &str) {
        self.sessions.lock().unwrap().insert(session.to_owned(), uuid_form(workspace_key));
    }

    /// How many `_acpmux/info` requests the fake acpmux has answered.
    pub fn acpmux_lookups(&self) -> u64 {
        self.fake.lookups.load(Ordering::SeqCst)
    }

    /// How many `_acpmux/info` requests named `session`.
    pub fn lookups_of(&self, session: &str) -> usize {
        self.fake.looked_up.lock().unwrap().iter().filter(|s| *s == session).count()
    }

    /// The fake acpmux reads its chat logs from now on and never finishes
    /// ([`FakeAcpmux::reading_logs`]).
    pub fn reading_chat_logs(&self) {
        self.fake.reading_logs.store(true, Ordering::SeqCst);
    }

    /// The fake acpmux no longer knows `session` (it was deleted).
    pub fn delete_session(&self, session: &str) {
        self.sessions.lock().unwrap().remove(session);
    }

    /// `session` runs on a peer daemon in `workspace_key`: acpmux forwards
    /// its `_acpmux/info` and prompts there, but not a withdraw.
    pub fn place_peer_session(&self, session: &str, workspace_key: &str) {
        self.fake.peers.lock().unwrap().insert(session.to_owned());
        self.place_session(session, workspace_key);
    }

    /// [`Self::place_peer_session`] whose peer daemon becomes unreachable
    /// once a prompt went out: a forwarded `_acpmux/info` then fails with
    /// an error other than `no session matches`.
    pub fn place_unreachable_peer_session(&self, session: &str, workspace_key: &str) {
        self.fake.unreachable_peers.lock().unwrap().insert(session.to_owned());
        self.place_peer_session(session, workspace_key);
    }

    /// The params of every prompt the fake acpmux took, in order.
    pub fn prompts(&self) -> Vec<Value> {
        self.fake.prompts.lock().unwrap().clone()
    }

    /// The params of every withdraw the fake acpmux was asked, in order.
    pub fn withdrawals(&self) -> Vec<Value> {
        self.fake.withdrawals.lock().unwrap().clone()
    }

    /// The fake acpmux answers a withdraw on `session` with `outcome`.
    pub fn withdraw_answers(&self, session: &str, outcome: &str) {
        self.fake.outcomes.lock().unwrap().insert(session.to_owned(), outcome.to_owned());
    }

    /// `session`'s prompts wait, unanswered, until [`Self::open_gate`].
    pub fn gate(&self, session: &str) {
        self.fake.gates.lock().unwrap().insert(session.to_owned());
    }

    /// `session` refuses its next `count` prompts as moving to another
    /// machine (`transfer.moving`).
    pub fn moving(&self, session: &str, count: u32) {
        self.fake.moving.lock().unwrap().insert(session.to_owned(), count);
    }

    /// `session` never accepts or answers its next `count` prompts.
    pub fn silent(&self, session: &str, count: u32) {
        self.fake.silent.lock().unwrap().insert(session.to_owned(), count);
    }

    /// `session`'s withdraws wait, unanswered, until [`Self::release_withdraws`].
    pub fn hold_withdraws(&self, session: &str) {
        self.fake.withdraw_gates.lock().unwrap().insert(session.to_owned());
    }

    /// The withdraws waiting for `session` go on.
    pub fn release_withdraws(&self, session: &str) {
        self.fake.withdraw_gates.lock().unwrap().remove(session);
        self.fake.withdraw_gate_opened.notify_all();
    }

    /// The prompts waiting at `session`'s gate go on.
    pub fn open_gate(&self, session: &str) {
        self.fake.gates.lock().unwrap().remove(session);
        self.fake.gate_opened.notify_all();
    }

    /// The listed message `id` once `done` holds for it (20 s at most).
    pub fn wait_for(&self, id: &str, what: &str, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let found = self.list(json!({"limit": 1000})).into_iter().find(|m| m["id"] == id);
            if let Some(message) = found {
                if done(&message) {
                    return message;
                }
                assert!(Instant::now() < deadline, "{what} never happened: {message}");
            } else {
                assert!(Instant::now() < deadline, "{id} is not listed");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// One `cmux.protocol/2` request on a new connection; `extra` adds
    /// envelope members (a credential, an idempotency key).
    pub fn v2(&self, operation: &str, params: Value, extra: Value) -> Value {
        let id = format!("r{}", NEXT.fetch_add(1, Ordering::Relaxed));
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        for (key, value) in extra.as_object().into_iter().flatten() {
            request[key] = value.clone();
        }
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == id {
                return value;
            }
        }
    }

    /// A connection proven as the cmux app (an owner daemon only).
    pub fn app(&self) -> App {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut app = App { reader: BufReader::new(stream) };
        let challenge = app.request(json!({"cmd": "client-hello", "role": "main",
            "install_id": INSTALL}));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL, &nonce);
        let proved =
            app.request(json!({"cmd": "client-hello", "install_id": INSTALL, "proof": proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        app
    }

    /// A mutation with a fresh idempotency key, as `credential`'s holder
    /// (the person without one).
    pub fn mutate(&self, operation: &str, params: Value, credential: Option<&str>) -> Value {
        self.mutate_keyed(operation, params, credential, &unique("key"))
    }

    /// [`Self::mutate`] under the idempotency key `key`.
    pub fn mutate_keyed(
        &self,
        operation: &str,
        params: Value,
        credential: Option<&str>,
        key: &str,
    ) -> Value {
        let mut extra = json!({"idempotency_key": key});
        if let Some(credential) = credential {
            extra["credential"] = json!(credential);
        }
        self.v2(operation, params, extra)
    }

    /// `agent.message.send`.
    pub fn send(&self, credential: Option<&str>, fields: Value) -> Value {
        self.mutate("agent.message.send", fields, credential)
    }

    /// The stored message a send answered with.
    pub fn sent(&self, credential: Option<&str>, fields: Value) -> Value {
        let reply = self.send(credential, fields);
        assert_eq!(reply["ok"], true, "the send was refused: {reply}");
        reply["result"]["value"].clone()
    }

    /// `agent.message.list` with `filter`.
    pub fn list(&self, filter: Value) -> Vec<Value> {
        let reply = self.v2("agent.message.list", filter, json!({}));
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].as_array().unwrap().clone()
    }

    /// A launch credential for the ACP session `session`, minted on a
    /// connection proven as the cmux app: only the verified frontend mints
    /// (an owner daemon only, [`Self::start_owner_with`]).
    pub fn acp_credential(&self, session: &str) -> String {
        let minted = self.app().call("credential.mint", json!({"acp_session": session}));
        assert_eq!(minted["ok"], true, "{minted}");
        minted["result"]["credential"].as_str().unwrap().to_owned()
    }

    /// `cmux --json <args>` against this daemon.
    pub fn cli(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--json")
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_LAUNCH_CREDENTIAL")
            .env_remove("ACPMUX_SESSION_ID")
            .output()
            .unwrap()
    }

    /// `cmux --json <args>` started against this daemon and its acpmux, as
    /// `credential`'s holder; the caller waits for it.
    pub fn cli_started(&self, args: &[&str], credential: &str) -> Child {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--json")
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .env("LC_ALL", "C")
            .env("ACPMUX_SOCKET", self.dir.join("acpmux.sock"))
            .env("CMUX_TUI_SOCKET", &self.socket)
            .env("CMUX_LAUNCH_CREDENTIAL", credential)
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("ACPMUX_SESSION_ID")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }

    /// `cmux --json <args>` that must succeed; its JSON output.
    pub fn cli_ok(&self, args: &[&str]) -> Value {
        let output = self.cli(args);
        assert!(
            output.status.success(),
            "cmux {args:?} failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    /// A new workspace: its public id and its key.
    pub fn workspace(&self, name: &str) -> (String, String) {
        let created = self.cli_ok(&["workspace", "create", "--name", name]);
        let id = created["value"]["workspace_id"].as_str().unwrap().to_owned();
        let listed = self.legacy(json!({"id": 1, "cmd": "list-workspaces"})).unwrap();
        let key = listed["data"]["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["resource_id"] == id.as_str())
            .and_then(|workspace| workspace["key"].as_str())
            .unwrap_or_else(|| panic!("no key for {id}: {listed}"))
            .to_owned();
        (id, key)
    }

    /// A terminal in `workspace` that runs `script` (with `sh -c`) and
    /// stays open.
    pub fn terminal(&self, workspace: &str, script: &str) -> String {
        let run = self.cli_ok(&[
            "workspace",
            workspace,
            "run",
            "--on-exit",
            "keep",
            "--",
            "/bin/sh",
            "-c",
            script,
        ]);
        run["value"]["terminal_id"].as_str().unwrap().to_owned()
    }

    /// A terminal in `workspace` whose child writes its launch credential to
    /// a file and then runs `then` (a shell command); its id and credential.
    pub fn agent_terminal(&self, workspace: &str, then: &str) -> (String, String) {
        let out = self.dir.join(unique("credential"));
        let script = format!(
            "printf %s \"$CMUX_LAUNCH_CREDENTIAL\" > '{0}.tmp' && mv '{0}.tmp' '{0}'; {then}; \
             exec sleep 600",
            out.display()
        );
        let terminal = self.terminal(workspace, &script);
        let credential = wait_for_file(&out);
        assert!(credential.starts_with("cmuxlc1."), "the terminal child got no launch credential");
        (terminal, credential)
    }

    /// The session registry, for a test that edits it while the daemon is down.
    pub fn registry(&self) -> PathBuf {
        let mut pending = vec![self.state.clone()];
        while let Some(dir) = pending.pop() {
            for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
                    return path;
                }
                if path.is_dir() {
                    pending.push(path);
                }
            }
        }
        panic!("no workspace registry under {}", self.state.display());
    }

    /// One legacy request on a new connection.
    fn legacy(&self, request: Value) -> Option<Value> {
        let stream = UnixStream::connect(&self.socket).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(30))).ok()?;
        let mut reader = BufReader::new(stream);
        writeln!(reader.get_mut(), "{request}").ok()?;
        let mut line = String::new();
        reader.read_line(&mut line).ok()?;
        serde_json::from_str(&line).ok()
    }

    /// Closes every workspace and ends its terminals (terminal hosts
    /// outlive the daemon).
    fn close_workspaces(&self) {
        let tree = self.legacy(json!({"id": 1, "cmd": "list-workspaces"}));
        for workspace in
            tree.iter().flat_map(|tree| tree["data"]["workspaces"].as_array()).flatten()
        {
            let _ = self.legacy(
                json!({"id": 2, "cmd": "close-workspace", "key": workspace["key"], "end_terminals": true}),
            );
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.close_workspaces();
        self.stop();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub fn wait_for_file(path: &Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Ok(text) = fs::read_to_string(path) {
            return text;
        }
        assert!(Instant::now() < deadline, "{} never appeared", path.display());
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The uppercase 8-4-4-4-12 form the app hands sessions (`uuidForm`).
fn uuid_form(key: &str) -> String {
    let hex: String = key.chars().filter(|ch| *ch != '-').collect::<String>().to_uppercase();
    if hex.len() != 32 || !hex.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return key.to_owned();
    }
    [&hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]].join("-")
}

/// A unix socket that answers `_acpmux/info` and takes prompts for the
/// sessions in `sessions`, answers withdraws as `fake` says, and an error
/// for anything else.
fn serve_fake_acpmux(socket: &Path, sessions: Sessions, fake: Arc<FakeAcpmux>) {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let sessions = sessions.clone();
            let fake = fake.clone();
            std::thread::spawn(move || answer(stream, &sessions, &fake));
        }
    });
}

fn answer(stream: UnixStream, sessions: &Sessions, fake: &FakeAcpmux) {
    let Ok(mut writer) = stream.try_clone() else { return };
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let Ok(line) = line else { return };
        let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = request.get("id").cloned() else { continue };
        let params = &request["params"];
        let session = params["sessionId"].as_str().unwrap_or_default();
        let workspace = sessions.lock().unwrap().get(session).cloned();
        let error = |code: i64, message: &str, reason: Value| {
            json!({"jsonrpc": "2.0", "id": id,
                "error": {"code": code, "message": message, "data": {"reason": reason}}})
        };
        let reply = match (request["method"].as_str(), workspace) {
            (Some("_acpmux/info"), workspace) => {
                fake.lookups.fetch_add(1, Ordering::SeqCst);
                fake.looked_up.lock().unwrap().push(session.to_owned());
                if fake.reading_logs.load(Ordering::SeqCst) && params["waitLogs"] != json!(false) {
                    continue;
                }
                let prompted =
                    fake.prompts.lock().unwrap().iter().any(|p| p["sessionId"] == session);
                let unreachable =
                    prompted && fake.unreachable_peers.lock().unwrap().contains(session);
                match workspace {
                    Some(_) if unreachable => json!({"jsonrpc": "2.0", "id": id, "error":
                        {"code": -32603, "message": "peer daemon unreachable"}}),
                    Some(workspace) => json!({"jsonrpc": "2.0", "id": id, "result":
                        {"sessionId": session, "sessionEnv": {"CMUX_WORKSPACE_ID": workspace}}}),
                    // acpmux's session lookup (`Hub::resolve`), with no `data`.
                    None => json!({"jsonrpc": "2.0", "id": id, "error":
                        {"code": -32002, "message": format!("no session matches {session:?}")}}),
                }
            }
            (Some("session/prompt"), Some(_)) => {
                fake.prompts.lock().unwrap().push(params.clone());
                let mut silent = fake.silent.lock().unwrap();
                let left = silent.get_mut(session).filter(|left| **left > 0);
                if left.map(|left| *left -= 1).is_some() {
                    continue;
                }
                drop(silent);
                let mut gates = fake.gates.lock().unwrap();
                while gates.contains(session) {
                    gates = fake.gate_opened.wait(gates).unwrap();
                }
                drop(gates);
                let mut moving = fake.moving.lock().unwrap();
                let left = moving.get_mut(session).filter(|left| **left > 0);
                let refuse = left.map(|left| *left -= 1).is_some();
                drop(moving);
                if refuse {
                    let reply = error(
                        -32000,
                        "transfer.moving: the session is moving",
                        json!("transfer.moving"),
                    );
                    if writeln!(writer, "{reply}").is_err() {
                        return;
                    }
                    continue;
                }
                let accepted = json!({"jsonrpc": "2.0", "method": "_acpmux/prompt_accepted",
                    "params": {"sessionId": session,
                        "promptId": params["_meta"]["acpmux"]["promptId"]}});
                if writeln!(writer, "{accepted}").is_err() {
                    return;
                }
                json!({"jsonrpc": "2.0", "id": id, "result": {"stopReason": "end_turn"}})
            }
            (Some("_acpmux/prompt_withdraw"), workspace) => {
                fake.withdrawals.lock().unwrap().push(params.clone());
                let mut held = fake.withdraw_gates.lock().unwrap();
                while held.contains(session) {
                    held = fake.withdraw_gate_opened.wait(held).unwrap();
                }
                drop(held);
                let msg_id = params["msgId"].clone();
                let outcome = fake.outcomes.lock().unwrap().get(session).cloned();
                match outcome.as_deref() {
                    // acpmux's session lookup (`Hub::resolve`), with no `data`.
                    _ if workspace.is_none() || fake.peers.lock().unwrap().contains(session) => {
                        json!({"jsonrpc": "2.0", "id": id, "error":
                        {"code": -32002, "message": format!("no session matches {session:?}")}})
                    }
                    Some("hang-up") => return,
                    Some(refusal) if refusal.starts_with("refuse:") => {
                        let reason = refusal.trim_start_matches("refuse:");
                        error(-32602, &format!("{reason}: refused"), json!(reason))
                    }
                    Some(outcome) => json!({"jsonrpc": "2.0", "id": id, "result": {
                        "sessionId": session, "outcome": outcome, "promptId": msg_id,
                        "msgId": msg_id}}),
                    None => error(
                        -32602,
                        "withdraw.not_found: no such prompt",
                        json!("withdraw.not_found"),
                    ),
                }
            }
            _ => json!({"jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": "not served by this fake"}}),
        };
        if writeln!(writer, "{reply}").is_err() {
            return;
        }
    }
}

/// The delivery of `recipient` in a message snapshot.
pub fn delivery<'a>(message: &'a Value, recipient: &str) -> &'a Value {
    message["deliveries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|delivery| delivery["recipient"] == recipient)
        .unwrap_or_else(|| panic!("no delivery to {recipient}: {message}"))
}

/// The `(code, details.reason)` of a refused reply.
pub fn refusal(reply: &Value) -> (String, String) {
    assert_eq!(reply["ok"], false, "expected a refusal: {reply}");
    (
        reply["error"]["code"].as_str().unwrap_or_default().to_owned(),
        reply["error"]["details"]["reason"].as_str().unwrap_or_default().to_owned(),
    )
}

/// One connection proven as the cmux app (the `frontend` actor).
pub struct App {
    reader: BufReader<UnixStream>,
}

impl App {
    /// One request (legacy or `cmux.protocol/2`) and its response.
    fn request(&mut self, mut request: Value) -> Value {
        let id = format!("app{}", NEXT.fetch_add(1, Ordering::Relaxed));
        request["id"] = json!(id);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == id {
                return value;
            }
        }
    }

    /// A `cmux.protocol/2` request that is not a mutation (no idempotency key).
    pub fn call(&mut self, operation: &str, mut params: Value) -> Value {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        self.request(json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "operation": operation,
            "params": params,
        }))
    }

    /// A `cmux.protocol/2` mutation with a fresh idempotency key.
    pub fn mutate(&mut self, operation: &str, mut params: Value) -> Value {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        self.request(json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "operation": operation,
            "params": params,
            "idempotency_key": unique("key"),
        }))
    }

    /// A `cmux.protocol/2` mutation under `key`, as the holder of `credential` (the app sending
    /// for an ACP session it minted one for).
    pub fn mutate_as(
        &mut self,
        operation: &str,
        mut params: Value,
        credential: &str,
        key: &str,
    ) -> Value {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        self.request(json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "operation": operation,
            "params": params,
            "credential": credential,
            "idempotency_key": key,
        }))
    }
}
