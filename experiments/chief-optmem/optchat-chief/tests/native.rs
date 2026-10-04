//! The native engine end to end against a fake Messages API: the request
//! layout and breakpoints of section 8, the log of a turn, and messages
//! delivered between tool calls (section 7).

mod common;

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use common::*;
use optchat_chief::brain::Engine;
use optchat_chief::native::{CallError, ChatModel, Native, NativeConfig};
use serde_json::{Value, json};

/// Answers each call with the next scripted message and keeps every body.
/// While `gate` is set, the first call waits.
struct Scripted {
    replies: Mutex<VecDeque<Value>>,
    bodies: Mutex<Vec<Value>>,
    gate: Mutex<bool>,
    opened: Condvar,
}

impl ChatModel for Scripted {
    fn send(&self, body: &Value) -> Result<Value, CallError> {
        {
            let mut gate = self.gate.lock().unwrap();
            while *gate {
                gate = self.opened.wait(gate).unwrap();
            }
        }
        self.bodies.lock().unwrap().push(body.clone());
        self.replies.lock().unwrap().pop_front().ok_or(CallError {
            message: "no reply scripted".into(),
            retry: false,
        })
    }
}

fn scripted(replies: Vec<Value>, gated: bool) -> Arc<Scripted> {
    Arc::new(Scripted {
        replies: Mutex::new(replies.into()),
        bodies: Mutex::new(Vec::new()),
        gate: Mutex::new(gated),
        opened: Condvar::new(),
    })
}

fn native(model: Arc<Scripted>, dir: &std::path::Path) -> Engine {
    let config = NativeConfig {
        model: "claude-opus-5-5".into(),
        effort: Some("high".into()),
        max_tokens: 64_000,
        server_fallback: false,
        system: optchat_chief::prompt::claude_md(None),
        cwd: dir.to_owned(),
        env: BTreeMap::new(),
        bash_timeout: Duration::from_secs(30),
        pwd_file: dir.join(".pwd"),
    };
    Engine::Native(Arc::new(Native::new(
        config,
        model,
        Duration::from_millis(10),
    )))
}

fn tool_step() -> Value {
    json!({
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 900, "output_tokens": 20},
        "content": [
            {"type": "thinking", "thinking": "", "signature": "sig-1"},
            {"type": "text", "text": "Checking."},
            {"type": "tool_use", "id": "t1", "name": "bash", "input": {"command": "echo hi"}}
        ]
    })
}

fn final_step(text: &str) -> Value {
    json!({
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 5, "cache_read_input_tokens": 900, "cache_creation_input_tokens": 40, "output_tokens": 8},
        "content": [{"type": "text", "text": text}]
    })
}

fn pairs(log: &[(String, String)]) -> Vec<(&str, &str)> {
    log.iter().map(|(k, t)| (k.as_str(), t.as_str())).collect()
}

#[test]
fn a_native_turn_logs_its_steps_and_lays_out_the_request_for_the_cache() {
    let model = scripted(vec![tool_step(), final_step("It says hi.")], false);
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.connect();
    h.say("user_local", "what does echo say?");
    h.settle();
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "what does echo say?"),
            ("talk", "Checking."),
            ("tool", "bash {\"command\":\"echo hi\"}"),
            ("echo", "hi\n"),
            ("talk", "It says hi."),
        ]
    );
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert_eq!(sends[0].1, "It says hi.");
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(bodies.len(), 2);
    let first = &bodies[0];
    assert_eq!(first["model"], "claude-opus-5-5");
    assert_eq!(first["stream"], true);
    assert_eq!(first["output_config"]["effort"], "high");
    assert_eq!(
        first["cache_control"]["type"], "ephemeral",
        "the request end"
    );
    assert_eq!(first["tools"][0]["type"], "bash_20250124");
    assert_eq!(first["tools"][2]["name"], "zoom");
    assert_eq!(
        first["system"], bodies[1]["system"],
        "byte-identical system prompt"
    );
    assert_eq!(first["tools"], bodies[1]["tools"], "byte-identical tools");
    let opening = first["messages"][0]["content"].as_array().unwrap();
    assert_eq!(opening[0]["text"], "<chat>\n</chat>");
    assert_eq!(opening[0]["cache_control"]["type"], "ephemeral");
    assert_eq!(opening[1]["text"], "what does echo say?");
    assert!(opening[1].get("cache_control").is_none());
    let second = bodies[1]["messages"].as_array().unwrap();
    assert_eq!(second.len(), 3);
    assert_eq!(
        second[0], first["messages"][0],
        "the opening is resent unchanged"
    );
    assert_eq!(
        second[1]["content"],
        tool_step()["content"],
        "model output kept verbatim"
    );
    assert_eq!(
        second[2]["content"],
        json!([{"type": "tool_result", "tool_use_id": "t1", "content": "hi\n"}])
    );
}

#[test]
fn a_message_sent_during_a_native_turn_is_delivered_between_tool_calls() {
    let model = scripted(vec![tool_step(), final_step("A and B are fine.")], true);
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model.clone(), workdir.path()));
    h.connect();
    h.say("user_local", "check A");
    h.step(); // settled: the turn starts, its first call waits
    h.say("user_local", "also check B");
    *model.gate.lock().unwrap() = false;
    model.opened.notify_all();
    h.settle();
    assert_eq!(
        pairs(&h.log()),
        vec![
            ("user", "check A"),
            ("talk", "Checking."),
            ("tool", "bash {\"command\":\"echo hi\"}"),
            ("echo", "hi\n"),
            ("user", "also check B"),
            ("talk", "A and B are fine."),
        ]
    );
    let bodies = model.bodies.lock().unwrap().clone();
    assert_eq!(
        bodies.len(),
        2,
        "one turn, no second turn for the delivered message"
    );
    assert_eq!(
        bodies[1]["messages"][2]["content"][1],
        json!({"type": "text", "text": "also check B"})
    );
    let owner = h.owner.lock().unwrap();
    assert_eq!(owner.sends().len(), 1);
    assert_eq!(
        owner.cursors(),
        vec![1, 2],
        "the cursor passes the delivered message"
    );
    assert!(
        h.agents.inner.lock().unwrap().prompts.is_empty(),
        "no acpmux session"
    );
}

#[test]
fn a_native_turn_that_is_refused_says_so() {
    let model = scripted(
        vec![json!({"stop_reason": "refusal", "content": [], "usage": {"input_tokens": 1}})],
        false,
    );
    let workdir = tempfile::tempdir().unwrap();
    let mut h = Harness::with_engine(native(model, workdir.path()));
    h.connect();
    h.say("user_local", "hello");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    assert_eq!(sends.len(), 1);
    assert!(sends[0].1.contains("refusal"), "{sends:?}");
}
