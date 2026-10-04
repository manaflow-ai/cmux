//! The brain end to end against the fake owners: the wake rule, the turn
//! assembly (view rendered before the new messages are logged), the log of a
//! turn, reply keys, the read cursor, the outbox rules, children, restarts.

mod common;

use std::sync::Arc;

use cmux_chief::acp::SessionSummary;
use cmux_conversation::{Participant, ParticipantKind};
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::ChildStatus;
use serde_json::json;

fn pairs(log: &[(String, String)]) -> Vec<(&str, &str)> {
    log.iter().map(|(k, t)| (k.as_str(), t.as_str())).collect()
}

#[test]
fn a_human_message_runs_one_fresh_turn_and_posts_one_reply() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let agents = h.agents.inner.lock().unwrap();
    assert_eq!(agents.prompts.len(), 1);
    assert_eq!(
        agents.prompts[0][0]["text"], "<chat>\n</chat>",
        "the view of an empty chat"
    );
    assert_eq!(agents.prompts[0][1]["text"], "hello");
    assert_eq!(agents.prompt_ids, vec!["optchat:0"]);
    let spec = &agents.specs[0];
    assert_eq!(spec.name, "optchat-0");
    assert_eq!(spec.cwd, h.dir.path().join("session"));
    assert_eq!(
        (spec.harness.as_str(), spec.policy.as_str()),
        ("claude-sr", "approve-all")
    );
    assert_eq!(
        agents.ended,
        vec!["s1"],
        "the turn session is removed after the turn"
    );
    drop(agents);
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "hello"),
            ("talk", "Checking."),
            ("tool", "Bash {\"command\":\"ls\"}"),
            ("echo", "a.txt"),
            ("talk", "answer 0"),
        ]
    );
    let owner = h.owner.lock().unwrap();
    assert_eq!(
        owner.sends(),
        vec![("turn:optchat:0".to_string(), "answer 0".to_string())]
    );
    assert_eq!(owner.cursors(), vec![1]);
    assert_eq!(owner.typing, vec![true, false]);
    assert_eq!(h.brain.state().logged_seq, 1);
    assert!(h.brain.state().turn.is_none());
    assert!(h.brain.state().outbox.is_empty());
}

#[test]
fn the_view_is_rendered_before_the_new_messages_are_logged_and_later_messages_wait() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "first");
    h.step(); // the worker settled; the brain logs "first" and starts the turn
    h.agents.wait_prompts(1);
    // Messages during a running turn wait for the next one (no steering).
    h.say("user_local", "second");
    h.say("user_local", "third");
    h.agents.release();
    h.agents.release();
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 2);
    let view = prompts[1][0]["text"].as_str().unwrap();
    assert!(view.starts_with("<chat>\n0+1|user: first\n"), "{view}");
    assert!(view.contains("4+1|talk: answer 0\n</chat>"), "{view}");
    assert!(
        !view.contains("second"),
        "the new messages are not in the view"
    );
    assert_eq!(prompts[1][1]["text"], "second\n\nthird");
    let log = h.log();
    assert_eq!(
        pairs(&log[5..7]),
        vec![("user", "second"), ("user", "third")]
    );
    let owner = h.owner.lock().unwrap();
    let keys: Vec<String> = owner.sends().into_iter().map(|(k, _)| k).collect();
    assert_eq!(keys, vec!["turn:optchat:0", "turn:optchat:5"]);
    assert_eq!(owner.cursors(), vec![1, 3]);
}

#[test]
fn the_wake_rule_skips_the_chiefs_own_messages_and_moves_the_cursor() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("agent_mux", "a message of mine");
    h.settle();
    assert!(h.agents.inner.lock().unwrap().prompts.is_empty());
    assert!(h.log().is_empty());
    assert_eq!(h.owner.lock().unwrap().cursors(), vec![1]);
    assert_eq!(h.brain.state().logged_seq, 1);
}

#[test]
fn a_group_message_without_a_mention_does_not_wake() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = summary();
    s.participants.push(Participant {
        id: "user_2".into(),
        kind: ParticipantKind::Human,
        display_name: "Bo".into(),
        agent_class: None,
        acp_session: None,
    });
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(s),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.say("user_local", "hi all");
    h.settle();
    assert!(h.agents.inner.lock().unwrap().prompts.is_empty());
}

#[test]
fn a_restart_catches_up_from_the_cursor_and_logs_each_message_once() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    // A message that arrived while the host was down.
    {
        let mut o = owner.lock().unwrap();
        let seq = o.messages.len() as u64 + 1;
        o.messages.push(message(seq, "user_local", "again"));
    }
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 1);
    assert_eq!(prompts[0][1]["text"], "again");
    let log = h.log();
    assert_eq!(log.iter().filter(|(_, t)| t == "hello").count(), 1);
    assert_eq!(log[5], ("user".to_string(), "again".to_string()));
    let keys: Vec<String> = h
        .owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(k, _)| k)
        .collect();
    assert_eq!(keys, vec!["turn:optchat:0", "turn:optchat:5"]);
}

#[test]
fn a_host_stopped_mid_turn_leaves_the_message_unanswered_and_says_so_once() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "hello");
    h.step();
    h.agents.wait_prompts(1);
    assert!(h.brain.state().turn.is_some());
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle();
    assert!(
        h.agents.inner.lock().unwrap().prompts.is_empty(),
        "the message is not answered again"
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert_eq!(sends[0].0, "turn:optchat:0");
    assert!(sends[0].1.starts_with("(interrupted"));
    assert_eq!(pairs(&h.log()), vec![("user", "hello")]);
}

fn timer(h: &mut Harness) {
    let at = h.brain.next_timer().expect("the outbox timer is armed");
    std::thread::sleep(at.saturating_duration_since(std::time::Instant::now()));
    h.brain.on_timer();
}

#[test]
fn agent_rate_is_retried_once_after_the_gap() {
    let mut h = Harness::new(default_script());
    h.owner.lock().unwrap().rejects = [Some("agent_rate".to_string()), None].into();
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    assert_eq!(h.brain.state().outbox.len(), 1);
    assert!(h.brain.state().outbox[0].rate_retried);
    timer(&mut h);
    assert!(h.brain.state().outbox.is_empty());
    let owner = h.owner.lock().unwrap();
    assert_eq!(owner.sends().len(), 2);
    assert_eq!(
        owner.messages.last().unwrap().author,
        "agent_mux",
        "the retry was committed"
    );
}

#[test]
fn a_second_agent_rate_and_agent_budget_are_dropped() {
    let mut h = Harness::new(default_script());
    h.owner.lock().unwrap().rejects = [
        Some("agent_rate".to_string()),
        Some("agent_rate".to_string()),
    ]
    .into();
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    timer(&mut h);
    assert!(h.brain.state().outbox.is_empty());
    assert_eq!(h.owner.lock().unwrap().sends().len(), 2);

    let mut h = Harness::new(default_script());
    h.owner.lock().unwrap().rejects = [Some("agent_budget".to_string())].into();
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    assert!(h.brain.state().outbox.is_empty());
    assert!(h.brain.next_timer().is_none());
    assert_eq!(h.owner.lock().unwrap().sends().len(), 1);
}

#[test]
fn actor_mismatch_keeps_the_reply_and_reconnects() {
    let mut h = Harness::new(default_script());
    h.owner.lock().unwrap().rejects = [Some("actor_mismatch".to_string())].into();
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    assert_eq!(h.owner.lock().unwrap().reconnects, 1);
    assert_eq!(h.brain.state().outbox.len(), 1, "kept for the next connect");
    h.connect();
    assert!(h.brain.state().outbox.is_empty());
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 2);
    assert!(
        sends.iter().all(|(k, _)| k == "turn:optchat:0"),
        "the same key: the owner dedupes"
    );
}

fn child(id: &str, status: &str, parent: &str, last_seq: u64) -> SessionSummary {
    serde_json::from_value(json!({
        "sessionId": id, "name": "worker", "harness": "claude-sr", "cwd": "/w", "status": status,
        "tags": {"mux.parent": parent}, "lastSeq": last_seq
    }))
    .unwrap()
}

#[test]
fn a_child_report_becomes_one_user_entry_and_a_new_turn() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.agents.set_events(
        "c1",
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "fixed the bug"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ],
    );
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "c1",
        "running",
        "optchat-chief",
        1,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "c1",
        "ready",
        "optchat-chief",
        3,
    ))));
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 1);
    assert_eq!(prompts[0][1]["text"], "[worker] fixed the bug");
    assert_eq!(
        h.log()[0],
        ("user".to_string(), "[worker] fixed the bug".to_string())
    );
    let record = &h.brain.state().children["c1"];
    assert_eq!((record.status, record.floor), (ChildStatus::Reported, 3));
    assert_eq!(h.owner.lock().unwrap().sends()[0].0, "turn:optchat:0");

    // Another parent's session is not a child.
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "c2", "running", "mux", 1,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "c2", "ready", "mux", 3,
    ))));
    assert!(h.brain.is_idle());
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 1);
}

#[test]
fn a_child_that_finished_while_the_host_was_away_reports_on_reconnect() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.brain.step(Input::from(AgentEvent::SessionChanged(child(
        "c1",
        "running",
        "optchat-chief",
        1,
    ))));
    h.agents.set_events(
        "c1",
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "done"}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ],
    );
    h.brain.step(Input::from(AgentEvent::Down));
    h.brain.step(Input::from(AgentEvent::Up(vec![child(
        "c1",
        "idle",
        "optchat-chief",
        3,
    )])));
    h.settle();
    assert_eq!(
        h.agents.inner.lock().unwrap().prompts[0][1]["text"],
        "[worker] done"
    );
}
