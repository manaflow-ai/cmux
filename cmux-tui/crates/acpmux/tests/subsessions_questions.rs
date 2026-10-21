//! A parent session answers its sub-sessions' questions
//! (`_acpmux/subsession/answer`, `hub/subsessions.rs`): an agent session,
//! proven by its caller token, sees a descendant's pending question in
//! `get_session` and answers it; the answer reaches the child's agent as a
//! person's would and the decision record names the parent. A permission
//! prompt, the child's own question and another family's are refused.
//!
//! Stand-in agents (fake_agent.py). One test function: the settings file is
//! read from this process's environment.

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
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const START: &str = "_acpmux/subsession/start";
const ANSWER: &str = "_acpmux/subsession/answer";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

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

    /// Starts a child of this session with `prompt` and waits until it asks.
    async fn child_that_asks(&mut self, prompt: &str) -> String {
        let child = self.ok(START, json!({"prompt": prompt})).await["sessionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let w = self
            .ok(
                "_acpmux/wait",
                json!({"sessions": [child], "until": ["permission"], "timeoutMs": 20000}),
            )
            .await;
        assert_eq!(w["timedOut"], false, "{w}");
        child
    }
}

#[tokio::test]
async fn subsession_questions_a_parent_answers_its_childs_question_but_never_a_permission() {
    let root = std::env::temp_dir().join(format!("acpmux-subq-it-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, "{}").unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    let stranger = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    let mut p = Client::as_session(&hub, &parent).await;

    // The child asks; the parent sees the question in its row.
    let child = p.child_that_asks("question: Which one?").await;
    let row = p.ok("_acpmux/subsession/get", json!({"sessionId": child})).await;
    let questions = row["questions"].as_array().unwrap_or_else(|| panic!("no questions: {row}"));
    assert_eq!(questions.len(), 1, "{row}");
    let q = &questions[0];
    let pid = q["permissionId"].as_str().unwrap().to_owned();
    assert_eq!(q["items"][0]["prompt"], "Which one?", "{q}");
    assert_eq!(q["items"][0]["options"][1]["label"], "B", "{q}");

    // Not the child's own question, not another family's, not without the token.
    let mut c = Client::as_session(&hub, &child).await;
    let answers = json!({"Which one?": "B"});
    let e = c
        .refused(ANSWER, json!({"sessionId": child, "permissionId": pid, "answers": answers}))
        .await;
    assert_eq!(e["data"]["reason"], "subsessions.not_family", "{e}");
    let mut s = Client::as_session(&hub, &stranger).await;
    let e = s
        .refused(ANSWER, json!({"sessionId": child, "permissionId": pid, "answers": answers}))
        .await;
    assert_eq!(e["data"]["reason"], "subsessions.not_family", "{e}");
    let e = app
        .refused(ANSWER, json!({"sessionId": child, "permissionId": pid, "answers": answers}))
        .await;
    assert_eq!(e["data"]["reason"], "subsessions.caller_required", "{e}");
    // Answers are checked as a person's are: every question, nothing blank.
    let e = p
        .refused(
            ANSWER,
            json!({"sessionId": child, "permissionId": pid, "answers": {"Which one?": " "}}),
        )
        .await;
    assert!(e["message"].as_str().unwrap().contains("answers"), "{e}");

    // The parent's answer reaches the child's agent as the tool's answers.
    let got =
        p.ok(ANSWER, json!({"sessionId": child, "permissionId": pid, "answers": answers})).await;
    assert_eq!(got["answered"], true, "{got}");
    p.ok("_acpmux/wait", json!({"sessions": [child], "until": ["ready"], "timeoutMs": 20000}))
        .await;
    let row = p.ok("_acpmux/subsession/get", json!({"sessionId": child})).await;
    assert_eq!(row["lastReply"], r#"chose allow_once {"Which one?": "B"}"#, "{row}");
    assert_eq!(row["questions"], json!([]), "{row}");
    // The child's record says the parent answered, not the person.
    let decision = hub
        .events(&child, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "permission_decision")
        .next_back()
        .expect("a permission_decision record");
    assert_eq!(decision.msg["answeredBy"]["session"], parent.as_str(), "{:?}", decision.msg);
    // Spent: a second answer finds nothing pending.
    let e = p
        .refused(ANSWER, json!({"sessionId": child, "permissionId": pid, "answers": answers}))
        .await;
    assert!(e["message"].as_str().unwrap().contains("no pending"), "{e}");

    // A permission prompt stays the person's: the parent cannot allow it.
    let asking = p.child_that_asks("ask: rm -rf build").await;
    let row = p.ok("_acpmux/subsession/get", json!({"sessionId": asking})).await;
    assert_eq!(row["questions"], json!([]), "{row}");
    let last = |kind: &str| {
        hub.events(&asking, 0, 1000).unwrap().into_iter().filter(|e| e.kind == kind).next_back()
    };
    let ppid = last("permission_request").expect("a permission_request record").msg["permissionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let e = p
        .refused(ANSWER, json!({"sessionId": asking, "permissionId": ppid, "answers": {"x": "y"}}))
        .await;
    assert_eq!(e["data"]["reason"], "subsessions.not_a_question", "{e}");
    let message = e["message"].as_str().unwrap();
    assert!(message.contains("cmux NEXT"), "{message}");
    // It is still pending for the person.
    assert!(last("permission_decision").is_none(), "the prompt was decided");
    let row = p.ok("_acpmux/subsession/get", json!({"sessionId": asking})).await;
    assert_eq!(row["status"], "waiting", "{row}");

    let _ = std::fs::remove_dir_all(&root);
}
