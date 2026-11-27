use super::*;

#[test]
fn a_followed_event_reads_as_one_line() {
    let span = json!({"kind": "span", "at": 3_723_000u64, "name": "new chat", "ms": 3400.0, "budgetMs": 3000.0,
        "over": true, "parts": [{"name": "agent start", "ms": 2900.0}, {"name": "first token", "ms": 380.0}]});
    assert_eq!(
        event_text(&span),
        "01:02:03 span  new chat 3.4 s (over 3.0 s): agent start 2.9 s | first token 380 ms"
    );
    let note =
        json!({"kind": "note", "at": 0, "text": "SessionList re-rendered 14 times in 200 ms"});
    assert_eq!(event_text(&note), "00:00:00 note  SessionList re-rendered 14 times in 200 ms");
    let meter = json!({"kind": "meter", "at": 0, "top": [{"label": "reply to _acpmux/sessions", "channel": "daemon-ipc", "bytesPerMinute": 41943040u64}]});
    assert_eq!(
        event_text(&meter),
        "00:00:00 meter reply to _acpmux/sessions [daemon-ipc] 40.0 MB/min"
    );
}

#[test]
fn frames_read_as_one_line() {
    let read = json!({"visible_chat": {"frames": 1200, "window_s": 300, "p50_ms": 8.35,
        "p95_ms": 16.65, "p99_ms": 33.45, "over_budget": 14, "budget_ms": 16.7}});
    assert_eq!(
        frames_text(&read),
        "visible chat: 1200 frames in 300 s, p50 8.35 ms, p95 16.65 ms, p99 33.45 ms (14 over 16.7 ms)"
    );
    let empty = json!({"visible_chat": {"frames": 0, "window_s": 40}});
    assert_eq!(frames_text(&empty), "visible chat: no frames drawn in the last 40 s");
}

#[test]
fn only_debug_perf_is_taken() {
    let words = |list: &[&str]| list.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    assert!(run_if_requested(&words(&["debug", "open-settings"])).is_none());
    assert!(run_if_requested(&words(&["agents", "snapshot"])).is_none());
    assert_eq!(run_if_requested(&words(&["debug", "perf", "nonsense"])), Some(2));
}
