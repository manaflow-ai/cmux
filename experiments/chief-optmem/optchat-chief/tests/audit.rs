//! Regressions from audit round 1: each test failed before its fix.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, Mutex};

use cmux_chief::acp::SessionSummary;
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::{ChildStatus, HostState, StateFile};
use optchat_core::Kind;
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

/// The texts the owner committed as the Chief's messages.
fn committed(owner: &Arc<Mutex<Owner>>) -> Vec<String> {
    owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .filter(|m| m.author == "agent_mux")
        .map(|m| match &m.parts[0] {
            cmux_conversation::Part::Text { text, .. } => text.clone(),
            _ => String::new(),
        })
        .collect()
}

#[test]
fn a_second_child_turn_ending_while_its_report_is_queued_is_not_lost() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.say("user_local", "go");
    h.step();
    h.agents.wait_prompts(1);
    // The child ends turn 1 while the Chief is busy: its report waits.
    h.agents.set_events("c1", child_turn("report one"));
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "running", 1,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "ready", 3,
    ))));
    // The Chief prompts it again and it ends turn 2 before the Chief's turn ends.
    let mut both = child_turn("report one");
    both.extend(child_turn("report two"));
    h.agents.set_events("c1", both);
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "running", 4,
    ))));
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "ready", 6,
    ))));
    h.agents.release();
    h.agents.release();
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 2);
    let text = prompts[1].last().unwrap()["text"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(text.contains("[worker] report one"), "{text}");
    assert!(text.contains("[worker] report two"), "{text}");
    let record = &h.brain.state().children["c1"];
    assert_eq!((record.status, record.floor), (ChildStatus::Reported, 6));
}

#[test]
fn replies_after_a_memory_reset_are_not_dropped_as_reused_keys() {
    let mut h = Harness::new(default_script());
    h.owner.lock().unwrap().ledger = Some(Default::default());
    h.connect();
    h.say("user_local", "first question");
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
    // The user resets the Chief's memory (or restores an older backup).
    std::fs::remove_dir_all(dir.path().join("chat")).unwrap();
    std::fs::remove_file(dir.path().join("host.json")).unwrap();
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.say("user_local", "second question");
    h.settle();
    assert_eq!(
        committed(&h.owner).len(),
        2,
        "both replies are posted: {:?}",
        h.owner.lock().unwrap().sends()
    );
}

#[test]
fn a_new_conversation_id_starts_from_its_own_cursor() {
    let dir = tempfile::tempdir().unwrap();
    // The host handled 500 messages of a conversation the owner no longer has.
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some("conv_old".into()),
            logged_seq: 500,
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.say("user_local", "hello again");
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(
        prompts.len(),
        1,
        "the first message of the new conversation wakes"
    );
    assert_eq!(prompts[0].last().unwrap()["text"], "hello again");
    assert_eq!(h.brain.state().logged_seq, 1);
}

#[test]
fn the_view_goes_in_pieces_cut_at_the_cache_marks() {
    let mut h = Harness::new(default_script());
    // ~700 short lines: about 76k characters of view, so one mark (50k).
    for i in 0..700 {
        h.chat
            .append(Kind::Note, &format!("{i:04} {}", "n".repeat(90)))
            .unwrap();
    }
    h.connect();
    h.say("user_local", "what is in my notes?");
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let blocks = &prompts[0];
    assert_eq!(blocks.len(), 3, "two view pieces, then the new message");
    let first = blocks[0]["text"].as_str().unwrap();
    assert!(first.starts_with("<chat>\n") && first.ends_with('\n'));
    assert!(first.chars().count() <= 50_000);
    assert!(blocks[1]["text"].as_str().unwrap().ends_with("</chat>"));
    assert_eq!(blocks[2]["text"], "what is in my notes?");
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

#[test]
fn a_lost_turn_says_so_and_folds_its_orphan_session_later() {
    let mut h = Harness::new(talk_only());
    h.agents.inner.lock().unwrap().lose = true;
    h.connect();
    h.say("user_local", "check the build");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert!(sends[0].1.contains("Let me check."), "{:?}", sends[0]);
    assert!(sends[0].1.contains("connection was lost"), "{:?}", sends[0]);
    assert!(
        h.agents.inner.lock().unwrap().ended.is_empty(),
        "a lost session cannot be ended until acpmux is back"
    );
    // The orphan finished on its own while the connection was down.
    let mut events = talk_only()(0, &[]);
    events.push(update(
        "agent_message_chunk",
        json!({"content": {"type": "text", "text": " The build is green."}}),
    ));
    events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
    h.agents.set_events("s1", events);
    h.brain.step(Input::from(AgentEvent::Down));
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    assert_eq!(h.agents.inner.lock().unwrap().ended, vec!["s1"]);
    let log = h.log();
    assert!(
        log.iter().any(|(_, t)| t.contains("The build is green.")),
        "{log:?}"
    );
}

#[test]
fn a_running_child_whose_session_is_gone_is_reported() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.brain.step(Input::from(AgentEvent::SessionChanged(worker(
        "c1", "running", 1,
    ))));
    h.brain.step(Input::from(AgentEvent::Down));
    h.brain.step(Input::from(AgentEvent::Up(Vec::new())));
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 1);
    let text = prompts[0].last().unwrap()["text"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        text.starts_with("[worker]") && text.contains("gone"),
        "{text}"
    );
}

#[test]
fn the_host_state_is_private_to_the_user() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "my password is hunter2");
    h.settle();
    let mode = std::fs::metadata(h.dir.path().join("host.json"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
}

/// A host that crashed after it saved the pending turn: `logged` says whether
/// the turn's one message reached the log before the crash.
fn crashed_while_logging(logged: bool) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    if logged {
        let chat = open_chat(&dir.path().join("chat"));
        chat.append(Kind::User, "hello").unwrap();
        chat.shutdown();
    }
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            turn: Some(optchat_chief::state::PendingTurn {
                key: String::new(),
                conversation: Some(CONV.into()),
                session: "optchat-0".into(),
                first_id: Some(0),
                seqs: vec![Some(1)],
            }),
            ..Default::default()
        })
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        messages: vec![message(1, "user_local", "hello")],
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.settle();
    h
}

#[test]
fn a_crash_before_the_append_answers_the_message_normally() {
    let h = crashed_while_logging(false);
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 1);
    let log = h.log();
    assert_eq!(log.iter().filter(|(_, t)| t == "hello").count(), 1);
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert!(!sends[0].1.starts_with("(interrupted"), "{sends:?}");
}

#[test]
fn a_crash_after_the_append_never_logs_the_message_twice() {
    let h = crashed_while_logging(true);
    assert!(h.agents.inner.lock().unwrap().prompts.is_empty());
    assert_eq!(h.log(), vec![("user".to_string(), "hello".to_string())]);
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert!(sends[0].1.starts_with("(interrupted"), "{sends:?}");
    // Seq 1 is in the log; seq 2 is the interrupted notice itself (no log).
    assert_eq!(h.brain.state().logged_seq, 2);
}
