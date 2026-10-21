//! A chat's route at creation, with a `file:` secret (the Cloud hand's per-run
//! gateway token, crates/acpmux/src/hand/gateway.rs). Over the daemon socket:
//! a route whose secret is `file:<owner-only file>` gives the harness the
//! file's content at spawn and never shows it in the route, the session or
//! its summary; `session/new {_meta.acpmux.route}` binds the new chat before
//! its harness starts, so the first turn already runs on it; a rotated token
//! reaches the next spawn; a file another user could read, or a symlink, is
//! refused at spawn; only the unix socket may name a route at creation.
//!
//! Unix only: the owner-only file check is Unix (a Windows reference is refused).
//!
//! One test: the methods read acpmux's home from ACPMUX_HOME, a process-wide
//! setting.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-routes-file-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        reply["result"].clone()
    }

    async fn err(&mut self, m: &str, params: Value) -> Value {
        let (reply, _) = self.call_text(m, params).await;
        reply.get("error").cloned().unwrap_or_else(|| panic!("{m} did not fail: {reply}"))
    }

    async fn env_of(&mut self, session: &str, name: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]});
        let (reply, mut text) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        // The reply can overtake the turn's last streamed update.
        while !text.contains(&format!("{name}=")) {
            let line = tokio::time::timeout(Duration::from_secs(10), self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no env text: reply {reply}, text {text:?}"))
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
        // A turn that ran before this one may have streamed text first.
        let at = text.rfind(&format!("{name}=")).unwrap_or(0);
        text[at..].to_owned()
    }
}

fn reason(error: &Value) -> &str {
    error["data"]["reason"].as_str().unwrap_or("")
}

fn hub(root: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude",
                               "env": {"ANTHROPIC_API_KEY": "zzprofilekey"}}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.path = Some(root.join("home").join("config.json"));
    cfg.profile_sources.user_dir = Some(root.join("config").join("harnesses"));
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_starts_on_a_file_secret_route_named_at_creation() {
    use std::os::unix::fs::PermissionsExt;
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("ANTHROPIC_AUTH_TOKEN", "zzinherited");
    }
    let hub = hub(&root);
    let mut local = client(&hub, Origin::Local);
    let token = root.join("run.token");
    std::fs::write(&token, "zzruntoken.one\n").unwrap();
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
    let secret = format!("file:{}", token.display());

    // A relative file reference is not a reference: it is refused as an inline secret.
    let relative = local
        .err("_acpmux/route/add", json!({"id": "rel", "kind": "custom-anthropic", "anthropicBaseUrl": "http://127.0.0.1:9/g", "auth": "bearer", "secret": "file:run.token"}))
        .await;
    assert_eq!(reason(&relative), "route.secret_inline", "{relative}");
    let added = local
        .ok("_acpmux/route/add", json!({"id": "gw-run", "kind": "custom-anthropic", "families": ["claude"], "anthropicBaseUrl": "http://127.0.0.1:9/gw", "auth": "bearer", "secret": secret}))
        .await;
    assert_eq!(added["secret"], secret, "the reference only: {added}");

    // Named at creation: the very first spawn runs on the route.
    let created = local
        .ok(
            "session/new",
            json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "gw-run"}}}),
        )
        .await;
    let sid = created["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&sid, "ANTHROPIC_AUTH_TOKEN").await,
        "ANTHROPIC_AUTH_TOKEN=zzruntoken.one"
    );
    assert_eq!(
        local.env_of(&sid, "ANTHROPIC_BASE_URL").await,
        "ANTHROPIC_BASE_URL=http://127.0.0.1:9/gw"
    );
    let listed = local.ok("_acpmux/route/list", json!({"sessionId": sid})).await;
    assert_eq!(listed["active"], json!({"routeId": "gw-run", "scope": "chat"}), "{listed}");
    let dump = format!("{listed}{}", local.ok("_acpmux/info", json!({"sessionId": sid})).await);
    assert!(!dump.contains("zzruntoken"), "the token value is never shown: {dump}");

    // A rotated token reaches the next spawn of a new chat.
    std::fs::write(&token, "zzruntoken.two").unwrap();
    let second = local
        .ok(
            "session/new",
            json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "gw-run"}}}),
        )
        .await;
    let sid2 = second["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        local.env_of(&sid2, "ANTHROPIC_AUTH_TOKEN").await,
        "ANTHROPIC_AUTH_TOKEN=zzruntoken.two"
    );

    // A token file its group or others can read is refused at spawn, and so is any
    // symlink (in or out of the folder); the refusal names the path, never the value.
    for mode in [0o640, 0o604, 0o644] {
        std::fs::set_permissions(&token, std::fs::Permissions::from_mode(mode)).unwrap();
        let open = local
            .err(
                "session/new",
                json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "gw-run"}}}),
            )
            .await;
        assert!(open.to_string().contains("readable by others"), "mode {mode:o}: {open}");
        assert!(!open.to_string().contains("zzruntoken"), "mode {mode:o}: {open}");
    }
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
    let link = root.join("link.token");
    std::os::unix::fs::symlink(&token, &link).unwrap();
    local
        .ok("_acpmux/route/add", json!({"id": "gw-link", "kind": "custom-anthropic", "families": ["claude"], "anthropicBaseUrl": "http://127.0.0.1:9/gw", "auth": "bearer", "secret": format!("file:{}", link.display())}))
        .await;
    let linked = local
        .err(
            "session/new",
            json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "gw-link"}}}),
        )
        .await;
    assert!(linked.to_string().contains("not a regular file"), "{linked}");
    assert!(!linked.to_string().contains("zzruntoken"), "{linked}");

    // A route that does not exist, or a bad id, starts no chat.
    let missing = local
        .err(
            "session/new",
            json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "no-such-route"}}}),
        )
        .await;
    assert!(missing.to_string().contains("no-such-route"), "{missing}");
    local
        .err(
            "session/new",
            json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "../x"}}}),
        )
        .await;

    // Only the unix socket names a route at creation.
    let mut web = client(&hub, Origin::Web);
    web.err(
        "session/new",
        json!({"cwd": root, "mcpServers": [], "_meta": {"acpmux": {"route": "gw-run"}}}),
    )
    .await;
    let _ = std::fs::remove_dir_all(&root);
}
