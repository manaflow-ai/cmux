use serde_json::json;

use super::super::{AppCommand, parse};
use super::human;

fn english() -> &'static crate::localization::Catalog {
    crate::localization::catalog_for_locale("en_US.UTF-8")
}

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// `cmux app chat perf --tab <tab> --seconds <S>` calls the app's `agent.chat.perf` with the tab
/// and the window; the window defaults to 5 seconds and is a whole number from 1 to 60.
#[test]
fn app_chat_perf_parses_tab_and_seconds() {
    let command =
        parse(&args(&["app", "chat", "perf", "--tab", "tab_1", "--seconds", "12"])).unwrap().unwrap();
    assert_eq!(
        command,
        AppCommand::ChatPerf { params: json!({"tab": "tab_1", "seconds": 12}), seconds: 12 }
    );
    let command = parse(&args(&["app", "chat", "perf", "--tab=tab_2"])).unwrap().unwrap();
    assert_eq!(
        command,
        AppCommand::ChatPerf { params: json!({"tab": "tab_2", "seconds": 5}), seconds: 5 }
    );
    for bad in [
        &["app", "chat", "perf"][..],
        &["app", "chat", "perf", "--tab", ""],
        &["app", "chat", "perf", "--tab", "tab_1", "--seconds", "0"],
        &["app", "chat", "perf", "--tab", "tab_1", "--seconds", "61"],
        &["app", "chat", "perf", "--tab", "tab_1", "--seconds", "2.5"],
        &["app", "chat", "perf", "--tab", "tab_1", "--seconds", "soon"],
        &["app", "chat", "perf", "--tab", "tab_1", "--focus"],
        &["app", "chat", "perf", "--tab", "tab_1", "extra"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?} should be refused");
    }
}

fn report() -> serde_json::Value {
    json!({
        "tab": "tab_1",
        "seconds": 5,
        "measured": true,
        "unmeasured_reason": null,
        "visibility": {"start": "visible", "end": "visible", "changes": 0, "hidden_ms": 0},
        "frames": {"count": 300, "interval_p50_ms": 16.67, "interval_p95_ms": 17.1,
                   "interval_p99_ms": 33.4, "interval_max_ms": 84, "over_33_ms": 3, "over_50_ms": 1},
        "long_tasks": {"source": "long-animation-frame", "count": 2, "longest_ms": 84, "total_ms": 140,
                       "blocking_ms": 60, "top_scripts": [
            {"invoker": "MessagePort.onmessage", "source_url": "cmux-page://agent/app.js",
             "function": "", "count": 2, "total_ms": 110, "max_ms": 70}]},
        "layout_shift": {"count": 1, "sum": 0.02},
        "records": {
            "all": {"count": 4, "to_paint": {"p50_ms": 20, "p95_ms": 90, "max_ms": 90}, "apply": {"p50_ms": 1, "p95_ms": 9, "max_ms": 9}},
            "tool_call": {"count": 3, "to_paint": {"p50_ms": 20, "p95_ms": 90, "max_ms": 90}, "apply": {"p50_ms": 1, "p95_ms": 9, "max_ms": 9}},
            "tool_call_update": {"count": 0, "to_paint": {"p50_ms": 0, "p95_ms": 0, "max_ms": 0}, "apply": {"p50_ms": 0, "p95_ms": 0, "max_ms": 0}},
            "agent_message_chunk": {"count": 1, "to_paint": {"p50_ms": 12, "p95_ms": 12, "max_ms": 12}, "apply": {"p50_ms": 0.5, "p95_ms": 0.5, "max_ms": 0.5}},
            "other": {"count": 0, "to_paint": {"p50_ms": 0, "p95_ms": 0, "max_ms": 0}, "apply": {"p50_ms": 0, "p95_ms": 0, "max_ms": 0}},
            "unpainted": 0
        }
    })
}

/// The summary names frames, long tasks, layout shift and each kind that arrived, and nothing
/// for kinds that did not.
#[test]
fn summary_lists_frames_long_tasks_and_records_by_kind() {
    let text = human(&report(), &english().app_control);
    assert!(text.starts_with("Chat tab_1: 5 s, page visible\n"), "{text}");
    assert!(text.contains("Frames: 300; interval p50 16.67 ms"), "{text}");
    assert!(text.contains("3 over 33 ms, 1 over 50 ms"), "{text}");
    assert!(text.contains("Long tasks (long-animation-frame): 2, longest 84 ms"), "{text}");
    assert!(text.contains("110 ms in 2: MessagePort.onmessage cmux-page://agent/app.js"), "{text}");
    assert!(text.contains("  tool_call: 3, p50 20 ms, p95 90 ms, max 90 ms"), "{text}");
    assert!(text.contains("  agent_message_chunk: 1,"), "{text}");
    assert!(!text.contains("tool_call_update"), "{text}");
    assert!(!human(&report(), &crate::localization::catalog_for_locale("ja_JP.UTF-8").app_control).contains("{"));
}

/// A hidden or covered page reports that it measured nothing, not its frame numbers.
#[test]
fn summary_says_a_hidden_or_covered_page_measured_nothing() {
    let mut hidden = report();
    hidden["measured"] = json!(false);
    hidden["unmeasured_reason"] = json!("page_hidden");
    let text = human(&hidden, &english().app_control);
    assert!(text.contains("Measured nothing: the chat's page was hidden"), "{text}");
    assert!(!text.contains("Frames:"), "{text}");
    hidden["unmeasured_reason"] = json!("no_frames");
    let text = human(&hidden, &english().app_control);
    assert!(text.contains("drew no frames"), "{text}");
}
