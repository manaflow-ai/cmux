//! A sub-session never asks less than the session that starts or messages
//! it (`hub/subsessions.rs`, `hub/subsession_guard.rs`):
//! - the requested folder is resolved once (a symlink or `..` is followed
//!   before any check) and must be inside the caller's folder or trusted, by
//!   a walk up to `/` in which only the person's own nearer `trusted`
//!   decision outranks an `untrusted` folder farther up;
//! - a child whose harness mode does not ask, from a caller whose does, is
//!   moved to an asking mode or closed (OpenCode's default `build` allows
//!   everything);
//! - a folder harness profile, or a profile whose command skips the
//!   permission checks, starts only from a caller in full access;
//! - the child runs the caller's permission policy even when the caller has
//!   none of its own (the daemon default answers for it);
//! - a message is never sent to a session that asks less than its sender.
//!
//! Stand-in agents (fake_agent.py).

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::folder_profiles::{self, FolderGate};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";
const SEND: &str = "_acpmux/subsession/send";

/// The process environment every test here shares: an empty settings file
/// (sub-sessions on, new chats start in full access where the harness has it).
fn env_once() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let root =
            std::env::temp_dir().join(format!("acpmux-subsafe-env-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let settings = root.join("cmux-next.json");
        std::fs::write(&settings, "{}").unwrap();
        // SAFETY: set once, before any test of this binary starts a session.
        unsafe {
            std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
            std::env::set_var("ACPMUX_HOME", root.join("home"));
        }
    });
}

/// One test's scratch folder, canonical, with its trust files.
struct Scratch {
    root: PathBuf,
    trust: acpmux::trust::Paths,
}

impl Scratch {
    fn new(name: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("acpmux-subsafe-{name}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        let trust = acpmux::trust::Paths {
            claude_json: root.join("claude.json"),
            codex_config: root.join("codex.toml"),
            record: root.join("acpmux").join("trust.json"),
            agent_home: Some(root.join("agent-home")),
        };
        Scratch { root, trust }
    }

    fn dir(&self, rel: &str) -> PathBuf {
        let d = self.root.join(rel);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The person's own decision for `dir` (`acp.trust.set`).
    fn decide(&self, dir: &Path, level: &str) {
        acpmux::trust::set(&self.trust, &dir.to_string_lossy(), level).unwrap();
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn hub_with(s: &Scratch, extra: Value, gate: Option<FolderGate>) -> Arc<Hub> {
    env_once();
    let fake =
        |family: &str, env: Value| json!({"argv": ["python3", FAKE], "family": family, "env": env});
    let mut doc = json!({
        "harnesses": {
            "fake": fake("fake", json!({})),
            "fake-full": fake("fake", json!({"FAKE_FULL_ACCESS": "1"})),
            "oc": fake("opencode", json!({"FAKE_PLAN_MODE": "1"})),
            "skipper": {"argv": ["python3", FAKE, "--dangerously-skip-permissions"], "family": "fake"},
            "lax": {"argv": ["python3", FAKE], "family": "fake", "policy": "approve-all"},
            "nomodes": fake("custom", json!({"FAKE_NO_MODES": "1"})),
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    });
    if let (Some(d), Some(e)) = (doc.as_object_mut(), extra.as_object()) {
        for (k, v) in e {
            d.insert(k.clone(), v.clone());
        }
    }
    let mut cfg: Config = serde_json::from_value(doc).unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.folder_gate = gate;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(s.trust.clone()));
    hub
}

fn hub(s: &Scratch) -> Arc<Hub> {
    hub_with(s, json!({}), None)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        Self::with_origin(hub, Origin::Local)
    }

    fn with_origin(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let params = json!({"protocolVersion": 1,
            "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}});
        let r = c.call("initialize", params).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    async fn refused(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_some(), "{m} should be refused: {r}");
        r["error"].clone()
    }

    /// A session the person starts in `cwd` on `harness`.
    async fn new_session(&mut self, cwd: &Path, harness: &str) -> String {
        let new = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    async fn info(&mut self, id: &str) -> Value {
        self.ok("_acpmux/info", json!({"sessionId": id})).await
    }

    /// The children of `parent` that are not closed.
    async fn open_children(&mut self, parent: &str) -> Vec<Value> {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|s| s["startedBy"] == parent && s["status"] != "closed")
            .cloned()
            .collect()
    }
}

impl Client {
    async fn wait_ready(&mut self, id: &str) {
        let ready = json!({"sessions": [id], "until": ["ready"], "timeoutMs": 20000});
        self.ok("_acpmux/wait", ready).await;
    }

    async fn events(&mut self, id: &str) -> Vec<Value> {
        let r = self.ok("_acpmux/events", json!({"sessionId": id, "limit": 5000})).await;
        r["events"].as_array().cloned().unwrap_or_default()
    }

    /// The control of each turn the session started, oldest first.
    async fn turn_controls(&mut self, id: &str) -> Vec<String> {
        let events = self.events(id).await;
        let started = events.iter().filter(|e| e["kind"] == "turn_started");
        started.filter_map(|e| e["msg"]["control"].as_str().map(str::to_owned)).collect()
    }
}

/// `<folder>/.cmux/harnesses/fakefolder.toml` (the fake agent), enabled on `gate`.
fn folder_profile(gate: &FolderGate, folder: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let dir = folder_profiles::profile_dir(folder);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("fakefolder.toml");
    let toml =
        format!("schema = 1\nid = \"fakefolder\"\ncommand = \"python3\"\nargs = [{FAKE:?}]\n");
    std::fs::write(&file, toml).unwrap();
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&cfg, gate, folder, "fakefolder")
        .and_then(|fp| fp.sha256)
        .expect("sha256");
    folder_profiles::enable(&cfg, gate, folder, "fakefolder", &sha).unwrap();
}

fn gate_of(s: &Scratch) -> FolderGate {
    FolderGate {
        enable_record: s.root.join("acpmux").join(folder_profiles::ENABLE_RECORD),
        trust: s.trust.clone(),
    }
}

fn canonical(p: &str) -> PathBuf {
    std::fs::canonicalize(p).unwrap()
}

#[tokio::test]
async fn a_start_checks_the_folder_a_symlink_or_dotdot_resolves_to() {
    let s = Scratch::new("cwd");
    let own = s.dir("own");
    let untrusted = s.dir("elsewhere");
    s.decide(&untrusted, "untrusted");
    std::os::unix::fs::symlink(&untrusted, own.join("link")).unwrap();
    std::fs::create_dir_all(own.join("sub")).unwrap();
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;

    // A link inside the caller's folder is the folder it points to.
    let e = p.refused(START, json!({"prompt": "echo x", "cwd": own.join("link")})).await;
    assert_eq!(e["data"]["reason"], "subsessions.folder_untrusted", "{e}");
    // `..` is resolved before the check, not after it.
    let dotdot = own.join("sub/../../elsewhere");
    let e = p.refused(START, json!({"prompt": "echo x", "cwd": dotdot})).await;
    assert_eq!(e["data"]["reason"], "subsessions.folder_untrusted", "{e}");
    assert!(app.open_children(&parent).await.is_empty());

    // A link to a folder the person trusts runs in the folder it resolves to.
    let trusted = s.dir("trusted");
    s.decide(&trusted, "trusted");
    std::os::unix::fs::symlink(&trusted, own.join("ok")).unwrap();
    let child = p.ok(START, json!({"prompt": "echo x", "cwd": own.join("ok")})).await;
    let info = app.info(child["sessionId"].as_str().unwrap()).await;
    assert_eq!(canonical(info["cwd"].as_str().unwrap()), trusted, "{info}");
}

#[tokio::test]
async fn a_folder_agents_trust_inside_one_the_person_did_not_is_refused() {
    let s = Scratch::new("walk");
    let own = s.dir("own");
    let outer = s.dir("outer");
    let inner = s.dir("outer/inner");
    s.decide(&outer, "untrusted");
    // Claude Code and Codex both trust the inner folder.
    let key = inner.to_string_lossy().into_owned();
    std::fs::write(
        &s.trust.claude_json,
        json!({"projects": {(key.clone()): {"hasTrustDialogAccepted": true}}}).to_string(),
    )
    .unwrap();
    std::fs::write(
        &s.trust.codex_config,
        format!("[projects.{key:?}]\ntrust_level = \"trusted\"\n"),
    )
    .unwrap();
    let plain = s.dir("plain");
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;

    let e = p.refused(START, json!({"prompt": "echo x", "cwd": inner})).await;
    assert_eq!(e["data"]["reason"], "subsessions.folder_untrusted", "{e}");
    // A folder nobody trusts, outside the caller's own, is refused too.
    let e = p.refused(START, json!({"prompt": "echo x", "cwd": plain})).await;
    assert_eq!(e["data"]["reason"], "subsessions.folder_unknown", "{e}");
    assert!(app.open_children(&parent).await.is_empty());

    // The person's own decision on the nearer folder ends the walk.
    s.decide(&inner, "trusted");
    p.ok(START, json!({"prompt": "echo x", "cwd": inner})).await;
}

#[tokio::test]
async fn a_child_whose_mode_does_not_ask_is_closed_under_an_asking_caller() {
    let s = Scratch::new("mode");
    let own = s.dir("own");
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;

    // OpenCode starts in `build`, which allows everything, and has no mode
    // that asks: the child is closed.
    let e = p.refused(START, json!({"prompt": "echo x", "harness": "oc"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.asks_less", "{e}");
    assert!(app.open_children(&parent).await.is_empty());

    // A caller in full access starts it.
    let full = app.new_session(&own, "fake-full").await;
    assert_eq!(app.info(&full).await["modes"]["currentModeId"], "full-access");
    let mut f = Client::as_session(&hub, &full).await;
    f.ok(START, json!({"prompt": "echo x", "harness": "oc"})).await;
}

#[tokio::test]
async fn a_profile_that_skips_permissions_needs_a_full_access_caller() {
    let s = Scratch::new("skip");
    let own = s.dir("own");
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;

    let e = p.refused(START, json!({"prompt": "echo x", "harness": "skipper"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.asks_less", "{e}");
    assert!(app.open_children(&parent).await.is_empty());

    let full = app.new_session(&own, "fake-full").await;
    let mut f = Client::as_session(&hub, &full).await;
    f.ok(START, json!({"prompt": "echo x", "harness": "skipper"})).await;
}

#[tokio::test]
async fn a_folder_profile_needs_a_full_access_caller() {
    let s = Scratch::new("folderprofile");
    let folder = s.dir("repo");
    std::fs::create_dir_all(folder_profiles::profile_dir(&folder)).unwrap();
    std::fs::write(
        folder_profiles::profile_dir(&folder).join("fakefolder.toml"),
        format!("schema = 1\nid = \"fakefolder\"\ncommand = \"python3\"\nargs = [{FAKE:?}]\n"),
    )
    .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        let file = folder_profiles::profile_dir(&folder).join("fakefolder.toml");
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    s.decide(&folder, "trusted");
    let gate = FolderGate {
        enable_record: s.root.join("acpmux").join(folder_profiles::ENABLE_RECORD),
        trust: s.trust.clone(),
    };
    let cfg = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&cfg, &gate, &folder, "fakefolder")
        .and_then(|fp| fp.sha256)
        .expect("sha256");
    folder_profiles::enable(&cfg, &gate, &folder, "fakefolder", &sha).unwrap();
    let hub = hub_with(&s, json!({}), Some(gate));
    let mut app = Client::new(&hub);
    // The person can start it.
    app.new_session(&folder, "fakefolder").await;

    let parent = app.new_session(&folder, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;
    let e = p.refused(START, json!({"prompt": "echo x", "harness": "fakefolder"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.folder_profile", "{e}");
    assert!(app.open_children(&parent).await.is_empty());

    let full = app.new_session(&folder, "fake-full").await;
    let mut f = Client::as_session(&hub, &full).await;
    f.ok(START, json!({"prompt": "echo x", "harness": "fakefolder"})).await;
}

#[tokio::test]
async fn a_child_runs_the_callers_policy_when_the_caller_names_none() {
    let s = Scratch::new("policy");
    let own = s.dir("own");
    // The daemon default asks; the `lax` profile's own default approves all.
    let hub = hub_with(&s, json!({"permissionPolicy": "ask"}), None);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    assert_eq!(app.info(&parent).await["enforcement"]["policy"], "ask");
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.ok(START, json!({"prompt": "echo x", "harness": "lax"})).await;
    let info = app.info(child["sessionId"].as_str().unwrap()).await;
    assert_eq!(info["enforcement"]["policy"], "ask", "{info}");
}

#[tokio::test]
async fn a_message_never_reaches_a_session_that_asks_less_than_its_sender() {
    let s = Scratch::new("send");
    let own = s.dir("own");
    // The fake harness's `normal` mode asks, by the person's own table.
    let hub = hub_with(&s, json!({"webAskingModes": {"fake": ["normal", "strict"]}}), None);
    let mut app = Client::new(&hub);
    let top = app.new_session(&own, "fake-full").await;
    let mut t = Client::as_session(&hub, &top).await;
    let mid =
        t.ok(START, json!({"prompt": "echo mid"})).await["sessionId"].as_str().unwrap().to_owned();
    let mut m = Client::as_session(&hub, &mid).await;
    let low =
        m.ok(START, json!({"prompt": "echo low"})).await["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(app.info(&low).await["modes"]["currentModeId"], "full-access");
    // The middle session is moved back to asking (a narrowing needs nobody).
    app.ok("session/set_mode", json!({"sessionId": mid, "modeId": "normal"})).await;
    let ready = json!({"sessions": [mid, low], "until": ["ready"], "timeoutMs": 20000});
    app.ok("_acpmux/wait", ready).await;

    // It no longer messages the sessions in full access: its child or its parent.
    let e = m.refused(SEND, json!({"sessionId": low, "text": "echo hi"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.receiver_asks_less", "{e}");
    let e = m.refused(SEND, json!({"sessionId": top, "text": "echo hi"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.receiver_asks_less", "{e}");
    // The session in full access still messages it.
    t.ok(SEND, json!({"sessionId": mid, "text": "echo hi"})).await;
}

#[tokio::test]
async fn a_caller_that_does_not_ask_never_starts_an_unlisted_mode_of_another_family() {
    let s = Scratch::new("unlisted");
    let own = s.dir("own");
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    // OpenCode's `build` does not ask.
    let parent = app.new_session(&own, "oc").await;
    let mut p = Client::as_session(&hub, &parent).await;
    // Another family whose mode no list names, and one that reports no mode:
    // either may be full autonomy under its own name.
    for harness in ["fake", "nomodes"] {
        let e = p.refused(START, json!({"prompt": "echo x", "harness": harness})).await;
        assert_eq!(e["data"]["reason"], "subsessions.asks_less", "{harness}: {e}");
    }
    assert!(app.open_children(&parent).await.is_empty());
}
