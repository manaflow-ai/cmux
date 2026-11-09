//! Who a send from the acpmux CLI is, through the real binary and a raw old client (W5-S, bench
//! round 4 A5 defect 1, 2026-11-08): an agent's Bash ran the user's old `~/.local/bin/acpmux`
//! 0.1.0, which sends no caller token, and the daemon recorded the send as the person's
//! (`origin: {actor: "person", verified: true}`). A client that proves no identity is never
//! the person: an old acpmux CLI and an agent's shell whose token is for another daemon are
//! `unverified`; the owner's own terminal send stays the person's. Each agent gets its daemon's
//! own CLI as `ACPMUX_BIN`, so it does not run an old one.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// One daemon on its own socket and home, with the fake agent as its only harness.
struct Daemon {
    root: PathBuf,
    child: Option<Child>,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        // Short: the socket path must stay under the macOS limit.
        let root = std::env::temp_dir().join(format!("w5s-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["home", "amx", "work"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        let root = std::fs::canonicalize(&root).unwrap();
        let config = json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}},
                            "defaultHarness": "fake", "permissionPolicy": "approve-all"});
        std::fs::write(root.join("amx").join("config.json"), config.to_string()).unwrap();
        let mut daemon = Self { root, child: None };
        // `--memory`: no store on disk, so no agent host outlives the test.
        let mut child = daemon
            .cmd()
            .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        let ready = daemon_env::ready_line(child.stdout.take().unwrap());
        assert!(ready.contains("\"ready\":true"), "daemon not ready: {ready}");
        daemon.child = Some(child);
        daemon
    }

    fn socket(&self) -> PathBuf {
        self.root.join("s.sock")
    }

    /// The CLI at a plain terminal of the owner: no acpmux session around it.
    fn cmd(&self) -> Command {
        let mut cmd = daemon_env::command(&self.root, daemon_env::Agents::StandIn, &[]);
        cmd.current_dir(self.root.join("work"))
            .env("ACPMUX_HOME", self.root.join("amx"))
            .env("ACPMUX_SOCKET", self.socket())
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_REGISTRY_FETCH", "0")
            .env("ACPMUX_HEALTH_FETCH", "0")
            .env("ACPMUX_PROBE_HARNESSES", "fake")
            .stdin(Stdio::null());
        cmd
    }

    fn run(&self, cmd: &mut Command) -> Output {
        let out = cmd.output().expect("run acpmux");
        assert!(out.status.success(), "{cmd:?} failed: {}", text(&out));
        out
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = self.cmd().args(["daemon", "shutdown", "--end-agents"]).output();
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn text(out: &Output) -> String {
    format!("{} {}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
}

/// A raw unix client of the socket, as an old CLI or a script speaks to it.
struct Raw {
    out: UnixStream,
    lines: BufReader<UnixStream>,
    next: i64,
}

impl Raw {
    fn open(socket: &std::path::Path) -> Self {
        let out = UnixStream::connect(socket).expect("connect");
        out.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let lines = BufReader::new(out.try_clone().unwrap());
        Self { out, lines, next: 0 }
    }

    /// The `initialize` params of this CLI (caller protocol 1) declaring `kind` (`terminal` or
    /// `agent`), or of an old one (0.1.0, no caller protocol) for `None`; no caller token.
    fn hello(kind: Option<&str>) -> Value {
        match kind {
            Some(kind) => json!({"protocolVersion": 1, "clientCapabilities": {},
                "clientInfo": {"name": "acpmux-cli", "version": "9.9.9"},
                "_meta": {"acpmux": {"callerProtocol": 1, "callerKind": kind}}}),
            None => json!({"protocolVersion": 1, "clientCapabilities": {},
                "clientInfo": {"name": "acpmux-cli", "version": "0.1.0"}}),
        }
    }

    /// Sends a request and returns its result, skipping notifications.
    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.out, "{line}").unwrap();
        loop {
            let mut line = String::new();
            let n = self.lines.read_line(&mut line).expect("read reply");
            assert!(n > 0, "the daemon closed the connection during {method}");
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg.get("id") == Some(&json!(id)) {
                assert!(msg.get("error").is_none(), "{method}: {msg}");
                return msg["result"].clone();
            }
        }
    }
}

/// The `user_message` record of the prompt whose text is `words`.
fn user_message(raw: &mut Raw, session: &str, words: &str) -> Value {
    let page = raw.call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}));
    let events = page["events"].as_array().cloned().unwrap_or_default();
    events
        .into_iter()
        .map(|e| e["msg"].clone())
        .find(|m| m["text"].as_str().is_some_and(|t| t.contains(words)))
        .unwrap_or_else(|| panic!("no user_message with {words:?}: {page}"))
}

#[test]
fn w5s_an_old_cli_or_an_unproven_agent_shell_is_never_the_person() {
    let daemon = Daemon::start("who");
    let created = daemon.run(daemon.cmd().args(["--json", "new", "-n", "rx", "-d"]));
    let created: Value = serde_json::from_slice(&created.stdout)
        .unwrap_or_else(|e| panic!("new printed no JSON ({e}): {}", text(&created)));
    let rx = created["sessionId"].as_str().expect("sessionId").to_owned();

    // The owner at a plain terminal: the person's prompt. Sent as this CLI's hello declares it
    // (`cli_caller::declare` outside a session), not by the CLI itself: the CLI also names the
    // harness above it in its process chain (`sender_harness.rs`), and a CI runner started below
    // Claude Code or Codex (the macOS runner, review of #39020 N7) makes every send from it a
    // harness's, which is no person's either.
    let mut owner_terminal = Raw::open(&daemon.socket());
    owner_terminal.call("initialize", Raw::hello(Some("terminal")));
    owner_terminal.call(
        "session/prompt",
        json!({"sessionId": rx, "prompt": [{"type": "text", "text": "owner-words"}],
               "_meta": {"acpmux": {"promptId": "p-owner"}}}),
    );

    // The old CLI (0.1.0) in an agent's shell: no caller token, no caller protocol.
    let mut old = Raw::open(&daemon.socket());
    old.call(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {},
               "clientInfo": {"name": "acpmux-cli", "version": "0.1.0"}}),
    );
    old.call(
        "session/prompt",
        json!({"sessionId": rx, "prompt": [{"type": "text", "text": "old-cli-words"}],
               "_meta": {"acpmux": {"promptId": "p-old-cli"}}}),
    );

    // This CLI in the shell of another daemon's agent: its token goes only to that daemon's
    // socket, so this daemon gets none.
    let elsewhere = daemon.root.join("other.sock");
    daemon.run(
        daemon
            .cmd()
            .env("ACPMUX_SESSION_ID", "0199aaaa-0000-7000-8000-000000000001")
            .env("ACPMUX_SESSION_TOKEN", "a".repeat(64))
            .env("ACPMUX_SESSION_TOKEN_SOCKET", &elsewhere)
            .args(["send", "rx", "agent-shell-words"]),
    );

    let mut reader = Raw::open(&daemon.socket());
    reader.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "w5s-test"}}));
    let owner = user_message(&mut reader, &rx, "owner-words");
    assert_eq!(owner.pointer("/_meta/origin/actor"), Some(&json!("person")), "{owner}");
    assert_eq!(owner.pointer("/_meta/provenance"), None, "{owner}");

    let old_cli = user_message(&mut reader, &rx, "old-cli-words");
    assert_eq!(old_cli.pointer("/_meta/origin"), None, "an old CLI is no person: {old_cli}");
    assert_eq!(old_cli.pointer("/_meta/provenance/kind"), Some(&json!("unverified")), "{old_cli}");
    assert_eq!(old_cli.pointer("/_meta/provenance/verified"), Some(&json!(false)), "{old_cli}");
    assert_eq!(
        old_cli.pointer("/_meta/provenance/claimed/client"),
        Some(&json!("acpmux-cli 0.1.0")),
        "the record names the old client: {old_cli}"
    );

    let agent = user_message(&mut reader, &rx, "agent-shell-words");
    assert_eq!(agent.pointer("/_meta/origin"), None, "an agent's shell is no person: {agent}");
    assert_eq!(agent.pointer("/_meta/provenance/kind"), Some(&json!("unverified")), "{agent}");
}

#[test]
fn w5s_each_agent_gets_its_daemons_own_cli() {
    let daemon = Daemon::start("bin");
    let out =
        daemon.run(daemon.cmd().args(["--json", "run", "--timeout", "60", "envs: ACPMUX_BIN"]));
    let reply: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("run printed no JSON ({e}): {}", text(&out)));
    let env: Value = serde_json::from_str(reply["reply"].as_str().expect("reply"))
        .unwrap_or_else(|e| panic!("the agent printed no environment ({e}): {reply}"));
    let bin = env["ACPMUX_BIN"].as_str().unwrap_or_default();
    assert!(!bin.is_empty(), "the agent has no ACPMUX_BIN: {env}");
    let canonical = |p: &std::path::Path| std::fs::canonicalize(p).unwrap();
    assert_eq!(
        canonical(std::path::Path::new(bin)),
        canonical(daemon_env::bin()),
        "ACPMUX_BIN is the daemon's own executable"
    );
}
