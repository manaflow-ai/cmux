//! Only the person-facing app may allow (cx-1l61). The real daemon binary,
//! over its real unix socket: a client that did not present this launch's
//! person key (the acpmux CLI, the TUI, an agent that runs the CLI) may read
//! a prompt and deny or cancel it, never allow it, and never widen what the
//! session or the daemon runs without asking. The refusal is the declared
//! error `permission.person_required`; the prompt stays pending. A
//! connection that presented the key (the app's own connection; the key
//! comes to an unsigned daemon only on `--person-key-fd` at spawn) may.
#![cfg(unix)]

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

    /// A connection that presents `key` in its first `initialize`.
    async fn person(path: &Path, key: &str) -> Self {
        let mut c = Self::connect(path).await;
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1, "_meta": {"acpmux": {"personKey": key}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "initialize: {r}");
        c
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
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_acpmux"));
        cmd.args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env_remove("ACPMUX_LOGIN_ENV")
            .env_remove("XPC_SERVICE_NAME")
            .env_remove("CLAUDECODE")
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

    // A later `initialize` on a plain connection never makes it a person.
    let late = agent
        .call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": {"personKey": KEY}}}))
        .await;
    assert!(late.get("error").is_none(), "{late}");
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
