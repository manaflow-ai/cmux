//! The person's Stop, through the engine: a running batch ends at its next
//! step, later calls are refused with the text the agent must see, Resume
//! undoes it, and other sessions never notice.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;

use super::*;
use crate::cursor::{CursorEvent, CursorSink};
use crate::desktop::fake::{Event, FakeDesktop};
use crate::engine::{CallContext, Engine, EngineParts, Origin};

struct Recorder(Mutex<Vec<CursorEvent>>);
impl CursorSink for Recorder {
    fn show(&self, e: CursorEvent) {
        self.0.lock().unwrap().push(e);
    }
}

fn ctx(session: &str, call: &str) -> CallContext {
    CallContext {
        session: session.into(),
        label: "Claude".into(),
        call_id: Some(call.into()),
        origin: Origin::Local,
        tag: None,
    }
}

/// An engine whose sleeps advance a fake clock; a sleep of exactly
/// `stop_at` stops session `s1` (the person clicks Stop while it waits).
fn engine(stop_at: Option<Duration>) -> (Arc<FakeDesktop>, Engine, Arc<Stops>, Arc<Recorder>) {
    let d = Arc::new(FakeDesktop::standard());
    let mut parts = EngineParts::new(d.clone());
    let stops = parts.stops.clone();
    let now = Arc::new(AtomicU64::new(0));
    let (a, b) = (now.clone(), now);
    let s = stops.clone();
    parts.sleep = Arc::new(move |t| {
        if Some(t) == stop_at {
            s.stop("s1");
        }
        a.fetch_add(t.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    let rec = Arc::new(Recorder(Mutex::new(vec![])));
    parts.cursor = rec.clone();
    (d, Engine::new(parts), stops, rec)
}

#[test]
fn a_stop_mid_batch_ends_the_batch_at_its_next_step() {
    let (d, e, _, _) = engine(Some(Duration::from_millis(777)));
    let out = e.call(
        &ctx("s1", "b1"),
        "batch",
        &json!({"window_id": "1", "observe": false, "actions": [
            {"action": "click", "element_id": "e1"},
            {"action": "wait", "ms": 777},
            {"action": "type_text", "text": "never typed"},
            {"action": "press_key", "keys": "Return"}
        ]}),
    );
    assert!(out.is_error, "{:?}", out.body);
    assert_eq!(out.code.as_deref(), Some(STOPPED_CODE));
    assert_eq!(out.body["error"], STOPPED_MESSAGE);
    assert_eq!(out.body["stopped_during_call"], true);
    assert_eq!(out.body["acted_before_stop"], true);
    assert_eq!(out.body["completed"], 2);
    let events = d.events();
    assert_eq!(events.len(), 1, "{events:?}");
    assert!(matches!(events[0], Event::Click { .. }));
}

#[test]
fn a_stop_during_paced_typing_ends_it_between_two_keys() {
    // Anthropic pacing sleeps 12 ms between keys; the stop comes on the first.
    let (d, e, _, _) = engine(Some(crate::engine::ANTHROPIC_TYPING_DELAY));
    let out = e.call(
        &ctx("s1", "t1"),
        "type_text",
        &json!({"window_id": "1", "text": "hello", "settle": "anthropic", "observe": false}),
    );
    assert_eq!(out.code.as_deref(), Some(STOPPED_CODE), "{:?}", out.body);
    let typed = d.events().iter().filter(|e| matches!(e, Event::Type { .. })).count();
    assert_eq!(typed, 1, "one key went before the stop");
}

#[test]
fn later_calls_are_refused_with_the_text_the_agent_sees_and_resume_works() {
    let (d, e, _, rec) = engine(None);
    assert!(e.stop_session("s1", "Claude"));
    assert!(!e.stop_session("s1", "Claude"), "already stopped");
    assert!(e.is_stopped("s1"));
    assert_eq!(e.stopped_sessions(), vec!["s1".to_string()]);
    // The cursor goes red with Stopped (and hides on its own idle timer).
    assert!(rec.0.lock().unwrap().iter().any(
        |ev| matches!(ev, CursorEvent::Refused { session, reason, .. } if session == "s1" && reason == STOPPED_CAPTION)
    ));
    for (name, args) in [
        ("click", json!({"window_id": "1", "element_id": "e1"})),
        ("screenshot", json!({"window_id": "1"})),
        ("list_windows", json!({})),
    ] {
        let out = e.call(&ctx("s1", name), name, &args);
        assert_eq!(out.code.as_deref(), Some(STOPPED_CODE), "{name}");
        // What reaches the agent: the MCP text content carries the message unchanged.
        let mcp = out.to_mcp();
        assert_eq!(mcp["isError"], true);
        let text: serde_json::Value =
            serde_json::from_str(mcp["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(text["error"], STOPPED_MESSAGE);
        assert_eq!(text["code"], STOPPED_CODE);
    }
    assert!(d.events().is_empty());
    // Resume: the same call id runs now (a refused call left no retry record).
    assert!(e.resume_session("s1"));
    assert!(!e.resume_session("s1"));
    let out = e.call(&ctx("s1", "click"), "click", &json!({"window_id": "1", "element_id": "e1", "observe": false}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(d.events().len(), 1);
}

#[test]
fn other_sessions_are_unaffected() {
    let (d, e, _, _) = engine(None);
    e.stop_session("s1", "Claude");
    let out = e.call(&ctx("s2", "c"), "click", &json!({"window_id": "1", "element_id": "e1", "observe": false}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(d.events().len(), 1);
    assert!(!e.is_stopped("s2"));
}

#[test]
fn nothing_stopped_costs_one_load() {
    let stops = Stops::default();
    assert!(!stops.is_stopped("s1"));
    stops.stop("s1");
    stops.resume("s1");
    assert!(!stops.any.load(std::sync::atomic::Ordering::Acquire));
}
