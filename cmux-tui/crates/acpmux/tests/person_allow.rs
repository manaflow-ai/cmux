//! Only the person-facing app may allow (cx-1l61). The real daemon binary,
//! over its real unix socket: a client that did not present this launch's
//! person key (the acpmux CLI, the TUI, an agent that runs the CLI) may read
//! a prompt and deny or cancel it, never allow it, and never widen what the
//! session or the daemon runs without asking. The refusal is the declared
//! error `permission.person_required`; the prompt stays pending. A
//! connection that presented the key (the app's own connection; the key
//! comes to an unsigned daemon only on `--person-key-fd` at spawn) may.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const REASON: &str = "permission.person_required";
/// 32 bytes as hex: what the app makes at each launch.
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

/// The app's proof for one connection's challenge, as `hub/person.rs`
/// defines it: lowercase hex HMAC-SHA256(key, "acpmux-person-v1" 0 "unix" 0
/// nonce 0 connection). Written out here so the test states the wire contract.
fn person_proof(key: &str, nonce: &str, connection: &str) -> Option<String> {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key)?;
    // These connections are the unix socket.
    let mut message = b"acpmux-person-v1\0unix\0".to_vec();
    message.extend_from_slice(nonce.as_bytes());
    message.push(0);
    message.extend_from_slice(connection.as_bytes());
    Some(hex(&hmac_sha256(&key, &message)))
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
    /// Notifications read while waiting for a reply.
    notes: Vec<Value>,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0, notes: Vec::new() }
    }

    /// A connection that answers its challenge with `key`, as the app does:
    /// `initialize` first (it carries no key), then `_acpmux/person_prove`.
    async fn person(path: &Path, key: &str) -> Self {
        Self::person_with(path, key).await.0
    }

    /// `person`, with the proof reply and the challenge it answered.
    async fn person_with(path: &Path, key: &str) -> (Self, Value, Value) {
        let mut c = Self::connect(path).await;
        let challenge = c.initialize().await;
        let proof = person_proof(
            key,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let reply = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        (c, reply, challenge)
    }

    /// `initialize`; the person challenge it returned.
    async fn initialize(&mut self) -> Value {
        let r = self.call("initialize", json!({"protocolVersion": 1})).await;
        assert!(r.get("error").is_none(), "initialize: {r}");
        r["result"]["_meta"]["acpmux"]["personChallenge"].clone()
    }

    async fn line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
            .await
            .expect("daemon answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        serde_json::from_str(&line).unwrap()
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        self.next
    }

    /// The whole reply (result or error).
    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply(id).await
    }

    async fn reply(&mut self, id: i64) -> Value {
        loop {
            let v = self.line().await;
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
            self.notes.push(v);
        }
    }

    async fn ok(&mut self, method: &str, params: Value) -> Value {
        let r = self.call(method, params).await;
        assert!(r.get("error").is_none(), "{method} failed: {r}");
        r["result"].clone()
    }

    /// The next notification `method` whose params pass `pick`.
    async fn note(&mut self, method: &str, pick: impl Fn(&Value) -> bool) -> Value {
        if let Some(i) = self.notes.iter().position(|n| n["method"] == method && pick(&n["params"]))
        {
            return self.notes.remove(i)["params"].clone();
        }
        loop {
            let v = self.line().await;
            if v["method"] == method && pick(&v["params"]) {
                return v["params"].clone();
            }
            self.notes.push(v);
        }
    }
}

struct Daemon {
    child: std::process::Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    /// The real daemon; `key` goes in on `--person-key-fd 3`, like the app's launcher.
    fn start(tag: &str, key: Option<&str>) -> Self {
        // Short: the socket path must stay under the macOS limit.
        let dir = std::env::temp_dir().join(format!("amp-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("work")).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        std::fs::write(
            dir.join("config.json"),
            json!({
                "harnesses": {
                    "fake": {"argv": ["python3", FAKE]},
                    "mirror": {"argv": ["python3", FAKE]},
                },
                "defaultHarness": "fake",
                "permissionPolicy": "ask",
                "webAskingModes": {"fake": ["normal", "strict"]},
            })
            .to_string(),
        )
        .unwrap();
        let socket = dir.join("s.sock");
        let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
        cmd.args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        let mut fds = [-1i32; 2];
        if let Some(key) = key {
            cmd.args(["--person-key-fd", "3"]);
            // SAFETY: a fresh pipe; both ends are owned here.
            assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
            let line = format!("{key}\n");
            // SAFETY: the write end is open; the line fits the pipe buffer.
            let n = unsafe { libc::write(fds[1], line.as_ptr().cast(), line.len()) };
            assert_eq!(n as usize, line.len());
            // SAFETY: closing our own write end.
            unsafe { libc::close(fds[1]) };
            let read_end = fds[0];
            // SAFETY: only dup2 between fork and exec (async-signal-safe).
            unsafe {
                cmd.pre_exec(move || {
                    if libc::dup2(read_end, 3) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let mut child = cmd.spawn().unwrap();
        if fds[0] >= 0 {
            // SAFETY: the child has its own copy on fd 3.
            unsafe { libc::close(fds[0]) };
        }
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
        assert!(ready, "the daemon exited before its ready line");
        Daemon { child, socket, dir }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid of the child this test spawned and still owns.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

async fn new_session(c: &mut Rpc, d: &Daemon) -> String {
    let s = c.ok("session/new", json!({"cwd": d.dir.join("work"), "mcpServers": []})).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.ok("_acpmux/attach", json!({"sessionId": id})).await;
    id
}

fn prompt(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]})
}

async fn pending_ids(c: &mut Rpc, id: &str) -> Vec<String> {
    let info = c.ok("_acpmux/info", json!({"sessionId": id})).await;
    info["pending"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p["permissionId"].as_str().map(str::to_owned))
        .collect()
}

/// The turn's text the fake agent printed after the answer.
async fn turn_said(c: &mut Rpc, rid: i64) -> String {
    let done = c.reply(rid).await;
    assert!(done.get("error").is_none(), "{done}");
    let chunk =
        c.note("session/update", |p| p["update"]["sessionUpdate"] == "agent_message_chunk").await;
    chunk["update"]["content"]["text"].as_str().unwrap_or_default().to_owned()
}

#[tokio::test]
async fn an_agent_side_client_reads_denies_and_cancels_but_never_allows() {
    let d = Daemon::start("agent", None);
    let mut agent = Rpc::connect(&d.socket).await;
    let id = new_session(&mut agent, &d).await;

    let rid = agent.send("session/prompt", prompt(&id, "ask: rm -rf /")).await;
    let pending = agent.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    // It reads the prompt.
    assert_eq!(pending["request"]["toolCall"]["title"], "rm -rf /");

    // Allow: refused with the declared error; the prompt stays pending.
    let allow = json!({"sessionId": id, "permissionId": pid, "optionId": "yes"});
    let r = agent.call("_acpmux/permission_respond", allow.clone()).await;
    assert_eq!(reason(&r), REASON, "an agent-side allow must be refused: {r}");
    assert!(
        r["error"]["message"].as_str().unwrap_or_default().contains("approve this on the Mac app"),
        "{r}"
    );
    assert_eq!(pending_ids(&mut agent, &id).await, vec![pid.clone()]);
    // A question's answer is an allow too.
    let answer = json!({"sessionId": id, "permissionId": pid, "optionId": "yes", "answers": {}});
    assert_eq!(reason(&agent.call("_acpmux/permission_respond", answer).await), REASON);

    // Deny: accepted, and the agent hears it.
    agent
        .ok(
            "_acpmux/permission_respond",
            json!({"sessionId": id, "permissionId": pid, "optionId": "no"}),
        )
        .await;
    assert_eq!(turn_said(&mut agent, rid).await, "chose no");

    // Cancel (no option): accepted.
    let rid = agent.send("session/prompt", prompt(&id, "ask: again")).await;
    let pending = agent.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    agent.ok("_acpmux/permission_respond", json!({"sessionId": id, "permissionId": pid})).await;
    assert_eq!(turn_said(&mut agent, rid).await, "chose cancelled");

    // A grouped prompt: allow refused, deny accepted.
    let rid = agent.send("session/prompt", prompt(&id, "permission-batch: single")).await;
    let event = agent
        .note("_acpmux/event", |p| {
            p["kind"] == "permission_group" && p["msg"]["group"]["state"] == "pending"
        })
        .await;
    let g = &event["msg"]["group"];
    let decide = |key: &str, choice: &str| {
        json!({"sessionId": id, "groupId": g["groupId"], "revision": g["revision"],
               "decisionKey": key, "decision": choice})
    };
    for choice in ["allow_once", "allow_chat"] {
        let r = agent.call("_acpmux/permission_group_respond", decide(choice, choice)).await;
        assert_eq!(reason(&r), REASON, "group {choice}: {r}");
    }
    agent.ok("_acpmux/permission_group_respond", decide("deny", "deny")).await;
    assert!(agent.reply(rid).await.get("error").is_none());
}

#[tokio::test]
async fn an_agent_side_client_never_widens_what_runs_without_asking() {
    let d = Daemon::start("grant", None);
    let mut agent = Rpc::connect(&d.socket).await;
    let id = new_session(&mut agent, &d).await;
    let refused = [
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-reads"})),
        ("_acpmux/set_default_policy", json!({"policy": "approve-all"})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"autoApprove": ["execute"]}})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"default": "approve"}})),
        ("_acpmux/defaults", json!({"family": "fake", "set": {"policy": "approve-all"}})),
        ("session/set_mode", json!({"sessionId": id, "modeId": "bypass"})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "mode", "value": "yolo"}),
        ),
    ];
    for (m, p) in refused {
        let r = agent.call(m, p.clone()).await;
        assert_eq!(reason(&r), REASON, "{m} {p}: {r}");
    }
    // The session still asks.
    let info = agent.ok("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["policy"], "approve-all", "{info}");
    // Narrowing stays open to every client.
    let open = [
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "deny-all"})),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "ask"})),
        ("_acpmux/set_default_policy", json!({"policy": "ask"})),
        (
            "_acpmux/set_rules",
            json!({"sessionId": id, "rules": {"autoDeny": ["execute"], "default": "ask"}}),
        ),
        ("session/set_mode", json!({"sessionId": id, "modeId": "strict"})),
    ];
    for (m, p) in open {
        agent.ok(m, p).await;
    }
}

#[tokio::test]
async fn the_connection_that_presented_the_person_key_allows_and_grants() {
    let d = Daemon::start("person", Some(KEY));
    let mut agent = Rpc::connect(&d.socket).await;
    // A wrong key makes no person connection.
    let mut wrong = Rpc::person(&d.socket, &"0".repeat(64)).await;
    let mut app = Rpc::person(&d.socket, KEY).await;
    let id = new_session(&mut agent, &d).await;

    let rid = agent.send("session/prompt", prompt(&id, "ask: write")).await;
    let pending = agent.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let allow = json!({"sessionId": id, "permissionId": pid, "optionId": "yes"});
    assert_eq!(reason(&agent.call("_acpmux/permission_respond", allow.clone()).await), REASON);
    assert_eq!(reason(&wrong.call("_acpmux/permission_respond", allow.clone()).await), REASON);
    app.ok("_acpmux/permission_respond", allow).await;
    assert_eq!(turn_said(&mut agent, rid).await, "chose yes");

    // The key itself in an `initialize` (the old way) makes no person.
    let mut old = Rpc::connect(&d.socket).await;
    let late = old
        .call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": {"personKey": KEY}}}))
        .await;
    assert!(late.get("error").is_none(), "{late}");
    let r = old.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let r =
        agent.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})).await;
    assert_eq!(reason(&r), REASON, "{r}");

    for (m, p) in [
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"autoApprove": ["read"]}})),
        ("session/set_mode", json!({"sessionId": id, "modeId": "bypass"})),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})),
    ] {
        app.ok(m, p).await;
    }
    let info = app.ok("_acpmux/info", json!({"sessionId": id})).await;
    assert_eq!(info["policy"], "approve-all", "{info}");
}

/// A session on `harness` with `extra` fields (`policy`, ...).
async fn session_on(c: &mut Rpc, d: &Daemon, harness: &str, extra: Value) -> String {
    let mut p = json!({"cwd": d.dir.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": harness}}});
    for (k, v) in extra.as_object().unwrap() {
        p[k] = v.clone();
    }
    let s = c.ok("session/new", p).await;
    s["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn an_agent_side_client_never_removes_a_narrower_rule_default_or_preset() {
    let d = Daemon::start("narrow", Some(KEY));
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut agent = Rpc::connect(&d.socket).await;
    let id = new_session(&mut app, &d).await;
    // The person runs the session approve-all, but keeps commands asking.
    app.ok("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})).await;
    app.ok("_acpmux/set_rules", json!({"sessionId": id, "rules": {"ask": ["execute"]}})).await;
    // Under a policy that does not ask, every rules change from the agent
    // side is refused: a clear, an empty set, a different narrow set.
    for rules in [json!(null), json!({}), json!({"autoDeny": ["rm"]})] {
        let r = agent.call("_acpmux/set_rules", json!({"sessionId": id, "rules": rules})).await;
        assert_eq!(reason(&r), REASON, "set_rules {rules}: {r}");
    }
    // Commands still ask.
    agent.ok("_acpmux/attach", json!({"sessionId": id})).await;
    let rid = agent.send("session/prompt", prompt(&id, "ask: rm -rf /")).await;
    let pending = agent.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    agent
        .ok(
            "_acpmux/permission_respond",
            json!({"sessionId": id, "permissionId": pid, "optionId": "no"}),
        )
        .await;
    assert!(agent.reply(rid).await.get("error").is_none());

    // A family default and a preset the person narrowed stay narrowed.
    app.ok("_acpmux/defaults", json!({"family": "fake", "set": {"policy": "ask"}})).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "careful", "set": {"harness": "fake", "policy": "deny-all"}}),
    )
    .await;
    for (m, p) in [
        ("_acpmux/defaults", json!({"family": "fake", "clear": true})),
        ("_acpmux/defaults", json!({"family": "fake", "set": {"policy": null}})),
        ("_acpmux/presets", json!({"name": "careful", "clear": true})),
        ("_acpmux/presets", json!({"name": "careful", "set": {"policy": null}})),
    ] {
        let r = agent.call(m, p.clone()).await;
        assert_eq!(reason(&r), REASON, "{m} {p}: {r}");
    }
    let presets = app.ok("_acpmux/presets", json!({"name": "careful"})).await;
    assert_eq!(presets["policy"], "deny-all", "{presets}");
    // The person may.
    app.ok("_acpmux/set_rules", json!({"sessionId": id, "rules": null})).await;
    app.ok("_acpmux/presets", json!({"name": "careful", "clear": true})).await;
}

#[tokio::test]
async fn an_agent_side_client_never_widens_a_session_through_a_handoff() {
    let d = Daemon::start("handoff", Some(KEY));
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut agent = Rpc::connect(&d.socket).await;
    // The person's never-prompted session on another harness, asking.
    let person = session_on(&mut app, &d, "mirror", json!({})).await;
    // The agent may not mark it as a handoff target.
    let tag = json!({"sessionId": person, "set": {"handoffKey": "k-orphan"}});
    let r = agent.call("_acpmux/tag", tag.clone()).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let r = agent.call("_acpmux/tag", json!({"sessionId": person, "remove": ["handoffKey"]})).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // Even when the tag is there (an earlier prepare left it), a handoff
    // from an approve-all source never adopts the asking session wider.
    app.ok("_acpmux/tag", tag).await;
    let source = session_on(&mut agent, &d, "fake", json!({"policy": "approve-all"})).await;
    let r = agent
        .call(
            "_acpmux/handoff_prepare",
            json!({"sessionId": source, "harness": "mirror", "handoffKey": "k-orphan"}),
        )
        .await;
    assert_eq!(reason(&r), "key_conflict", "{r}");
    let info = app.ok("_acpmux/info", json!({"sessionId": person})).await;
    assert_ne!(info["policy"], "approve-all", "{info}");
}

#[tokio::test]
async fn an_agent_side_client_never_calls_a_harness_method_acpmux_does_not_handle() {
    let d = Daemon::start("forward", Some(KEY));
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut agent = Rpc::connect(&d.socket).await;
    let id = new_session(&mut app, &d).await;
    let call = json!({"sessionId": id, "mode": "bypass"});
    let r = agent.call("_fake/set_permission_mode", call.clone()).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // The person's call reaches the harness (the fake does not know it).
    let r = app.call("_fake/set_permission_mode", call).await;
    assert_ne!(reason(&r), REASON, "{r}");
    assert!(r["error"]["message"].as_str().unwrap_or_default().contains("no such method"), "{r}");
}

/// cx-aocz: the person's app answers for a device the person answered on
/// (the feed bridge) and says so; the claim is recorded, never sent to the
/// agent, and only the person's connection may make it.
#[tokio::test]
async fn the_person_records_which_device_answered() {
    let d = Daemon::start("answered", Some(KEY));
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut agent = Rpc::connect(&d.socket).await;
    let id = new_session(&mut agent, &d).await;
    let rid = agent.send("session/prompt", prompt(&id, "ask: deploy")).await;
    let pending = agent.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let by = json!({"device": "ios-device:7f3a", "feedItem": "fi_01k2abc"});
    let answer = |option: &str, by: Value| {
        json!({"sessionId": id, "permissionId": pid, "optionId": option,
               "_meta": {"acpmux": {"answeredBy": by}}})
    };
    // Only the person's connection may name who answered, also on a deny.
    let r = agent.call("_acpmux/permission_respond", answer("no", by.clone())).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // A malformed claim is refused and answers nothing.
    for bad in [
        json!({"device": "ios-device:7f3a"}),
        json!({"device": "", "feedItem": "fi"}),
        json!({"device": "a b", "feedItem": "fi"}),
        json!({"device": "d", "feedItem": "fi", "extra": "x"}),
        json!("ios-device:7f3a"),
    ] {
        let r = app.call("_acpmux/permission_respond", answer("yes", bad.clone())).await;
        assert_eq!(r["error"]["code"], -32602, "{bad}: {r}");
    }
    assert_eq!(pending_ids(&mut agent, &id).await, vec![pid.clone()]);
    app.ok("_acpmux/permission_respond", answer("yes", by.clone())).await;
    assert_eq!(turn_said(&mut agent, rid).await, "chose yes");
    let events = agent.ok("_acpmux/events", json!({"sessionId": id, "limit": 500})).await;
    let events = events["events"].as_array().unwrap();
    let decision = events
        .iter()
        .find(|e| e["kind"] == "permission_decision")
        .unwrap_or_else(|| panic!("no permission_decision: {events:?}"));
    assert_eq!(decision["msg"]["answeredBy"], by, "{decision}");
    assert_eq!(decision["msg"]["outcome"]["optionId"], "yes", "{decision}");
    // The agent's own messages never carry the claim.
    for e in events.iter().filter(|e| e["kind"] != "permission_decision") {
        let text = e.to_string();
        assert!(!text.contains("fi_01k2abc") && !text.contains("_acpmuxAnsweredBy"), "{e}");
    }
}

/// cx-fcaq: whatever listens on the socket path (an agent that shut the
/// daemon down and bound the path) gets nothing that makes it the person
/// against the real daemon. The app's handshake sends no key; the proof it
/// sends answers the squatter's own challenge, so the real daemon refuses
/// it on any connection. (A squatter that relays the real challenge is
/// stopped by the app's check of the server peer, Swift side.)
#[tokio::test]
async fn a_squatter_on_the_socket_path_learns_nothing_that_makes_it_the_person() {
    let d = Daemon::start("squat", Some(KEY));
    let squat_path = d.dir.join("squat.sock");
    let listener = tokio::net::UnixListener::bind(&squat_path).unwrap();
    // The squatter: answers initialize with a challenge of its own and
    // keeps every byte the client sent.
    let squatter = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = tokio::io::BufReader::new(rd).lines();
        let mut seen = String::new();
        while let Ok(Ok(Some(line))) =
            tokio::time::timeout(Duration::from_secs(10), lines.next_line()).await
        {
            seen.push_str(&line);
            seen.push('\n');
            let v: Value = serde_json::from_str(&line).unwrap();
            let reply = if v["method"] == "initialize" {
                json!({"jsonrpc": "2.0", "id": v["id"], "result": {"protocolVersion": 1, "_meta": {"acpmux": {
                    "personChallenge": {"nonce": "ab".repeat(32), "connection": "squatter-conn"}}}}})
            } else {
                json!({"jsonrpc": "2.0", "id": v["id"], "result": {"person": true}})
            };
            wr.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            if v["method"] == "_acpmux/person_prove" {
                break;
            }
        }
        seen
    });
    let (_victim, _, _) = Rpc::person_with(&squat_path, KEY).await;
    let seen = squatter.await.unwrap();
    assert!(!seen.contains(KEY), "the key crossed the socket: {seen}");
    let captured: Vec<String> = seen
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v["method"] == "_acpmux/person_prove")
        .filter_map(|v| v["params"]["proof"].as_str().map(str::to_owned))
        .collect();
    assert_eq!(captured.len(), 1, "{seen}");

    // Against the real daemon, the captured proof proves nothing.
    let mut agent = Rpc::connect(&d.socket).await;
    agent.initialize().await;
    let r = agent.call("_acpmux/person_prove", json!({"proof": captured[0]})).await;
    assert_eq!(reason(&r), "person.proof_refused", "{r}");
    let id = new_session(&mut agent, &d).await;
    let r =
        agent.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})).await;
    assert_eq!(reason(&r), REASON, "{r}");
}

/// cx-fcaq: a proof answers one connection's challenge only. Replayed on
/// another connection it is refused, and so is a valid proof that is not
/// the second request.
#[tokio::test]
async fn a_person_proof_replayed_on_another_connection_is_refused() {
    let d = Daemon::start("replay", Some(KEY));
    let (mut app, reply, challenge) = Rpc::person_with(&d.socket, KEY).await;
    assert_eq!(reply["result"]["person"], json!(true), "{reply}");
    let proof = person_proof(
        KEY,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();

    let mut other = Rpc::connect(&d.socket).await;
    let theirs = other.initialize().await;
    assert_ne!(theirs["nonce"], challenge["nonce"]);
    let r = other.call("_acpmux/person_prove", json!({"proof": proof})).await;
    assert_eq!(reason(&r), "person.proof_refused", "{r}");

    // A relay that hands this unix connection's challenge to the app's
    // WebSocket gets a proof for the `app` transport: refused here.
    let mut relayed = Rpc::connect(&d.socket).await;
    let unix_challenge = relayed.initialize().await;
    let for_app = acpmux::hub::person::person_proof(
        KEY,
        acpmux::hub::person::TRANSPORT_APP,
        unix_challenge["nonce"].as_str().unwrap(),
        unix_challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    let r = relayed.call("_acpmux/person_prove", json!({"proof": for_app})).await;
    assert_eq!(reason(&r), "person.proof_refused", "{r}");

    // The right proof, but not as the second request: refused.
    let mut late = Rpc::connect(&d.socket).await;
    let mine = late.initialize().await;
    late.ok("_acpmux/status", json!({})).await;
    let own =
        person_proof(KEY, mine["nonce"].as_str().unwrap(), mine["connection"].as_str().unwrap())
            .unwrap();
    let r = late.call("_acpmux/person_prove", json!({"proof": own})).await;
    assert_eq!(reason(&r), "person.proof_refused", "{r}");

    // Only the connection that proved may widen.
    let id = new_session(&mut other, &d).await;
    for c in [&mut other, &mut late] {
        let r =
            c.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})).await;
        assert_eq!(reason(&r), REASON, "{r}");
    }
    app.ok("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})).await;
}

/// Starts the real daemon with `args` in `dir` (with its config.json): its
/// ready line, or None when it exited first, with its exit status and stderr.
fn run_until_ready(dir: &Path, args: &[&str]) -> (Option<Value>, std::process::Child) {
    let mut child = daemon_env::acpmux(dir)
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    // Its ready line, or the end of its output when it exits.
    let ready = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_str::<Value>(&line).ok())
        .find(|v| v["ready"] == true);
    (ready, child)
}

fn port_dir(tag: &str, port: u16) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amp-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    std::fs::write(
        dir.join("config.json"),
        json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake",
            "websocket": {"listen": format!("127.0.0.1:{port}"), "token": "t".repeat(32)},
        })
        .to_string(),
    )
    .unwrap();
    dir
}

/// cx-fcaq, availability: an unrelated program on the configured
/// WebSocket port does not stop acpmux. The daemon listens on a new free
/// loopback port, reports it, and saves it (the app reads the port from
/// status, then checks that port's listener before it connects).
#[test]
fn a_taken_configured_websocket_port_moves_the_daemon_to_a_free_port() {
    let other = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let taken = other.local_addr().unwrap().port();
    let dir = port_dir("moved", taken);
    let (ready, mut child) = run_until_ready(&dir, &[]);
    let ready = ready.expect("the daemon runs with its configured port taken");
    let web = ready["webUrl"].as_str().expect("a web listener").to_owned();
    assert!(!web.contains(&format!(":{taken}/")), "{web}");
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("config.json")).unwrap()).unwrap();
    let listen = saved["websocket"]["listen"].as_str().unwrap().to_owned();
    assert_ne!(listen, format!("127.0.0.1:{taken}"));
    assert!(web.contains(&listen), "saved {listen}, reported {web}");
    // SAFETY: the pid of the child this test spawned and still owns.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
    drop(other);
    let _ = std::fs::remove_dir_all(&dir);
}

/// cx-fcaq: an explicit `--listen` that is taken stops the daemon with a
/// clear error, and its unix socket never answers.
#[test]
fn a_taken_explicit_listen_port_makes_the_daemon_exit() {
    let squatter = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = squatter.local_addr().unwrap().port();
    let dir = port_dir("listen", port);
    let listen = format!("127.0.0.1:{port}");
    let (ready, mut child) = run_until_ready(&dir, &["--listen", &listen]);
    if ready.is_some() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("the daemon got ready with its --listen port taken");
    }
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "the daemon ran with a taken port: {stderr}");
    assert!(stderr.contains("is taken"), "{stderr}");
    assert!(
        std::os::unix::net::UnixStream::connect(dir.join("s.sock")).is_err(),
        "the unix socket still answers"
    );
    drop(squatter);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The decision proof the app sends for an allow relayed from another machine
/// (cx-0q7o), as `hub/person.rs` defines it: lowercase hex HMAC-SHA256(key,
/// "acpmux-person-decision-v1" 0 instance 0 session 0 permission 0 option 0
/// nonce). Written out here so the test states the wire contract.
fn decision_proof(
    key: &str,
    instance: &str,
    session: &str,
    permission: &str,
    option: &str,
    nonce: &str,
) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).unwrap();
    let mut message = b"acpmux-person-decision-v1".to_vec();
    for part in [instance, session, permission, option, nonce] {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    hex(&hmac_sha256(&key, &message))
}

/// `permission_respond` with an allow and a decision proof.
fn decided(session: &str, permission: &str, option: &str, nonce: &str, proof: &str) -> Value {
    json!({"sessionId": session, "permissionId": permission, "optionId": option,
           "_meta": {"acpmux": {"decisionNonce": nonce, "personDecision": proof}}})
}

/// cx-0q7o: an allow that comes through a relay (a peer daemon, the remote
/// cmux-tui server), on a connection that is never the person, counts only
/// with the person's decision proof for that exact prompt, option, nonce and
/// daemon instance, and only once.
#[tokio::test]
async fn a_relayed_allow_counts_only_with_the_persons_decision_proof_and_only_once() {
    let d = Daemon::start("decide", Some(KEY));
    let mut relay = Rpc::connect(&d.socket).await;
    let id = new_session(&mut relay, &d).await;

    let rid = relay.send("session/prompt", prompt(&id, "ask: write")).await;
    let pending = relay.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().expect("a decision nonce").to_owned();
    let instance = pending["personInstance"].as_str().expect("the daemon instance").to_owned();

    // No proof, a proof for another option, another daemon instance, or
    // another key: refused, and the prompt stays pending.
    let plain = json!({"sessionId": id, "permissionId": pid, "optionId": "yes"});
    assert_eq!(reason(&relay.call("_acpmux/permission_respond", plain).await), REASON);
    let other_option = decision_proof(KEY, &instance, &id, &pid, "no", &nonce);
    let r = relay
        .call("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &other_option))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    let other_instance = decision_proof(KEY, "0123456789abcdef", &id, &pid, "yes", &nonce);
    let r = relay
        .call("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &other_instance))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    let other_key = decision_proof(&"7".repeat(64), &instance, &id, &pid, "yes", &nonce);
    let r = relay
        .call("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &other_key))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert_eq!(pending_ids(&mut relay, &id).await, vec![pid.clone()]);

    // The person's proof: the allow counts.
    let good = decision_proof(KEY, &instance, &id, &pid, "yes", &nonce);
    relay.ok("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &good)).await;
    assert_eq!(turn_said(&mut relay, rid).await, "chose yes");

    // The next prompt has its own nonce; the old nonce (spent) and the old
    // proof answer nothing there.
    let rid = relay.send("session/prompt", prompt(&id, "ask: again")).await;
    let next = relay.note("_acpmux/permission_pending", |p| p["permissionId"] != json!(pid)).await;
    let pid2 = next["permissionId"].as_str().unwrap().to_owned();
    let nonce2 = next["decisionNonce"].as_str().unwrap().to_owned();
    assert_ne!(nonce2, nonce);
    let replayed = decision_proof(KEY, &instance, &id, &pid2, "yes", &nonce);
    let r = relay
        .call("_acpmux/permission_respond", decided(&id, &pid2, "yes", &nonce, &replayed))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    let r =
        relay.call("_acpmux/permission_respond", decided(&id, &pid2, "yes", &nonce2, &good)).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let ok = decision_proof(KEY, &instance, &id, &pid2, "yes", &nonce2);
    relay.ok("_acpmux/permission_respond", decided(&id, &pid2, "yes", &nonce2, &ok)).await;
    assert_eq!(turn_said(&mut relay, rid).await, "chose yes");
}

/// cx-0q7o: a daemon that holds a person key is not dumpable (Linux), so an
/// agent it starts (same uid) cannot ptrace it or read its memory through
/// /proc: the kernel then owns its /proc files.
#[cfg(target_os = "linux")]
#[test]
fn a_keyed_daemon_is_not_dumpable() {
    use std::os::unix::fs::MetadataExt;
    let d = Daemon::start("dump", Some(KEY));
    let meta = std::fs::metadata(format!("/proc/{}/environ", d.child.id())).unwrap();
    assert_eq!(meta.uid(), 0, "a dumpable daemon's /proc files belong to its user");
}

/// cx-0q7o: the nonce is spent only by an answer that counts. An allow that
/// the daemon refuses after the proof checks (here: the session policy is
/// deny-all for a moment) leaves the prompt answerable with the same proof,
/// and two answers with that proof racing on two connections count once.
#[tokio::test]
async fn a_refused_relayed_allow_keeps_its_nonce_and_racing_answers_count_once() {
    let d = Daemon::start("race", Some(KEY));
    let mut relay = Rpc::connect(&d.socket).await;
    let id = new_session(&mut relay, &d).await;
    let rid = relay.send("session/prompt", prompt(&id, "ask: write")).await;
    let pending = relay.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();
    let good = decision_proof(KEY, &instance, &id, &pid, "yes", &nonce);

    relay.ok("_acpmux/set_policy", json!({"sessionId": id, "policy": "deny-all"})).await;
    let r =
        relay.call("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &good)).await;
    assert_eq!(reason(&r), "policy_changed", "{r}");
    relay.ok("_acpmux/set_policy", json!({"sessionId": id, "policy": "ask"})).await;

    let mut other = Rpc::connect(&d.socket).await;
    let a =
        relay.send("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &good)).await;
    let b =
        other.send("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &good)).await;
    let (ra, rb) = (relay.reply(a).await, other.reply(b).await);
    let counted = [&ra, &rb].iter().filter(|r| r.get("error").is_none()).count();
    assert_eq!(counted, 1, "{ra} {rb}");
    assert_eq!(turn_said(&mut relay, rid).await, "chose yes");
}

/// cx-0q7o slice 2a: `initialize` names the daemon run that decision proofs
/// bind (`personInstance`), the same one its prompts carry, so the app can
/// tell a daemon it started from one that someone else restarted.
#[tokio::test]
async fn initialize_names_the_daemon_run_that_decision_proofs_bind() {
    let d = Daemon::start("inst", Some(KEY));
    let mut relay = Rpc::connect(&d.socket).await;
    let init = relay.call("initialize", json!({"protocolVersion": 1})).await;
    let named = init["result"]["_meta"]["acpmux"]["personInstance"].as_str().expect("an instance");
    let named = named.to_owned();
    let id = new_session(&mut relay, &d).await;
    relay.send("session/prompt", prompt(&id, "ask: write")).await;
    let pending = relay.note("_acpmux/permission_pending", |_| true).await;
    assert_eq!(pending["personInstance"], json!(named));
}

/// A config home for a daemon that `acpmux daemon start` launches.
fn start_home(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("ams-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("work")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
               "permissionPolicy": "ask"})
        .to_string(),
    )
    .unwrap();
    dir
}

/// `acpmux <args>` with this home, `stdin` as its standard input.
fn acpmux_cli(home: &Path, args: &[&str], stdin: Option<&str>) -> std::process::Output {
    // `daemon start` passes this environment on to the daemon it starts.
    let mut cmd = daemon_env::acpmux(home);
    cmd.args(args)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().unwrap();
    {
        use std::io::Write;
        let mut input = child.stdin.take().unwrap();
        if let Some(text) = stdin {
            input.write_all(text.as_bytes()).unwrap();
        }
    }
    child.wait_with_output().unwrap()
}

/// cx-0q7o slice 2a (D2): the app's own ssh exec runs `acpmux daemon start
/// --person-key-fd 0` with the key on stdin. The daemon it starts holds that
/// key (the app's proof makes a connection the person); a second keyed start
/// while a daemon runs refuses, since that daemon holds another key or none
/// (a keyed restart stops it first).
#[tokio::test]
async fn daemon_start_hands_its_stdin_key_to_the_daemon_it_starts() {
    let home = start_home("keyed");
    let out = acpmux_cli(
        &home,
        &["--json", "daemon", "start", "--person-key-fd", "0"],
        Some(&format!("{KEY}\n")),
    );
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let status: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(status["personKey"], true, "{status}");
    let socket = home.join("s.sock");
    let (_app, reply, _) = Rpc::person_with(&socket, KEY).await;
    assert!(reply.get("error").is_none(), "the started daemon does not hold the key: {reply}");
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        let pid = status["pid"].as_u64().unwrap();
        let meta = std::fs::metadata(format!("/proc/{pid}/environ")).unwrap();
        assert_eq!(meta.uid(), 0, "the keyed daemon is dumpable");
    }
    let again =
        acpmux_cli(&home, &["daemon", "start", "--person-key-fd", "0"], Some(&format!("{KEY}\n")));
    assert!(!again.status.success(), "a keyed start went on while a daemon runs");
    assert!(
        String::from_utf8_lossy(&again.stderr).contains("already runs"),
        "{}",
        String::from_utf8_lossy(&again.stderr)
    );
    let _ = acpmux_cli(&home, &["daemon", "shutdown", "--end-agents"], None);
    let _ = std::fs::remove_dir_all(&home);
}

/// cx-0q7o slice 2a (reviewer note 1): on a socket key descriptor the
/// daemon first makes itself not dumpable and says so ("nodump"), and only
/// then reads the key, so a same-uid process that opens
/// /proc/<pid>/fd/<n> before that finds no key to read.
#[cfg(target_os = "linux")]
#[test]
fn the_key_reaches_the_daemon_only_after_it_is_not_dumpable() {
    use std::io::{Read, Write};
    use std::os::fd::FromRawFd;
    use std::os::unix::fs::MetadataExt;
    let home = start_home("nodump");
    let mut fds = [-1i32; 2];
    // SAFETY: a fresh socket pair; both ends are owned here.
    let kind = libc::SOCK_STREAM | libc::SOCK_CLOEXEC;
    assert_eq!(unsafe { libc::socketpair(libc::AF_UNIX, kind, 0, fds.as_mut_ptr()) }, 0);
    let (ours, theirs) = (fds[0], fds[1]);
    let mut cmd = daemon_env::acpmux(&home);
    cmd.args([
        "daemon",
        "run",
        "--memory",
        "--ready-fd",
        "1",
        "--log",
        "warn",
        "--person-key-fd",
        "3",
    ])
    .env("ACPMUX_HOME", &home)
    .env("ACPMUX_SOCKET", home.join("s.sock"))
    .env("ACPMUX_LOGIN_ENV", "0")
    .stdin(std::process::Stdio::null())
    .stdout(std::process::Stdio::piped())
    .stderr(std::process::Stdio::null());
    // SAFETY: only dup2 between fork and exec (async-signal-safe).
    unsafe {
        cmd.pre_exec(move || {
            if libc::dup2(theirs, 3) < 0 || libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn().unwrap();
    // SAFETY: the child has its own copy on fd 3.
    unsafe { libc::close(theirs) };
    // SAFETY: our end, owned from here on.
    let mut link = unsafe { std::os::unix::net::UnixStream::from_raw_fd(ours) };
    link.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut said = [0u8; 7];
    link.read_exact(&mut said).expect("the daemon says nodump before it reads the key");
    assert_eq!(&said, b"nodump\n");
    let meta = std::fs::metadata(format!("/proc/{}/environ", child.id())).unwrap();
    assert_eq!(meta.uid(), 0, "the daemon asked for the key while dumpable");
    link.write_all(format!("{KEY}\n").as_bytes()).unwrap();
    link.shutdown(std::net::Shutdown::Write).unwrap();
    let ready = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map_while(Result::ok)
        .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
    assert!(ready, "the daemon exited before its ready line");
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (_app, reply, _) = rt.block_on(Rpc::person_with(&home.join("s.sock"), KEY));
    assert!(reply.get("error").is_none(), "the daemon does not hold the key: {reply}");
    // SAFETY: the pid of the child this test spawned and still owns.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&home);
}

/// cx-0q7o slice 2b review: a relayed allow for a prompt of THIS daemon,
/// from a connection that is not the person, counts only with the person's
/// proof for that prompt's own nonce. Proof fields with another nonce, or
/// the right nonce with a proof that is not the person's, are refused, and
/// the prompt stays pending (the person rule under the prompt's lock).
#[tokio::test]
async fn a_local_allow_with_a_wrong_nonce_or_a_wrong_proof_is_refused_and_stays_pending() {
    let d = Daemon::start("lock", Some(KEY));
    let mut relay = Rpc::connect(&d.socket).await;
    let id = new_session(&mut relay, &d).await;
    let rid = relay.send("session/prompt", prompt(&id, "ask: write")).await;
    let pending = relay.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();

    // (a) A nonce that is not this prompt's, with a proof that matches it.
    let other_nonce = "0".repeat(64);
    let for_other = decision_proof(KEY, &instance, &id, &pid, "yes", &other_nonce);
    let r = relay
        .call("_acpmux/permission_respond", decided(&id, &pid, "yes", &other_nonce, &for_other))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert_eq!(pending_ids(&mut relay, &id).await, vec![pid.clone()]);
    // (b) This prompt's nonce, with a proof that is not the person's.
    let forged = "ab".repeat(32);
    let r =
        relay.call("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &forged)).await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert_eq!(pending_ids(&mut relay, &id).await, vec![pid.clone()]);
    // The refused tries spent nothing: the person's proof for this nonce counts.
    let good = decision_proof(KEY, &instance, &id, &pid, "yes", &nonce);
    relay.ok("_acpmux/permission_respond", decided(&id, &pid, "yes", &nonce, &good)).await;
    assert_eq!(turn_said(&mut relay, rid).await, "chose yes");
}

/// The answer to `_acpmux/person_holds` (cx-0q7o slice 2c), as
/// `hub/person.rs` defines it: lowercase hex HMAC-SHA256(key,
/// "acpmux-person-holds-v1" 0 instance 0 nonce). Its own domain: it is never
/// a decision proof or a connection proof.
fn holds_proof(key: &str, instance: &str, nonce: &str) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).unwrap();
    let mut message = b"acpmux-person-holds-v1".to_vec();
    for part in [instance, nonce] {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    hex(&hmac_sha256(&key, &message))
}

/// cx-0q7o slice 2c: the app checks that a daemon it started holds ITS key,
/// over a fresh nonce of its own, before it relays any allow there. Whatever
/// answers on the socket path without the key cannot answer this. A daemon
/// without a key refuses; a malformed nonce is invalid; one connection gets
/// a few answers only.
#[tokio::test]
async fn a_keyed_daemon_proves_it_holds_the_key_over_the_apps_nonce() {
    let d = Daemon::start("holds", Some(KEY));
    let mut app = Rpc::connect(&d.socket).await;
    let init = app.call("initialize", json!({"protocolVersion": 1})).await;
    let instance = init["result"]["_meta"]["acpmux"]["personInstance"].as_str().unwrap().to_owned();
    let nonce = "3c".repeat(32);
    let r = app.call("_acpmux/person_holds", json!({"nonce": nonce})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(r["result"]["instance"], json!(instance), "{r}");
    assert_eq!(r["result"]["proof"], json!(holds_proof(KEY, &instance, &nonce)), "{r}");
    assert_ne!(r["result"]["proof"], json!(holds_proof(&"7".repeat(64), &instance, &nonce)));
    assert_ne!(
        r["result"]["proof"],
        json!(decision_proof(KEY, &instance, &nonce, "", "", "")),
        "the holds answer shares a domain with decision proofs"
    );
    let bad = app.call("_acpmux/person_holds", json!({"nonce": "short"})).await;
    assert_eq!(bad["error"]["code"], json!(-32602), "{bad}");
    for _ in 0..6 {
        let again = app.call("_acpmux/person_holds", json!({"nonce": "4d".repeat(32)})).await;
        assert!(again.get("error").is_none(), "{again}");
    }
    let limited = app.call("_acpmux/person_holds", json!({"nonce": "5e".repeat(32)})).await;
    assert_eq!(reason(&limited), "person.holds_limit", "{limited}");
    let mut fresh = Rpc::connect(&d.socket).await;
    let r = fresh.call("_acpmux/person_holds", json!({"nonce": nonce})).await;
    assert!(r.get("error").is_none(), "a new connection answers again: {r}");

    let plain = Daemon::start("noholds", None);
    let mut c = Rpc::connect(&plain.socket).await;
    let r = c.call("_acpmux/person_holds", json!({"nonce": nonce})).await;
    assert_eq!(reason(&r), "person.no_key", "{r}");
}

// ---- Phone approvers (cnx-ios verify/phone-approvals.md, hub/approvers.rs) ----

/// A phone's Secure Enclave key, as a software P-256 key.
fn phone_key() -> ring::signature::EcdsaKeyPair {
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair};
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// What the phone signs, as `hub/approvers.rs` defines it. Written out here
/// so the test states the wire contract.
#[allow(clippy::too_many_arguments)]
fn approver_signature(
    key: &ring::signature::EcdsaKeyPair,
    instance: &str,
    mac: &str,
    approver: &str,
    session: &str,
    permission: &str,
    option: &str,
    nonce: &str,
    expires: u64,
    answers_digest: &str,
) -> String {
    let expires = expires.to_string();
    let mut message = b"acpmux-approver-decision-v1".to_vec();
    for part in [
        instance,
        mac,
        approver,
        session,
        permission,
        option,
        nonce,
        expires.as_str(),
        answers_digest,
    ] {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    hex_of(key.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref())
}

fn signed(
    session: &str,
    permission: &str,
    option: &str,
    nonce: &str,
    approver: &str,
    expires: u64,
    sig: &str,
) -> Value {
    json!({"sessionId": session, "permissionId": permission, "optionId": option,
           "_meta": {"acpmux": {"decisionNonce": nonce,
               "approverDecision": {"approver": approver, "expiresAt": expires, "signature": sig}}}})
}

fn enroll(key: &ring::signature::EcdsaKeyPair) -> Value {
    use ring::signature::KeyPair;
    json!({"macDevice": "mac-1", "approvers": [
        {"id": "phone-1", "publicKey": hex_of(key.public_key().as_ref()), "name": "iPhone"}]})
}

/// Only the person enrolls approvers; an agent-side client can neither add
/// its own key nor read the list.
#[tokio::test]
async fn only_the_person_enrolls_approvers() {
    let d = Daemon::start("apset", Some(KEY));
    let key = phone_key();
    let mut agent = Rpc::connect(&d.socket).await;
    agent.initialize().await;
    let r = agent.call("_acpmux/approvers_set", enroll(&key)).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let r = agent.call("_acpmux/approvers", json!({})).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let mut app = Rpc::person(&d.socket, KEY).await;
    assert_eq!(app.ok("_acpmux/approvers_set", enroll(&key)).await["count"], 1);
    let listed = app.ok("_acpmux/approvers", json!({})).await;
    assert_eq!(listed["approvers"][0]["id"], "phone-1");
    assert_eq!(listed["macDevice"], "mac-1");
}

/// A phone's signed allow counts once, for that prompt, option, Mac and
/// daemon run, until it expires; a revoked phone's signature counts nothing.
#[tokio::test]
async fn a_phones_signed_allow_counts_once_and_stops_when_revoked() {
    let d = Daemon::start("apallow", Some(KEY));
    let key = phone_key();
    let mut app = Rpc::person(&d.socket, KEY).await;
    app.ok("_acpmux/approvers_set", enroll(&key)).await;
    let mut phone = Rpc::connect(&d.socket).await;
    let id = new_session(&mut phone, &d).await;

    let rid = phone.send("session/prompt", prompt(&id, "ask: write")).await;
    let pending = phone.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();
    let exp = unix_now() + 120;
    let sign = |k: &ring::signature::EcdsaKeyPair,
                inst: &str,
                mac: &str,
                option: &str,
                n: &str,
                e: u64| {
        approver_signature(k, inst, mac, "phone-1", &id, &pid, option, n, e, "")
    };

    // Unsigned, another option, Mac, daemon run or key, expired, or too far
    // ahead: refused, and the prompt stays pending.
    let r = phone
        .call(
            "_acpmux/permission_respond",
            json!({"sessionId": id, "permissionId": pid, "optionId": "yes"}),
        )
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    for (sig, e) in [
        (sign(&key, &instance, "mac-1", "no", &nonce, exp), exp),
        (sign(&key, &instance, "mac-2", "yes", &nonce, exp), exp),
        (sign(&key, "0123456789abcdef", "mac-1", "yes", &nonce, exp), exp),
        (sign(&phone_key(), &instance, "mac-1", "yes", &nonce, exp), exp),
        (sign(&key, &instance, "mac-1", "yes", &nonce, unix_now() - 5), unix_now() - 5),
        (sign(&key, &instance, "mac-1", "yes", &nonce, unix_now() + 900), unix_now() + 900),
    ] {
        let r = phone
            .call(
                "_acpmux/permission_respond",
                signed(&id, &pid, "yes", &nonce, "phone-1", e, &sig),
            )
            .await;
        assert_eq!(reason(&r), REASON, "{r}");
    }
    assert_eq!(pending_ids(&mut phone, &id).await, vec![pid.clone()]);

    // The phone's signature: the allow counts.
    let good = sign(&key, &instance, "mac-1", "yes", &nonce, exp);
    phone
        .ok("_acpmux/permission_respond", signed(&id, &pid, "yes", &nonce, "phone-1", exp, &good))
        .await;
    assert_eq!(turn_said(&mut phone, rid).await, "chose yes");

    // Replayed on the next prompt (spent nonce, other permission): refused.
    let rid = phone.send("session/prompt", prompt(&id, "ask: again")).await;
    let next = phone.note("_acpmux/permission_pending", |p| p["permissionId"] != json!(pid)).await;
    let pid2 = next["permissionId"].as_str().unwrap().to_owned();
    let nonce2 = next["decisionNonce"].as_str().unwrap().to_owned();
    let r = phone
        .call(
            "_acpmux/permission_respond",
            signed(&id, &pid2, "yes", &nonce, "phone-1", exp, &good),
        )
        .await;
    assert_eq!(reason(&r), REASON, "{r}");

    // Revoked: a fresh, valid signature counts nothing; a deny still does.
    app.ok("_acpmux/approvers_set", json!({"macDevice": "mac-1", "approvers": []})).await;
    let fresh = approver_signature(
        &key, &instance, "mac-1", "phone-1", &id, &pid2, "yes", &nonce2, exp, "",
    );
    let r = phone
        .call(
            "_acpmux/permission_respond",
            signed(&id, &pid2, "yes", &nonce2, "phone-1", exp, &fresh),
        )
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    phone
        .ok(
            "_acpmux/permission_respond",
            json!({"sessionId": id, "permissionId": pid2, "optionId": "no"}),
        )
        .await;
    assert_eq!(turn_said(&mut phone, rid).await, "chose no");
}

/// A phone answers a question with a signature that covers the answers:
/// other answers under the same signature count nothing.
#[tokio::test]
async fn a_phones_signed_answer_covers_exactly_its_answers() {
    let d = Daemon::start("apq", Some(KEY));
    let key = phone_key();
    let mut app = Rpc::person(&d.socket, KEY).await;
    app.ok("_acpmux/approvers_set", enroll(&key)).await;
    let mut phone = Rpc::connect(&d.socket).await;
    let id = new_session(&mut phone, &d).await;
    let rid = phone.send("session/prompt", prompt(&id, "question: Which one?")).await;
    let pending = phone.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();
    let exp = unix_now() + 120;
    // sha256 of the canonical answers JSON `{"Which one?":"B"}`.
    use sha2::Digest;
    let digest = hex_of(&sha2::Sha256::digest(br#"{"Which one?":"B"}"#));
    let sig = approver_signature(
        &key,
        &instance,
        "mac-1",
        "phone-1",
        &id,
        &pid,
        "allow_once",
        &nonce,
        exp,
        &digest,
    );
    let mut swapped = signed(&id, &pid, "allow_once", &nonce, "phone-1", exp, &sig);
    swapped["answers"] = json!({"Which one?": "A"});
    let r = phone.call("_acpmux/permission_respond", swapped).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let mut answer = signed(&id, &pid, "allow_once", &nonce, "phone-1", exp, &sig);
    answer["answers"] = json!({"Which one?": "B"});
    phone.ok("_acpmux/permission_respond", answer).await;
    assert_eq!(turn_said(&mut phone, rid).await, r#"chose allow_once {"Which one?": "B"}"#);
}

/// The decision proof of a relayed answer to a question (cmux NEXT's pane, a chat on another
/// machine): as [`decision_proof`] under "acpmux-person-decision-answers-v1", with the
/// sha256 of the canonical answers JSON (`approvers::answers_digest`) as a sixth part, and the
/// sha256 of the canonical annotations JSON as a seventh when the answer has annotations.
fn decision_answers_proof(
    key: &str,
    parts: [&str; 5],
    canonical_answers: &str,
    canonical_annotations: Option<&str>,
) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    use sha2::Digest;
    let key = unhex::<32>(key).unwrap();
    let digest = |text: &str| hex_of(&sha2::Sha256::digest(text.as_bytes()));
    let digests: Vec<String> = [Some(canonical_answers), canonical_annotations]
        .into_iter()
        .flatten()
        .map(digest)
        .collect();
    let mut message = b"acpmux-person-decision-answers-v1".to_vec();
    for part in parts.into_iter().chain(digests.iter().map(String::as_str)) {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    hex(&hmac_sha256(&key, &message))
}

/// Leo 2026-10-21: answering an agent's question in the app's pane, for a chat on an ssh peer,
/// was refused as "accepted only from the cmux app". A relayed answer counts with the person's
/// decision proof over exactly its answers; a proof that covers no answers, or other answers,
/// counts nothing and the question stays pending.
#[tokio::test]
async fn a_relayed_answer_counts_with_the_persons_proof_over_exactly_its_answers() {
    let d = Daemon::start("decans", Some(KEY));
    let mut relay = Rpc::connect(&d.socket).await;
    let id = new_session(&mut relay, &d).await;
    let rid = relay.send("session/prompt", prompt(&id, "question: Which one?")).await;
    let pending = relay.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();
    let answered = |proof: &str, answers: Value| {
        let mut frame = decided(&id, &pid, "allow_once", &nonce, proof);
        frame["answers"] = answers;
        frame
    };
    let parts = [instance.as_str(), id.as_str(), pid.as_str(), "allow_once", nonce.as_str()];

    let covers_none = decision_proof(KEY, &instance, &id, &pid, "allow_once", &nonce);
    let r = relay
        .call("_acpmux/permission_respond", answered(&covers_none, json!({"Which one?": "B"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    let for_b = decision_answers_proof(KEY, parts, r#"{"Which one?":"B"}"#, None);
    let r = relay
        .call("_acpmux/permission_respond", answered(&for_b, json!({"Which one?": "A"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert_eq!(pending_ids(&mut relay, &id).await, vec![pid.clone()]);

    relay.ok("_acpmux/permission_respond", answered(&for_b, json!({"Which one?": "B"}))).await;
    assert_eq!(turn_said(&mut relay, rid).await, r#"chose allow_once {"Which one?": "B"}"#);
}

/// The answers proof's bytes, as the Mac app computes them too
/// (`AcpmuxPersonKeyAnswersProofTests`): key order by bytes, escapes as `approvers::canonical_json`.
#[test]
fn the_answers_decision_proof_matches_the_apps_vector() {
    let answers = json!({"Which one?": "B", "Pick a color\n(one)": ["red", "blue"], "é": "\u{1}"});
    let proof = acpmux::hub::person::decision_answers_proof(
        KEY,
        "0123456789abcdef",
        "sess-1",
        "perm-1",
        "allow_once",
        "nonce-1",
        &answers,
        None,
    );
    assert_eq!(
        proof.as_deref(),
        Some("3b11c2af201d95772c106a4c8463a54b94e615f85e88eac0700f7d657c24f0e9")
    );
    // With annotations (a preview with a line break and a character past the BMP).
    let annotations = json!({"Which one?": {"preview": "[ B ]\n\u{1F600}", "notes": "n"}});
    let proof = acpmux::hub::person::decision_answers_proof(
        KEY,
        "0123456789abcdef",
        "sess-1",
        "perm-1",
        "allow_once",
        "nonce-1",
        &answers,
        Some(&annotations),
    );
    assert_eq!(
        proof.as_deref(),
        Some("03512f50a44821e899adf320ffd8babf9fc9a34c105e62b4861103c901da6992")
    );
}

/// #24356's chosen preview and notes, answered in the pane for a chat on another machine: they
/// count only under the person's proof over exactly those annotations. A proof over the answers
/// alone or a proof over other notes counts nothing and the question stays pending; the agent
/// gets them only from the proved answer.
#[tokio::test]
async fn a_relayed_answers_annotations_count_only_under_the_persons_proof_over_them() {
    let d = Daemon::start("decnotes", Some(KEY));
    let mut relay = Rpc::connect(&d.socket).await;
    let id = new_session(&mut relay, &d).await;
    let rid = relay.send("session/prompt", prompt(&id, "preview-question: Which layout?")).await;
    let pending = relay.note("_acpmux/permission_pending", |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let nonce = pending["decisionNonce"].as_str().unwrap().to_owned();
    let instance = pending["personInstance"].as_str().unwrap().to_owned();
    let answered = |proof: &str, notes: &str| {
        let mut frame = decided(&id, &pid, "allow_once", &nonce, proof);
        frame["answers"] = json!({"Which layout?": "B"});
        frame["annotations"] = json!({"Which layout?": {"preview": "[ B ]", "notes": notes}});
        frame
    };
    let parts = [instance.as_str(), id.as_str(), pid.as_str(), "allow_once", nonce.as_str()];
    let answers = r#"{"Which layout?":"B"}"#;
    let narrower = r#"{"Which layout?":{"notes":"but narrower","preview":"[ B ]"}}"#;

    let answers_only = decision_answers_proof(KEY, parts, answers, None);
    let r = relay.call("_acpmux/permission_respond", answered(&answers_only, "but narrower")).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let for_narrower = decision_answers_proof(KEY, parts, answers, Some(narrower));
    let r = relay.call("_acpmux/permission_respond", answered(&for_narrower, "but wider")).await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert_eq!(pending_ids(&mut relay, &id).await, vec![pid.clone()]);

    relay.ok("_acpmux/permission_respond", answered(&for_narrower, "but narrower")).await;
    assert_eq!(
        turn_said(&mut relay, rid).await,
        r#"got {"annotations": {"Which layout?": {"notes": "but narrower", "preview": "[ B ]\n"}}, "answers": {"Which layout?": "B"}}"#
    );
}
