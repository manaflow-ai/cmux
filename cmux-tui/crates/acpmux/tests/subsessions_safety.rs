//! A sub-session never asks less than the session that starts or messages
//! it (`hub/subsessions.rs`, `hub/subsession_guard.rs`):
//! - the requested folder is resolved once (a symlink or `..` is followed
//!   before any check) and must be inside the caller's folder or trusted, by
//!   a walk up to `/` in which only the person's own nearer `trusted`
//!   decision outranks an `untrusted` folder farther up;
//! - a folder nobody decided first waits on the person's trust card
//!   (`hub/trust_wait.rs`), and Not now refuses it; a folder the person
//!   marked untrusted, or a harness the caller may not start, is refused
//!   without a card;
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
use acpmux::hub::person::Answerer;
use acpmux::hub::{Control, Hub};
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
const RETRY: &str = "_acpmux/subsession/retry";

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
            cmux_worktrees: None,
        };
        Scratch { root, trust }
    }

    fn dir(&self, rel: &str) -> PathBuf {
        let d = self.root.join(rel);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The caller's own folder, which the person trusts: a sub-session there
    /// raises no trust card (`hub/trust_wait.rs`).
    fn own(&self) -> PathBuf {
        let own = self.dir("own");
        self.decide(&own, "trusted");
        own
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
            // Claude Code's modes: a new chat starts in `bypassPermissions`.
            "cc": fake("claude", json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"})),
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
    // The person said no to that folder: they are not asked again.
    assert!(hub.resolve(&parent).unwrap().pending_permissions().is_empty());

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
    let session = hub.resolve(&parent).unwrap();
    assert!(session.pending_permissions().is_empty(), "a refused folder raised a card");
    // A folder nobody decided, outside the caller's own, waits on the
    // person's trust card; Not now refuses it.
    let waiting = {
        let (hub, parent) = (hub.clone(), parent.clone());
        tokio::spawn(async move {
            let mut agent = Client::as_session(&hub, &parent).await;
            agent.call(START, json!({"prompt": "echo x", "cwd": plain})).await
        })
    };
    let asks = json!({"sessions": [parent], "until": ["permission"], "timeoutMs": 20000});
    app.ok("_acpmux/wait", asks).await;
    let cards = session.pending_permissions();
    assert_eq!(cards.len(), 1, "{cards:?}");
    let not_now = Some("not_now".to_owned());
    let (who, control) = (Answerer::default(), Control::Local);
    hub.respond_permission(&session, &cards[0].0, not_now, None, None, who, control).await.unwrap();
    let e = waiting.await.unwrap();
    assert_eq!(e["error"]["data"]["reason"], "subsessions.trust_declined", "{e}");
    assert!(app.open_children(&parent).await.is_empty());

    // The person's own decision on the nearer folder ends the walk.
    s.decide(&inner, "trusted");
    p.ok(START, json!({"prompt": "echo x", "cwd": inner})).await;
}

#[tokio::test]
async fn a_child_whose_mode_does_not_ask_is_closed_under_an_asking_caller() {
    let s = Scratch::new("mode");
    let own = s.own();
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
    let own = s.own();
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;

    let e = p.refused(START, json!({"prompt": "echo x", "harness": "skipper"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.asks_less", "{e}");
    // The harness is checked before the folder's trust card: in a folder
    // nobody decided, the person is not asked for a start that is refused.
    let undecided = json!({"prompt": "echo x", "harness": "skipper", "cwd": s.dir("undecided")});
    let e = p.refused(START, undecided).await;
    assert_eq!(e["data"]["reason"], "subsessions.asks_less", "{e}");
    assert!(hub.resolve(&parent).unwrap().pending_permissions().is_empty());
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
    let own = s.own();
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

/// The daemon default `ask` does not narrow a chat (`policy_mode.rs`): a caller in full access
/// under it starts its child in full access too, with the same policy, never in an asking mode.
#[tokio::test]
async fn a_full_access_callers_child_stays_in_full_access_under_the_default_policy() {
    let s = Scratch::new("default-policy");
    let own = s.own();
    let hub = hub_with(&s, json!({"permissionPolicy": "ask"}), None);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "cc").await;
    let info = app.info(&parent).await;
    assert_eq!(info["modes"]["currentModeId"], "bypassPermissions", "{info}");
    assert_eq!(info["enforcement"]["policy"], "ask", "{info}");
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.ok(START, json!({"prompt": "echo x"})).await;
    let info = app.info(child["sessionId"].as_str().unwrap()).await;
    assert_eq!(info["modes"]["currentModeId"], "bypassPermissions", "{info}");
    assert_eq!(info["enforcement"]["policy"], "ask", "{info}");
}

#[tokio::test]
async fn a_message_never_reaches_a_session_that_asks_less_than_its_sender() {
    let s = Scratch::new("send");
    let own = s.own();
    // The fake harness's `normal` mode asks, by the person's own table.
    let hub = hub_with(&s, json!({"webAskingModes": {"fake": ["normal", "strict"]}}), None);
    let mut app = Client::new(&hub);
    let top = app.new_session(&own, "fake-full").await;
    let mut t = Client::as_session(&hub, &top).await;
    let mid =
        t.ok(START, json!({"prompt": "echo mid"})).await["sessionId"].as_str().unwrap().to_owned();
    let mut m = Client::as_session(&hub, &mid).await;
    // Its first turn fails, for the retries below.
    let low = m.ok(START, json!({"prompt": "fail-once: low"})).await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
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
    // Nor retries its child's failed turn (Codex review of #25296); the session in full access
    // above them does.
    let e = m.refused(RETRY, json!({"sessionId": low})).await;
    assert_eq!(e["data"]["reason"], "subsessions.receiver_asks_less", "{e}");
    let retried = t.ok(RETRY, json!({"sessionId": low})).await;
    assert_eq!(retried["kind"], "turn", "{retried}");
    // The session in full access still messages it.
    t.ok(SEND, json!({"sessionId": mid, "text": "echo hi"})).await;
}

#[tokio::test]
async fn a_caller_that_does_not_ask_never_starts_an_unlisted_mode_of_another_family() {
    let s = Scratch::new("unlisted");
    let own = s.own();
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

/// A hub whose `fake` harness a Web client drives: its folder is a Web root,
/// its `normal` mode asks, and the daemon default policy asks.
async fn web_family(s: &Scratch, own: &Path) -> (Arc<Hub>, String) {
    s.decide(own, "trusted");
    let extra = json!({
        "webRoots": [own],
        "webAskingModes": {"fake": ["normal", "strict"]},
        "permissionPolicy": "ask",
    });
    let hub = hub_with(s, extra, None);
    let mut web = Client::with_origin(&hub, Origin::Web);
    let parent = web.new_session(own, "fake").await;
    let prompt = json!({"sessionId": parent, "prompt": [{"type": "text", "text": "echo web"}]});
    web.ok("session/prompt", prompt).await;
    (hub, parent)
}

#[tokio::test]
async fn a_family_prompt_from_an_agent_after_a_web_turn_runs_as_a_web_turn() {
    let s = Scratch::new("webstart");
    let own = s.dir("own");
    let (hub, parent) = web_family(&s, &own).await;
    let mut app = Client::new(&hub);
    assert_eq!(app.turn_controls(&parent).await, ["web"]);
    // The agent the Web turn drove starts a child: its prompt is held to the
    // remote floor as that turn was.
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.ok(START, json!({"prompt": "echo from the web turn"})).await;
    let child = child["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;
    assert_eq!(app.turn_controls(&child).await, ["web"]);
}

#[tokio::test]
async fn an_agent_after_a_web_turn_cannot_enqueue_mesh_controls() {
    let s = Scratch::new("webmesh");
    let own = s.dir("own");
    let (hub, parent) = web_family(&s, &own).await;
    assert!(hub.resolve(&parent).unwrap().turn().is_none());
    let mut caller = Client::as_session(&hub, &parent).await;
    let error = caller
        .refused(
            "_acpmux/mesh_control",
            json!({"op": "stop", "to": {"name": "remote"}, "idempotencyKey": "web-control-1"}),
        )
        .await;
    // Checked before the absent relay: the previous Web turn stays restrictive.
    assert_eq!(error["data"]["reason"], "mesh.local_only", "{error}");
    hub.shutdown_all().await;
}

/// An agent a remote device drives never sends files with a message: `send_message` asks the
/// daemon before it reads any path (`attachCheck`), and a send that carries files anyway, inline
/// or by upload reference, is refused before the daemon reads or resolves them.
#[tokio::test]
async fn an_agent_a_web_turn_drove_cannot_send_files_with_a_message() {
    let s = Scratch::new("webattach");
    let own = s.dir("own");
    let (hub, parent) = web_family(&s, &own).await;
    let mut app = Client::new(&hub);
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.ok(START, json!({"prompt": "echo child"})).await;
    let child = child["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;

    let inline = acpmux::attach::block("secret.txt", b"from the agent's machine");
    let send = json!({"sessionId": child, "text": "see this", "attachments": [inline]});
    let e = p.refused(SEND, send).await;
    assert_eq!(e["data"]["reason"], "attach.remote", "{e}");
    let upload = uuid::Uuid::now_v7().to_string();
    let by_ref = json!({"type": "resource_link", "name": "secret.txt",
        "uri": format!("acpmux-upload:{upload}"),
        "_meta": {"acpmux": {"upload": {"uploadId": upload, "fileName": "secret.txt"}}}});
    let send = json!({"sessionId": child, "text": "see this", "attachments": [by_ref]});
    let e = p.refused(SEND, send).await;
    assert_eq!(e["data"]["reason"], "attach.remote", "{e}");
    let check = json!({"sessionId": child, "text": "", "attachCheck": true});
    let e = p.refused(SEND, check).await;
    assert_eq!(e["data"]["reason"], "attach.remote", "{e}");
    let events = app.events(&child).await;
    let sent: Vec<_> = events.iter().filter(|e| e["kind"] == "user_message").collect();
    assert_eq!(sent.len(), 1, "only its start prompt reached the child: {sent:?}");
}

/// The same agent's own shell: `acpmux send --attach` (now or `--no-wait`) and the
/// cmux-subsessions `send_message` tool, run as that agent (its caller token), send no file and
/// read none for the tool: the daemon refuses a prompt, a queued send or an upload carrying them,
/// and `send_message` asks before it reads a path (here one that is not there).
#[tokio::test]
async fn an_agent_a_web_turn_drove_sends_no_files_from_its_shell_or_its_tools() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let s = Scratch::new("webshell");
    let own = s.dir("own");
    let (hub, parent) = web_family(&s, &own).await;
    let mut app = Client::new(&hub);
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.ok(START, json!({"prompt": "echo child"})).await;
    let child = child["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;
    let socket = PathBuf::from("/tmp").join(format!("acpmux-webshell-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket);
    let listener = acpmux::server::bind_unix(&socket).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    let as_parent = |cmd: &mut tokio::process::Command| {
        cmd.env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_SESSION_ID", &parent)
            .env("ACPMUX_SESSION_TOKEN", acpmux::hub::person::caller_token(&parent))
            .env("ACPMUX_SESSION_TOKEN_SOCKET", &socket)
            .kill_on_drop(true);
    };
    let small = s.root.join("small.txt");
    std::fs::write(&small, b"from the agent's machine").unwrap();
    // Past what goes inline: sent by upload first.
    let big = s.root.join("big.bin");
    std::fs::write(&big, vec![7u8; 5 << 20]).unwrap();
    for (file, wait) in [(&small, true), (&big, true), (&small, false)] {
        let mut cmd = daemon_env::tokio_command(&s.root, daemon_env::Agents::Deny);
        cmd.arg("send").arg("--attach").arg(file);
        if !wait {
            cmd.arg("--no-wait");
        }
        cmd.arg(&child).arg("see this");
        as_parent(&mut cmd);
        let out = tokio::time::timeout(Duration::from_secs(60), cmd.output()).await.unwrap();
        let out = out.unwrap();
        let said = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(!out.status.success(), "{}: {said}", file.display());
        assert!(said.contains("remote device"), "{}: {said}", file.display());
    }
    // The tool: refused before it reads the path, which is not there.
    let mut mcp = daemon_env::tokio_command(&s.root, daemon_env::Agents::Deny);
    mcp.arg("subsession-mcp")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped());
    as_parent(&mut mcp);
    let mut mcp = mcp.spawn().unwrap();
    let mut stdin = mcp.stdin.take().unwrap();
    let mut lines = tokio::io::BufReader::new(mcp.stdout.take().unwrap()).lines();
    let missing = s.root.join("not-there.txt");
    for line in [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "send_message",
            "arguments": {"sessionId": child, "text": "see this", "attachments": [missing]}}}),
        // No files: a text message, which it may send.
        json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send_message",
            "arguments": {"sessionId": child, "text": "just text", "attachments": []}}}),
    ] {
        stdin.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }
    let mut answers = std::collections::HashMap::new();
    while answers.len() < 2 {
        let line = tokio::time::timeout(Duration::from_secs(60), lines.next_line()).await;
        let v: Value = serde_json::from_str(&line.unwrap().unwrap().unwrap()).unwrap();
        if let Some(id @ (2 | 3)) = v["id"].as_i64() {
            answers.insert(id, v);
        }
    }
    let text =
        |a: &Value| a["result"]["content"][0]["text"].as_str().unwrap_or_default().to_owned();
    let refused = &answers[&2];
    assert_eq!(refused["result"]["isError"], true, "{refused}");
    assert!(text(refused).contains("remote device"), "read the path first: {refused}");
    let plain = &answers[&3];
    assert_ne!(plain["result"]["isError"], true, "a text message was refused: {plain}");
    let events = app.events(&child).await;
    let sent: Vec<_> = events.iter().filter(|e| e["kind"] == "user_message").collect();
    let texts: Vec<_> =
        sent.iter().map(|e| e["msg"]["text"].as_str().unwrap_or_default()).collect();
    assert!(!texts.contains(&"see this"), "a message with files reached the child: {sent:?}");
    let uploads = std::env::var_os("ACPMUX_HOME").map(PathBuf::from).unwrap().join("uploads");
    let saved = std::fs::read_dir(uploads.join(&child)).map(|d| d.count()).unwrap_or(0);
    assert_eq!(saved, 0, "an upload was begun for the child");
    let _ = std::fs::remove_file(&socket);
}

#[tokio::test]
async fn a_family_prompt_never_clears_its_receivers_web_floor() {
    let s = Scratch::new("webfloor");
    let own = s.dir("own");
    let (hub, parent) = web_family(&s, &own).await;
    let mut app = Client::new(&hub);
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.ok(START, json!({"prompt": "echo child"})).await;
    let child = child["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;
    // The child's last turn is a local one.
    let prompt = json!({"sessionId": child, "prompt": [{"type": "text", "text": "echo local"}]});
    app.ok("session/prompt", prompt).await;
    // Its report runs in the parent, whose last turn was a Web turn: under the floor.
    let mut c = Client::as_session(&hub, &child).await;
    c.ok(SEND, json!({"sessionId": parent, "text": "echo report"})).await;
    app.wait_ready(&parent).await;
    let controls = app.turn_controls(&parent).await;
    assert_eq!(controls.last().map(String::as_str), Some("web"), "{controls:?}");
}

#[tokio::test]
async fn outside_its_folder_an_asking_caller_needs_the_persons_own_trust() {
    let s = Scratch::new("inherited");
    let own = s.dir("own");
    // Claude Code and Codex trust the home folder, so `.aws` inherits it.
    let home = s.dir("home");
    let aws = s.dir("home/.aws");
    let key = home.to_string_lossy().into_owned();
    let claude = json!({"projects": {(key.clone()): {"hasTrustDialogAccepted": true}}});
    std::fs::write(&s.trust.claude_json, claude.to_string()).unwrap();
    let codex = format!("[projects.{key:?}]\ntrust_level = \"trusted\"\n");
    std::fs::write(&s.trust.codex_config, codex).unwrap();
    // Another chat's agent-home folder, trusted by construction.
    let other_home = s.dir("agent-home/other");
    std::fs::write(other_home.join(acpmux::trust::AGENT_HOME_MARKER), "").unwrap();
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;
    for cwd in [&aws, &other_home] {
        let e = p.refused(START, json!({"prompt": "echo x", "cwd": cwd})).await;
        assert_eq!(e["data"]["reason"], "subsessions.folder_unknown", "{}: {e}", cwd.display());
    }
    assert!(app.open_children(&parent).await.is_empty());

    // A caller in full access may start there.
    let full = app.new_session(&own, "fake-full").await;
    let mut f = Client::as_session(&hub, &full).await;
    for cwd in [&aws, &other_home] {
        f.ok(START, json!({"prompt": "echo x", "cwd": cwd})).await;
    }
}

#[tokio::test]
async fn a_queued_message_is_checked_again_when_it_would_run() {
    let s = Scratch::new("queued");
    let own = s.own();
    let hub = hub_with(&s, json!({"webAskingModes": {"fake": ["normal", "strict"]}}), None);
    let mut app = Client::new(&hub);
    let top = app.new_session(&own, "fake-full").await;
    let mut t = Client::as_session(&hub, &top).await;
    let mid =
        t.ok(START, json!({"prompt": "echo mid"})).await["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&mid).await;
    // The child is busy; a message waits behind its turn.
    let gate = s.root.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    t.ok(SEND, json!({"sessionId": mid, "text": format!("gate: {}", gate.display())})).await;
    let queued = t.ok(SEND, json!({"sessionId": mid, "text": "echo queued"})).await;
    assert_eq!(queued["queued"], true, "{queued}");
    // The sender is moved back to asking before the message runs: the child
    // in full access now asks less than it.
    app.ok("session/set_mode", json!({"sessionId": top, "modeId": "normal"})).await;
    tokio::task::spawn_blocking(move || std::fs::write(gate, "go")).await.unwrap().unwrap();
    for _ in 0..100 {
        let said = serde_json::to_string(&app.events(&mid).await).unwrap();
        assert!(!said.contains("echo: echo queued"), "the queued message ran");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Its refusal is logged (`prompt_refused`), so a daemon restart does not
    // queue it again (`hub/lost_start.rs`).
    let events = app.events(&mid).await;
    let refused = events.iter().find(|e| {
        e["kind"] == "prompt_refused"
            && e["msg"]["data"]["reason"] == "subsessions.receiver_asks_less"
    });
    assert!(refused.is_some(), "no prompt_refused: {events:?}");
}

#[tokio::test]
async fn a_prompt_preview_is_masked_before_it_is_cut() {
    let s = Scratch::new("preview");
    let own = s.own();
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;
    let child =
        p.ok(START, json!({"prompt": "echo c"})).await["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;
    // A key that straddles the 200-character preview cut: its first 14
    // characters fall before the cut.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let lead = "gate: ".len() + s.root.to_string_lossy().len() + 2;
    let pad = s.dir(&"p".repeat(186 - lead));
    let gate = pad.join(&key);
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let text = format!("gate: {}", gate.display());
    assert_eq!(text.find(&key), Some(186));
    p.ok(SEND, json!({"sessionId": child, "text": text})).await;
    let got = p.ok("_acpmux/subsession/get", json!({"sessionId": child})).await;
    tokio::task::spawn_blocking(move || std::fs::write(gate, "go")).await.unwrap().unwrap();
    assert!(got["turn"]["prompt"].is_string(), "{got}");
    assert!(!got.to_string().contains(&key[..10]), "{got}");
}

/// `subsession/get` of `id` once `ready` holds of it: an agent's updates land after its
/// prompt is accepted.
async fn row_when(c: &mut Client, id: &str, ready: impl Fn(&Value) -> bool) -> Value {
    for _ in 0..200 {
        let row = c.ok("_acpmux/subsession/get", json!({"sessionId": id})).await;
        if ready(&row) {
            return row;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("{id}'s row never got there");
}

#[tokio::test]
async fn a_childs_activity_is_masked_before_its_cut() {
    let s = Scratch::new("activity");
    let own = s.own();
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;
    let child =
        p.ok(START, json!({"prompt": "echo c"})).await["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;
    // A tool call whose title holds a key across the 160-character activity
    // cut: its first 14 characters fall before the cut.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let title = format!("echo {} {key}", "w".repeat(140));
    assert_eq!(title.find(&key), Some(146));
    let gate = s.root.join("gate");
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let text = format!("work-gate: {} | {title}", gate.display());
    p.ok(SEND, json!({"sessionId": child, "text": text})).await;
    let got = row_when(&mut p, &child, |r| r["turn"]["activity"].is_string()).await;
    tokio::task::spawn_blocking(move || std::fs::write(gate, "go")).await.unwrap().unwrap();
    assert!(got["turn"]["activity"].as_str().unwrap().starts_with("echo w"), "{got}");
    assert!(!got.to_string().contains(&key[..10]), "{got}");
}

#[tokio::test]
async fn a_childs_question_is_masked_before_its_cut() {
    let s = Scratch::new("question");
    let own = s.own();
    let hub = hub(&s);
    let mut app = Client::new(&hub);
    let parent = app.new_session(&own, "fake").await;
    let mut p = Client::as_session(&hub, &parent).await;
    let child =
        p.ok(START, json!({"prompt": "echo c"})).await["sessionId"].as_str().unwrap().to_owned();
    app.wait_ready(&child).await;
    // The question it waits on holds a key across the 120-character cut of
    // the prompt `doing` quotes: its first 14 characters fall before the cut.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    let question = format!("{} {key}", "w".repeat(105));
    assert_eq!(question.find(&key), Some(106));
    p.ok(SEND, json!({"sessionId": child, "text": format!("question: {question}")})).await;
    let got = row_when(&mut p, &child, |r| r["waitingOn"] == "question").await;
    let doing = got["doing"].as_str().unwrap_or_default();
    assert!(doing.starts_with("Waiting for the user to answer, in the app: w"), "{got}");
    assert!(!got.to_string().contains(&key[..10]), "{got}");
}

#[tokio::test]
async fn the_callers_own_folder_profile_is_its_own_only_from_its_own_folder() {
    let s = Scratch::new("ownprofile");
    let a = s.dir("a");
    let b = s.dir("b");
    s.decide(&a, "trusted");
    s.decide(&b, "trusted");
    let gate = gate_of(&s);
    // Two folders with a profile of the same id and the same command.
    folder_profile(&gate, &a);
    folder_profile(&gate, &b);
    let hub = hub_with(&s, json!({}), Some(gate));
    let mut app = Client::new(&hub);
    let parent = app.new_session(&a, "fakefolder").await;
    let mut p = Client::as_session(&hub, &parent).await;
    // Its own folder's profile is its own harness.
    p.ok(START, json!({"prompt": "echo x"})).await;
    // The other folder's is that folder's.
    let e = p.refused(START, json!({"prompt": "echo x", "cwd": b})).await;
    assert_eq!(e["data"]["reason"], "subsessions.folder_profile", "{e}");
}
