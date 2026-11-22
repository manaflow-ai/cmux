//! A chat the owner's own paired phone starts with no folder (a chat tab whose workspace has no
//! project folder) gets a folder of its own on the Mac, as the Mac's pane gives a chat in a
//! workspace with no folder: a new agent-home folder (`remote_guard.rs` `phone_agent_home`),
//! owner-only, marked as made by cmux, so nobody is asked to trust it and the phone's first
//! message runs. Before, the phone said "Open this workspace in a project folder on the Mac, then
//! send again." ("figure out the fucking right behaviour we want, perfect it.", Leo).
//!
//! What still holds: every other Web caller with no folder (the shared dashboard token, a paired
//! machine that is not a phone, a removed phone) is refused; the home folder is refused to the
//! phone too; and the phone's chat keeps an asking policy.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::pairing::Role;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_device, serve_connection_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A hub as the daemon runs it: the folder-trust gate on (the hermetic home's trust files, none
/// yet), one Web root, the stand-in's asking modes.
fn hub(root: &std::path::Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webRoots": [root],
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(acpmux::trust::Paths::current().expect("a home folder")));
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, Option<&'static str>);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0, None)
    }

    /// A connection that presented the paired credential `token`, served as its role says (a
    /// phone as Web under its own id, as the Mac's mobile host connects for it), forwarding for
    /// its Web client when `via_web`.
    fn device(hub: &Arc<Hub>, token: &str, via_web: bool) -> Self {
        let proof = hub.pairing.device_for(token).expect("a live credential");
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_device(hub.clone(), in_rx, out_tx, proof));
        Client(in_tx, out_rx, 0, via_web.then_some("web"))
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.try_call(m, params).await.expect("the connection stays open")
    }

    /// The reply, or None when the daemon closed the connection first (a revoked credential).
    async fn try_call(&mut self, m: &str, mut params: Value) -> Option<Value> {
        self.2 += 1;
        let id = self.2;
        if let Some(via) = self.3 {
            let meta = params.as_object_mut().unwrap().entry("_meta").or_insert(json!({}));
            let mux = meta.as_object_mut().unwrap().entry("acpmux").or_insert(json!({}));
            mux["via"] = json!(via);
        }
        self.0.send(Message::request(id, m, params).to_line()).await.ok()?;
        loop {
            let line =
                tokio::time::timeout(Duration::from_secs(30), self.1.recv()).await.unwrap()?;
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id").and_then(Value::as_i64) == Some(id) && v.get("method").is_none() {
                return Some(v);
            }
        }
    }
}

/// What the phone sends for a chat with no project folder (`LiveWorkspaceCreation.swift`
/// `startAgentSession`): no `cwd`, the asking policy.
fn folderless() -> Value {
    json!({"mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "policy": "ask"}}})
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

fn agent_home_root() -> PathBuf {
    std::fs::canonicalize(acpmux::trust::agent_home_root().expect("a data folder"))
        .expect("made by the phone's start")
}

#[tokio::test]
async fn the_owners_phone_with_no_folder_gets_a_new_agent_home_folder_and_its_message_runs() {
    let root = daemon_env::Scratch::new("phone-scratch-own");
    let hub = hub(root.path());
    let (_, token) = hub.pairing.issue_phone("phone-iphone").unwrap();
    let mut phone = Client::device(&hub, &token, false);

    let r = phone.call("session/new", folderless()).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let meta = hub.resolve(&id).unwrap().meta();
    let cwd = meta.cwd.clone();
    // A new folder in the Mac's agent-home folder, marked as made by cmux, owner-only.
    assert_eq!(cwd.parent(), Some(agent_home_root().as_path()), "{r}");
    assert!(cwd.file_name().unwrap().to_string_lossy().starts_with("phone-"), "{r}");
    assert!(cwd.join(acpmux::trust::AGENT_HOME_MARKER).is_file());
    let mode = std::fs::metadata(&cwd).unwrap().permissions().mode();
    assert_eq!(mode & 0o077, 0, "owner-only");
    // The phone's chat keeps the asking policy.
    assert_eq!(meta.permission_policy.as_deref(), Some("ask"), "{r}");

    // Nobody is asked to trust it: the phone's first message runs.
    let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello from the phone"}]});
    let r = phone.call("session/prompt", p).await;
    assert_eq!(r["result"]["stopReason"], "end_turn", "{r}");

    // A second chat gets a folder of its own, never the first one's.
    let r = phone.call("session/new", folderless()).await;
    let second = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    let second = hub.resolve(second).unwrap().meta().cwd.clone();
    assert_ne!(second, cwd);
    assert_eq!(second.parent(), Some(agent_home_root().as_path()));
    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&second);
}

#[tokio::test]
async fn every_other_web_caller_with_no_folder_is_still_refused() {
    let root = daemon_env::Scratch::new("phone-scratch-others");
    let hub = hub(root.path());
    let laptop = hub.pairing.issue("laptop", Role::Client).unwrap().1;
    let (phone, token) = hub.pairing.issue_phone("old-iphone").unwrap();
    let mut removed = Client::device(&hub, &token, false);
    let mut callers = vec![
        ("dashboard", Client::new(&hub, Origin::Web)),
        ("client machine for its Web client", Client::device(&hub, &laptop, true)),
    ];
    for (who, c) in callers.iter_mut() {
        let r = c.call("session/new", folderless()).await;
        assert_eq!(reason(&r), "remote.cwd_outside_roots", "{who}: {r}");
    }
    // A phone removed in Settings is no longer the owner's: its open connection gets no folder.
    hub.pairing.revoke(&phone.id).unwrap();
    if let Some(r) = removed.try_call("session/new", folderless()).await {
        assert!(r.get("error").is_some(), "removed phone: {r}");
    }
    assert!(hub.sessions().is_empty(), "no chat was started");
}

#[tokio::test]
async fn the_owners_phone_is_still_refused_the_home_folder_and_an_approving_policy() {
    let root = daemon_env::Scratch::new("phone-scratch-home");
    let hub = hub(root.path());
    let (_, token) = hub.pairing.issue_phone("phone-iphone").unwrap();
    let mut phone = Client::device(&hub, &token, false);
    let home = dirs::home_dir().unwrap();
    std::fs::create_dir_all(&home).unwrap();
    let r = phone
        .call(
            "session/new",
            json!({"cwd": home, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}),
        )
        .await;
    assert_eq!(reason(&r), "remote.cwd_outside_roots", "home: {r}");
    // No folder does not widen the policy: an approving one is refused as with a folder.
    let r = phone
        .call(
            "session/new",
            json!({"mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "policy": "approve-all"}}}),
        )
        .await;
    assert!(r.get("error").is_some(), "approve-all: {r}");
    assert!(
        r["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("never from a remote WebSocket"),
        "{r}"
    );
}
