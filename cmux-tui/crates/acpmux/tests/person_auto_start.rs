//! A session that starts in a mode that does not ask, from the CLI, a script
//! or an agent (`hub/person.rs`, "Starting in a mode that does not ask").
//! The real daemon binary over its real unix socket:
//!
//! - (a) inherit: a caller that is itself an acpmux session, proven by the
//!   caller token acpmux put in that session's env (never by a claim in
//!   params), may start a session of its own family in its own current mode,
//!   never another mode that does not ask;
//! - (b) a preset the person approved once (`approveMode`) starts in its
//!   mode from any client, until the preset changes;
//! - (d) every refusal names the host to approve on and the preset to use.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;

const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const REASON: &str = "permission.person_required";
/// A caller token a profile or preset env tries to set in place of acpmux's.
const FORGED_TOKEN: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

fn person_proof(key: &str, nonce: &str, connection: &str) -> Option<String> {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key)?;
    let mut message = b"acpmux-person-v1\0unix\0".to_vec();
    message.extend_from_slice(nonce.as_bytes());
    message.push(0);
    message.extend_from_slice(connection.as_bytes());
    Some(hex(&hmac_sha256(&key, &message)))
}

/// The host the refusal names: this machine's host name without `.local`.
fn host_label() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: a writable buffer of the given length.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    assert_eq!(rc, 0, "gethostname");
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = String::from_utf8_lossy(&buf[..end]).trim().to_owned();
    name.strip_suffix(".local").map(str::to_owned).unwrap_or(name)
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
    notes: Vec<Value>,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0, notes: Vec::new() }
    }

    /// A client that only says `initialize` (the CLI outside any session).
    async fn plain(path: &Path) -> Self {
        Self::with_init(path, json!({"protocolVersion": 1})).await
    }

    /// A client whose `initialize` carries `params` (the CLI inside a
    /// session presents its caller token there).
    async fn with_init(path: &Path, params: Value) -> Self {
        let mut c = Self::connect(path).await;
        let r = c.call("initialize", params).await;
        assert!(r.get("error").is_none(), "initialize: {r}");
        c
    }

    /// The CLI inside session `id`, as `Client::connect` presents it.
    async fn in_session(path: &Path, id: &str, token: &str) -> Self {
        Self::with_init(
            path,
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await
    }

    /// The app: `initialize`, then the person proof.
    async fn person(path: &Path, key: &str) -> Self {
        let mut c = Self::connect(path).await;
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = r["result"]["_meta"]["acpmux"]["personChallenge"].clone();
        let proof = person_proof(
            key,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(r["result"]["person"], true, "{r}");
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

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply(id).await
    }

    async fn reply(&mut self, id: i64) -> Value {
        if let Some(i) = self.notes.iter().position(|n| n.get("id") == Some(&json!(id))) {
            return self.notes.remove(i);
        }
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
    /// The real daemon with the app's key on `--person-key-fd 3`. The fake
    /// harness asks in `normal` and `strict`; any other mode does not ask.
    /// `wide` also offers `full-access`, the start mode of a new chat
    /// (`hub/start_mode.rs`, `defaultPermissionMode` set for a hermetic run).
    fn start(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("aas-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("work")).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        std::fs::write(
            dir.join("config.json"),
            json!({
                "harnesses": {
                    "fake": {"argv": ["python3", FAKE]},
                    "mirror": {"argv": ["python3", FAKE], "family": "mirror"},
                    "other": {"argv": ["python3", FAKE], "family": "fake", "env": {"FAKE_SESSION_PREFIX": "other-"}},
                    "gated": {"argv": ["python3", FAKE], "family": "fake", "env": {"FAKE_START_GATE": dir.join("gate")}},
                    "wide": {"argv": ["python3", FAKE], "family": "wide", "env": {"FAKE_FULL_ACCESS": "1"}},
                    "forger": {"argv": ["python3", FAKE], "family": "fake", "env": {"ACPMUX_SESSION_TOKEN": FORGED_TOKEN, "ACPMUX_SESSION_TOKEN_SOCKET": "/tmp/acpmux-forged.sock"}},
                },
                "defaultHarness": "fake",
                "permissionPolicy": "ask",
                "defaultPermissionMode": "fullAccess",
                "webAskingModes": {"fake": ["normal", "strict"], "mirror": ["normal", "strict"], "wide": ["normal", "strict"]},
            })
            .to_string(),
        )
        .unwrap();
        let socket = dir.join("s.sock");
        let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
        cmd.args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
            .args(["--person-key-fd", "3"])
            .env("ACPMUX_HOME", &dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env_remove("ACPMUX_SESSION_ID")
            .env_remove("ACPMUX_SESSION_TOKEN")
            .env_remove("XPC_SERVICE_NAME")
            .env_remove("CLAUDECODE")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        // The key pipe is close-on-exec (`std::io::pipe`), so a daemon another
        // test spawns at the same moment never inherits its write end and
        // holds this daemon's key read open (two daemons that each held the
        // other's never got their key: both tests hung).
        let (reader, mut writer) = std::io::pipe().unwrap();
        std::io::Write::write_all(&mut writer, format!("{KEY}\n").as_bytes()).unwrap();
        drop(writer);
        let read_end = std::os::fd::AsRawFd::as_raw_fd(&reader);
        // SAFETY: only dup2 and fcntl between fork and exec (async-signal-safe).
        unsafe {
            cmd.pre_exec(move || {
                if read_end == 3 {
                    // dup2 onto itself keeps close-on-exec: clear it.
                    if libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                } else if libc::dup2(read_end, 3) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = cmd.spawn().unwrap();
        // The child has its own copy on fd 3.
        drop(reader);
        let stdout = child.stdout.take().unwrap();
        let ready = BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
        assert!(ready, "the daemon exited before its ready line");
        Daemon { child, socket, dir }
    }

    fn work(&self) -> PathBuf {
        self.dir.join("work")
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid of the child this test spawned and still owns.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        // A daemon that does not stop in time is killed, so a failed test
        // never hangs here holding its agents' stdin open.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while matches!(self.child.try_wait(), Ok(None)) && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

fn message(v: &Value) -> &str {
    v["error"]["message"].as_str().unwrap_or_default()
}

/// `session/new` params on `harness` with `_meta.acpmux` fields `meta`.
fn new_params(d: &Daemon, meta: Value) -> Value {
    json!({"cwd": d.work(), "mcpServers": [], "_meta": {"acpmux": meta}})
}

fn current_mode(new_result: &Value) -> &str {
    new_result["modes"]["currentModeId"].as_str().unwrap_or_default()
}

async fn session_count(c: &mut Rpc) -> usize {
    let v = c.ok("_acpmux/sessions", json!({})).await;
    v["sessions"].as_array().map_or(0, Vec::len)
}

/// The person's session on `harness` in `mode`, and the caller token its
/// agent sees in its env (`ACPMUX_SESSION_TOKEN`).
async fn parent_in(app: &mut Rpc, d: &Daemon, harness: &str, mode: &str) -> (String, String) {
    let s = app.ok("session/new", new_params(d, json!({"harness": harness}))).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    app.ok("_acpmux/attach", json!({"sessionId": id})).await;
    app.ok("session/set_mode", json!({"sessionId": id, "modeId": mode})).await;
    let rid = app
        .send(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "env: ACPMUX_SESSION_TOKEN"}]}),
        )
        .await;
    let chunk = app
        .note("session/update", |p| {
            p["sessionId"] == id.as_str() && p["update"]["sessionUpdate"] == "agent_message_chunk"
        })
        .await;
    let text = chunk["update"]["content"]["text"].as_str().unwrap_or_default().to_owned();
    let done = app.reply(rid).await;
    assert!(done.get("error").is_none(), "{done}");
    let token = text.strip_prefix("ACPMUX_SESSION_TOKEN=").unwrap_or_default().to_owned();
    assert_eq!(token.len(), 64, "the session's agent gets a caller token: {text:?}");
    // acpmux never shows the token to clients (only the agent's own reply,
    // which printed it here, carries it).
    let mut info = app.ok("_acpmux/info", json!({"sessionId": id})).await;
    for echoed in ["lastMessage", "preview"] {
        info.as_object_mut().unwrap().remove(echoed);
    }
    assert!(!info.to_string().contains(&token), "{info}");
    (id, token)
}

#[tokio::test]
async fn auto_start_a_session_in_a_no_ask_mode_starts_a_session_in_its_own_mode() {
    let d = Daemon::start("inherit");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let (parent, token) = parent_in(&mut app, &d, "fake", "bypass").await;
    let mut agent = Rpc::in_session(&d.socket, &parent, &token).await;
    let child =
        agent.ok("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"}))).await;
    assert_eq!(current_mode(&child), "bypass", "{child}");
    let info = agent.ok("_acpmux/info", json!({"sessionId": child["sessionId"]})).await;
    assert_eq!(info["modes"]["currentModeId"], "bypass", "{info}");
    // An asking mode needs no caller at all.
    let mut cli = Rpc::plain(&d.socket).await;
    let asking =
        cli.ok("session/new", new_params(&d, json!({"harness": "fake", "mode": "strict"}))).await;
    assert_eq!(current_mode(&asking), "strict", "{asking}");
}

#[tokio::test]
async fn auto_start_a_caller_that_is_no_session_needs_the_person_for_a_mode_that_does_not_ask() {
    let d = Daemon::start("nosession");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let _ = parent_in(&mut app, &d, "fake", "bypass").await;
    let mut cli = Rpc::plain(&d.socket).await;
    let before = session_count(&mut cli).await;
    let r =
        cli.call("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // Refused before anything starts.
    assert_eq!(session_count(&mut cli).await, before);
    // The person may.
    let s =
        app.ok("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"}))).await;
    assert_eq!(current_mode(&s), "bypass", "{s}");
}

#[tokio::test]
async fn auto_start_a_session_never_starts_one_in_another_mode_that_does_not_ask() {
    let d = Daemon::start("stronger");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let (bypass, bypass_token) = parent_in(&mut app, &d, "fake", "bypass").await;
    let (asking, asking_token) = parent_in(&mut app, &d, "fake", "normal").await;
    let mut agent = Rpc::in_session(&d.socket, &bypass, &bypass_token).await;
    // Another mode that does not ask: refused.
    let r =
        agent.call("session/new", new_params(&d, json!({"harness": "fake", "mode": "yolo"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // Its own mode on another family (mode ids are per family): refused.
    let r = agent
        .call("session/new", new_params(&d, json!({"harness": "mirror", "mode": "bypass"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    // A session that asks starts nothing that does not ask.
    let mut asker = Rpc::in_session(&d.socket, &asking, &asking_token).await;
    let r = asker
        .call("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    // A caller that left its no-ask mode inherits nothing any more.
    app.ok("session/set_mode", json!({"sessionId": bypass, "modeId": "normal"})).await;
    let r = agent
        .call("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
}

#[tokio::test]
async fn auto_start_a_caller_session_named_in_params_or_with_a_wrong_token_counts_for_nothing() {
    let d = Daemon::start("spoof");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let (parent, token) = parent_in(&mut app, &d, "fake", "bypass").await;
    // A wrong token at initialize.
    let mut wrong = Rpc::in_session(&d.socket, &parent, &"0".repeat(64)).await;
    let r = wrong
        .call("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    // The parent named in the request's params, even with its real token:
    // only the connection's own initialize binds a caller.
    let mut cli = Rpc::plain(&d.socket).await;
    let spoofed = new_params(
        &d,
        json!({"harness": "fake", "mode": "bypass", "parentSessionId": parent,
               "callerSession": {"sessionId": parent, "token": token}}),
    );
    let r = cli.call("session/new", spoofed).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // Another session's token under this session's id.
    let (other, other_token) = parent_in(&mut app, &d, "fake", "normal").await;
    assert_ne!(other, parent);
    let mut swapped = Rpc::in_session(&d.socket, &parent, &other_token).await;
    let r = swapped
        .call("session/new", new_params(&d, json!({"harness": "fake", "mode": "bypass"})))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
}

#[tokio::test]
async fn auto_start_a_preset_the_person_approved_starts_in_its_mode_from_the_cli() {
    let d = Daemon::start("preset");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut cli = Rpc::plain(&d.socket).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "fake", "mode": "bypass"}, "approveMode": true}),
    )
    .await;
    let view = cli.ok("_acpmux/presets", json!({"name": "lane"})).await;
    assert_eq!(view["mode"], "bypass", "{view}");
    assert_eq!(view["modeApproved"], true, "{view}");
    let s = cli.ok("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    assert_eq!(current_mode(&s), "bypass", "{s}");
    // The approval covers the preset's own mode, never another one.
    let r =
        cli.call("session/new", new_params(&d, json!({"preset": "lane", "mode": "yolo"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
}

#[tokio::test]
async fn auto_start_a_preset_changed_after_its_approval_loses_it() {
    let d = Daemon::start("edited");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut cli = Rpc::plain(&d.socket).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "fake", "mode": "bypass"}, "approveMode": true}),
    )
    .await;
    // Any client may change the harness or model (they never set a mode
    // that does not ask by themselves): the approval no longer covers it.
    cli.ok("_acpmux/presets", json!({"name": "lane", "set": {"harness": "mirror"}})).await;
    let view = cli.ok("_acpmux/presets", json!({"name": "lane"})).await;
    assert_eq!(view["modeApproved"], false, "{view}");
    let r = cli.call("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
    // The approval is bound to the preset's contents: the exact contents
    // the person approved are approved again.
    cli.ok("_acpmux/presets", json!({"name": "lane", "set": {"harness": "fake"}})).await;
    let view = cli.ok("_acpmux/presets", json!({"name": "lane"})).await;
    assert_eq!(view["modeApproved"], true, "{view}");
    // A model change drops it too, and so does the person's own edit.
    app.ok("_acpmux/presets", json!({"name": "lane", "set": {"model": "m2"}})).await;
    let view = cli.ok("_acpmux/presets", json!({"name": "lane"})).await;
    assert_eq!(view["modeApproved"], false, "{view}");
    let r = cli.call("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
}

#[tokio::test]
async fn auto_start_only_the_person_approves_a_preset_mode_or_sets_one_that_does_not_ask() {
    let d = Daemon::start("approve");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut cli = Rpc::plain(&d.socket).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "fake", "mode": "bypass"}}),
    )
    .await;
    for p in [
        json!({"name": "lane", "approveMode": true}),
        json!({"name": "lane", "set": {"model": "m1"}, "approveMode": true}),
        json!({"name": "other", "set": {"harness": "fake", "mode": "yolo"}}),
        json!({"name": "lane", "set": {"mode": "yolo"}}),
    ] {
        let r = cli.call("_acpmux/presets", p.clone()).await;
        assert_eq!(reason(&r), REASON, "{p}: {r}");
    }
    let view = cli.ok("_acpmux/presets", json!({"name": "lane"})).await;
    assert_eq!(view["modeApproved"], false, "{view}");
    assert_eq!(view["mode"], "bypass", "{view}");
    // A mode that asks, and withdrawing an approval, stay open.
    cli.ok(
        "_acpmux/presets",
        json!({"name": "careful", "set": {"harness": "fake", "mode": "strict"}}),
    )
    .await;
    cli.ok("_acpmux/presets", json!({"name": "lane", "approveMode": false})).await;
    // Unapproved, the preset's mode is refused from the CLI.
    let r = cli.call("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
}

#[tokio::test]
async fn auto_start_a_refused_start_mode_names_the_host_and_the_preset_to_approve() {
    let d = Daemon::start("where");
    let mut app = Rpc::person(&d.socket, KEY).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "fake", "mode": "bypass"}}),
    )
    .await;
    let mut cli = Rpc::plain(&d.socket).await;
    let host = host_label();
    // Through a preset: the message names it.
    let r = cli.call("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    assert_eq!(reason(&r), REASON, "{r}");
    let text = message(&r);
    assert!(text.contains(&format!("cmux NEXT on {host}")), "{text}");
    assert!(text.contains("preset lane"), "{text}");
    assert_eq!(text.matches(". ").count(), 0, "one sentence: {text}");
    assert_eq!(r["error"]["data"]["host"], host.as_str(), "{r}");
    assert_eq!(r["error"]["data"]["preset"], "lane", "{r}");
    assert_eq!(r["error"]["data"]["mode"], "bypass", "{r}");
    // Without one: the message says to approve a preset once.
    let r =
        cli.call("session/new", new_params(&d, json!({"harness": "fake", "mode": "yolo"}))).await;
    let text = message(&r);
    assert!(text.contains(&format!("cmux NEXT on {host}")), "{text}");
    assert!(text.contains("preset"), "{text}");
    // A mode change on a running session names the host too.
    let s = cli.ok("session/new", new_params(&d, json!({"harness": "fake"}))).await;
    let r = cli
        .call("session/set_mode", json!({"sessionId": s["sessionId"], "modeId": "bypass"}))
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert!(message(&r).contains(&format!("cmux NEXT on {host}")), "{r}");
}

/// Session `id`'s mode now.
async fn mode(c: &mut Rpc, id: Value) -> String {
    let info = c.ok("_acpmux/info", json!({"sessionId": id})).await;
    info["modes"]["currentModeId"].as_str().unwrap_or_default().to_owned()
}

/// The start mode of a new chat (`hub/start_mode.rs`: full access by
/// default) never widens a caller session: a session in a mode that asks
/// starts its chats in that mode (`start_mode.rs`, "Inherit"); one in full
/// access starts them in full access, as the person's chats start.
#[tokio::test]
async fn auto_start_the_default_full_access_never_widens_a_caller_session_that_asks() {
    let d = Daemon::start("default");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let own = app.ok("session/new", new_params(&d, json!({"harness": "wide"}))).await;
    assert_eq!(mode(&mut app, own["sessionId"].clone()).await, "full-access", "{own}");
    let (asking, token) = parent_in(&mut app, &d, "wide", "strict").await;
    let mut agent = Rpc::in_session(&d.socket, &asking, &token).await;
    let child = agent.ok("session/new", new_params(&d, json!({"harness": "wide"}))).await;
    assert_eq!(mode(&mut agent, child["sessionId"].clone()).await, "strict", "{child}");
    let (wide, token) = parent_in(&mut app, &d, "wide", "full-access").await;
    let mut agent = Rpc::in_session(&d.socket, &wide, &token).await;
    let child = agent.ok("session/new", new_params(&d, json!({"harness": "wide"}))).await;
    assert_eq!(mode(&mut agent, child["sessionId"].clone()).await, "full-access", "{child}");
}

/// An adopt that finds a session already running never moves it to the
/// caller's mode: a caller in a no-ask mode that names another running
/// session's conversation with `ifLive: "open"` is refused, and that
/// session stays in the mode that asks (only the person widens a running
/// session, `session/set_mode`).
#[tokio::test]
async fn auto_start_an_adopt_never_moves_a_running_session_to_the_callers_mode() {
    let d = Daemon::start("adopt");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let (parent, token) = parent_in(&mut app, &d, "fake", "bypass").await;
    let (running, _) = parent_in(&mut app, &d, "other", "normal").await;
    let info = app.ok("_acpmux/info", json!({"sessionId": running})).await;
    let agent_session = info["agentSessionId"].as_str().expect("its conversation id").to_owned();
    let mut agent = Rpc::in_session(&d.socket, &parent, &token).await;
    let r = agent
        .call(
            "session/new",
            new_params(
                &d,
                json!({"harness": "fake", "mode": "bypass",
                       "adopt": {"agentSessionId": agent_session, "ifLive": "open"}}),
            ),
        )
        .await;
    assert_eq!(reason(&r), REASON, "{r}");
    assert_eq!(mode(&mut app, json!(running)).await, "normal");
}

/// A preset's approval holds for the contents the session runs: a session
/// started from an approved preset whose preset changed afterwards comes back
/// from a respawn in the harness's own mode, not the approved one.
#[tokio::test]
async fn auto_start_an_approved_preset_edited_then_respawned_leaves_its_no_ask_mode() {
    let d = Daemon::start("respawn");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut cli = Rpc::plain(&d.socket).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "fake", "mode": "bypass"}, "approveMode": true}),
    )
    .await;
    let s = cli.ok("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(mode(&mut cli, json!(id)).await, "bypass");
    // Any client may change the preset; the approval no longer covers it.
    cli.ok("_acpmux/presets", json!({"name": "lane", "set": {"model": "m2"}})).await;
    cli.ok("_acpmux/attach", json!({"sessionId": id})).await;
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    cli.ok("session/prompt", prompt("answer-then-exit")).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    // The next prompt respawns the harness from the changed preset.
    cli.ok("session/prompt", prompt("hello")).await;
    // The harness's own mode, not the approved one replayed (the fake's
    // session/load reports none, so acpmux knows no mode).
    assert_ne!(mode(&mut cli, json!(id)).await, "bypass");
}

/// An approved preset starts exactly what the person approved: a request
/// that adds its own model, effort, policy or env to it needs the person.
#[tokio::test]
async fn auto_start_an_approved_preset_with_request_overrides_needs_the_person() {
    let d = Daemon::start("override");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut cli = Rpc::plain(&d.socket).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "fake", "mode": "bypass"}, "approveMode": true}),
    )
    .await;
    for extra in [
        json!({"model": "m2"}),
        json!({"effort": "high"}),
        json!({"policy": "approve-all"}),
        json!({"env": {"FOO": "1"}}),
        json!({"route": "lane-route"}),
    ] {
        let mut meta = json!({"preset": "lane"});
        for (k, v) in extra.as_object().unwrap() {
            meta[k] = v.clone();
        }
        let r = cli.call("session/new", new_params(&d, meta)).await;
        assert_eq!(reason(&r), REASON, "{extra}: {r}");
    }
    // Its own folder is fine.
    let s = cli.ok("session/new", new_params(&d, json!({"preset": "lane"}))).await;
    assert_eq!(current_mode(&s), "bypass", "{s}");
}

/// An approved preset's start counts only the contents its own harness was
/// spawned with. Another request on the session while that harness starts
/// (after any client edited the preset) spawns nothing and records nothing,
/// so the start, which spawned the approved contents, keeps its mode.
#[tokio::test]
async fn auto_start_a_request_during_the_start_never_rebinds_the_approval() {
    let d = Daemon::start("race");
    let mut app = Rpc::person(&d.socket, KEY).await;
    let mut cli = Rpc::plain(&d.socket).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "lane", "set": {"harness": "gated", "mode": "bypass"}, "approveMode": true}),
    )
    .await;
    // The harness waits at its gate, so the start holds the session's spawn.
    let mut starter = Rpc::plain(&d.socket).await;
    let rid = starter
        .send("session/new", new_params(&d, json!({"preset": "lane", "name": "racing"})))
        .await;
    let id = loop {
        let list = cli.ok("_acpmux/sessions", json!({})).await;
        let found = list["sessions"]
            .as_array()
            .and_then(|a| a.iter().find(|s| s["name"] == "racing").map(|s| s["sessionId"].clone()));
        if let Some(id) = found {
            break id;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    tokio::time::sleep(Duration::from_millis(500)).await;
    // Meanwhile a client edits the preset and asks the starting session for something.
    cli.ok("_acpmux/presets", json!({"name": "lane", "set": {"model": "m2"}})).await;
    let mut other = Rpc::plain(&d.socket).await;
    other
        .send(
            "session/set_config_option",
            json!({"sessionId": id, "configId": "effort", "value": "high"}),
        )
        .await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    std::fs::write(d.dir.join("gate"), "").unwrap();
    let s = starter.reply(rid).await;
    assert!(s.get("error").is_none(), "{s}");
    assert_eq!(current_mode(&s["result"]), "bypass", "{s}");
}

/// The gated harness never outlives the daemon holding its stdin: a test that
/// fails before it opens the gate leaves no agent polling for it (257 were
/// left on huge-blue, 2026-10-21). What the daemon sent before the gate opens
/// is still read after it.
#[test]
fn auto_start_a_gated_agent_exits_with_its_daemon_and_keeps_what_came_first() {
    use std::io::Write;
    let dir = std::env::temp_dir().join(format!("aas-gate-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let gate = dir.join("gate");
    let spawn = || {
        std::process::Command::new("python3")
            .arg(FAKE)
            .env("FAKE_START_GATE", &gate)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap()
    };
    let exited = |child: &mut std::process::Child| {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(Some(_)) = child.try_wait() {
                return true;
            }
            if std::time::Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    };

    let mut waiting = spawn();
    std::thread::sleep(Duration::from_millis(300));
    drop(waiting.stdin.take());
    assert!(exited(&mut waiting), "a gated agent outlived the stdin of its daemon");

    let mut early = spawn();
    let mut stdin = early.stdin.take().unwrap();
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}});
    writeln!(stdin, "{init}").unwrap();
    std::thread::sleep(Duration::from_millis(300));
    std::fs::write(&gate, "").unwrap();
    let mut line = String::new();
    BufReader::new(early.stdout.take().unwrap()).read_line(&mut line).unwrap();
    drop(stdin);
    assert!(exited(&mut early), "the agent did not exit at EOF after its gate");
    let _ = std::fs::remove_dir_all(&dir);
    let reply: Value = serde_json::from_str(&line).unwrap_or_else(|e| panic!("{e}: {line:?}"));
    assert_eq!(reply["id"], 1, "{reply}");
}

/// The caller token and its socket are acpmux's own: a harness profile's or
/// a preset's env that names them is dropped, so an agent never runs with a
/// token or socket its config chose (`hub/person.rs` (a)).
#[tokio::test]
async fn auto_start_a_profile_or_preset_env_never_sets_the_caller_token() {
    let d = Daemon::start("forged");
    let mut app = Rpc::person(&d.socket, KEY).await;
    app.ok(
        "_acpmux/presets",
        json!({"name": "forging", "set": {"harness": "fake",
               "env": {"ACPMUX_SESSION_TOKEN": FORGED_TOKEN,
                       "ACPMUX_SESSION_TOKEN_SOCKET": "/tmp/acpmux-forged.sock"}}}),
    )
    .await;
    for meta in [json!({"harness": "forger"}), json!({"preset": "forging"})] {
        let s = app.ok("session/new", new_params(&d, meta.clone())).await;
        let id = s["sessionId"].as_str().unwrap().to_owned();
        app.ok("_acpmux/attach", json!({"sessionId": id})).await;
        for name in ["ACPMUX_SESSION_TOKEN", "ACPMUX_SESSION_TOKEN_SOCKET"] {
            let rid = app
                .send(
                    "session/prompt",
                    json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("env: {name}")}]}),
                )
                .await;
            let chunk = app
                .note("session/update", |p| {
                    p["sessionId"] == id.as_str()
                        && p["update"]["sessionUpdate"] == "agent_message_chunk"
                })
                .await;
            let done = app.reply(rid).await;
            assert!(done.get("error").is_none(), "{done}");
            let text = chunk["update"]["content"]["text"].as_str().unwrap_or_default();
            let value = text.strip_prefix(&format!("{name}=")).unwrap_or_default();
            assert!(!value.is_empty(), "{meta}: {text:?}");
            assert_ne!(value, FORGED_TOKEN, "{meta}: {text:?}");
            assert_ne!(value, "/tmp/acpmux-forged.sock", "{meta}: {text:?}");
        }
        // The token the agent got proves its session.
        let token = {
            let rid = app
                .send(
                    "session/prompt",
                    json!({"sessionId": id, "prompt": [{"type": "text", "text": "env: ACPMUX_SESSION_TOKEN"}]}),
                )
                .await;
            let chunk = app
                .note("session/update", |p| {
                    p["sessionId"] == id.as_str()
                        && p["update"]["sessionUpdate"] == "agent_message_chunk"
                })
                .await;
            app.reply(rid).await;
            chunk["update"]["content"]["text"]
                .as_str()
                .unwrap_or_default()
                .trim_start_matches("ACPMUX_SESSION_TOKEN=")
                .to_owned()
        };
        assert_eq!(token.len(), 64, "{meta}: {token:?}");
    }
}
