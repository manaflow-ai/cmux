//! A sub-session in a folder nobody answered the trust question for waits for the person
//! instead of failing (`hub/trust_wait.rs`):
//!
//! - a folder under the person's project roots starts at once, no card (`trust_auto.rs`); a
//!   worktree made from it is not recorded as trusted, since no person trusted its source;
//! - any other folder raises a Trust / Not now card on the starting session: the session is
//!   `waiting`, carries the `trust.pending:<name>` tag, and the card names the folder;
//! - Trust (the person's answer) lets the start go on by itself, and the folder stays trusted;
//! - the folder trusted elsewhere (`acp.trust.set`, the pane's own question) withdraws the card
//!   and lets the start go on; a withdrawn card is logged as a cancelled decision, so the chat
//!   drops it, and the session leaves `waiting`;
//! - Not now refuses the start with `subsessions.trust_declined`, and an agent that asks again
//!   within minutes is refused without a second card;
//! - only the person allows the card (a connection that is not the person is refused);
//! - with two starts waiting on one folder, each has its own card: one start's Not now leaves
//!   the other's card up;
//! - a project root answers only the app's pane: a Web client's start there still waits for a
//!   person, a Web client's `_acpmux/warm` starts no agent there, a sub-session started in a Web
//!   turn waits on a card there, and an explicit Don't trust wins over the root;
//! - a settings file that cannot be read trusts nothing by a rule.
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
        Self::from(hub, Origin::Local)
    }

    fn from(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
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

/// The logged answer to the card `permission_id` on `session`, if any.
fn decision(hub: &Arc<Hub>, session: &str, permission_id: &str) -> Option<Value> {
    hub.events(session, 0, 100_000)
        .unwrap()
        .into_iter()
        .find(|e| e.kind == "permission_decision" && e.msg["permissionId"] == permission_id)
        .map(|e| e.msg)
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
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
    for folder in [
        "parent",
        "mine/app",
        "mine/web",
        "mine/repo",
        "mine/sub",
        "webparent",
        "elsewhere/a",
        "elsewhere/b",
        "elsewhere/c",
        "elsewhere/d",
        "elsewhere/e",
    ] {
        std::fs::create_dir_all(root.join(folder)).unwrap();
    }
    std::fs::create_dir_all(root.join("home")).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(
        &settings,
        json!({"agents": {"trust": {"autoTrust": true, "projectRoots": [mine], "ownOrgs": []}}})
            .to_string(),
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
    let paths = Paths {
        claude_json: root.join("home/.claude.json"),
        codex_config: root.join("home/config.toml"),
        record: root.join("home/trust.json"),
        agent_home: None,
        cmux_worktrees: None,
    };
    hub.set_trust_gate(Some(paths.clone()));
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

    // 1b. A worktree of a folder only a rule trusts: no person trusted its source, so no trust is
    //     recorded for the worktree (a Web client could read such a record as a person's).
    let repo = mine.join("repo");
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    let made = agent
        .ok(START, json!({"prompt": "echo hi", "name": "made", "cwd": repo, "worktree": true}))
        .await;
    let worktree = std::fs::canonicalize(made["worktree"]["root"].as_str().unwrap()).unwrap();
    let worktree = worktree.to_string_lossy().into_owned();
    let record: serde_json::Map<String, Value> = serde_json::from_str(
        &std::fs::read_to_string(&paths.record).unwrap_or_else(|_| "{}".to_owned()),
    )
    .unwrap();
    assert!(
        !record.contains_key(&worktree),
        "a rule's trust was recorded as a person's: {record:?}"
    );
    let trust = app.ok("acp.trust.get", json!({"cwd": worktree})).await;
    assert_ne!(trust["level"], "trusted", "{trust}");

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
    // A remote browser may not allow it even as the person: this chat is a
    // Claude session the Mac started (family claude), which no remote device
    // controls (D13, `local_claude_refusal`), so that refusal comes first.
    // `trust.web_cannot_answer` itself is covered where the Web may control
    // the chat (`local_app_trust_gate.rs`).
    let web = hub
        .respond_permission(
            &session,
            &card_id,
            Some("trust".into()),
            None,
            None,
            Answerer::of(true, &json!({})),
            Control::Web,
        )
        .await
        .unwrap_err();
    assert_eq!(
        web.data.as_ref().and_then(|d| d.get("reason")),
        Some(&json!("remote.local_claude_session")),
        "{}",
        web.message
    );

    // Trust: the start goes on by itself and the folder stays trusted.
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
    let (withdrawn, _) = card_of(&hub, &parent);
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
    // The withdrawn card is logged as cancelled (the chat drops it on that record), and the
    // session no longer reads as needing the person.
    assert_ne!(summary["status"], "waiting", "{summary}");
    let logged = decision(&hub, &parent, &withdrawn).expect("no decision for the withdrawn card");
    assert_eq!(logged["outcome"]["outcome"], "cancelled", "{logged}");

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
        Answerer::of(true, &json!({})),
        Control::Local,
    )
    .await
    .unwrap();
    for started in [first.await.unwrap(), second.await.unwrap()] {
        assert!(started.get("error").is_none(), "{started}");
    }
    let summary = app.summary(&parent).await;
    assert_eq!(summary["pendingPermissions"], 0, "{summary}");
    // The other start's card went with the folder's trust: logged as cancelled, and the session
    // is not left waiting on it.
    assert_ne!(summary["status"], "waiting", "{summary}");
    let logged = decision(&hub, &parent, &cards[1].0).expect("no decision for the other card");
    assert_eq!(logged["outcome"]["outcome"], "cancelled", "{logged}");

    // 6. Two starts in one folder, one Not now: only that start's card goes; the other waits on.
    let first = start_in_background(&hub, &parent, &elsewhere.join("e"), "sixth");
    let second = start_in_background(&hub, &parent, &elsewhere.join("e"), "seventh");
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
        Some("not_now".into()),
        None,
        None,
        Answerer::default(),
        Control::Local,
    )
    .await
    .unwrap();
    for _ in 0..200 {
        if first.is_finished() || second.is_finished() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let (declined, other) = if first.is_finished() { (first, second) } else { (second, first) };
    let declined = declined.await.unwrap();
    assert_eq!(declined["error"]["data"]["reason"], "subsessions.trust_declined", "{declined}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!other.is_finished(), "the other start still waits");
    let (card_id, _) = card_of(&hub, &parent);
    assert_ne!(card_id, cards[0].0);
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
    let started = other.await.unwrap();
    assert!(started.get("error").is_none(), "{started}");
    assert_eq!(app.summary(&parent).await["pendingPermissions"], 0);

    // 7. An explicit Don't trust wins over the project root.
    let app_folder = mine.join("app").to_string_lossy().into_owned();
    app.ok("acp.trust.set", json!({"cwd": app_folder, "level": "untrusted"})).await;
    let trust = app.ok("acp.trust.get", json!({"cwd": app_folder})).await;
    assert_eq!(trust["level"], "untrusted", "{trust}");
    app.ok("acp.trust.set", json!({"cwd": app_folder, "level": "unknown"})).await;

    // 8. A project root answers the app's pane, never a Web client: a Web client cannot answer
    //    the question, so its folder needs a decision a person made.
    let mut web_cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude"}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webRoots": [root],
    }))
    .unwrap();
    web_cfg.store.mode = StoreMode::Memory;
    let web_store = acpmux::store::open(&web_cfg.store, Path::new("/nonexistent")).unwrap();
    let web_hub = Hub::new(web_cfg, web_store);
    web_hub.set_trust_gate(Some(paths.clone()));
    let new_in = |cwd: &Path| json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let mut web = Client::from(&web_hub, Origin::Web);
    let r = web.call("session/new", new_in(&mine.join("web"))).await;
    assert_eq!(r["error"]["data"]["reason"], "trust.pending", "{r}");
    let mut pane = Client::from(&web_hub, Origin::LocalApp);
    let r = pane.call("session/new", new_in(&mine.join("web"))).await;
    assert!(r.get("error").is_none(), "the pane starts under a project root: {r}");
    let pane_chat = r["result"]["sessionId"].as_str().unwrap().to_owned();
    // Warming answers alike: a Web client's warm starts no agent there, the pane's does.
    let r = web.call("_acpmux/warm", json!({"sessionIds": [pane_chat]})).await;
    assert_ne!(r["result"]["warmed"][0]["sessionId"], json!(pane_chat), "warmed for Web: {r}");
    let r = pane.call("_acpmux/warm", json!({"sessionIds": [pane_chat]})).await;
    assert_eq!(r["result"]["warmed"][0]["sessionId"], json!(pane_chat), "{r}");

    // 8b. A sub-session started in a Web turn: the project root is no answer there either, so
    //     the start waits on a card for the person.
    let web_parent_dir = root.join("webparent");
    app.ok("acp.trust.set", json!({"cwd": web_parent_dir.to_string_lossy(), "level": "trusted"}))
        .await;
    let web_parent = web.ok("session/new", new_in(&web_parent_dir)).await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let turn = json!({"sessionId": web_parent, "prompt": [{"type": "text", "text": "hi"}]});
    web.ok("session/prompt", turn).await;
    let waiting = start_in_background(&web_hub, &web_parent, &mine.join("sub"), "webchild");
    let web_session = web_hub.resolve(&web_parent).unwrap();
    for _ in 0..200 {
        if waiting.is_finished() || !web_session.pending_permissions().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    if waiting.is_finished() {
        panic!("a Web turn's start went on by a rule: {}", waiting.await.unwrap());
    }
    let (card_id, request) = card_of(&web_hub, &web_parent);
    assert_eq!(
        request["toolCall"]["_meta"]["acpmux"]["trust"]["cwd"],
        mine.join("sub").to_string_lossy().as_ref(),
        "{request}"
    );
    web_hub
        .respond_permission(
            &web_session,
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

    // 9. A settings file that cannot be read trusts nothing by a rule.
    std::fs::write(&settings, "{ not json").unwrap();
    let trust = app.ok("acp.trust.get", json!({"cwd": mine.join("web").to_string_lossy()})).await;
    assert_eq!(trust["level"], "unknown", "{trust}");
    assert!(trust["auto"].is_null(), "{trust}");
    let _ = std::fs::remove_dir_all(&root);
}
