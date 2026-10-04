//! Regressions from audit round 2: each test failed before its fix.

mod common;

use std::collections::BTreeMap;
use std::sync::mpsc::channel;
use std::sync::{Arc, Condvar, Mutex};

use cmux_chief::acp::SessionSummary;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Brain, Input};
use optchat_chief::state::{ChildRecord, ChildStatus, HostState, StateFile};
use optchat_chief::turn::Orphan;
use optchat_core::Kind;
use optchat_host::{CompactModel, CompactRequest, Config, Followup, ModelError, OptChat, Reply};
use serde_json::{Value, json};

fn worker(id: &str, status: &str, last_seq: u64) -> SessionSummary {
    serde_json::from_value(json!({
        "sessionId": id, "name": "worker", "harness": "claude-sr", "cwd": "/w", "status": status,
        "tags": {"mux.parent": optchat_chief::brain::PARENT}, "lastSeq": last_seq
    }))
    .unwrap()
}

fn child_turn(text: &str) -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
    ]
}

fn talk_only() -> Script {
    Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "Let me check."}}),
            ),
        ]
    })
}

/// The last block of every turn prompt: the new messages.
fn new_messages(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|p| p.last().unwrap()["text"].as_str().unwrap().to_owned())
        .collect()
}

/// The conversation owner connects (acpmux is handled by the test).
fn daemon_up(h: &mut Harness) {
    let owner = h.owner.clone();
    let summary = owner.lock().unwrap().summary.clone().unwrap();
    let reconnects = owner.clone();
    h.brain.step(Input::from(optchat_chief::daemon::DaemonEvent::Up {
        port: Box::new(FakeDaemon(owner)),
        conversation: summary,
        reconnect: Box::new(move || reconnects.lock().unwrap().reconnects += 1),
    }));
}

/// A compactor that waits while `hold` is set.
struct Gated {
    hold: Mutex<bool>,
    cv: Condvar,
}

impl CompactModel for Gated {
    fn call(&self, r: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        let mut h = self.hold.lock().unwrap();
        while *h {
            h = self.cv.wait(h).unwrap();
        }
        Ok(Reply::text(format!("summary of {}", r.node.name())))
    }
}

#[test]
fn an_orphan_folded_after_the_settle_does_not_reach_the_view_unsummarized() {
    let gate = Arc::new(Gated {
        hold: Mutex::new(false),
        cv: Condvar::new(),
    });
    let dir = tempfile::tempdir().unwrap();
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            dir.path().join("chat"),
            config,
            gate.clone(),
            Arc::new(optchat_host::SystemClock),
        )
        .unwrap(),
    );
    let agents = FakeAgents::new(talk_only());
    let (tx, rx) = channel();
    let brain = Brain::new(
        chat.clone(),
        agents.clone(),
        settings(dir.path()),
        StateFile::new(&dir.path().join("host.json")),
        tx,
        Arc::new(|_: &str| {}),
    );
    let mut h = Harness {
        dir,
        chat,
        owner: Arc::new(Mutex::new(Owner {
            summary: Some(summary()),
            ..Owner::default()
        })),
        agents,
        brain,
        rx,
    };
    h.agents.inner.lock().unwrap().lose = true;
    h.connect();
    h.say("user_local", "check the build");
    h.settle();
    assert_eq!(h.brain.state().orphans.len(), 1);
    assert!(h.chat.wait_idle(None, Some(WAIT)));
    let mut events = talk_only()(0, &[]);
    events.push(update(
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": format!(" {}", "long words ".repeat(200))}}),
    ));
    events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
    h.agents.set_events("s1", events);
    *gate.hold.lock().unwrap() = true;
    h.say("user_local", "and now?");
    // The worker settled; acpmux reconnects before the brain takes the turn,
    // and the orphan's long reply is folded into the log.
    let settled = h.rx.recv_timeout(WAIT).unwrap();
    assert!(matches!(settled, Input::Settled(_)));
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    h.brain.step(settled);
    *gate.hold.lock().unwrap() = false;
    gate.cv.notify_all();
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 2);
    let view: String = prompts[1][..prompts[1].len() - 1]
        .iter()
        .map(|b| b["text"].as_str().unwrap().to_owned())
        .collect();
    assert!(
        !view.contains("not summarized yet"),
        "the turn saw a placeholder:\n{view}"
    );
}

#[test]
fn a_turn_is_not_taken_while_acpmux_is_down() {
    let mut h = Harness::new(default_script());
    h.connect();
    let m = {
        let mut owner = h.owner.lock().unwrap();
        let m = message(1, "user_local", "hello");
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(optchat_chief::daemon::DaemonEvent::Changed {
        conversation: CONV.into(),
        change: cmux_conversation::Change::Message { message: m },
    }));
    let settled = h.rx.recv_timeout(WAIT).unwrap();
    h.brain.step(Input::from(AgentEvent::Down));
    h.brain.step(settled);
    assert!(
        h.agents.inner.lock().unwrap().prompts.is_empty(),
        "no turn starts while acpmux is down"
    );
    assert!(h.log().is_empty(), "the message waits in the queue, unlogged");
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    h.settle();
    assert_eq!(new_messages(&h), vec!["hello"]);
    assert_eq!(
        h.log().iter().filter(|(_, t)| t == "hello").count(),
        1,
        "{:?}",
        h.log()
    );
}

#[test]
fn a_crash_after_logging_a_child_report_logs_it_once_and_posts_no_notice() {
    let dir = tempfile::tempdir().unwrap();
    {
        let chat = open_chat(&dir.path().join("chat"));
        chat.append(Kind::User, "[worker] report one").unwrap();
        chat.shutdown();
    }
    let mut children = BTreeMap::new();
    children.insert(
        "c1".to_string(),
        ChildRecord {
            name: "worker".into(),
            status: ChildStatus::Running,
            floor: 0,
        },
    );
    let pending: optchat_chief::state::PendingTurn = serde_json::from_value(json!({
        "key": "", "conversation": CONV, "session": "optchat-0",
        "first_id": 0, "seqs": [null],
        "items": [{"child": {"session_id": "c1", "floor": 3}}]
    }))
    .unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            turn: Some(pending),
            children,
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.agents.set_events("c1", child_turn("report one"));
    h.brain
        .step(Input::from(AgentEvent::Up(vec![worker("c1", "idle", 3)])));
    daemon_up(&mut h);
    h.settle();
    let log = h.log();
    let n = log.iter().filter(|(_, t)| t == "[worker] report one").count();
    assert_eq!(n, 1, "{log:?}");
    let sends = h.owner.lock().unwrap().sends();
    assert!(
        sends.iter().all(|(_, t)| !t.starts_with("(interrupted")),
        "no human message was in that turn: {sends:?}"
    );
}

#[test]
fn a_childs_next_turn_is_reported_when_its_end_is_handled_late() {
    let mut h = Harness::new(default_script());
    h.connect();
    // Turn 1 ended at seq 3; turn 2 already started (4, 5) when the brain
    // handles the first end.
    let mut events = child_turn("report one");
    events.extend(child_turn("report two")[..2].iter().cloned());
    h.agents.set_events("c1", events);
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "running", 1,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "ready", 5,
    ))));
    h.settle();
    let mut events = child_turn("report one");
    events.extend(child_turn("report two"));
    h.agents.set_events("c1", events);
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "running", 5,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "ready", 6,
    ))));
    h.settle();
    assert_eq!(
        new_messages(&h),
        vec!["[worker] report one", "[worker] report two"]
    );
}

#[test]
fn a_child_turn_that_fails_reports_its_error() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.agents.set_events(
        "c1",
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "half done"}}),
            ),
            json!({"dir": "mux", "kind": "turn_error", "msg": {"error": "overloaded"}}),
        ],
    );
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "running", 1,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "ready", 3,
    ))));
    h.settle();
    let texts = new_messages(&h);
    assert_eq!(texts.len(), 1);
    assert!(
        texts[0].contains("half done") && texts[0].contains("overloaded"),
        "{texts:?}"
    );
}

#[test]
fn an_orphan_whose_session_is_gone_is_dropped() {
    let dir = tempfile::tempdir().unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            orphans: vec![Orphan {
                session: "s9".into(),
                after: 4,
            }],
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.agents.inner.lock().unwrap().events_error =
        Some("events: no session matches \"s9\"".into());
    h.connect();
    assert!(h.brain.state().orphans.is_empty(), "dropped, not retried at every connect");
}

#[test]
fn a_turn_that_stops_without_text_says_why() {
    let mut h = Harness::new(Box::new(|_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "refusal"}}),
        ]
    }));
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert!(sends[0].1.contains("refusal"), "{sends:?}");
}

#[test]
fn a_prompt_answer_with_another_stop_reason_says_why() {
    let mut h = Harness::new(Box::new(|_, _| {
        vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})]
    }));
    h.agents.inner.lock().unwrap().answer = Some(json!({"stopReason": "max_tokens"}));
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert!(sends[0].1.contains("max_tokens"), "{sends:?}");
}

#[test]
fn a_lost_binding_on_a_cursor_write_reconnects() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.owner
        .lock()
        .unwrap()
        .cursor_rejects
        .push_back(Some("actor_mismatch".into()));
    h.say("agent_mux", "a message of mine");
    assert_eq!(h.owner.lock().unwrap().reconnects, 1);
}
