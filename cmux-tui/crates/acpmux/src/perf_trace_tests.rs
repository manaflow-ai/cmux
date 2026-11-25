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

fn events_of(buf: &Buf) -> Vec<serde_json::Value> {
    let text = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    serde_json::from_str(&format!("{}]", text.trim_end().trim_end_matches(','))).unwrap()
}

#[test]
fn a_w3c_traceparent_gives_its_trace_id() {
    let id = "4bf92f3577b34da6a3ce929d0e0e4736";
    let params =
        serde_json::json!({"_meta": {"traceparent": format!("00-{id}-00f067aa0ba902b7-01")}});
    assert_eq!(super::trace_id_of(Some(&params)), Some(id));
    assert_eq!(super::trace_id_of_traceparent("00-nothex-00f067aa0ba902b7-01"), None);
    // traceId wins when both are sent.
    let both =
        serde_json::json!({"_meta": {"traceId": "x", "traceparent": format!("00-{id}-00-01")}});
    assert_eq!(super::trace_id_of(Some(&both)), Some("x"));
}

#[test]
fn daemon_spans_are_on_the_epoch_clock_the_app_shares() {
    let buf = Buf::default();
    let before = super::now_us();
    let sub = tracing_subscriber::registry().with(PerfTraceLayer::new(buf.clone()));
    tracing::subscriber::with_default(sub, || drop(tracing::info_span!("step").entered()));
    let ts = events_of(&buf)[0]["ts"].as_u64().unwrap();
    assert!(ts >= before && ts <= super::now_us(), "ts {ts} is not epoch microseconds");
}

#[test]
fn a_request_without_a_trace_id_inherits_none_and_writes_none() {
    let buf = Buf::default();
    let sub = tracing_subscriber::registry().with(PerfTraceLayer::new(buf.clone()));
    tracing::subscriber::with_default(sub, || {
        drop(super::request_span("x", Some(&serde_json::json!({}))).entered());
    });
    assert!(events_of(&buf)[0]["args"].get("trace_id").is_none());
}

#[test]
fn client_spans_land_in_the_same_trace_with_their_floor_and_gap() {
    let buf = Buf::default();
    let layer = PerfTraceLayer::new(buf.clone());
    let reply = super::write_client_spans(
        &layer.out,
        &serde_json::json!({
            "process": "mac-app",
            "pid": 77,
            "spans": [
                {"name": "send.enter_to_paint", "ts_us": 1_000, "dur_us": 40_000, "floor_us": 8_000,
                 "trace_id": "abc", "args": {"chat": "c1"}},
                {"name": "missing_ts", "dur_us": 1},
            ],
        }),
    );
    assert_eq!(reply["recorded"], 1);
    let events = events_of(&buf);
    assert_eq!(events[0]["ph"], "M");
    assert_eq!(events[0]["args"]["name"], "mac-app");
    let e = &events[1];
    assert_eq!(
        (e["name"].as_str(), e["pid"].as_u64(), e["ts"].as_u64()),
        (Some("send.enter_to_paint"), Some(77), Some(1_000))
    );
    assert_eq!(e["args"]["trace_id"], "abc");
    assert_eq!(e["args"]["gap_us"], 32_000);
    assert_eq!(e["args"]["chat"], "c1");
}
