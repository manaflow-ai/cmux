//! A session started from inside another session is linked to it and carries the tag
//! `lane.reportsTo` naming it; a run tied to its connection, a session the person starts, or one
//! started under a closed parent carries none. A lane reports each turn to the session that
//! started it (`hub/lane_reports.rs`): its name,
//! the start of its last reply, the pull requests and commits it names and its state. One a
//! turn, the same report not twice, and a parent's turn on reports never reports upward.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
#[path = "lane_reports/detach.rs"]
mod detach;
#[path = "lane_reports/reads.rs"]
mod reads;
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
const TAG: &str = "lane.reportsTo";
const SHA: &str = "0a558b6332eb640fc859718cfcd55d28d63d3360";

fn flaky_mark() -> String {
    std::env::temp_dir()
        .join(format!("lane-report-flaky-{}", std::process::id()))
        .display()
        .to_string()
}

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            // Steers as Claude Code does: a prompt during a turn is read into it.
            "steer": {"argv": ["python3", FAKE], "family": "fake", "env": {"FAKE_CLAUDE_STEER": "1"}},
            // A turn on a lane report runs until it is cancelled.
            "slow": {"argv": ["python3", FAKE], "family": "fake", "env": {"FAKE_UNTIL_CANCEL_IN": " · turn "}},
            "steer-slow": {"argv": ["python3", FAKE], "family": "fake",
                           "env": {"FAKE_CLAUDE_STEER": "1", "FAKE_UNTIL_CANCEL_IN": " · turn "}},
            // Starts no more once the file `FLAKY_MARK` names exists. Each variant is of the
            // starter's family, so a lane started from a `fake` parent inherits its mode.
            "flaky": {"argv": ["sh", "-c", "[ -e \"$FLAKY_MARK\" ] && exit 1; exec python3 \"$0\"", FAKE], "family": "fake",
                      "env": {"FLAKY_MARK": flaky_mark()}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        Self::with_origin(hub, Origin::Local)
    }

    fn with_origin(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
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
        self.call_with_notifications(m, params).await.0
    }

    async fn call_with_notifications(&mut self, m: &str, params: Value) -> (Value, Vec<Value>) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut notes = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no answer in 30 s")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, notes);
            }
            notes.push(v);
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

    async fn message_events(&mut self, id: &str) -> Vec<Value> {
        let page = self.ok("_acpmux/events", json!({"sessionId": id, "limit": 5000})).await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["kind"] == "_acpmux/message")
            .map(|e| e["msg"].clone())
            .collect()
    }

    /// Waits until session `id` has at least `n` reports.
    async fn until(&mut self, id: &str, n: usize) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let got = self.reports(id).await;
            if got.len() >= n {
                return got;
            }
            assert!(Instant::now() < deadline, "{} of {n} reports in 20 s: {got:#?}", got.len());
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
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

/// The tag `lane.reportsTo` of session `id`, if any.
fn tag(hub: &Arc<Hub>, id: &str) -> Option<String> {
    let s = hub.resolve(id).unwrap();
    hub.session_summary(&s)["tags"].get(TAG).and_then(Value::as_str).map(str::to_owned)
}

#[tokio::test]
async fn lane_link_a_session_started_from_a_session_is_linked_to_it() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-a", json!({})).await;
    assert_eq!(tag(&hub, &lane).as_deref(), Some(coord.as_str()));
    // One the person starts is no lane.
    assert_eq!(tag(&hub, &coord), None);
}

#[tokio::test]
async fn lane_link_an_ephemeral_run_is_no_lane() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    // The run's own connection stays open: closing it purges the run.
    let mut owner = Client::as_session(&hub, &coord).await;
    let probe = owner.new_session("probe", json!({"ephemeral": true})).await;
    assert_eq!(tag(&hub, &probe), None);
}

#[tokio::test]
async fn lane_link_a_closed_parent_gets_no_new_lane() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let mut from_coord = Client::as_session(&hub, &coord).await;
    person.ok("session/close", json!({"sessionId": coord})).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let r = from_coord
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "late"}}}),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().expect("session/new");
    assert_eq!(tag(&hub, id), None);
}

#[tokio::test]
async fn lane_link_a_purged_callers_connection_never_links_to_a_session_named_its_id() {
    let hub = hub();
    let mut person = Client::new(&hub);
    // A connection proven as session A stays open while A is purged; another session then takes
    // A's id as its name.
    let gone = person.new_session("a", json!({})).await;
    let mut from_gone = Client::as_session(&hub, &gone).await;
    person.ok("_acpmux/kill", json!({"sessionId": gone, "purge": true})).await;
    let impostor = person.new_session(&gone, json!({})).await;
    let r = from_gone
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "lane-g"}}}),
        )
        .await;
    let lane = r["result"]["sessionId"].as_str().expect("session/new");
    assert_eq!(tag(&hub, lane), None, "linked to {impostor}");
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
    assert!(t.starts_with("[lane-a] echo: Opened "), "{t}");
    assert!(t.lines().next().unwrap().ends_with(" · turn 1, idle"), "{t}");
    assert!(!t.contains("Session:"), "details are not visible text: {t}");
    assert!(t.contains(&format!("echo: Opened {PR}, merged as {SHA}.")), "{t}");
    assert!(t.contains(&format!("Pull requests: {PR}")), "{t}");
    assert!(!t.contains("Commits named:") && !t.contains("acpmux sends this"), "{t}");
    let p = &report["_meta"]["provenance"];
    assert_eq!(p["kind"], "lane_report", "{report}");
    assert_eq!(p["from"], json!(lane), "{report}");
    assert_eq!(p["to"], json!(coord), "{report}");
    assert_eq!(p["turn"], 1, "{report}");
    assert_eq!(p["state"], "idle", "{report}");
    assert_eq!(p["details"], json!({"session": lane, "commits": [SHA]}));
    assert!(report["promptId"].as_str().unwrap().starts_with("lane-report-"), "{report}");

    let incoming: Vec<_> = person
        .message_events(&coord)
        .await
        .into_iter()
        .filter(|event| event["messageId"] == report["promptId"])
        .collect();
    assert_eq!(incoming.len(), 1, "{incoming:#?}");
    assert_eq!(incoming[0]["sessionId"], coord);
    assert_eq!(incoming[0]["sender"]["sessionId"], lane);
    assert_eq!(incoming[0]["messageId"], report["promptId"]);
    assert!(incoming[0]["text"].as_str().unwrap().contains(" · turn 1, idle"));
    let outgoing: Vec<_> = person
        .message_events(&lane)
        .await
        .into_iter()
        .filter(|event| event["messageId"] == report["promptId"])
        .collect();
    assert_eq!(outgoing.len(), 1, "{outgoing:#?}");
    assert_eq!(outgoing[0]["sessionId"], lane);
    assert_eq!(outgoing[0]["sender"]["sessionId"], lane);
    assert_eq!(incoming[0]["sender"]["name"], "lane-a");
    assert_eq!(incoming[0]["text"], report["text"]);
    assert!(incoming[0]["at"].as_u64().is_some_and(|at| at > 0));
    assert_eq!(incoming[0]["sender"], outgoing[0]["sender"]);
    assert_eq!(incoming[0]["text"], outgoing[0]["text"]);
    assert_eq!(incoming[0]["at"], outgoing[0]["at"]);

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
    assert!(t.starts_with("[lane-a] echo: Still on "), "{t}");
    assert!(t.lines().next().unwrap().ends_with(" · turn 3, idle"), "{t}");
    assert!(!t.contains("Pull requests:"), "{t}");
}

#[tokio::test]
async fn session_message_without_prompt_id_records_both_journal_copies() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({"policy": "ask"})).await;
    let lane = person.new_session("lane", json!({})).await;
    let mut from_lane = Client::as_session(&hub, &lane).await;

    let reply = from_lane
        .ok("session/prompt", json!({"sessionId": coord, "prompt": [{"type": "text", "text": "message without a client id"}]}))
        .await;

    let incoming = person.message_events(&coord).await;
    assert_eq!(incoming.len(), 1, "{incoming:#?}");
    assert_eq!(incoming[0]["sender"]["sessionId"], lane);
    assert!(!incoming[0]["messageId"].as_str().unwrap().is_empty());
    assert_eq!(incoming[0]["messageId"], reply["_meta"]["acpmux"]["promptId"]);
    let outgoing = person.message_events(&lane).await;
    assert_eq!(outgoing.len(), 1, "{outgoing:#?}");
    assert_eq!(outgoing[0]["sender"]["sessionId"], lane);
    assert_eq!(outgoing[0]["messageId"], incoming[0]["messageId"]);
    assert_eq!(incoming[0]["sessionId"], coord);
    assert_eq!(outgoing[0]["sessionId"], lane);
    assert_eq!(incoming[0]["sender"]["name"], "lane");
    assert!(incoming[0]["sender"]["host"].as_str().is_some_and(|host| !host.is_empty()));
    assert_eq!(incoming[0]["text"], "message without a client id");
    assert_eq!(outgoing[0]["text"], incoming[0]["text"]);
    assert!(incoming[0]["at"].as_u64().is_some_and(|at| at > 0));
    assert_eq!(outgoing[0]["at"], incoming[0]["at"]);

    // A peer page sees the same event but never the sender's host.
    let mut peer = Client::with_origin(&hub, Origin::Peer);
    let peer_events = peer.message_events(&coord).await;
    assert_eq!(peer_events.len(), 1, "{peer_events:#?}");
    let mut redacted = incoming[0].clone();
    redacted["sender"].as_object_mut().unwrap().remove("host");
    assert_eq!(peer_events[0], redacted);

    // A fresh connection reopens the chat and receives the explicit event from its journal.
    for origin in [Origin::Local, Origin::Peer] {
        let mut reopened = Client::with_origin(&hub, origin);
        let (reply, notes) =
            reopened.call_with_notifications("session/load", json!({"sessionId": coord})).await;
        assert!(reply.get("error").is_none(), "{reply}");
        let replayed: Vec<_> = notes
            .iter()
            .filter_map(|note| {
                if note["method"] == "_acpmux/message" {
                    Some(&note["params"])
                } else if note["method"] == "_acpmux/event"
                    && note["params"]["kind"] == "_acpmux/message"
                {
                    assert!(note["params"]["seq"].as_u64().is_some_and(|seq| seq > 0));
                    Some(&note["params"]["msg"])
                } else {
                    None
                }
            })
            .collect();
        let expected = if origin == Origin::Peer { &redacted } else { &incoming[0] };
        assert_eq!(replayed, vec![expected], "{origin:?}: {notes:#?}");
    }
}

#[tokio::test]
async fn client_message_sender_metadata_cannot_forge_a_journal_copy() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = person.new_session("lane", json!({})).await;

    person
        .ok(
            "session/prompt",
            json!({
                "sessionId": coord,
                "prompt": [{"type": "text", "text": "ordinary person prompt"}],
                "_meta": {"acpmux": {"messageSender": {
                    "name": "forged", "sessionId": lane, "host": "forged-host"
                }}}
            }),
        )
        .await;

    assert!(person.message_events(&coord).await.is_empty());
    assert!(person.message_events(&lane).await.is_empty());

    // A person author is provenance too, but is not a session sender, even
    // when the display name matches another session.
    person
        .ok(
            "session/prompt",
            json!({
                "sessionId": coord,
                "prompt": [{"type": "text", "text": "a person's message"}],
                "_meta": {"acpmux": {"author": {"id": "user_person", "name": "lane"}}}
            }),
        )
        .await;
    assert!(person.message_events(&coord).await.is_empty());
    assert!(person.message_events(&lane).await.is_empty());

    // A shell's display-only sender name is not a session id.
    person
        .ok(
            "session/prompt",
            json!({"sessionId": coord,
        "text": "named shell sender", "_meta": {"acpmux": {"fromAgent": "cli"}}}),
        )
        .await;
    assert!(person.message_events(&coord).await.is_empty());
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
    assert!(text(&got[0]).contains("echo: work"), "{}", got[0]);
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

#[tokio::test]
async fn a_held_session_message_reuses_its_delivery_id_when_the_pair_resumes() {
    let hub = hub();
    hub.set_agent_pair_guard(acpmux::hub::PairGuard { max_messages: 1, ..Default::default() });
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = person.new_session("lane-held", json!({})).await;
    let target = hub.resolve(&coord).unwrap();
    let provenance = |text: &str| {
        json!({
            "kind": "session_message",
            "from": lane.clone(),
            "fromName": "lane-held",
            "to": coord.clone(),
            "text": text,
        })
    };

    hub.prompt_with(
        &target,
        vec![json!({"type": "text", "text": "first"})],
        "acpmux",
        false,
        acpmux::hub::PromptOptions {
            prompt_id: Some("prompt-first".into()),
            message_id: Some("delivery-first".into()),
            provenance: Some(provenance("first")),
            ..Default::default()
        },
    )
    .await
    .expect("first exchange accepted");
    let held = hub
        .prompt_with(
            &target,
            vec![json!({"type": "text", "text": "held"})],
            "acpmux",
            false,
            acpmux::hub::PromptOptions {
                prompt_id: Some("prompt-held".into()),
                message_id: Some("delivery-held".into()),
                provenance: Some(provenance("held")),
                ..Default::default()
            },
        )
        .await
        .expect_err("second exchange is held");
    assert_eq!(held.data.as_ref().and_then(|d| d.get("held")), Some(&json!(true)));

    let mut events = hub.subscribe();
    let resumed = hub.agent_pair_resume(&coord, None);
    assert_eq!(resumed["delivered"], 1, "{resumed}");
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = events.recv().await.expect("message event");
            if event.session_id == lane
                && event.record.kind == "_acpmux/message"
                && event.record.msg["messageId"] == "delivery-held"
            {
                break;
            }
        }
    })
    .await
    .expect("held message recorded in sender journal");

    let incoming = person.message_events(&coord).await;
    let outgoing = person.message_events(&lane).await;
    let incoming: Vec<_> = incoming.iter().filter(|e| e["text"] == "held").collect();
    let outgoing: Vec<_> = outgoing.iter().filter(|e| e["text"] == "held").collect();
    assert_eq!(incoming.len(), 1, "{incoming:#?}");
    assert_eq!(outgoing.len(), 1, "{outgoing:#?}");
    assert_eq!(incoming[0]["messageId"], "delivery-held");
    assert_eq!(outgoing[0]["messageId"], "delivery-held");
}

#[tokio::test]
async fn lane_report_a_lane_whose_tag_is_changed_still_reports_to_the_session_that_started_it() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let other = person.new_session("other", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-t", json!({})).await;
    // Any local client can set or remove a tag: the tag shows the link, it does not make it.
    person.ok("_acpmux/tag", json!({"sessionId": lane, "remove": ["lane.reportsTo"]})).await;
    Client::as_session(&hub, &coord).await.prompt(&lane, "first").await;
    person.exactly(&coord, 1).await;
    person.ok("_acpmux/tag", json!({"sessionId": lane, "set": {"lane.reportsTo": other}})).await;
    Client::as_session(&hub, &coord).await.prompt(&lane, "second").await;
    person.exactly(&coord, 2).await;
    assert!(person.reports(&other).await.is_empty());
}

#[tokio::test]
async fn lane_report_a_turn_whose_agent_cannot_start_reports_the_lane_blocked() {
    let hub = hub();
    let mark = flaky_mark();
    let _ = std::fs::remove_file(&mark);
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord)
        .await
        .new_session("lane-x", json!({"harness": "flaky"}))
        .await;
    // The agent answers, then exits; it cannot start again.
    Client::as_session(&hub, &coord).await.prompt(&lane, "answer-then-exit").await;
    person.exactly(&coord, 1).await;
    std::fs::write(&mark, "").unwrap();
    Client::as_session(&hub, &coord)
        .await
        .send(
            "session/prompt",
            json!({"sessionId": lane, "prompt": [{"type": "text", "text": "next task"}]}),
        )
        .await;
    let got = person.exactly(&coord, 2).await;
    let _ = std::fs::remove_file(&mark);
    let t = text(&got[1]);
    assert!(t.starts_with("[lane-x] (no reply) · turn 2, blocked"), "{}", got[1]);
    // The turn that never started has no reply: turn 1's is not passed off as its.
    assert!(text(&got[0]).contains("answered"), "{}", got[0]);
    assert!(t.contains("(no reply)"), "{t}");
    assert!(!t.contains("answered") && !t.contains("Commits named"), "{t}");
}

#[tokio::test]
async fn lane_report_a_coordinators_report_turn_with_a_task_queued_behind_it_reports_nothing_upward()
 {
    let hub = hub();
    let mut person = Client::new(&hub);
    let top = person.new_session("top", json!({})).await;
    let coord =
        Client::as_session(&hub, &top).await.new_session("coord", json!({"harness": "slow"})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-q", json!({})).await;

    // The coordinator's turn on the report runs; the person's task waits behind it and starts the
    // moment that turn ends.
    Client::as_session(&hub, &coord).await.prompt(&lane, "lane task").await;
    person.until(&coord, 1).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    person
        .send(
            "session/prompt",
            json!({"sessionId": coord, "prompt": [{"type": "text", "text": "person task"}]}),
        )
        .await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    person.ok("session/cancel", json!({"sessionId": coord})).await;

    // Top hears the person's task (turn 2), never the turn on the report.
    let got = person.exactly(&top, 1).await;
    assert_eq!(got[0]["_meta"]["provenance"]["turn"], 2, "{got:#?}");
}

#[tokio::test]
async fn lane_report_a_task_steered_into_a_report_turn_is_reported_upward() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let top = person.new_session("top", json!({})).await;
    let coord = Client::as_session(&hub, &top)
        .await
        .new_session("coord", json!({"harness": "steer-slow"}))
        .await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-v", json!({})).await;

    Client::as_session(&hub, &coord).await.prompt(&lane, "lane task").await;
    person.until(&coord, 1).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    // The person's task joins the turn on the report: that turn did real work now.
    person
        .ok(
            "session/prompt",
            json!({"sessionId": coord, "prompt": [{"type": "text", "text": "person task"}],
                   "_meta": {"acpmux": {"steer": true}}}),
        )
        .await;
    person.ok("session/cancel", json!({"sessionId": coord})).await;
    let got = person.exactly(&top, 1).await;
    assert_eq!(got[0]["_meta"]["provenance"]["turn"], 1, "{got:#?}");
}

#[tokio::test]
async fn lane_report_turns_back_to_back_report_each_turn_at_most_once_and_twenty_in_ten_minutes() {
    let hub = hub();
    // The runaway pair guard would pause this pair first: the cap alone is tested here.
    hub.set_agent_pair_guard(acpmux::hub::PairGuard { enabled: false, ..Default::default() });
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-c", json!({})).await;
    let mut from_coord = Client::as_session(&hub, &coord).await;
    for i in 1..=22 {
        from_coord.prompt(&lane, &format!("task {i}")).await;
    }
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let got = person.reports(&coord).await;
    let mut turns: Vec<u64> =
        got.iter().map(|r| r["_meta"]["provenance"]["turn"].as_u64().unwrap()).collect();
    let n = turns.len();
    turns.dedup();
    assert_eq!(turns.len(), n, "a turn reported twice: {got:#?}");
    assert!(n <= 20, "{n} reports in a few seconds: {got:#?}");
    // Waiting on each report in turn reaches the cap: no 21st.
    let more = 21 - n.min(21);
    for i in 0..more {
        from_coord.prompt(&lane, &format!("more {i}")).await;
        person.until(&coord, (n + i + 1).min(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert_eq!(person.reports(&coord).await.len(), 20);
}

#[tokio::test]
async fn lane_report_a_closed_parent_hears_nothing_and_is_not_reopened() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-c", json!({})).await;
    person.ok("session/close", json!({"sessionId": coord})).await;

    person.prompt(&lane, "after the parent closed").await;
    // Before the link was retired on close, this report went in and reopened the parent.
    person.exactly(&coord, 0).await;
}

#[tokio::test]
async fn lane_report_a_turn_that_ends_before_replying_never_reports_the_last_turns_reply() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-r", json!({})).await;
    let mut from_coord = Client::as_session(&hub, &coord).await;
    from_coord.prompt(&lane, "first-reply-marker").await;
    let got = person.exactly(&coord, 1).await;
    assert!(text(&got[0]).contains("first-reply-marker"), "{}", got[0]);
    // Turn 2 ends with an error and no reply of its own.
    let r = from_coord
        .call(
            "session/prompt",
            json!({"sessionId": lane, "prompt": [{"type": "text", "text": "codex-fail"}]}),
        )
        .await;
    assert!(r.get("error").is_some(), "{r}");
    let got = person.exactly(&coord, 2).await;
    let t = text(&got[1]);
    assert!(t.starts_with("[lane-r] (no reply) · turn 2,"), "{t}");
    assert!(!t.contains("first-reply-marker"), "{t}");
    assert!(t.contains("(no reply)"), "{t}");
}

#[tokio::test]
async fn lane_report_surfaces_review_verdict_counts_and_whole_findings_after_prose() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("review-1", json!({})).await;
    let padding = "Background context that is not a finding.\n".repeat(30);
    let reply = format!(
        "I checked it. Review (Astra): BLOCK at {SHA}\n{padding}\n\
         - **P1 — The parent loses the result.** This explains how.\n\
         - P2: A menu never opens. Further context.\n\
         - [P2] The second failure persists. Further context.\n\
         - P3: Improve the test name."
    );
    Client::as_session(&hub, &coord).await.prompt(&lane, &reply).await;
    let got = person.exactly(&coord, 1).await;
    let report = text(&got[0]);
    assert!(
        report.starts_with(&format!(
            "[review-1] BLOCK at {} · 1 P1, 2 P2, 1 P3 · turn 1, idle",
            &SHA[..12]
        )),
        "{report}"
    );
    for finding in
        ["The parent loses the result.", "A menu never opens.", "The second failure persists."]
    {
        assert!(report.contains(finding), "missing whole finding {finding}: {report}");
    }
    assert!(
        !report.contains("This explains how.") && !report.contains("Further context."),
        "findings use their first sentence: {report}"
    );
}

#[tokio::test]
async fn lane_report_ship_without_findings_and_non_review_first_sentence() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("review-2", json!({})).await;
    let mut parent = Client::as_session(&hub, &coord).await;
    parent.prompt(&lane, &format!("Some prose Review (Sol): SHIP at {SHA}\nNone")).await;
    let got = person.exactly(&coord, 1).await;
    assert!(
        text(&got[0]).starts_with(&format!(
            "[review-2] SHIP at {} · no findings · turn 1, idle",
            &SHA[..12]
        ))
    );
    parent.prompt(&lane, "Fixed the missing callback. Tests pass.").await;
    let got = person.exactly(&coord, 2).await;
    assert_eq!(
        text(&got[1]).lines().next(),
        Some("[review-2] echo: Fixed the missing callback. · turn 2, idle")
    );
}
