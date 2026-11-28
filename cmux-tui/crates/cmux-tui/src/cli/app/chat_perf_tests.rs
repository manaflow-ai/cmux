use serde_json::json;

use super::super::{AppCommand, parse};
use super::{human, page_source_human};

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
    let command = parse(&args(&["app", "chat", "perf", "--tab", "tab_1", "--seconds", "12"]))
        .unwrap()
        .unwrap();
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
    assert!(
        !human(&report(), &crate::localization::catalog_for_locale("ja_JP.UTF-8").app_control)
            .contains("{")
    );
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

/// The summary names the page code that asked for frames, timers and animations, by source file
/// and bundle position, and says when page code asked for none, so a release readback names the file.
#[test]
fn summary_names_frame_owners_by_file() {
    let mut busy = report();
    busy["owners"] = json!({
        "page_frames": 290,
        "frames": [{"file": "src/agent-session/acpmux/flickerLog.ts", "at": "pane.js:1:48213", "count": 290, "per_s": 58}],
        "timers": [{"file": "src/ui/pageClock.ts", "at": "timeout pane.js:1:9120", "count": 5, "per_s": 1}],
        "animate": [],
        "animations": [{"name": "cmux-spin", "target": "span.cv-spinner__arc", "iterations": "infinite", "count": 2}],
        "sites_resolved": true
    });
    let text = human(&busy, &english().app_control);
    assert!(text.contains("page code asked for another frame in 290 of 300 frames"), "{text}");
    assert!(
        text.contains("  frame 58/s (290): src/agent-session/acpmux/flickerLog.ts pane.js:1:48213"),
        "{text}"
    );
    assert!(text.contains("  timeout 1/s (5): src/ui/pageClock.ts pane.js:1:9120"), "{text}");
    assert!(
        text.contains(
            "  animation cmux-spin on span.cv-spinner__arc: 2 running, infinite iterations"
        ),
        "{text}"
    );
    let ja = human(&busy, &crate::localization::catalog_for_locale("ja_JP.UTF-8").app_control);
    assert!(!ja.contains('{'), "{ja}");

    let mut idle = report();
    idle["owners"] = json!({"page_frames": 0, "frames": [], "timers": [], "animate": [], "animations": [], "sites_resolved": false});
    let text = human(&idle, &english().app_control);
    assert!(text.contains("in 0 of 300 frames"), "{text}");
    assert!(text.contains("no page code asked for frames"), "{text}");
    // A page from before the owners says so instead of printing nothing.
    assert!(human(&report(), &english().app_control).contains("does not report them"));
}

/// `cmux app chat perf --page-source` asks the app for its page-source counts alone: no tab, no
/// window, no `reset`; a tab or seconds beside it is refused.
#[test]
fn app_chat_perf_page_source_needs_no_tab() {
    let command = parse(&args(&["app", "chat", "perf", "--page-source"])).unwrap().unwrap();
    assert_eq!(command, AppCommand::ChatPageSource { params: json!({"page_source": true}) });
    for bad in [
        &["app", "chat", "perf", "--page-source", "--tab", "tab_1"][..],
        &["app", "chat", "perf", "--page-source", "--seconds", "5"],
        &["app", "chat", "perf", "--page-source", "--reset"],
        &["app", "chat", "perf", "--page-source=true"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?} should be refused");
    }
}

/// The summary names each source, the spare's misses, and the reasons largest first; an app from
/// before the counts says so.
#[test]
fn page_source_summary_lists_sources_and_reasons() {
    let report = json!({"page_source": {
        "spare_adopted": 3, "spare_empty": 1, "spare_unready": 0, "spare_refused": 2,
        "kept": 1, "cold": 7,
        "cold_why": {"spare_not_taken": 3, "relaunch_wake": 4},
        "refused_why": {"touched": 1, "has_session": 1}
    }, "pages": {"chat": 9, "new_tab": 2, "frozen": 4, "released": 6}});
    let text = page_source_human(&report, &english().app_control);
    assert!(
        text.starts_with("Chat pages made since launch: 3 took the warm spare, 1 reused a kept page, 7 built cold\n"),
        "{text}"
    );
    assert!(text.contains("  Spare not used: 1 none parked, 0 not ready, 2 refused\n"), "{text}");
    assert!(text.contains("  Built cold because: relaunch_wake 4, spare_not_taken 3\n"), "{text}");
    assert!(text.contains("  Spare refused because: has_session 1, touched 1\n"), "{text}");
    assert!(
        text.contains("Pages now: 9 chat pages built (4 asleep), 2 New Tab pages; 6 chat pages let go while hidden since launch\n"),
        "{text}"
    );

    let empty = json!({"page_source": {"spare_adopted": 0, "spare_empty": 0, "spare_unready": 0,
        "spare_refused": 0, "kept": 0, "cold": 0, "cold_why": {}, "refused_why": {}}});
    let text = page_source_human(&empty, &english().app_control);
    assert!(!text.contains("because"), "{text}");
    assert!(!text.contains("Pages now"), "an app from before the page counts prints none: {text}");

    assert!(
        page_source_human(&json!({"tab": "x"}), &english().app_control).contains("does not count")
    );
    let ja = page_source_human(
        &report,
        &crate::localization::catalog_for_locale("ja_JP.UTF-8").app_control,
    );
    assert!(!ja.contains('{'), "{ja}");
}
