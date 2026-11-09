use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Begin, Ended, Outcome, Port, last_turn, newest_prompt, run_turn};

const CHAT: &str = "0d4f9a52-8c1e-4b7a-9f3e-2a6b5c7d8e9f";

fn item(id: u64, role: &str, text: &str) -> Value {
    json!({"id": id, "role": role, "text": text})
}

fn end(id: u64, status: &str) -> Value {
    json!({"id": id, "role": "turn_end", "text": "", "status": status})
}

/// A fake app and acpmux: each wait answers the next of `waits` (None: the slice ran out), each
/// read the next of `reads`, and the clock moves by what a wait or a pause took.
struct Fake {
    begun: Vec<Begin>,
    receipt: Value,
    last_seq: u64,
    waits: VecDeque<Option<Value>>,
    reads: VecDeque<Vec<Value>>,
    turn_start: u64,
    read_after: Vec<u64>,
    slices: Vec<Duration>,
    clock: Instant,
}

impl Fake {
    fn new(receipt: Value) -> Self {
        Self {
            begun: Vec::new(),
            receipt,
            last_seq: 0,
            waits: VecDeque::new(),
            reads: VecDeque::new(),
            turn_start: 0,
            read_after: Vec::new(),
            slices: Vec::new(),
            clock: Instant::now(),
        }
    }
}

impl Port for Fake {
    fn begin(&mut self, begin: &Begin) -> Result<Value, Value> {
        self.begun.push(begin.clone());
        Ok(self.receipt.clone())
    }

    fn last_seq(&mut self, _target: &str) -> Result<(String, u64), Value> {
        Ok((CHAT.to_owned(), self.last_seq))
    }

    fn wait_idle(&mut self, chat: &str, slice: Duration) -> Result<Option<Value>, Value> {
        assert_eq!(chat, CHAT);
        self.slices.push(slice);
        let next = self.waits.pop_front().unwrap_or(None);
        if next.is_none() {
            self.clock += slice;
        }
        Ok(next)
    }

    fn turn_start(&mut self, _chat: &str) -> Result<u64, Value> {
        Ok(self.turn_start)
    }

    fn read(&mut self, _chat: &str, after: u64) -> Result<Vec<Value>, Value> {
        self.read_after.push(after);
        Ok(self.reads.pop_front().unwrap_or_default())
    }

    fn pause(&mut self, duration: Duration) {
        self.clock += duration;
    }

    fn now(&mut self) -> Instant {
        self.clock
    }
}

fn new_receipt() -> Value {
    json!({"schema_version": 1, "action": "chat.new", "result": {
        "chat": CHAT, "name": "summarize", "harness": "claude", "opened": true,
        "tab": "tab_7", "pane": "pane_3", "workspace": "ws_2",
        "prompt": {"state": "accepted", "prompt_id": "p1"},
    }})
}

fn idle() -> Option<Value> {
    Some(json!({"target": CHAT, "chat": CHAT, "state": "idle"}))
}

fn answer(outcome: &Outcome) -> &Value {
    match outcome {
        Outcome::Done(answer) => answer,
        Outcome::Failed { error, .. } => panic!("failed: {error}"),
    }
}

fn error(outcome: &Outcome) -> (&str, i32) {
    match outcome {
        Outcome::Failed { error, exit } => (error["code"].as_str().unwrap_or_default(), *exit),
        Outcome::Done(answer) => panic!("done: {answer}"),
    }
}

/// `cmux chat --prompt X --wait --json` here: one command answers the reply and the ids, the shape
/// `cmux chat --on vm:new --wait --json` answers (session_id, workspace_id, tab_id, reply).
#[test]
fn a_new_chat_here_answers_its_reply_and_ids_in_one_run() {
    let mut fake = Fake::new(new_receipt());
    // Two slices run out (a turn longer than an MCP call may wait), then the chat is idle.
    fake.waits = VecDeque::from([None, None, idle()]);
    fake.turn_start = 1;
    fake.reads = VecDeque::from([vec![
        item(1, "user", "Summarize README.md"),
        item(2, "assistant", "Let me read it."),
        json!({"id": 3, "role": "tool", "text": "", "tool": {"kind": "read", "status": "completed"}}),
        item(4, "assistant", "README.md describes cmux."),
        end(5, "completed"),
    ]]);
    let begin = Begin::New(vec!["--".into(), "Summarize README.md".into()]);
    let outcome = run_turn(&mut fake, &begin, Duration::from_secs(900));
    let answer = answer(&outcome);
    assert_eq!(answer["session_id"], CHAT);
    assert_eq!(answer["workspace_id"], "ws_2");
    assert_eq!(answer["tab_id"], "tab_7");
    assert_eq!(answer["placement"], "here");
    assert_eq!(answer["sent"], true);
    assert_eq!(answer["reply"], "README.md describes cmux.", "the turn's last answer");
    assert_eq!(answer["turn"], json!({"seq": 5, "status": "completed"}));
    assert_eq!(answer["follow_up"]["send"], format!("cmux chat send {CHAT} 'PROMPT' --wait"));
    assert_eq!(answer.get("timed_out"), None);
    assert_eq!(fake.begun, vec![begin]);
    // Each slice is at most the MCP cap, however long --timeout is.
    assert!(
        fake.slices.iter().all(|slice| *slice <= Duration::from_secs(120)),
        "{:?}",
        fake.slices
    );
    // The read starts at the turn's prompt, never at the chat's first event.
    assert_eq!(fake.read_after, vec![0]);
}

#[test]
fn the_deadline_answers_timed_out_with_exit_3_as_cloud_does() {
    let mut fake = Fake::new(new_receipt());
    let outcome = run_turn(&mut fake, &Begin::New(vec!["go".into()]), Duration::from_secs(300));
    assert_eq!(error(&outcome), ("chat.wait_timeout", 3));
    let Outcome::Failed { error, .. } = &outcome else { unreachable!() };
    assert_eq!(error["details"]["answer"]["timed_out"], true);
    assert_eq!(error["details"]["answer"]["session_id"], CHAT);
    assert_eq!(error["details"]["answer"]["tab_id"], "tab_7");
    // 300 s in slices of at most 120 s, the last one only what was left.
    let slices: Vec<u64> = fake.slices.iter().map(Duration::as_secs).collect();
    assert_eq!(slices, vec![120, 120, 60]);
}

#[test]
fn a_send_waits_for_the_turn_after_it_not_the_one_before() {
    let receipt = json!({"action": "chat.send", "result": {"chat": CHAT, "message_id": "m9",
                                                          "state": "delivered"}});
    let mut fake = Fake::new(receipt);
    fake.last_seq = 40;
    // Idle at once (the daemon has not handed the prompt over yet): the newest turn is the old
    // one, so it waits on; then the new turn ends.
    fake.waits = VecDeque::from([idle(), idle()]);
    fake.turn_start = 30;
    fake.reads = VecDeque::from([
        vec![item(30, "user", "old"), item(31, "assistant", "old reply"), end(32, "completed")],
        vec![item(41, "user", "next"), item(42, "assistant", "new reply"), end(43, "completed")],
    ]);
    let begin = Begin::Send { session: CHAT.into(), text: "next".into() };
    let outcome = run_turn(&mut fake, &begin, Duration::from_secs(60));
    let answer = answer(&outcome);
    assert_eq!(answer["reply"], "new reply");
    assert_eq!(answer["message_id"], "m9");
    assert_eq!(answer["sent"], true);
}

/// The send's prompt is still held by the daemon while the turn before it ends after the send:
/// that turn's reply is not the send's (review of this change).
#[test]
fn a_send_never_answers_with_a_turn_that_ended_after_it_but_began_before() {
    let receipt = json!({"action": "chat.send", "result": {"chat": CHAT, "message_id": "m9",
                                                          "state": "queued"}});
    let mut fake = Fake::new(receipt);
    fake.last_seq = 40;
    fake.waits = VecDeque::from([idle(), idle()]);
    fake.turn_start = 30;
    fake.reads = VecDeque::from([
        vec![item(30, "user", "old"), item(35, "assistant", "old reply"), end(44, "completed")],
        vec![item(45, "user", "next"), item(46, "assistant", "new reply"), end(47, "completed")],
    ]);
    let begin = Begin::Send { session: CHAT.into(), text: "next".into() };
    let outcome = run_turn(&mut fake, &begin, Duration::from_secs(60));
    assert_eq!(answer(&outcome)["reply"], "new reply");
}

#[test]
fn a_permission_a_failed_turn_and_a_closed_chat_exit_as_cloud_does() {
    let blocked = Some(json!({"target": CHAT, "chat": CHAT, "state": "blocked"}));
    let mut fake = Fake::new(new_receipt());
    fake.waits = VecDeque::from([blocked]);
    let outcome = run_turn(&mut fake, &Begin::New(vec!["go".into()]), Duration::from_secs(60));
    assert_eq!(error(&outcome), ("chat.permission_waiting", 2));

    let mut fake = Fake::new(new_receipt());
    fake.waits = VecDeque::from([idle()]);
    fake.reads = VecDeque::from([vec![item(1, "user", "go"), end(2, "cancelled")]]);
    let outcome = run_turn(&mut fake, &Begin::New(vec!["go".into()]), Duration::from_secs(60));
    assert_eq!(error(&outcome), ("chat.turn_failed", 1));

    let mut fake = Fake::new(new_receipt());
    fake.waits = VecDeque::from([Some(json!({"target": CHAT, "chat": CHAT, "state": "closed"}))]);
    let outcome = run_turn(&mut fake, &Begin::New(vec!["go".into()]), Duration::from_secs(60));
    assert_eq!(error(&outcome), ("chat.lost", 1));
}

#[test]
fn a_rejected_first_prompt_or_no_prompt_does_not_wait() {
    let mut rejected = new_receipt();
    rejected["result"]["prompt"]["state"] = json!("failed");
    let mut fake = Fake::new(rejected);
    let outcome = run_turn(&mut fake, &Begin::New(vec!["go".into()]), Duration::from_secs(60));
    assert_eq!(error(&outcome), ("chat.send_failed", 1));
    assert!(fake.slices.is_empty());

    let mut started = new_receipt();
    started["result"].as_object_mut().unwrap().remove("prompt");
    let mut fake = Fake::new(started);
    let outcome = run_turn(&mut fake, &Begin::New(Vec::new()), Duration::from_secs(60));
    assert_eq!(answer(&outcome)["sent"], false);
    assert!(fake.slices.is_empty());
}

#[test]
fn chat_wait_prints_the_last_turns_reply_without_sending() {
    let mut fake = Fake::new(Value::Null);
    fake.waits = VecDeque::from([idle()]);
    fake.turn_start = 7;
    fake.reads = VecDeque::from([vec![
        item(7, "user", "go"),
        item(8, "assistant", "done"),
        end(9, "completed"),
    ]]);
    let outcome =
        run_turn(&mut fake, &Begin::Wait { session: CHAT.into() }, Duration::from_secs(60));
    assert_eq!(answer(&outcome)["reply"], "done");
    assert!(fake.begun.is_empty(), "chat wait sends nothing");
    assert_eq!(fake.read_after, vec![6]);

    // A chat that never ran a turn: nothing to wait for.
    let mut fake = Fake::new(Value::Null);
    fake.waits = VecDeque::from([idle()]);
    let outcome =
        run_turn(&mut fake, &Begin::Wait { session: CHAT.into() }, Duration::from_secs(60));
    assert_eq!(answer(&outcome)["reply"], Value::Null);
}

#[test]
fn the_reply_is_the_last_answer_of_the_last_turn() {
    let items = [
        item(1, "user", "first"),
        item(2, "assistant", "one"),
        end(3, "completed"),
        item(4, "user", "second"),
        item(5, "assistant", "two"),
        json!({"id": 6, "role": "user", "text": "also this", "steer": true}),
        item(7, "assistant", "two, steered"),
        end(8, "completed"),
    ];
    assert_eq!(
        last_turn(&items, 0),
        Some(Ended { seq: 8, status: "completed".into(), reply: Some("two, steered".into()) })
    );
    // A turn that ended at or before the baseline is not the one waited on, and neither is one
    // whose prompt came before it (the prompt sent was still held when that turn ended).
    assert_eq!(last_turn(&items, 8), None);
    assert_eq!(last_turn(&items, 5).map(|ended| ended.seq), Some(8), "the send steered (6)");
    assert_eq!(last_turn(&items, 6), None, "its prompt (4) and steer (6) came before the send");
    assert_eq!(last_turn(&items, 3).map(|ended| ended.seq), Some(8));
    // A turn with no answer (only tools) has no reply.
    let silent = [item(1, "user", "go"), end(2, "completed")];
    assert_eq!(last_turn(&silent, 0).and_then(|ended| ended.reply), None);
    assert_eq!(last_turn(&[item(1, "user", "go")], 0), None, "still running");
}

#[test]
fn the_newest_prompt_is_found_in_a_page_read_back() {
    let events = [
        json!({"seq": 12, "dir": "in", "kind": "session/update"}),
        json!({"seq": 11, "dir": "mux", "kind": "user_message"}),
        json!({"seq": 10, "dir": "mux", "kind": "turn_result"}),
        json!({"seq": 4, "dir": "mux", "kind": "user_message"}),
    ];
    assert_eq!(newest_prompt(&events), Some(11));
    let steered = [
        json!({"seq": 14, "dir": "mux", "kind": "user_message", "msg": {"steer": true}}),
        json!({"seq": 11, "dir": "mux", "kind": "user_message"}),
    ];
    assert_eq!(newest_prompt(&steered), Some(11), "a steer is inside the turn at 11");
    assert_eq!(newest_prompt(&events[..1]), None);
}

/// Review of this change (F1): a send that steers into a running turn reads that turn from its
/// prompt, before the send, and answers with its reply.
#[test]
fn a_send_steered_into_a_running_turn_answers_with_that_turns_reply() {
    let receipt = json!({"action": "chat.send", "result": {"chat": CHAT, "message_id": "m9",
                                                          "state": "delivered"}});
    let mut fake = Fake::new(receipt);
    fake.last_seq = 40;
    fake.waits = VecDeque::from([idle()]);
    fake.turn_start = 30;
    fake.reads = VecDeque::from([vec![
        item(30, "user", "old"),
        json!({"id": 41, "role": "user", "text": "next", "steer": true}),
        item(42, "assistant", "steered reply"),
        end(43, "completed"),
    ]]);
    let begin = Begin::Send { session: CHAT.into(), text: "next".into() };
    let outcome = run_turn(&mut fake, &begin, Duration::from_secs(60));
    assert_eq!(answer(&outcome)["reply"], "steered reply");
    assert_eq!(fake.read_after, vec![29]);
}

/// Review of this change (F2): a send held for approval starts no turn, so it answers at once as
/// a permission wait, not a timeout.
#[test]
fn a_send_held_for_approval_answers_permission_waiting_at_once() {
    let receipt = json!({"action": "chat.send", "result": {"chat": CHAT, "message_id": "m9",
                                                          "state": "held"}});
    let mut fake = Fake::new(receipt);
    let begin = Begin::Send { session: CHAT.into(), text: "next".into() };
    let outcome = run_turn(&mut fake, &begin, Duration::from_secs(60));
    assert_eq!(error(&outcome), ("chat.permission_waiting", 2));
    assert!(fake.slices.is_empty(), "it does not wait");
}
