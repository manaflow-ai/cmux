//! A sub-session in a folder nobody answered the trust question for waits for the person
//! instead of failing (`hub/trust_wait.rs`):
//!
//! - a folder under the person's project roots starts at once, no card (`trust_auto.rs`);
//! - any other folder raises a Trust / Not now card on the starting session: the session is
//!   `waiting`, carries the `trust.pending:<name>` tag, and the card names the folder;
//! - Trust (the person's answer) lets the start go on by itself, and the folder stays trusted;
//! - the folder trusted elsewhere (`acp.trust.set`, the pane's own question) withdraws the card
//!   and lets the start go on;
//! - Not now refuses the start with `subsessions.trust_declined`, and an agent that asks again
//!   within minutes is refused without a second card;
//! - only the person allows the card (a connection that is not the person is refused).
//!
//! Stand-in agents (fake_agent.py). One test function: the settings file is read from this
//! process's environment.

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

    async fn summary(&mut self, id: &str) -> Value {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["sessionId"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("{id} is not listed: {list}"))
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

/// A start the agent makes, running while the test looks at the session.
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

fn card_of(hub: &Arc<Hub>, parent: &str) -> (String, Value) {
    let session = hub.resolve(parent).unwrap();
    let pending = session.pending_permissions();
    assert_eq!(pending.len(), 1, "one card: {pending:?}");
    pending.into_iter().next().unwrap()
}

#[tokio::test]
async fn a_folder_nobody_answered_for_waits_on_a_card_and_resumes_by_itself() {
    let root = std::fs::canonicalize({
        let d =
            std::env::temp_dir().join(format!("acpmux-subsession-trust-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&d).unwrap();
        d
    })
    .unwrap();
    let mine = root.join("mine");
    let elsewhere = root.join("elsewhere");
    for folder in ["parent", "mine/app", "elsewhere/a", "elsewhere/b", "elsewhere/c", "elsewhere/d"]
    {
        std::fs::create_dir_all(root.join(folder)).unwrap();
    }
    std::fs::create_dir_all(root.join("home")).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(
        &settings,
        json!({"agents": {"trust": {"projectRoots": [mine], "ownOrgs": []}}}).to_string(),
    )
    .unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude"}},
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
    }));
    let mut app = Client::new(&hub);
    // The parent runs in a folder of the person's own: the unix socket never asks.
    let new = json!({"cwd": root.join("parent"), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();

    // 1. Under a project root: no card, the child starts at once.
    let mut agent = Client::as_session(&hub, &parent).await;
    let own =
        agent.ok(START, json!({"prompt": "echo hi", "name": "own", "cwd": mine.join("app")})).await;
    assert_eq!(own["depth"], 1, "{own}");
    assert_eq!(app.summary(&parent).await["pendingPermissions"], 0);

    // 2. Another folder: the start waits on a card in the parent's chat.
    let waiting = start_in_background(&hub, &parent, &elsewhere.join("a"), "first");
    app.until_waiting(&parent).await;
    let summary = app.summary(&parent).await;
    assert_eq!(summary["status"], "waiting", "{summary}");
    assert_eq!(summary["pendingPermissions"], 1, "{summary}");
    assert_eq!(
        summary["tags"]["trust.pending:first"],
        elsewhere.join("a").to_string_lossy().as_ref(),
        "{summary}"
    );
    let (card_id, request) = card_of(&hub, &parent);
    let folder = elsewhere.join("a").to_string_lossy().into_owned();
    assert_eq!(request["toolCall"]["_meta"]["acpmux"]["trust"]["cwd"], folder.as_str());
    let item = &request["toolCall"]["_meta"]["acpmux"]["question"]["items"][0];
    assert_eq!(item["header"], "Folder trust", "{request}");
    let labels: Vec<&str> =
        item["options"].as_array().unwrap().iter().filter_map(|o| o["label"].as_str()).collect();
    assert_eq!(labels, ["Trust folder", "Not now"]);
    assert!(!waiting.is_finished(), "the start waits");

    // Only the person allows: an agent's connection is refused, and the card stays.
    let session = hub.resolve(&parent).unwrap();
    let refused = hub
        .respond_permission(
            &session,
            &card_id,
            Some("trust".into()),
            None,
            None,
            Answerer::default(),
            Control::Local,
        )
        .await
        .unwrap_err();
    assert!(refused.message.contains("Mac app"), "{}", refused.message);
    assert_eq!(app.summary(&parent).await["pendingPermissions"], 1);
    // A remote browser may not allow it even as the person.
    let web = hub
        .respond_permission(
            &session,
            &card_id,
            Some("trust".into()),
            None,
            None,
            Answerer { person: true, ..Answerer::default() },
            Control::Web,
        )
        .await
        .unwrap_err();
    assert!(web.message.contains("trust.web_cannot_answer"), "{}", web.message);

    // Trust: the start goes on by itself and the folder stays trusted.
    hub.respond_permission(
        &session,
        &card_id,
        Some("trust".into()),
        None,
        None,
        Answerer { person: true, ..Answerer::default() },
        Control::Local,
    )
    .await
    .unwrap();
    let started = waiting.await.unwrap();
    assert!(started.get("error").is_none(), "{started}");
    assert_eq!(started["result"]["depth"], 1, "{started}");
    let summary = app.summary(&parent).await;
    assert_eq!(summary["pendingPermissions"], 0, "{summary}");
    assert!(summary["tags"].get("trust.pending:first").is_none(), "{summary}");
    let trust = app.ok("acp.trust.get", json!({"cwd": folder})).await;
    assert_eq!(trust["level"], "trusted", "{trust}");
    // The folder answers the next start without a card.
    let again = agent
        .ok(START, json!({"prompt": "echo hi", "name": "again", "cwd": elsewhere.join("a")}))
        .await;
    assert_eq!(again["depth"], 1, "{again}");

    // 3. Trusted elsewhere (the pane's own question) while the start waits: the card goes away.
    let waiting = start_in_background(&hub, &parent, &elsewhere.join("b"), "second");
    app.until_waiting(&parent).await;
    app.ok(
        "acp.trust.set",
        json!({"cwd": elsewhere.join("b").to_string_lossy(), "level": "trusted"}),
    )
    .await;
    let started = waiting.await.unwrap();
    assert!(started.get("error").is_none(), "{started}");
    let summary = app.summary(&parent).await;
    assert_eq!(summary["pendingPermissions"], 0, "{summary}");
    assert!(summary["tags"].get("trust.pending:second").is_none(), "{summary}");

    // 4. Not now: refused with the reason, remembered, and no second card.
    let waiting = start_in_background(&hub, &parent, &elsewhere.join("c"), "third");
    app.until_waiting(&parent).await;
    let (card_id, _) = card_of(&hub, &parent);
    hub.respond_permission(
        &session,
        &card_id,
        Some("not_now".into()),
        None,
        None,
        Answerer::default(),
        Control::Local,
    )
    .await
    .unwrap();
    let declined = waiting.await.unwrap();
    assert_eq!(declined["error"]["data"]["reason"], "subsessions.trust_declined", "{declined}");
    let retry = agent
        .call(START, json!({"prompt": "echo hi", "name": "retry", "cwd": elsewhere.join("c")}))
        .await;
    assert_eq!(retry["error"]["data"]["reason"], "subsessions.trust_declined", "{retry}");
    assert_eq!(app.summary(&parent).await["pendingPermissions"], 0);

    // 5. Two starts in one untrusted folder raise two cards; Trust on one lets both go on.
    let first = start_in_background(&hub, &parent, &elsewhere.join("d"), "fourth");
    let second = start_in_background(&hub, &parent, &elsewhere.join("d"), "fifth");
    let mut cards = Vec::new();
    for _ in 0..200 {
        cards = session.pending_permissions();
        if cards.len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(cards.len(), 2, "two cards: {cards:?}");
    hub.respond_permission(
        &session,
        &cards[0].0,
        Some("trust".into()),
        None,
        None,
        Answerer { person: true, ..Answerer::default() },
        Control::Local,
    )
    .await
    .unwrap();
    for started in [first.await.unwrap(), second.await.unwrap()] {
        assert!(started.get("error").is_none(), "{started}");
    }
    assert_eq!(app.summary(&parent).await["pendingPermissions"], 0);
    let _ = std::fs::remove_dir_all(&root);
}
