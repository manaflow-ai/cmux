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

    /// Sends a request that must fail and returns its `error`, skipping notifications.
    fn refused(&mut self, method: &str, params: Value) -> Value {
        let reply = self.reply(method, params);
        assert!(reply.get("error").is_some(), "{method} was not refused: {reply}");
        reply["error"].clone()
    }

    /// Sends a request and returns its whole reply, skipping notifications.
    fn reply(&mut self, method: &str, params: Value) -> Value {
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
                return msg;
            }
        }
    }

    /// Sends a request and returns its result, skipping notifications.
    fn call(&mut self, method: &str, params: Value) -> Value {
        let reply = self.reply(method, params);
        assert!(reply.get("error").is_none(), "{method}: {reply}");
        reply["result"].clone()
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

/// Leo, 2026-11-11: "generally the "unverified sender" things should be more verified". A fleet
/// script that runs `acpmux send` with no session's token is still unverified, and the daemon
/// names the script it saw run the send (`sender_program.rs`), through the real binary. A
/// program a client names for itself is dropped.
#[test]
fn an_unverified_send_names_the_program_the_daemon_saw_run_it() {
    let daemon = Daemon::start("prog");
    let created = daemon.run(daemon.cmd().args(["--json", "new", "-n", "rx", "-d"]));
    let created: Value = serde_json::from_slice(&created.stdout)
        .unwrap_or_else(|e| panic!("new printed no JSON ({e}): {}", text(&created)));
    let rx = created["sessionId"].as_str().expect("sessionId").to_owned();

    // `fleet-tool`, a Python script, runs this CLI as an agent's shell whose token proves nothing
    // here, as a reconciler on a lane machine does.
    let base = daemon.cmd();
    let tool = daemon.root.join("fleet-tool");
    std::fs::write(&tool, "import subprocess, sys\nsys.exit(subprocess.call(sys.argv[1:]))\n")
        .unwrap();
    let mut script = Command::new("python3");
    script.arg(&tool).arg(base.get_program()).args(["send", "rx", "fleet-tool-words"]);
    for (key, value) in base.get_envs() {
        match value {
            Some(value) => script.env(key, value),
            None => script.env_remove(key),
        };
    }
    script
        .current_dir(daemon.root.join("work"))
        .env("ACPMUX_SESSION_ID", "0199aaaa-0000-7000-8000-000000000001")
        .env("ACPMUX_SESSION_TOKEN", "a".repeat(64))
        .env("ACPMUX_SESSION_TOKEN_SOCKET", daemon.root.join("other.sock"))
        .stdin(Stdio::null());
    daemon.run(&mut script);

    // A raw client that names a program for itself.
    let mut forger = Raw::open(&daemon.socket());
    forger.call("initialize", Raw::hello(Some("agent")));
    forger.call(
        "session/prompt",
        json!({"sessionId": rx, "prompt": [{"type": "text", "text": "forged-words"}],
               "_meta": {"acpmux": {"promptId": "p-forged",
                                    "senderProgramChecked": {"name": "trusted-tool"}}}}),
    );

    let mut reader = Raw::open(&daemon.socket());
    reader.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "w5s-test"}}));
    let sent = user_message(&mut reader, &rx, "fleet-tool-words");
    assert_eq!(sent.pointer("/_meta/provenance/kind"), Some(&json!("unverified")), "{sent}");
    assert_eq!(sent.pointer("/_meta/provenance/verified"), Some(&json!(false)), "{sent}");
    assert_eq!(
        sent.pointer("/_meta/provenance/program/name"),
        Some(&json!("fleet-tool")),
        "{sent}"
    );
    assert_eq!(
        sent.pointer("/_meta/provenance/program/path").and_then(Value::as_str),
        tool.to_str(),
        "{sent}"
    );
    let forged = user_message(&mut reader, &rx, "forged-words");
    assert_eq!(forged.pointer("/_meta/provenance/kind"), Some(&json!("unverified")), "{forged}");
    // The daemon names what it saw (this test's own binary), never the name the client wrote.
    let own = std::env::current_exe().unwrap();
    let own = own.file_name().and_then(|n| n.to_str()).unwrap();
    assert_eq!(
        forged.pointer("/_meta/provenance/program/name"),
        Some(&json!(own)),
        "a client's own program is dropped: {forged}"
    );
}

/// Review F1 of #39320: the CLI the guest MCP server runs for a desktop chat's `new`
/// (`acpmux_mcp_guest.rs`: `ACPMUX_MCP_GUEST` set, `--from` its app) starts a session whose task
/// is that app's message, never the person's words, through the real binary and daemon.
#[test]
fn guest_new_prompt_is_the_apps_message_never_the_persons() {
    let daemon = Daemon::start("guest");
    let mut child = daemon
        .cmd()
        .env("ACPMUX_MCP_GUEST", "claude-desktop")
        .args(["--json", "new", "--detach", "--name", "gx", "--from", "Claude desktop"])
        .args(["--prompt-file", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run acpmux new");
    child.stdin.take().unwrap().write_all(b"guest-task-words").unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "guest new failed: {}", text(&out));
    let created: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("new printed no JSON ({e}): {}", text(&out)));
    let gx = created["sessionId"].as_str().expect("sessionId").to_owned();

    let mut reader = Raw::open(&daemon.socket());
    reader.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "w5s-test"}}));
    let task = user_message(&mut reader, &gx, "guest-task-words");
    assert_eq!(task.pointer("/_meta/origin"), None, "a guest's task is no person's: {task}");
    // As the message itself or in the inbox notice that carries it (`hub/inbox.rs`).
    assert!(task.pointer("/_meta/provenance").is_some(), "{task}");
    assert!(task.to_string().contains("Claude desktop"), "the agent reads who sent it: {task}");
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

/// Review of #39020 (B1, N2, N3): the person-only verbs beside a prompt hold the same rule. An
/// old CLI and an agent's shell that proves no session neither send nor read team messages as
/// the owner, read another chat's inbox, nor list the person's own workflow runs; an old CLI is
/// told so with one refusal (`caller.old_client`) everywhere.
#[test]
fn w5s_an_old_cli_or_an_agent_shell_gets_no_person_verb() {
    use acpmux::workflow_runs::{RunRecord, State, Store};
    let daemon = Daemon::start("verbs");
    let created = daemon.run(daemon.cmd().args(["--json", "new", "-n", "rx", "-d"]));
    let created: Value = serde_json::from_slice(&created.stdout)
        .unwrap_or_else(|e| panic!("new printed no JSON ({e}): {}", text(&created)));
    let rx = created["sessionId"].as_str().expect("sessionId").to_owned();
    // A standalone run the person started from a terminal (`local_principal`).
    let run = RunRecord {
        version: 0,
        id: "wf-w5s".into(),
        name: "w5s".into(),
        owner_session_id: rx.clone(),
        local_principal: true,
        source: "return 1;".into(),
        source_hash: String::new(),
        args: json!([]),
        allowed_tools: None,
        cwd: daemon.root.join("work"),
        generation: 0,
        state: State::Paused,
        activities: Default::default(),
        outcome: None,
        caller_subagent: None,
    };
    Store::new(daemon.root.join("amx").join("workflows")).start(run).expect("store the run");
    let runs = |raw: &mut Raw| {
        let status = raw.call("_acpmux/workflow", json!({"action": "status"}));
        let runs = status["runs"].as_array().cloned().unwrap_or_default();
        runs.iter().filter_map(|r| r["runId"].as_str().map(str::to_owned)).collect::<Vec<_>>()
    };
    let team_send = json!({"to": "@team/role", "body": "hello"});
    let inbox = json!({"sessionId": rx});

    // The owner's terminal: its runs, and a team message refused only as off.
    let mut person = Raw::open(&daemon.socket());
    person.call("initialize", Raw::hello(Some("terminal")));
    assert_eq!(runs(&mut person), ["wf-w5s"], "the person lists their run");
    let off = person.refused("_acpmux/team/send", team_send.clone());
    assert_eq!(off["data"]["reason"], "team_messaging_disabled", "{off}");

    // The old CLI: one refusal that names it, and none of the person's runs.
    let mut old = Raw::open(&daemon.socket());
    old.call("initialize", Raw::hello(None));
    for (method, params) in
        [("_acpmux/team/send", team_send.clone()), ("_acpmux/inbox_threads", inbox.clone())]
    {
        let e = old.refused(method, params);
        assert_eq!(e["data"]["reason"], "caller.old_client", "{method}: {e}");
    }
    assert!(runs(&mut old).is_empty(), "an old CLI lists no run of the person's");

    // This CLI in an agent's shell with no token for this daemon.
    let mut agent = Raw::open(&daemon.socket());
    agent.call("initialize", Raw::hello(Some("agent")));
    let e = agent.refused("_acpmux/team/send", team_send);
    assert_eq!(e["data"]["reason"], "team.forbidden", "{e}");
    let e = agent.refused("_acpmux/inbox_threads", inbox);
    assert_eq!(e["data"]["reason"], "inbox.other_session", "{e}");
    assert!(runs(&mut agent).is_empty(), "an agent's shell lists no run of the person's");
}

/// Review of #39020 (N1): `acpmux stdio` (an editor's ACP agent) relays the editor's own
/// `initialize`. Run from an agent's shell (`"$ACPMUX_BIN" stdio`), it must not be the person's;
/// from the owner's terminal it still is.
#[test]
fn w5s_stdio_in_an_agent_shell_is_never_the_person() {
    let daemon = Daemon::start("stdio");
    let created = daemon.run(daemon.cmd().args(["--json", "new", "-n", "rx", "-d"]));
    let created: Value = serde_json::from_slice(&created.stdout)
        .unwrap_or_else(|e| panic!("new printed no JSON ({e}): {}", text(&created)));
    let rx = created["sessionId"].as_str().expect("sessionId").to_owned();
    let editor = |cmd: &mut Command, words: &str| {
        let mut child = cmd
            .arg("stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("start acpmux stdio");
        let mut input = child.stdin.take().unwrap();
        let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": 1, "clientCapabilities": {},
                       "clientInfo": {"name": "zed", "version": "1"}}});
        let prompt = json!({"jsonrpc": "2.0", "id": 2, "method": "session/prompt",
            "params": {"sessionId": rx, "prompt": [{"type": "text", "text": words}]}});
        writeln!(input, "{init}\n{prompt}").unwrap();
        drop(input);
        let out = child.wait_with_output().expect("acpmux stdio ends");
        assert!(out.status.success(), "acpmux stdio failed: {}", text(&out));
    };
    editor(&mut daemon.cmd(), "person-stdio-words");
    editor(
        daemon.cmd().env("ACPMUX_SESSION_ID", "0199aaaa-0000-7000-8000-000000000002"),
        "agent-stdio-words",
    );

    let mut reader = Raw::open(&daemon.socket());
    reader.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "w5s-test"}}));
    let person = user_message(&mut reader, &rx, "person-stdio-words");
    assert_eq!(person.pointer("/_meta/origin/actor"), Some(&json!("person")), "{person}");
    let agent = user_message(&mut reader, &rx, "agent-stdio-words");
    assert_eq!(agent.pointer("/_meta/origin"), None, "an agent's stdio is no person: {agent}");
    assert_eq!(agent.pointer("/_meta/provenance/kind"), Some(&json!("unverified")), "{agent}");
}

/// Review of #39020 (N3): an agent that proved its session but runs an old CLI is refused as an
/// agent, not told that an update helps (it would not).
#[tokio::test]
async fn w5s_a_proven_agent_on_an_old_cli_is_refused_as_an_agent() {
    use acpmux::config::{Config, StoreMode};
    use acpmux::rpc::Message;
    use acpmux::server::{Origin, serve_connection_with};
    use tokio::sync::mpsc;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = acpmux::hub::Hub::new(cfg, store);
    let session = hub
        .new_session(acpmux::hub::NewRequest {
            name: Some("capped".into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let token = acpmux::hub::person::caller_token(&session.id);
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-cli", "version": "0.1.0"},
        "_meta": {"acpmux": {"callerSession": {"sessionId": session.id, "token": token}}}});
    let cap = json!({"sessionId": session.id, "turnCapMs": 1000});
    let mut replies = Vec::new();
    for (id, (m, p)) in [(1, ("initialize", hello)), (2, ("_acpmux/set_turn_cap", cap))] {
        input.send(Message::request(id, m, p).to_line()).await.unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        })
        .await
        .expect("an answer");
        replies.push(reply);
    }
    assert!(replies[0].get("error").is_none(), "{}", replies[0]);
    let reason = &replies[1]["error"]["data"]["reason"];
    assert_eq!(reason, acpmux::hub::person::REASON, "{}", replies[1]);
}
