//! LAUNCH-NO-TCC-PROMPTS: a daemon start never starts an agent in a privacy-protected folder by
//! itself. A prompt queued (or a turn cut) in a chat whose folder is guarded waits after a
//! restart until the person opens that chat; then it runs, in its place. A chat in an ordinary
//! folder resumes at once, as before (`hub/protected_hold.rs`).

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A hub whose log lives in `dir`, so a second one there is the same daemon restarted.
fn durable_hub(dir: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn prompt(session: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, method, params).to_line()).await.unwrap();
        self.2
    }

    async fn until(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if pred(&value) {
                return value;
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        let value = self.until(|v| v.get("id") == Some(&json!(id))).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self, cwd: &Path) -> String {
        let new = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        let created = self.call("session/new", new).await;
        created["sessionId"].as_str().unwrap().to_owned()
    }

    async fn ran(&mut self, session: &str, prompt_id: &str) -> bool {
        let page = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
            .await;
        page["events"].as_array().unwrap().iter().any(|e| e["msg"]["promptId"] == prompt_id)
    }

    async fn wait_ran(&mut self, session: &str, prompt_id: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !self.ran(session, prompt_id).await {
            assert!(Instant::now() < deadline, "{prompt_id} never ran in {session}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Starts an "until-cancel" turn, waits until it runs, then queues `queued` behind it.
    async fn busy_with_queued(&mut self, session: &str, queued: &str) {
        self.send("session/prompt", prompt(session, &format!("{queued}-run"), "until-cancel"))
            .await;
        self.until(|v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
        self.send("session/prompt", prompt(session, queued, "queued")).await;
        self.until(|v| {
            v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == json!(queued)
        })
        .await;
    }
}

/// A folder outside every guarded location, and one in the home folder's Downloads. The test
/// process's HOME is its own scratch home (`support/daemon_env.rs`), so this is never the
/// person's Downloads, and no read here raises a prompt.
fn folders(dir: &Path) -> (PathBuf, PathBuf) {
    let plain = dir.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let home = dirs::home_dir().expect("a home folder");
    let guarded = home.join("Downloads").join(format!("project-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&guarded).unwrap();
    assert!(acpmux::protected_folders::unasked_refusal(&guarded).is_some());
    assert!(acpmux::protected_folders::unasked_refusal(&plain).is_none());
    (plain, guarded)
}

#[tokio::test]
async fn a_restart_starts_no_agent_in_a_protected_folder_until_the_chat_is_opened() {
    let dir =
        std::env::temp_dir().join(format!("acpmux-protected-resume-{}", uuid::Uuid::now_v7()));
    let (plain, guarded) = folders(&dir);
    let store = dir.join("store");
    std::fs::create_dir_all(&store).unwrap();
    let hub = durable_hub(&store);
    let mut c = Client::open(&hub);
    let open = c.new_session(&plain).await;
    let held = c.new_session(&guarded).await;
    c.busy_with_queued(&open, "p-open").await;
    c.busy_with_queued(&held, "p-held").await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&store);
    hub.resume_queues();
    let mut c = Client::open(&hub);
    // The ordinary folder's queue goes on by itself.
    c.wait_ran(&open, "p-open").await;
    // Startup is over; give the guarded chat's resume its chance to run too.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!c.ran(&held, "p-held").await, "a restart started an agent in a protected folder");
    assert!(
        !c.ran(&held, "p-held-run~resume-1").await,
        "a restart went on with a cut turn in a protected folder"
    );

    // The person opens the chat: what waited runs.
    c.call("_acpmux/attach", json!({"sessionId": held, "visible": true})).await;
    c.wait_ran(&held, "p-held").await;
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&guarded);
}

#[tokio::test]
async fn a_hidden_attach_keeps_the_hold_and_a_persons_prompt_lifts_it() {
    let dir =
        std::env::temp_dir().join(format!("acpmux-protected-prompt-{}", uuid::Uuid::now_v7()));
    let (_plain, guarded) = folders(&dir);
    let store = dir.join("store");
    std::fs::create_dir_all(&store).unwrap();
    let hub = durable_hub(&store);
    let mut c = Client::open(&hub);
    let held = c.new_session(&guarded).await;
    c.busy_with_queued(&held, "p-held").await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&store);
    hub.resume_queues();
    let mut c = Client::open(&hub);
    // The app holds restored tabs attached without showing them: that is no person asking.
    c.call("_acpmux/attach", json!({"sessionId": held, "visible": false})).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !c.ran(&held, "p-held").await,
        "a hidden attach started an agent in a protected folder"
    );

    // A prompt the person sends there runs, after what waited in the queue.
    c.send("session/prompt", prompt(&held, "p-new", "after")).await;
    c.wait_ran(&held, "p-held").await;
    c.wait_ran(&held, "p-new").await;
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&guarded);
}

/// The test process's own folders (its HOME, Cargo's target tmp where it keeps them) are ordinary
/// folders to the daemon: a test chat there resumes at once. A fleet Mac builds on a second volume
/// (`/Volumes/ephemeral0`), which the daemon guards; there a chat under HOME waited for a person
/// after every restart and import (the transfer_guard tests failed only on macOS).
#[test]
fn the_test_home_is_an_ordinary_folder_to_the_daemon() {
    let home = dirs::home_dir().expect("a home directory");
    let chat = home.join("a-chat");
    assert_eq!(acpmux::protected_folders::unasked_refusal(&chat), None, "HOME {}", home.display());
}
