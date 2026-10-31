//! A sub-session's folder is checked, and only then does its harness start there. A folder
//! renamed or a link swapped in between (here while the start waits on the trust card) never
//! gets the harness: the start is refused with `subsessions.cwd_moved` before anything runs in
//! the folder that took the checked one's place (`hub/subsession_guard.rs` `CheckedFolder`).
//!
//! The stand-in harness (fake_agent.py) leaves a `harness-started-here` file in the folder it
//! starts in. One test function: the settings file is read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::person::Answerer;
use acpmux::hub::{Control, Hub};
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::trust::Paths;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";
/// What the stand-in harness leaves in the folder it starts in.
const MARKER: &str = "harness-started-here";
/// The harness: it leaves [`MARKER`] in its folder, then runs fake_agent.py.
const LEAVE_MARKER: &str = "import os, sys; open('harness-started-here', 'w').close(); \
     os.execvp(sys.executable, [sys.executable, sys.argv[1]])";

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.1.recv())
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

    /// Waits until the session asks the person something.
    async fn until_waiting(&mut self, id: &str) {
        self.ok(
            "_acpmux/wait",
            json!({"sessions": [id], "until": ["permission"], "timeoutMs": 20000}),
        )
        .await;
    }
}

/// A start the agent makes, running while the test changes the folder.
fn start_in_background(
    hub: &Arc<Hub>,
    parent: &str,
    cwd: &Path,
    name: &str,
) -> tokio::task::JoinHandle<Value> {
    let (hub, parent) = (hub.clone(), parent.to_owned());
    let params = json!({"prompt": "echo hi", "name": name, "cwd": cwd});
    tokio::spawn(async move {
        let mut agent = Client::as_session(&hub, &parent).await;
        agent.call(START, params).await
    })
}

/// The person's Trust on the one trust card in `parent`'s chat.
async fn trust_the_card(hub: &Arc<Hub>, parent: &str) {
    let session = hub.resolve(parent).unwrap();
    let pending = session.pending_permissions();
    assert_eq!(pending.len(), 1, "one card: {pending:?}");
    let (card_id, _) = pending.into_iter().next().unwrap();
    hub.respond_permission(
        &session,
        &card_id,
        Some("trust".into()),
        None,
        None,
        Answerer::of(true, &json!({})),
        Control::Local,
    )
    .await
    .unwrap();
}

/// The start's refusal reason; the start must have been refused.
fn refusal_reason(start: &Value) -> &Value {
    assert!(start.get("error").is_some(), "the start went on in a swapped folder: {start}");
    &start["error"]["data"]["reason"]
}

#[tokio::test]
async fn a_folder_swapped_while_its_start_waits_gets_no_harness() {
    let root = std::fs::canonicalize({
        let d = std::env::temp_dir().join(format!("acpmux-cwd-swap-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&d).unwrap();
        d
    })
    .unwrap();
    for folder in ["parent", "home", "checked", "stand-in", "linked", "other"] {
        std::fs::create_dir_all(root.join(folder)).unwrap();
    }
    let settings = root.join("cmux-next.json");
    std::fs::write(
        &settings,
        json!({"agents": {"trust": {"autoTrust": false, "projectRoots": [], "ownOrgs": []}}})
            .to_string(),
    )
    .unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", "-c", LEAVE_MARKER, FAKE], "family": "claude"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(Paths {
        claude_json: root.join("home/.claude.json"),
        codex_config: root.join("home/config.toml"),
        record: root.join("home/trust.json"),
        agent_home: None,
        cmux_worktrees: None,
    }));
    let mut app = Client::new(&hub);
    let new = json!({"cwd": root.join("parent"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    assert!(root.join("parent").join(MARKER).exists(), "the stand-in harness leaves its marker");

    // 1. Renamed: `checked` passes the checks; while the start waits on the card, it is moved
    //    away and another folder takes its name.
    let waiting = start_in_background(&hub, &parent, &root.join("checked"), "renamed");
    app.until_waiting(&parent).await;
    std::fs::rename(root.join("checked"), root.join("checked-moved")).unwrap();
    std::fs::rename(root.join("stand-in"), root.join("checked")).unwrap();
    trust_the_card(&hub, &parent).await;
    let start = waiting.await.unwrap();
    assert!(
        !root.join("checked").join(MARKER).exists(),
        "the harness started in the folder that took the checked one's name: {start}"
    );
    assert_eq!(refusal_reason(&start), "subsessions.cwd_moved", "{start}");

    // 2. Linked: `linked` passes the checks; while the start waits on the card, a link to
    //    another folder takes its place.
    let waiting = start_in_background(&hub, &parent, &root.join("linked"), "linked");
    app.until_waiting(&parent).await;
    std::fs::rename(root.join("linked"), root.join("linked-moved")).unwrap();
    std::os::unix::fs::symlink(root.join("other"), root.join("linked")).unwrap();
    trust_the_card(&hub, &parent).await;
    let start = waiting.await.unwrap();
    assert!(
        !root.join("other").join(MARKER).exists(),
        "the harness started in the folder the link points to: {start}"
    );
    assert_eq!(refusal_reason(&start), "subsessions.cwd_moved", "{start}");
    for folder in ["checked-moved", "linked-moved"] {
        assert!(!root.join(folder).join(MARKER).exists(), "nothing started in {folder}");
    }

    let _ = std::fs::remove_dir_all(&root);
}
