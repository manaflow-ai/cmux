//! RFD 0135 gate 4, first piece: the owner's phone chats with a Cloud machine with the Mac off.
//!
//! Leo: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet
//! wide pauses, esp when this is stuff that materially improves the app". The gate
//! (`scripts/cmux-next/rfd0135_gates.py phone`, PHONE_GATE_CMD) runs this test.
//!
//! A real headless cmux-tui daemon shaped like a personal Cloud VM (`journey_support`) runs its
//! own acpmux with a chat on it. Its real link serves `phone_chat` to the server's owner
//! (`server.json` `owner_session`). A second real link, the phone's, dials it with
//! `cmux link dial --service phone_chat` and speaks the phone's ACP on the stream: initialize,
//! the chat list, attach, a prompt (timed to the daemon's durable accept and to the agent's first
//! reply), and an action the relay does not carry. No Mac, no hostd: the VM and the phone only.
//! A paired peer that is not the owner is refused.
//!
//! Prints `GATE phone {json}`; `PHONE_GATE_OUT` also writes that JSON there.
//!
//! ```text
//! cargo test -p cmux-tui --test it -- --ignored --nocapture phone_direct_gate::
//! ```
#![cfg(target_os = "linux")]

use crate::journey_support;

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Output, Stdio};
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_server::pairing::{self, Transport};
use cmux_server_core::pairing::enrollment::{Begun, Paired, Waited, jwk_thumbprint};
use journey_support::*;
use serde_json::{Value, json};

const INSTALL: &str = "inst_00000000000000000001";
const OWNER_USER: &str = "user_00000000000000000001";
const STRANGER_USER: &str = "user_00000000000000000002";
const TEAM: &str = "team_00000000000000000001";
const NOW: u64 = 1_790_978_474_000;
const HISTORY: &str = "the turn before the phone";
const PHONE_TEXT: &str = "from the phone, the Mac off";

/// The pairing service, faked: the server's enrollment (as `paired_server_link.rs`).
#[derive(Default)]
struct Api {
    public: Mutex<Option<String>>,
}

impl Transport for Api {
    fn health(&self, _: &str) -> cmux_server::Result<Value> {
        Ok(json!({"environment":"staging"}))
    }

    fn begin(&self, _: &str, body: &Value) -> cmux_server::Result<Value> {
        *self.public.lock().unwrap() = Some(body["wg_public_key"].as_str().unwrap().into());
        Ok(json!({
            "code":"7KQ4M2XD", "expires_at":NOW+600_000,
            "thumbprint":jwk_thumbprint(&body["public_jwk"]).unwrap(),
            "collect_secret":"AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }))
    }

    fn wait(&self, _: &str, _: &Begun) -> cmux_server::Result<Waited> {
        Ok(Waited::Paired(Paired {
            host: "host_00000000000000000001".into(),
            team: TEAM.into(),
            user: OWNER_USER.into(),
            install: INSTALL.into(),
            machine_join: None,
        }))
    }
}

fn enrolled(home: &Path) -> (PathBuf, String) {
    let identity = home.join("pairing/identity.json");
    let api = Api::default();
    pairing::enroll(
        &identity,
        "https://api.example.test",
        json!({"name":"Phone gate VM","platform":"linux","os_version":"test","arch":"x86_64","cmux_version":"1.0.0"}),
        None,
        &api,
        NOW,
        |_| Ok(()),
    )
    .unwrap();
    let public = api.public.lock().unwrap().clone().unwrap();
    (identity, public)
}

fn cli(home: &Path, args: &[&str]) -> Command {
    let mut command = Command::new(bin());
    command
        .arg0("cmux")
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("TMPDIR", home)
        .env("LANG", "en_US.UTF-8")
        .env("CMUX_TUI_STATE_DIR", home.join("daemon"))
        .stdin(Stdio::null())
        .current_dir(home);
    command
}

/// The test's links (the VM's and two peers'), stopped when dropped, their logs shown on a failure.
struct Links {
    home: tempfile::TempDir,
    states: Vec<PathBuf>,
}

impl Links {
    fn state(&mut self, name: &str) -> PathBuf {
        let path = self.home.path().join(name).join("link");
        self.states.push(path.clone());
        path
    }

    fn run(&self, args: &[&str]) -> Output {
        cli(self.home.path(), args).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let out = self.run(args);
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        serde_json::from_slice(&out.stdout).unwrap()
    }

    fn add_peer(&self, state: &Path, install: &str, user: &str, public: &str, udp: &str) {
        let address: std::net::SocketAddr = udp.parse().unwrap();
        let endpoint = format!("[::1]:{}", address.port());
        let result = self.json(&[
            "link",
            "peer",
            "add",
            "--state-dir",
            state.to_str().unwrap(),
            "--install",
            install,
            "--user",
            user,
            "--team",
            TEAM,
            "--public-key",
            public,
            "--endpoint",
            &endpoint,
        ]);
        assert_eq!(result["reloaded"], true, "peer update did not reach the live mesh");
    }

    /// A peer link of the phone (or a stranger): `(init, live)`.
    fn peer(&mut self, name: &str, install: &str) -> (PathBuf, Value, Value) {
        let state = self.state(name);
        let init = self.json(&[
            "link",
            "init",
            "--state-dir",
            state.to_str().unwrap(),
            "--install",
            install,
            "--port",
            "0",
        ]);
        let live = self.json(&["link", "ensure", "--state-dir", state.to_str().unwrap()]);
        (state, init, live)
    }
}

impl Drop for Links {
    fn drop(&mut self) {
        if std::thread::panicking() {
            for state in &self.states {
                if let Ok(text) = std::fs::read_to_string(state.join("link.log")) {
                    eprintln!("{} link log:\n{text}", state.display());
                }
            }
        }
        for state in &self.states {
            if state.exists() {
                let _ = self.run(&["link", "stop", "--state-dir", state.to_str().unwrap()]);
            }
        }
    }
}

/// One `cmux link dial --service phone_chat`: the phone's stream.
struct Phone {
    child: Child,
    input: Option<ChildStdin>,
    lines: Receiver<Value>,
    next: u64,
}

impl Phone {
    /// Dials; the dial's own status line, and the phone when it connected.
    fn dial(links: &Links, socket: &str) -> (Value, Self) {
        let mut command = cli(
            links.home.path(),
            &["link", "dial", "--host", INSTALL, "--socket", socket, "--service", "phone_chat"],
        );
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = command.spawn().unwrap();
        let input = child.stdin.take();
        let mut status = BufReader::new(child.stderr.take().unwrap());
        let mut line = String::new();
        status.read_line(&mut line).unwrap();
        let dial: Value = serde_json::from_str(&line)
            .unwrap_or_else(|_| panic!("dial status is not JSON: {line:?}"));
        std::thread::spawn(move || {
            for line in status.lines().map_while(Result::ok) {
                eprintln!("phone dial: {line}");
            }
        });
        let stdout = child.stdout.take().unwrap();
        let (send, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    eprintln!("phone: not JSON: {line}");
                    continue;
                };
                if send.send(value).is_err() {
                    return;
                }
            }
        });
        (dial, Self { child, input, lines, next: 1 })
    }

    fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
        let input = self.input.as_mut().expect("phone input open");
        writeln!(input, "{request}").unwrap();
        input.flush().unwrap();
        id
    }

    /// The next line within `secs`; `None` at EOF or the deadline.
    fn next_line(&self, deadline: Instant) -> Option<Value> {
        let left = deadline.saturating_duration_since(Instant::now());
        match self.lines.recv_timeout(left) {
            Ok(value) => Some(value),
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => None,
        }
    }

    /// Lines until the answer to `id` (or the deadline): `(answer, notifications before it)`.
    fn answer(&self, id: u64, secs: u64, what: &str) -> (Value, Vec<Value>) {
        let deadline = Instant::now() + Duration::from_secs(secs);
        let mut seen = Vec::new();
        loop {
            let Some(line) = self.next_line(deadline) else {
                panic!("no answer to {what} within {secs}s; saw {seen:?}");
            };
            if line["id"] == json!(id) && line.get("method").is_none() {
                return (line, seen);
            }
            seen.push(line);
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        let (answer, _) = self.answer(id, 30, method);
        assert!(answer.get("error").is_none(), "{method} refused: {answer}");
        answer["result"].clone()
    }
}

impl Drop for Phone {
    fn drop(&mut self) {
        drop(self.input.take());
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The VM's acpmux with a Claude-family harness (the stand-in agent reporting Claude's modes),
/// asking by default: the phone may prompt only a chat in an asking mode under policy `ask`
/// (`cmux_cloud_phone_acp` `phone_prompt_mode`).
fn claude_family_acpmux(vm: &Machine) {
    let claude = json!({"argv": ["python3", FAKE_AGENT], "family": "claude",
        "env": {"FAKE_SESSION_PREFIX": "fake-session-", "FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"}});
    let config = json!({"harnesses": {"claude": claude},
                        "defaultHarness": "claude",
                        "permissionPolicy": "ask",
                        "defaultPermissionMode": "ask",
                        "webAskingModes": {"claude": ["default", "plan"]}});
    let path = vm.dir.join("acpmux/config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let stopped =
        vm.command().args(["acp", "daemon", "shutdown", "--end-agents"]).output().unwrap();
    assert!(stopped.status.success(), "acp stop: {}", String::from_utf8_lossy(&stopped.stderr));
    let started = vm.command().args(["acp", "daemon", "start"]).output().unwrap();
    assert!(started.status.success(), "acp start: {}", String::from_utf8_lossy(&started.stderr));
}

fn agent_reply(line: &Value) -> bool {
    line["method"] == "_acpmux/event"
        && line.to_string().contains(PHONE_TEXT)
        && line.to_string().contains("agent_message")
}

#[test]
#[ignore = "gate: run with --ignored --nocapture (PHONE_GATE_OUT)"]
fn phone_direct_gate_owner_phone_chats_with_a_cloud_machine_with_the_mac_off() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("phg-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-phone-gate".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    claude_family_acpmux(&vm);

    // A chat on the VM with a finished turn, in a tab of the VM's store.
    let mut acpmux = vm.acpmux();
    let cwd = vm.home().join("work").join("phone-gate");
    std::fs::create_dir_all(&cwd).unwrap();
    acpmux.call("acp.trust.set", json!({"cwd": cwd, "level": "trusted"}));
    let created = acpmux.call(
        "session/new",
        json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "claude"}}}),
    );
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, HISTORY, "phone-gate-history"));
    eprintln!("phone gate: VM chat {}", acpmux.summary(&session).unwrap_or_default());
    bound_agent_tab(&vm, &session);

    // The VM's link, owned by user _0001; the phone's link and a stranger's, paired with it.
    let mut links =
        Links { home: cmux_unix_socket::short_test_dir("phonegate"), states: Vec::new() };
    let (identity, public) = enrolled(links.home.path());
    let brain = links.home.path().join("brain");
    std::fs::create_dir_all(&brain).unwrap();
    let server_json = links.home.path().join("server.json");
    std::fs::write(
        &server_json,
        json!({"owner_session": {"owner_user": OWNER_USER, "owner_team": TEAM,
            "socket": brain.join("brain.sock"), "brain_home": brain}})
        .to_string(),
    )
    .unwrap();
    let server = links.state("vm");
    links.json(&[
        "link",
        "init",
        "--state-dir",
        server.to_str().unwrap(),
        "--server-identity",
        identity.to_str().unwrap(),
        "--port",
        "0",
    ]);
    let server_live = links.json(&[
        "link",
        "ensure",
        "--state-dir",
        server.to_str().unwrap(),
        "--session-socket",
        vm.socket.to_str().unwrap(),
        "--server-config",
        server_json.to_str().unwrap(),
    ]);
    let server_udp = server_live["udp"].as_str().unwrap().to_owned();
    let (phone_state, phone_init, phone_live) = links.peer("phone", "inst_phone");
    let (stranger_state, stranger_init, stranger_live) = links.peer("stranger", "inst_stranger");
    for (state, install, user, init, live) in [
        (&phone_state, "inst_phone", OWNER_USER, &phone_init, &phone_live),
        (&stranger_state, "inst_stranger", STRANGER_USER, &stranger_init, &stranger_live),
    ] {
        links.add_peer(
            &server,
            install,
            user,
            init["public_key"].as_str().unwrap(),
            live["udp"].as_str().unwrap(),
        );
        links.add_peer(state, INSTALL, OWNER_USER, &public, &server_udp);
    }

    // A paired peer that is not the owner: the stream ends before any answer.
    let (dial, mut stranger) = Phone::dial(&links, stranger_live["socket"].as_str().unwrap());
    let non_owner_refused = if dial["ok"] == json!(true) {
        let id = stranger.send("initialize", json!({"protocolVersion": 1}));
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut answered = false;
        while let Some(line) = stranger.next_line(deadline) {
            answered |= line["id"] == json!(id);
        }
        !answered
    } else {
        true
    };
    drop(stranger);
    assert!(non_owner_refused, "a non-owner peer got an answer");

    // The owner's phone.
    let connect_started = Instant::now();
    let (dial, mut phone) = Phone::dial(&links, phone_live["socket"].as_str().unwrap());
    assert_eq!(dial["ok"], true, "{dial}");
    let init = phone.call("initialize", json!({"protocolVersion": 1}));
    let connect_ms = connect_started.elapsed().as_millis() as u64;
    assert_eq!(init["_meta"]["acpmux"]["fullAccess"], false, "{init}");

    let sessions = phone.call("_acpmux/sessions", json!({}));
    let listed = sessions["sessions"].as_array().cloned().unwrap_or_default();
    assert!(listed.iter().any(|s| s["sessionId"] == json!(session)), "not listed: {sessions}");

    let page = phone.call("_acpmux/attach", json!({"sessionId": session}));
    let history = page.to_string().contains(HISTORY);

    let prompt_started = Instant::now();
    let id = phone.send(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": PHONE_TEXT}],
               "_meta": {"acpmux": {"promptId": "phone-gate-1"}}}),
    );
    let (answer, before) = phone.answer(id, 60, "session/prompt");
    assert!(answer.get("error").is_none(), "prompt refused: {answer}");
    let prompt_answer_ms = prompt_started.elapsed().as_millis() as u64;
    let accepted = before.iter().any(|l| l["method"] == "_acpmux/prompt_accepted");
    assert!(accepted, "no prompt_accepted before the answer: {before:?}");
    let mut first_reply_ms = before.iter().any(agent_reply).then_some(prompt_answer_ms);
    let deadline = Instant::now() + Duration::from_secs(60);
    while first_reply_ms.is_none() {
        let Some(line) = phone.next_line(deadline) else { break };
        if agent_reply(&line) {
            first_reply_ms = Some(prompt_started.elapsed().as_millis() as u64);
        }
    }

    // The VM's own chat holds the phone's turn: it ran there, nowhere else.
    let landed = wait_until(30, "the phone's turn on the VM", || {
        let events = acpmux.events(&session);
        (count(&events, "user_message", USER_TEXT, PHONE_TEXT) == 1).then_some(true)
    });

    let id = phone
        .send("session/set_mode", json!({"sessionId": session, "modeId": "bypassPermissions"}));
    let (refused, _) = phone.answer(id, 30, "session/set_mode");
    let unsupported_refused = refused["error"]["code"] == json!(-32601);
    assert!(unsupported_refused, "set_mode was not refused: {refused}");

    let ok = non_owner_refused && accepted && landed && unsupported_refused;
    let report = json!({
        "ok": ok,
        "connect_ms": connect_ms,
        "prompt_accepted_ms": prompt_answer_ms,
        "first_reply_ms": first_reply_ms,
        "sessions": listed.len(),
        "history": history,
        "turn_on_vm": landed,
        "unsupported_refused": unsupported_refused,
        "non_owner_refused": non_owner_refused,
        "mac": "off",
        "profile": if cfg!(debug_assertions) { "dev" } else { "release" },
    });
    println!("GATE phone {report}");
    if let Ok(path) = std::env::var("PHONE_GATE_OUT")
        && !path.is_empty()
    {
        std::fs::write(&path, format!("{report}\n")).unwrap();
    }
    assert!(ok, "{report}");
}
