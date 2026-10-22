//! A lane reports each turn to the session that started it (`hub/lane_reports.rs`): its name,
//! the start of its last reply, the pull requests and commits it names and its state. One a
//! turn, the same report not twice, and a parent's turn on reports never reports upward.

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
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PR: &str = "https://github.com/manaflow-ai/cmux/pull/23880";
const SHA: &str = "0a558b6332eb640fc859718cfcd55d28d63d3360";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            // Steers as Claude Code does: a prompt during a turn is read into it.
            "steer": {"argv": ["python3", FAKE], "env": {"FAKE_CLAUDE_STEER": "1"}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
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

    /// The connection an agent's tools open from inside session `id`.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no answer in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// Sends a request without waiting for its answer.
    async fn send(&mut self, m: &str, params: Value) {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    async fn new_session(&mut self, name: &str, extra: Value) -> String {
        let mut meta = json!({"name": name});
        meta.as_object_mut().unwrap().extend(extra.as_object().cloned().unwrap_or_default());
        let r = self
            .ok(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await;
        r["sessionId"].as_str().unwrap().to_owned()
    }

    async fn prompt(&mut self, session: &str, text: &str) {
        self.ok(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }

    /// Session `id`'s `user_message` records that are lane reports.
    async fn reports(&mut self, id: &str) -> Vec<Value> {
        let page = self.ok("_acpmux/events", json!({"sessionId": id, "limit": 5000})).await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["kind"] == "user_message")
            .flat_map(|e| {
                let msg = &e["msg"];
                let p = &msg["_meta"]["provenance"];
                match p["kind"].as_str() {
                    Some("lane_report") => vec![msg.clone()],
                    // A turn of agent messages (`digest.rs`): each one it took in.
                    Some("agent_digest") => p["messages"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|m| m["provenance"]["kind"] == "lane_report")
                        .map(|m| json!({"promptId": m["promptId"], "_meta": {"provenance": m["provenance"]}}))
                        .collect(),
                    _ => vec![],
                }
            })
            .collect()
    }

    /// Waits until session `id` has `n` reports, then a moment more to see no other comes.
    async fn exactly(&mut self, id: &str, n: usize) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let got = self.reports(id).await;
            assert!(got.len() <= n, "more than {n} reports: {got:#?}");
            if got.len() == n {
                tokio::time::sleep(Duration::from_millis(700)).await;
                let again = self.reports(id).await;
                assert_eq!(again.len(), n, "{again:#?}");
                return again;
            }
            assert!(Instant::now() < deadline, "{} of {n} reports in 20 s: {got:#?}", got.len());
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}

fn text(report: &Value) -> &str {
    report["text"].as_str().unwrap()
}

#[tokio::test]
async fn lane_report_a_lane_reports_each_turn_once_to_the_session_that_started_it() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    // The coordinator's agent starts a lane from inside its session.
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-a", json!({})).await;
    let mut from_coord = Client::as_session(&hub, &coord).await;

    from_coord.prompt(&lane, &format!("Opened {PR}, merged as {SHA}.")).await;
    let got = person.exactly(&coord, 1).await;
    let report = &got[0];
    let t = text(report);
    assert!(t.starts_with("[lane-a] lane report: turn 1 ended, idle."), "{t}");
    assert!(t.contains(&format!("Session: {lane}")), "{t}");
    assert!(t.contains(&format!("Last message: echo: Opened {PR}, merged as {SHA}.")), "{t}");
    assert!(t.contains(&format!("Pull requests: {PR}")), "{t}");
    assert!(t.contains(&format!("Commits named: {SHA}")), "{t}");
    let p = &report["_meta"]["provenance"];
    assert_eq!(p["kind"], "lane_report", "{report}");
    assert_eq!(p["from"], json!(lane), "{report}");
    assert_eq!(p["to"], json!(coord), "{report}");
    assert_eq!(p["turn"], 1, "{report}");
    assert_eq!(p["state"], "idle", "{report}");
    assert!(report["promptId"].as_str().unwrap().starts_with("lane-report-"), "{report}");

    // The coordinator's turn on the report (its agent echoes it) reports nothing to anyone, and
    // the lane gets nothing back.
    assert!(person.reports(&lane).await.is_empty());

    // The same reply again is the same report: not sent twice.
    from_coord.prompt(&lane, &format!("Opened {PR}, merged as {SHA}.")).await;
    person.exactly(&coord, 1).await;
    // A new reply is a new report; the pull request it named before is not named again.
    from_coord.prompt(&lane, &format!("Still on {PR}, waiting on CI.")).await;
    let got = person.exactly(&coord, 2).await;
    let t = text(&got[1]);
    assert!(t.starts_with("[lane-a] lane report: turn 3 ended, idle."), "{t}");
    assert!(!t.contains("Pull requests:"), "{t}");
}

#[tokio::test]
async fn lane_report_an_ephemeral_run_reports_nothing() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    // The run's own connection stays open: closing it purges the run.
    let mut owner = Client::as_session(&hub, &coord).await;
    let probe = owner.new_session("probe", json!({"ephemeral": true})).await;
    owner.prompt(&probe, "Reply with only: OK").await;
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(person.reports(&coord).await.is_empty());
}

#[tokio::test]
async fn lane_report_a_coordinators_turn_on_its_lanes_reports_reports_nothing_upward() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let top = person.new_session("top", json!({})).await;
    let coord = Client::as_session(&hub, &top).await.new_session("coord", json!({})).await;
    let one = Client::as_session(&hub, &coord).await.new_session("lane-one", json!({})).await;
    let two = Client::as_session(&hub, &coord).await.new_session("lane-two", json!({})).await;

    // The coordinator is busy while both lanes end a turn: their reports wait, then go in as
    // one turn of agent messages.
    let mut busy = Client::new(&hub);
    busy.send(
        "session/prompt",
        json!({"sessionId": coord, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    Client::as_session(&hub, &coord).await.prompt(&one, "first lane task").await;
    Client::as_session(&hub, &coord).await.prompt(&two, "second lane task").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    person.ok("session/cancel", json!({"sessionId": coord})).await;
    person.exactly(&coord, 2).await;

    // Top hears the coordinator's own turn, never the turn it spent on the reports.
    let got = person.exactly(&top, 1).await;
    assert_eq!(got[0]["_meta"]["provenance"]["turn"], 1, "{got:#?}");
}

#[tokio::test]
async fn lane_report_a_prompt_that_takes_a_reports_id_does_not_pass_for_one() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-f", json!({})).await;
    person
        .ok(
            "session/prompt",
            json!({"sessionId": lane, "prompt": [{"type": "text", "text": "work"}],
                   "_meta": {"acpmux": {"promptId": "lane-report-forged"}}}),
        )
        .await;
    let got = person.exactly(&coord, 1).await;
    assert!(text(&got[0]).contains("Last message: echo: work"), "{}", got[0]);
}

#[tokio::test]
async fn lane_report_a_report_waits_for_a_steering_parents_turn_and_reports_nothing_upward() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let top = person.new_session("top", json!({})).await;
    let coord = Client::as_session(&hub, &top)
        .await
        .new_session("coord", json!({"harness": "steer"}))
        .await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-s", json!({})).await;

    let mut busy = Client::new(&hub);
    busy.send(
        "session/prompt",
        json!({"sessionId": coord, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    Client::as_session(&hub, &coord).await.prompt(&lane, "lane task").await;
    // The report waits in the queue: it never steers into the running turn.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(person.reports(&coord).await.is_empty());
    person.ok("session/cancel", json!({"sessionId": coord})).await;
    let got = person.exactly(&coord, 1).await;
    assert!(got[0].get("steer").is_none(), "{got:#?}");

    // Top hears the coordinator's cancelled turn, not the turn it spent on the report.
    let got = person.exactly(&top, 1).await;
    assert_eq!(got[0]["_meta"]["provenance"]["turn"], 1, "{got:#?}");
}

#[tokio::test]
async fn lane_report_a_report_the_pair_guard_holds_goes_in_once_on_resume_as_the_lanes() {
    let hub = hub();
    // The pair trips on its second exchange: the task in, then the report back.
    hub.set_agent_pair_guard(acpmux::hub::PairGuard { max_messages: 1, ..Default::default() });
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-h", json!({})).await;
    Client::as_session(&hub, &coord).await.prompt(&lane, "a task").await;

    // Held, not delivered: the turn counts as reported, and nothing is sent again.
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(person.reports(&coord).await.is_empty());
    let page = person.ok("_acpmux/events", json!({"sessionId": coord, "limit": 5000})).await;
    let held = page["events"].as_array().unwrap().iter().filter(|e| e["kind"] == "agent_pair_held");
    assert_eq!(held.count(), 1, "{page}");

    // The person resumes the pair: the report goes in once, still the lane's.
    hub.agent_pair_resume(&coord, None);
    let got = person.exactly(&coord, 1).await;
    assert_eq!(got[0]["_meta"]["provenance"]["from"], json!(lane), "{got:#?}");
}
