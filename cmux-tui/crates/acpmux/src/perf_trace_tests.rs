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
