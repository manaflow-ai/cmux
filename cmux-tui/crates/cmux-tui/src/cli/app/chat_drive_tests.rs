use serde_json::json;

use super::super::{AppCommand, parse};
use super::human;

fn english() -> &'static crate::localization::Catalog {
    crate::localization::catalog_for_locale("en_US.UTF-8")
}

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn params(words: &[&str]) -> serde_json::Value {
    match parse(&args(words)).unwrap().unwrap() {
        AppCommand::ChatDrive { params, .. } => params,
        other => panic!("expected chat drive, got {other:?}"),
    }
}

/// `cmux app chat drive` names one chat and one element; the wheel goes under the held pointer,
/// typing is opt-in, and every bound is the app's own (`AgentChatDriveControl`).
#[test]
fn app_chat_drive_parses_one_target_wheel_and_typing() {
    let command = parse(&args(&[
        "app",
        "chat",
        "drive",
        "--tab",
        "tab_1",
        "--hover-sent-image",
        "1",
        "--wheel",
        "30",
    ]))
    .unwrap()
    .unwrap();
    assert_eq!(
        command,
        AppCommand::ChatDrive {
            params: json!({
                "tab": "tab_1",
                "target": {"sent_image": 1},
                "wheel": {"ticks": 30, "delta": 100},
                "seconds": 10,
                "allow_busy": false,
            }),
            seconds: 10,
        }
    );
    assert_eq!(
        params(&[
            "app",
            "chat",
            "drive",
            "--tab",
            "tab_2",
            "--hover",
            "tool-screenshot",
            "--wheel",
            "5",
            "--delta",
            "-40",
            "--tick-ms",
            "33",
            "--hold-ms",
            "0",
            "--type",
            "hi",
            "--over-draft",
            "--allow-busy",
            "--seconds",
            "30",
        ]),
        json!({
            "tab": "tab_2",
            "target": {"test_id": "tool-screenshot"},
            "wheel": {"ticks": 5, "delta": -40, "tick_ms": 33},
            "type": {"text": "hi", "allow_draft": true},
            "hold_ms": 0,
            "seconds": 30,
            "allow_busy": true,
        })
    );
    assert_eq!(
        params(&["app", "chat", "drive", "--tab", "tab_3", "--type", "x"]),
        json!({"tab": "tab_3", "type": {"text": "x", "allow_draft": false}, "seconds": 10, "allow_busy": false})
    );
}

#[test]
fn app_chat_drive_refuses_what_it_cannot_bound() {
    let long = "x".repeat(501);
    for bad in [
        &["app", "chat", "drive"][..],
        &["app", "chat", "drive", "--tab", ""],
        // Nothing to drive.
        &["app", "chat", "drive", "--tab", "tab_1"],
        // Two targets.
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--hover-sent-image", "1"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover-tool-screenshot", "0"],
        // A wheel with no held pointer, or out of bounds.
        &["app", "chat", "drive", "--tab", "tab_1", "--type", "x", "--wheel", "3"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--wheel", "201"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--wheel", "3", "--delta", "0"],
        &[
            "app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--wheel", "3", "--delta",
            "2001",
        ],
        &[
            "app",
            "chat",
            "drive",
            "--tab",
            "tab_1",
            "--hover",
            "a",
            "--wheel",
            "3",
            "--tick-ms",
            "1",
        ],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--delta", "10"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--hold-ms", "10001"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--seconds", "31"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--seconds", "0"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--over-draft"],
        &["app", "chat", "drive", "--tab", "tab_1", "--type", ""],
        &["app", "chat", "drive", "--tab", "tab_1", "--type", long.as_str()],
        // No script, no focus: a fixed set of actions.
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--eval", "1"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "--focus"],
        &["app", "chat", "drive", "--tab", "tab_1", "--hover", "a", "extra"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?} should be refused");
    }
}

fn report() -> serde_json::Value {
    json!({
        "tab": "tab_1",
        "engine": "webkit:agent-chat",
        "hover": {"held": true, "native": true, "x": 412.5, "y": 300},
        "wheel": {"ticks": 30, "delta": 100, "delivered": 30},
        "engine_counters": null,
        "engine_counters_unavailable": "WebKit does not expose layout or style counts to the app",
        "page": {
            "measured": true,
            "frames": [
                {"t_ms": 16.7, "hovered": true, "card_open": true},
                {"t_ms": 33.4, "hovered": true, "card_open": false},
                {"t_ms": 50.1, "hovered": false, "card_open": false},
            ],
            "totals": {"frames": 3, "composer_renders": 0, "composer_mutations": 0, "mutation_nodes": 0,
                       "focus_flips": 0, "focus_within_flips": 0, "page_inactive_flips": 0,
                       "wheel_events": 30, "wheel_trusted": 30, "frame_p50_ms": 16.7,
                       "frame_p95_ms": 17.2, "frame_max_ms": 18, "over_33_ms": 0},
            "typed": 0,
        },
    })
}

#[test]
fn app_chat_drive_summary_reads_the_report() {
    let text = human(&report(), &english().app_control);
    assert_eq!(
        text,
        "Chat tab_1 (webkit:agent-chat)\n\
         Hover: held at 412.5, 300 (CSS px); the system pointer did not move\n\
         Wheel: 30 of 30 ticks of 100 px sent; the page saw 30 wheel events, 30 trusted\n\
         Frames: 3; p50 16.7 ms, p95 17.2 ms, max 18 ms; 0 over 33 ms\n\
         Composer: 0 renders, 0 DOM mutation batches (0 records)\n\
         Flips: focus 0, :focus-within 0, page inactive 0\n\
         Hovered in 2 of 3 frames; hover card open in 1\n\
         Engine layout and style counts: not available (WebKit does not expose layout or style counts to the app)\n"
    );
    let mut unmeasured = report();
    unmeasured["page"]["measured"] = json!(false);
    unmeasured["page"]["unmeasured_reason"] = json!("no_frames");
    let text = human(&unmeasured, &english().app_control);
    assert!(text.contains("Measured nothing: no_frames."), "{text}");
    assert!(!text.contains("Frames:"), "{text}");
}

/// The typed line gives a count, never the text: from a page's count, and from an older page that
/// sent the text itself.
#[test]
fn app_chat_drive_summary_counts_what_was_typed() {
    let mut typed = report();
    typed["page"]["typed"] = json!(8);
    let text = human(&typed, &english().app_control);
    assert!(text.contains("Typed 8 characters; they stay in the draft\n"), "{text}");
    typed["page"]["typed"] = json!("hi there");
    let text = human(&typed, &english().app_control);
    assert!(text.contains("Typed 8 characters; they stay in the draft\n"), "{text}");
    assert!(!text.contains("hi there"), "{text}");
    typed["page"]["typed"] = json!(null);
    assert!(!human(&typed, &english().app_control).contains("Typed"));
}
