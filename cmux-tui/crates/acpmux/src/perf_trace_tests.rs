use std::io::Write;
use std::sync::{Arc, Mutex};

use tracing_subscriber::layer::SubscriberExt as _;

use super::PerfTraceLayer;

#[derive(Clone, Default)]
struct Buf(Arc<Mutex<Vec<u8>>>);

impl Write for Buf {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn spans_become_chrome_trace_events_with_the_parents_trace_id() {
    let buf = Buf::default();
    let sub = tracing_subscriber::registry().with(PerfTraceLayer::new(buf.clone()));
    tracing::subscriber::with_default(sub, || {
        let outer = tracing::info_span!("close_tab", trace_id = "t-42");
        let _o = outer.enter();
        let inner = tracing::info_span!("journal_sync");
        drop(inner.enter());
    });
    let text = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    let json = format!("{}]", text.trim_end().trim_end_matches(','));
    let events: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0]["name"], "journal_sync");
    assert_eq!(events[0]["args"]["trace_id"], "t-42");
    assert_eq!(events[1]["name"], "close_tab");
    assert_eq!(events[1]["ph"], "X");
}

#[test]
fn a_request_carries_the_callers_trace_id_into_its_steps() {
    let params = serde_json::json!({"_meta": {"traceId": "phone-close-7"}, "tab": 3});
    assert_eq!(super::trace_id_of(Some(&params)), Some("phone-close-7"));
    assert_eq!(super::trace_id_of(Some(&serde_json::json!({}))), None);
    assert_eq!(super::trace_id_of(None), None);

    let buf = Buf::default();
    let sub = tracing_subscriber::registry().with(PerfTraceLayer::new(buf.clone()));
    tracing::subscriber::with_default(sub, || {
        let span = super::request_span("tab.close", Some(&params));
        let _g = span.enter();
        drop(tracing::info_span!("journal_sync").entered());
    });
    let text = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    let json = format!("{}]", text.trim_end().trim_end_matches(','));
    let events: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    assert_eq!(events[0]["args"]["trace_id"], "phone-close-7");
    assert_eq!(events[1]["args"]["method"], "tab.close");
}

#[test]
fn a_tool_call_becomes_one_event_from_its_start_to_its_last_update() {
    let buf = Buf::default();
    let sink: std::sync::Mutex<Box<dyn Write + Send>> = std::sync::Mutex::new(Box::new(buf.clone()));
    let zero = std::time::Instant::now();
    let start = serde_json::json!({"params": {"update": {
        "sessionUpdate": "tool_call", "toolCallId": "tc1", "kind": "read", "title": "Read lib.rs", "status": "pending"}}});
    let mid = serde_json::json!({"params": {"update": {"toolCallId": "tc1", "status": "in_progress"}}});
    let done = serde_json::json!({"params": {"update": {"toolCallId": "tc1", "status": "completed"}}});
    super::note_tool_record_into(&sink, zero, "s1", "tool_call", &start);
    super::note_tool_record_into(&sink, zero, "s1", "tool_call_update", &mid);
    assert!(buf.0.lock().unwrap().is_empty());
    super::note_tool_record_into(&sink, zero, "s1", "tool_call_update", &done);
    // A second completion of the same call writes nothing more.
    super::note_tool_record_into(&sink, zero, "s1", "tool_call_update", &done);
    let text = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    let json = format!("[{}]", text.trim_end().trim_end_matches(','));
    let events: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["name"], "tool:read");
    assert_eq!(events[0]["args"]["title"], "Read lib.rs");
    assert_eq!(events[0]["args"]["session"], "s1");
}
