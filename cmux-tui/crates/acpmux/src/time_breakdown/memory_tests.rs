//! What one chat's time breakdown holds once its span window is full ([`MAX_SPANS`]): every chat
//! a daemon has open keeps one, eviction or not (`hub/session.rs` `time_breakdown`), so its bytes
//! are paid per chat.

use super::*;
use serde_json::json;

const TURNS: u64 = 128;
const SEGMENTS: u64 = 8;

fn record(seq: u64, at: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

/// A chat of [`TURNS`] turns of [`SEGMENTS`] spans each, its ids as long as a harness's.
fn full_window() -> State {
    let mut state = State::default();
    let mut seq = 0;
    let mut next = |state: &mut State, at: u64, kind: &str, msg: Value| {
        seq += 1;
        state.record(&record(seq, at, kind, msg));
    };
    for turn in 0..TURNS {
        let at = turn * 100_000;
        let ids = json!({
            "turnSeq": turn,
            "turnId": format!("turn-0f8a6c2e-4b1d-4e7a-9c3f-{turn:012}"),
            "promptId": format!("prompt-7d2b9e41-a6c8-4f05-b3e2-{turn:012}"),
        });
        next(&mut state, at, "turn_started", ids);
        for s in 0..SEGMENTS / 2 {
            let start = at + 1_000 + s * 10_000;
            let tool = format!("tool-{turn}-{s}");
            next(&mut state, start, "tool_call", json!({"toolCallId": tool, "kind": "read"}));
            next(
                &mut state,
                start + 4_000,
                "tool_call_update",
                json!({"toolCallId": tool, "status": "completed"}),
            );
        }
        next(&mut state, at + 90_000, "turn_result", json!({"usage": {"totalTokens": 9}}));
    }
    state
}

#[cfg(target_os = "linux")]
#[test]
fn a_full_span_window_holds_under_its_budget() {
    use crate::hub::peer_snapshot::{thread_peak_bytes, thread_peak_take};
    let ((spans, held), _) = thread_peak_bytes(|| {
        let state = full_window();
        let _ = thread_peak_take();
        let held = thread_peak_take().unwrap_or(0);
        (state.reducer.spans.len(), held)
    });
    println!("time-breakdown-memory spans={spans} held={held} per_span={}", held / spans.max(1));
    assert_eq!(spans, MAX_SPANS);
    // Each span is a few numbers and its category, and its turn's ids are the turn's, shared:
    // 344 bytes a span as `TimeSpan`s with their own `String`s in a `Vec` cut back to the bound.
    assert!(held / spans < 128, "{held} bytes for {spans} spans");
}
