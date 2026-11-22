//! No prompt from the app's agent pane (LocalApp) or a remote browser (Web)
//! reaches an agent while the session's folder has no trust answer: acpmux
//! refuses `session/prompt` and `_acpmux/handoff_start` with `trust.pending`
//! until the user trusts the folder, and with `trust.untrusted` after "Don't
//! trust". A record that cannot be read is no answer. The page cannot get
//! around it: the refusal is in the daemon, on the connection the page uses.
//! A Web connection cannot answer the question itself. The unix socket (the
//! CLI, the TUI) is not gated.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::trust::Paths;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("atg-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("work").join("other")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn paths(d: &Path) -> Paths {
    Paths {
        claude_json: d.join("home").join(".claude.json"),
        codex_config: d.join("home").join("config.toml"),
        record: d.join("home").join("trust.json"),
        agent_home: Some(d.join("agent-home")),
    }
}

fn hub(d: &Path) -> Arc<Hub> {
    hub_with(d, "approve-all")
}

/// `policy`: a Web connection works only under an asking policy (`ask`).
fn hub_with(d: &Path, policy: &str) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "fcodex": {"argv": ["python3", FAKE], "family": "codex"},
        },
        "defaultHarness": "fclaude",
        "permissionPolicy": policy,
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(paths(d)));
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }

    async fn new_session(&mut self, cwd: &Path, harness: &str) -> String {
        let p = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }

    async fn trust(&mut self, cwd: &Path, level: &str) {
        let r = self.call("acp.trust.set", json!({"cwd": cwd, "level": level})).await;
        assert!(r.get("error").is_none(), "trust.set {level}: {r}");
    }

    /// The prompts the agent took, from the session's own log.
    async fn agent_saw(&mut self, s: &str, text: &str) -> bool {
        let r = self.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        r.to_string().contains(text)
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn the_local_app_sends_no_prompt_while_the_folders_trust_is_pending() {
    let d = dir("pending");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    let s = local.new_session(&work, "fclaude").await;

    let r = app.prompt(&s, "secret-before-trust").await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert_eq!(r["error"]["data"]["cwd"], json!(work.to_string_lossy()), "{r}");
    assert!(!app.agent_saw(&s, "secret-before-trust").await, "the agent got the prompt");

    // Don't trust: still no prompt, with its own reason.
    app.trust(&work, "untrusted").await;
    let r = app.prompt(&s, "secret-after-distrust").await;
    assert_eq!(reason(&r), "trust.untrusted", "{r}");
    assert!(!app.agent_saw(&s, "secret-after-distrust").await, "the agent got the prompt");

    // Undo goes back to pending.
    app.trust(&work, "unknown").await;
    assert_eq!(reason(&app.prompt(&s, "again").await), "trust.pending");

    // Trust: the prompt goes.
    app.trust(&work, "trusted").await;
    let r = app.prompt(&s, "hello-after-trust").await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(app.agent_saw(&s, "hello-after-trust").await);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn local_app_and_web_cannot_create_an_agent_before_folder_trust() {
    let d = dir("new");
    let hub = hub_with(&d, "ask");
    let work = d.join("work");
    for origin in [Origin::LocalApp, Origin::Web] {
        let mut client = Client::new(&hub, origin);
        let r = client
            .call(
                "session/new",
                json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"harness": "fclaude"}}}),
            )
            .await;
        assert_eq!(reason(&r), "trust.pending", "{origin:?}: {r}");
        assert!(r["result"].is_null(), "the agent was created: {r}");
    }
    let mut local = Client::new(&hub, Origin::Local);
    local.trust(&work, "trusted").await;
    let r = local
        .call(
            "session/new",
            json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"harness": "fclaude"}}}),
        )
        .await;
    assert!(r.get("error").is_none(), "trusted creation: {r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// cmux's own agent-home folder (the private folder the app makes for a new chat) is trusted by
/// construction: the app's first prompt there starts the agent and runs. A symlink inside
/// agent-home to a user folder is that user folder, and still waits for the answer.
#[tokio::test]
async fn a_new_chat_in_a_fresh_agent_home_folder_is_not_asked_about() {
    let d = dir("agent-home");
    let hub = hub(&d);
    let home = d.join("agent-home").join("6c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join(acpmux::trust::AGENT_HOME_MARKER), b"").unwrap();
    let mut app = Client::new(&hub, Origin::LocalApp);
    let new = |cwd: &Path| json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fclaude"}}});
    let r = app.call("session/new", new(&home)).await;
    assert!(r.get("error").is_none(), "agent-home session/new: {r}");
    let s = r["result"]["sessionId"].as_str().unwrap().to_owned();
    let r = app.prompt(&s, "hello-agent-home").await;
    assert!(r.get("error").is_none(), "agent-home prompt: {r}");
    assert!(app.agent_saw(&s, "hello-agent-home").await);

    // A symlink inside agent-home to a user folder (with a copied marker) is still asked about.
    let user = d.join("work").join("other");
    std::fs::write(user.join(acpmux::trust::AGENT_HOME_MARKER), b"").unwrap();
    let link = d.join("agent-home").join("link");
    std::os::unix::fs::symlink(&user, &link).unwrap();
    let r = app.call("session/new", new(&link)).await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert_eq!(r["error"]["data"]["cwd"], json!(user.to_string_lossy()), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_sessions_own_agent_answers_without_a_decision() {
    let d = dir("harness");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    // Claude Code accepted its own trust dialog for a parent folder; Codex knows nothing.
    std::fs::write(
        &paths(&d).claude_json,
        json!({"projects": {d.to_string_lossy(): {"hasTrustDialogAccepted": true}}}).to_string(),
    )
    .unwrap();
    let claude = local.new_session(&work, "fclaude").await;
    let r = app.prompt(&claude, "claude-trusted").await;
    assert!(r.get("error").is_none(), "Claude Code's own trust answers: {r}");
    // A Codex session in the same folder still waits for an answer.
    let codex = local.new_session(&work, "fcodex").await;
    assert_eq!(reason(&app.prompt(&codex, "codex-unknown").await), "trust.pending");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_unix_socket_is_not_gated() {
    let d = dir("unix");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d.join("work"), "fclaude").await;
    let r = local.prompt(&s, "from-the-cli").await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_handoff_start_waits_for_the_targets_folder_trust() {
    let d = dir("handoff");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    let src = local.new_session(&work, "fclaude").await;
    app.trust(&work, "trusted").await;
    let p = json!({"sessionId": src, "harness": "fcodex", "handoffKey": "k-trust"});
    let h = app.call("_acpmux/handoff_prepare", p).await;
    let id = h["result"]["handoffId"].as_str().unwrap_or_else(|| panic!("{h}")).to_owned();
    let target = h["result"]["target"]["sessionId"].as_str().unwrap().to_owned();
    app.trust(&work, "unknown").await;
    let start = json!({
        "handoffId": id,
        "revision": 1,
        "capsule": {"text": "capsule-before-trust"},
        "checkpoint": {"ref": "abc123", "attest": true},
    });

    let r = app.call("_acpmux/handoff_start", start.clone()).await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    let got = app.call("_acpmux/handoff_get", json!({"handoffId": id})).await;
    assert_eq!(got["result"]["state"], json!("draft"), "{got}");
    assert!(!app.agent_saw(&target, "capsule-before-trust").await, "the target got the capsule");

    app.trust(&work, "untrusted").await;
    let r = app.call("_acpmux/handoff_start", start.clone()).await;
    assert_eq!(reason(&r), "trust.untrusted", "{r}");

    app.trust(&work, "trusted").await;
    let r = app.call("_acpmux/handoff_start", start).await;
    assert_eq!(r["result"]["outcome"], json!("started"), "{r}");
    assert!(app.agent_saw(&target, "capsule-before-trust").await);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_prompt_waits_for_the_folders_trust_and_the_web_cannot_answer() {
    let d = dir("web");
    let hub = hub_with(&d, "ask");
    let mut web = Client::new(&hub, Origin::Web);
    // The user's own CLI answers the question; the remote browser cannot.
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    local.trust(&work, "trusted").await;
    let s = web.new_session(&work, "fclaude").await;
    local.trust(&work, "unknown").await;

    let r = web.prompt(&s, "web-before-trust").await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert!(!web.agent_saw(&s, "web-before-trust").await, "the agent got the prompt");

    // A Web connection does not answer the trust question itself.
    let r = web.call("acp.trust.set", json!({"cwd": work, "level": "trusted"})).await;
    assert_eq!(reason(&r), "trust.remote", "{r}");
    assert_eq!(reason(&web.prompt(&s, "web-after-own-trust").await), "trust.pending");

    // A peer that forwards for its own Web client is held to the same gate.
    let mut peer = Client::new(&hub, Origin::Peer);
    let p = json!({
        "sessionId": s,
        "prompt": [{"type": "text", "text": "peer-web-before-trust"}],
        "_meta": {"acpmux": {"via": "web"}},
    });
    assert_eq!(reason(&peer.call("session/prompt", p).await), "trust.pending");

    local.trust(&work, "untrusted").await;
    let r = web.prompt(&s, "web-after-distrust").await;
    assert_eq!(reason(&r), "trust.untrusted", "{r}");
    assert!(!web.agent_saw(&s, "web-after-distrust").await, "the agent got the prompt");

    local.trust(&work, "trusted").await;
    let r = web.prompt(&s, "web-after-trust").await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(web.agent_saw(&s, "web-after-trust").await);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_trust_record_that_cannot_be_read_is_no_answer() {
    let d = dir("damaged");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    // Claude Code trusts the folder, but acpmux's own record is damaged: the
    // decision in it cannot be known, so the prompt waits.
    std::fs::write(
        &paths(&d).claude_json,
        json!({"projects": {work.to_string_lossy(): {"hasTrustDialogAccepted": true}}}).to_string(),
    )
    .unwrap();
    std::fs::write(&paths(&d).record, "{not json").unwrap();
    let s = local.new_session(&work, "fclaude").await;
    std::fs::write(&paths(&d).record, "{not json").unwrap();
    let r = app.prompt(&s, "secret-with-damaged-record").await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert!(!app.agent_saw(&s, "secret-with-damaged-record").await, "the agent got the prompt");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_fork_into_a_folder_without_trust_waits_for_it() {
    let d = dir("fork");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let work = d.join("work");
    let other = work.join("other");
    app.trust(&work, "trusted").await;
    let s = app.new_session(&work, "fcodex").await;
    // Its own (trusted) folder: the fork goes.
    let r = app.call("session/fork", json!({"sessionId": s})).await;
    assert!(r.get("error").is_none(), "{r}");
    // Another folder with no answer: refused before any agent runs there.
    let r = app.call("session/fork", json!({"sessionId": s, "cwd": other})).await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert_eq!(r["error"]["data"]["cwd"], json!(other.to_string_lossy()), "{r}");
    app.trust(&other, "trusted").await;
    let r = app.call("session/fork", json!({"sessionId": s, "cwd": other})).await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn warm_starts_no_agent_in_a_folder_without_trust() {
    let d = dir("warm");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    let s = local.new_session(&work, "fcodex").await;
    let r = app.call("_acpmux/warm", json!({"sessionIds": [s]})).await;
    assert_eq!(r["result"]["warmed"], json!([]), "{r}");
    app.trust(&work, "trusted").await;
    let r = app.call("_acpmux/warm", json!({"sessionIds": [s]})).await;
    assert_eq!(r["result"]["warmed"][0]["sessionId"], json!(s), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_peer_request_for_the_app_waits_and_a_peers_own_does_not() {
    let d = dir("peer");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let mut peer = Client::new(&hub, Origin::Peer);
    let s = local.new_session(&d.join("work"), "fclaude").await;
    let p = |text: &str, via: Option<&str>| {
        let mut p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        if let Some(via) = via {
            p["_meta"] = json!({"acpmux": {"via": via}});
        }
        p
    };
    let r = peer.call("session/prompt", p("peer-for-its-app", Some("app"))).await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert!(!peer.agent_saw(&s, "peer-for-its-app").await, "the agent got the prompt");
    // The peer's own user (its unix socket): the peer judges, as today.
    let r = peer.call("session/prompt", p("peer-own-user", None)).await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}
