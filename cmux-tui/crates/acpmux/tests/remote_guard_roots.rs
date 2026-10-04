//! ACP-REMOTE-GUARD F1 to F4: a Web request starts asking (an absent policy
//! is `ask`; nothing permissive is copied, forked, loaded or handed off; no
//! mode at start), and Web folders sit inside a root in the filesystem's own
//! spelling.

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

struct T {
    base: PathBuf,
    root: PathBuf,
    project: PathBuf,
}

impl Drop for T {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

fn layout(tag: &str) -> T {
    let base = std::env::temp_dir().join(format!("argr-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let root = base.join("root");
    let project = base.join("project");
    std::fs::create_dir_all(root.join("sub")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    let base = std::fs::canonicalize(&base).unwrap();
    T { root: base.join("root"), project: base.join("project"), base }
}

fn hub(t: &T, default_policy: &str) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": default_policy,
        "presets": {"loose": {"harness": "fake", "policy": "approve-all"}},
        "webRoots": [t.root],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
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
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv()).await.unwrap().unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn new_in(&mut self, cwd: &Path, extra: Value) -> Value {
        let mut p = json!({"cwd": cwd, "mcpServers": []});
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone();
        }
        self.call("session/new", p).await
    }

    async fn policy_of(&mut self, created: &Value) -> Value {
        let id = created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}"));
        self.call("_acpmux/info", json!({"sessionId": id})).await["result"]["policy"].clone()
    }
}

fn err(v: &Value) -> String {
    v["error"]["message"].as_str().unwrap_or_default().to_owned()
}

#[tokio::test]
async fn an_absent_web_policy_is_ask_never_the_inherited_default() {
    let t = layout("f1");
    let hub = hub(&t, "approve-all");
    let mut web = Client::new(&hub, Origin::Web);
    let created = web.new_in(&t.root, json!({})).await;
    assert_eq!(web.policy_of(&created).await, json!("ask"), "{created}");
    // A preset's policy is not inherited either.
    let created = web.new_in(&t.root, json!({"_meta": {"acpmux": {"preset": "loose"}}})).await;
    assert_eq!(web.policy_of(&created).await, json!("ask"), "{created}");
    // The unix socket still inherits the daemon default.
    let mut local = Client::new(&hub, Origin::Local);
    let created = local.new_in(&t.root, json!({})).await;
    assert_eq!(local.policy_of(&created).await, Value::Null, "inherits: {created}");
}

#[tokio::test]
async fn a_web_request_never_sets_or_copies_a_mode_or_policy_that_skips_asking() {
    let t = layout("f2");
    let hub = hub(&t, "ask");
    let mut local = Client::new(&hub, Origin::Local);
    let loose = local.new_in(&t.root, json!({"policy": "approve-all"})).await;
    let loose = loose["result"]["sessionId"].as_str().unwrap().to_owned();
    let asking = local.new_in(&t.root, json!({})).await;
    let asking = asking["result"]["sessionId"].as_str().unwrap().to_owned();
    let mut web = Client::new(&hub, Origin::Web);
    for extra in [
        json!({"modeId": "default"}),
        json!({"mode": "bypassPermissions"}),
        json!({"_meta": {"acpmux": {"permissionMode": "acceptEdits"}}}),
        json!({"_meta": {"acpmux": {"sandbox": "danger-full-access"}}}),
    ] {
        let r = web.new_in(&t.root, extra.clone()).await;
        assert!(err(&r).contains("a mode at session start"), "{extra}: {r}");
    }
    for (m, p) in [
        ("_acpmux/defaults", json!({"family": "fake", "set": {"mode": "plan"}})),
        ("_acpmux/presets", json!({"name": "loose", "set": {"mode": "plan"}})),
        ("_acpmux/presets", json!({"name": "loose", "set": {"unknownField": 1}})),
        ("_acpmux/warm", json!({"sessionIds": [asking], "mode": "x"})),
    ] {
        let r = web.call(m, p.clone()).await;
        assert!(err(&r).contains("never from a remote WebSocket connection"), "{m} {p}: {r}");
    }
    for (m, p) in [
        ("session/fork", json!({"sessionId": loose})),
        ("session/load", json!({"sessionId": loose, "cwd": t.root, "mcpServers": []})),
        ("session/resume", json!({"sessionId": loose, "cwd": t.root})),
        ("_acpmux/handoff_prepare", json!({"sessionId": loose, "harness": "other", "handoffKey": "k1"})),
    ] {
        let r = web.call(m, p.clone()).await;
        assert!(err(&r).contains("does not ask"), "{m}: {r}");
    }
    // An asking source is not refused by that rule.
    let r = web.call("session/fork", json!({"sessionId": asking})).await;
    assert!(!err(&r).contains("does not ask"), "{r}");
    // LocalApp is unchanged.
    let mut app = Client::new(&hub, Origin::LocalApp);
    let r = app.call("session/fork", json!({"sessionId": loose})).await;
    assert!(!err(&r).contains("does not ask"), "{r}");
}

#[tokio::test]
async fn web_folders_sit_inside_a_root() {
    let t = layout("f3");
    let hub = hub(&t, "ask");
    let home = dirs::home_dir().unwrap();
    let mut local = Client::new(&hub, Origin::Local);
    // Known projects: a local session's cwd. One in the home directory does
    // not make home (or what is under it) a root.
    assert!(local.new_in(&t.project, json!({})).await.get("error").is_none());
    assert!(local.new_in(&home, json!({})).await.get("error").is_none());
    let outside = t.base.join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, t.root.join("escape")).unwrap();
    let mut web = Client::new(&hub, Origin::Web);
    for dir in [
        PathBuf::from("/"),
        home.clone(),
        home.join(".ssh"),
        home.join("Library"),
        outside.clone(),
        t.root.join("escape"),
    ] {
        let r = web.new_in(&dir, json!({})).await;
        assert!(err(&r).contains("is refused"), "{} must be refused: {r}", dir.display());
        let r = web.new_in(&t.root, json!({"additionalDirectories": [dir]})).await;
        assert!(err(&r).contains("is refused"), "extra {} must be refused: {r}", dir.display());
    }
    for dir in [t.root.clone(), t.root.join("sub"), t.project.clone()] {
        let r = web.new_in(&dir, json!({})).await;
        assert!(r.get("error").is_none(), "{} is inside a root: {r}", dir.display());
    }
    let r = web.call("session/new", json!({"mcpServers": []})).await;
    assert!(err(&r).contains("is refused"), "no cwd means home: {r}");
    // LocalApp keeps the native relay's roots: no daemon root check.
    let mut app = Client::new(&hub, Origin::LocalApp);
    let r = app.new_in(&outside, json!({})).await;
    assert!(r.get("error").is_none(), "{r}");
}

#[tokio::test]
async fn the_root_compare_uses_the_filesystem_spelling() {
    let t = layout("f4");
    let hub = hub(&t, "ask");
    let mut web = Client::new(&hub, Origin::Web);
    let outside = t.base.join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    let upper = |p: &Path| PathBuf::from(p.to_string_lossy().replace("/outside", "/OUTSIDE"));
    let r = web.new_in(&upper(&outside), json!({})).await;
    assert!(err(&r).contains("is refused"), "a case-different outside path stays refused: {r}");
    // On a case-insensitive filesystem (macOS), a case-different spelling of
    // a folder inside a root is that folder.
    if cfg!(target_os = "macos") {
        let spelled = PathBuf::from(t.root.join("sub").to_string_lossy().replace("/sub", "/SUB"));
        let r = web.new_in(&spelled, json!({})).await;
        assert!(r.get("error").is_none(), "{r}");
    }
}
