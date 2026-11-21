//! Rolling chat summaries (`hub/rolling_summary.rs`; David Beyer's ask, 2026-11-20: "rolling
//! summaries of every chat with a next action for each"): after a turn a person started, the chat
//! carries one short line on where it stands and the next action (`rollingSummary` on its row),
//! for the sidebar and the chat header.
//!
//! It costs nothing when the agent already said it: a turn that ends on a `wrap_up` call is
//! summarized from its recap and ask. Only a person's turn without one asks the summary command,
//! once, with the last summary, the prompt and the reply's end, never the transcript. Another
//! agent's turn asks nothing. The tests' command is a fake (`tests/fake_summarizer.py`): no test
//! reaches a model.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const SUMMARIZER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_summarizer.py");

/// A hub whose summary command records each request in `asked`; titles are off, so the only
/// command that runs is the summary's.
fn hub(asked: &Path, generate: Option<bool>) -> Arc<Hub> {
    let mut summaries = json!({"command": ["python3", SUMMARIZER, asked]});
    if let Some(generate) = generate {
        summaries["generate"] = json!(generate);
    }
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "titles": {"generate": false},
        "summaries": summaries,
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn asked_path(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "acpmux-summaries-{name}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

/// The requests the summary command was given, in order.
fn requests(asked: &Path) -> Vec<String> {
    std::fs::read_to_string(asked)
        .unwrap_or_default()
        .split("\n---\n")
        .filter(|r| !r.trim().is_empty())
        .map(str::to_owned)
        .collect()
}

/// A client connection. Pushes that arrive while a call waits for its reply are kept in
/// `backlog`: a wrap-up's summary is told before the prompt's reply.
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, VecDeque<Value>);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0, VecDeque::new())
    }

    async fn line(&mut self, within: Duration) -> Option<Value> {
        let line = tokio::time::timeout(within, self.1.recv()).await.ok()??;
        serde_json::from_str(&line).ok()
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let value = self.line(Duration::from_secs(30)).await.expect("no reply");
            if value.get("id") == Some(&json!(id)) {
                assert!(value.get("error").is_none(), "{method}: {value}");
                return value["result"].clone();
            }
            self.3.push_back(value);
        }
    }

    async fn watch(&mut self) {
        self.call("_acpmux/watch", json!({"enabled": true})).await;
    }

    async fn new_session(&mut self) -> String {
        let created = self
            .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
            .await;
        created["sessionId"].as_str().unwrap().to_owned()
    }

    /// A person's prompt, answered when its turn ends.
    async fn prompt(&mut self, session: &str, text: &str) {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }

    /// Another agent's message (`acpmux send --from`), answered when its turn ends.
    async fn agent_prompt(&mut self, session: &str, text: &str) {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
                   "_meta": {"acpmux": {"promptId": "from-lane", "fromAgent": "lane-a"}}}),
        )
        .await;
    }

    async fn rolling(&mut self, session: &str) -> Value {
        self.call("_acpmux/info", json!({"sessionId": session})).await["rollingSummary"].clone()
    }

    /// The next `_acpmux/session_changed` of a `summarized` record, within `within`: one that
    /// came while a call waited first.
    async fn summarized(&mut self, within: Duration) -> Option<Value> {
        let is_summarized =
            |v: &Value| v.pointer("/params/recordKind") == Some(&json!("summarized"));
        if let Some(at) = self.3.iter().position(is_summarized) {
            let found = self.3.remove(at);
            self.3.drain(..at);
            return found;
        }
        self.3.clear();
        let end = tokio::time::Instant::now() + within;
        loop {
            let left = end.saturating_duration_since(tokio::time::Instant::now());
            let value = self.line(left).await?;
            if value.pointer("/params/recordKind") == Some(&json!("summarized")) {
                return Some(value);
            }
        }
    }
}

#[tokio::test]
async fn a_persons_turn_gets_a_rolling_summary_and_next_action_on_its_row() {
    let asked = asked_path("model");
    let hub = hub(&asked, None);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.prompt(&session, "Plan a three-dish picnic menu").await;
    let changed = client.summarized(Duration::from_secs(15)).await.expect("no summarized change");
    // The row the sidebar reads carries it, cleaned of the model's quotes and blank lines.
    let expected = json!({
        "text": "The picnic menu has three dishes, all vegetarian.",
        "next": "Pick a dessert.",
        "source": "model",
        "turn": 1,
    });
    let row = changed.pointer("/params/session/rollingSummary").cloned().unwrap_or(Value::Null);
    assert_eq!(strip_at(row), expected);
    assert_eq!(strip_at(client.rolling(&session).await), expected);
    let first = requests(&asked);
    assert_eq!(first.len(), 1, "one request per turn: {first:?}");
    assert!(first[0].contains("Plan a three-dish picnic menu"), "{}", first[0]);

    // Rolling: the next turn's request carries the last summary, not the transcript.
    client.prompt(&session, "now make it vegetarian").await;
    let second = client.summarized(Duration::from_secs(15)).await.expect("no second summary");
    assert_eq!(
        second.pointer("/params/session/rollingSummary/text"),
        Some(&json!("The vegetarian picnic menu is final."))
    );
    let both = requests(&asked);
    assert_eq!(both.len(), 2, "{both:?}");
    assert!(both[1].contains("The picnic menu has three dishes"), "{}", both[1]);
    assert!(both[1].contains("now make it vegetarian"), "{}", both[1]);
    assert!(
        !both[1].contains("Plan a three-dish picnic menu"),
        "the old prompt went again: {}",
        both[1]
    );
    assert_eq!(client.rolling(&session).await["turn"], json!(2));
    let _ = std::fs::remove_file(&asked);
}

#[tokio::test]
async fn a_turn_that_ends_on_a_wrap_up_is_summarized_from_it_without_a_model_call() {
    let asked = asked_path("wrap-up");
    let hub = hub(&asked, None);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    let args = json!({
        "recap": "Fixed the parser and pushed it. CI is still running.",
        "ask": "Merge the PR once CI is green?",
        "actions": ["Merge it", "Not yet"],
    });
    client.prompt(&session, &format!("wrap-up: {args}")).await;
    client.summarized(Duration::from_secs(15)).await.expect("no summarized change");
    assert_eq!(
        strip_at(client.rolling(&session).await),
        json!({
            "text": "Fixed the parser and pushed it. CI is still running.",
            "next": "Merge the PR once CI is green?",
            "source": "wrap_up",
            "turn": 1,
        })
    );
    assert!(requests(&asked).is_empty(), "a model was asked for what the agent said");
    let _ = std::fs::remove_file(&asked);
}

#[tokio::test]
async fn another_agents_turn_asks_for_no_summary() {
    let asked = asked_path("agent");
    let hub = hub(&asked, None);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.agent_prompt(&session, "Run the fleet tests and report").await;
    assert!(
        client.summarized(Duration::from_secs(3)).await.is_none(),
        "summarized an agent's turn"
    );
    assert!(requests(&asked).is_empty(), "the summary command ran for an agent's turn");
    assert_eq!(client.rolling(&session).await, Value::Null);

    // The person's own prompt then is summarized.
    client.prompt(&session, "Plan a three-dish picnic menu").await;
    client.summarized(Duration::from_secs(15)).await.expect("no summary of the person's turn");
    assert_eq!(requests(&asked).len(), 1);
    let _ = std::fs::remove_file(&asked);
}

#[tokio::test]
async fn summaries_turned_off_ask_no_model_but_keep_the_agents_own_wrap_up() {
    let asked = asked_path("off");
    let hub = hub(&asked, Some(false));
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.prompt(&session, "Plan a three-dish picnic menu").await;
    assert!(client.summarized(Duration::from_secs(3)).await.is_none(), "summarized while off");
    assert!(requests(&asked).is_empty(), "the summary command ran while off");

    let args = json!({"recap": "Menu planned."});
    client.prompt(&session, &format!("wrap-up: {args}")).await;
    client.summarized(Duration::from_secs(15)).await.expect("the wrap-up's recap was dropped");
    assert_eq!(
        strip_at(client.rolling(&session).await),
        json!({"text": "Menu planned.", "source": "wrap_up", "turn": 2})
    );
    assert!(requests(&asked).is_empty());
    let _ = std::fs::remove_file(&asked);
}

/// The summary without its time (`at`, Unix ms), which each test checks is there.
fn strip_at(mut summary: Value) -> Value {
    if let Some(o) = summary.as_object_mut() {
        let at = o.remove("at");
        assert!(at.as_ref().and_then(Value::as_u64).is_some_and(|ms| ms > 0), "no time: {at:?}");
    }
    summary
}
