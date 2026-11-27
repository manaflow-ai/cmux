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
        "wheel": {"ticks": 30, "delta": 100, "sent": 30, "delivered": 30, "scrolled": 2800, "expected": 3000},
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
         Wheel: the transcript moved 2800 px of the 3000 px sent\n\
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

/// An older page's typed text is counted in graphemes, as the page counts what it types: a thumbs-up
/// with a skin tone and a family joined with zero-width joiners are two characters, not seven scalars.
#[test]
fn app_chat_drive_counts_typed_emoji_as_graphemes() {
    let emoji = "\u{1F44D}\u{1F3FD}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    assert_eq!(emoji.chars().count(), 7);
    let mut typed = report();
    typed["page"]["typed"] = json!(emoji);
    let text = human(&typed, &english().app_control);
    assert!(text.contains("Typed 2 characters; they stay in the draft\n"), "{text}");
    // The --type cap counts the same way: 500 of them pass, 501 do not (a thumbs-up is 2 UTF-16 units,
    // so 500 stay under the 2000-unit cap).
    let at_cap = "\u{1F44D}".repeat(500);
    assert!(parse(&args(&["app", "chat", "drive", "--tab", "t", "--type", &at_cap])).is_ok());
    let over = format!("{at_cap}x");
    assert!(parse(&args(&["app", "chat", "drive", "--tab", "t", "--type", &over])).is_err());
}

/// `--delta` is range-checked without `abs()`: `i64::MIN` (which has no absolute value) is refused,
/// not a panic or a wrap past the bound.
#[test]
fn app_chat_drive_refuses_the_most_negative_delta() {
    for delta in [i64::MIN, i64::MIN + 1, -2001, 2001, i64::MAX] {
        let delta = delta.to_string();
        let words = [
            "app", "chat", "drive", "--tab", "t", "--hover", "a", "--wheel", "3", "--delta", &delta,
        ];
        assert!(parse(&args(&words)).is_err(), "--delta {delta} should be refused");
    }
    for delta in ["-2000", "2000", "-1"] {
        let words = [
            "app", "chat", "drive", "--tab", "t", "--hover", "a", "--wheel", "3", "--delta", delta,
        ];
        assert!(parse(&args(&words)).is_ok(), "--delta {delta} should pass");
    }
}

/// The CLI refuses the `--type` text the app answers `invalid_params` to, from the table both sides
/// check (cmux-tui/spec/fixtures/chat-drive-type-text.json; the app's AgentChatDriveControlTests reads it too).
#[test]
fn app_chat_drive_type_text_matches_the_shared_table() {
    let table: serde_json::Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../spec/fixtures/chat-drive-type-text.json"
    )))
    .unwrap();
    assert_eq!(table["max_graphemes"], json!(super::MAX_TEXT));
    assert_eq!(table["max_utf16"], json!(super::MAX_TEXT_UTF16));
    assert_eq!(table["max_image_index"], json!(super::MAX_IMAGE_INDEX));
    for flag in ["--hover-sent-image", "--hover-tool-screenshot"] {
        let at = super::MAX_IMAGE_INDEX.to_string();
        let over = (super::MAX_IMAGE_INDEX + 1).to_string();
        assert!(
            parse(&args(&["app", "chat", "drive", "--tab", "t", flag, &at])).is_ok(),
            "{flag} {at}"
        );
        assert!(
            parse(&args(&["app", "chat", "drive", "--tab", "t", flag, &over])).is_err(),
            "{flag} {over}"
        );
    }
    let text = |case: &serde_json::Value| {
        case["text"].as_str().unwrap().repeat(case["repeat"].as_u64().unwrap_or(1) as usize)
    };
    let typed = |text: &str| parse(&args(&["app", "chat", "drive", "--tab", "t", "--type", text]));
    for case in table["typable"].as_array().unwrap() {
        let text = text(case);
        assert!(typed(&text).is_ok(), "{text:?} should be typable");
    }
    for case in table["refused"].as_array().unwrap() {
        let text = text(case);
        assert!(typed(&text).is_err(), "{text:?} ({}) should be refused", case["why"]);
        assert!(!(super::fits(&text) && super::typable(&text)), "{text:?}");
    }
}

/// An app from before `sent` reported its sends as `delivered`, with no `scrolled`: the summary still
/// reads them, and prints no scroll line it has no numbers for.
#[test]
fn app_chat_drive_summary_reads_an_older_apps_wheel() {
    let mut older = report();
    older["wheel"] = json!({"ticks": 30, "delta": 100, "delivered": 30});
    let text = human(&older, &english().app_control);
    assert!(text.contains("Wheel: 30 of 30 ticks of 100 px sent;"), "{text}");
    assert!(!text.contains("transcript moved"), "{text}");
}

/// A run cut off before its text was typed says how much went in and why; a complete one does not.
#[test]
fn app_chat_drive_summary_tells_cut_off_typing_from_done() {
    let mut cut = report();
    cut["page"]["typed"] = json!(2);
    cut["page"]["type_asked"] = json!(6);
    cut["page"]["type_stopped"] = json!("time_up");
    let text = human(&cut, &english().app_control);
    assert!(
        text.contains(
            "Typed 2 of 6 characters, then stopped (time_up); what was typed stays in the draft\n"
        ),
        "{text}"
    );
    let mut done = report();
    done["page"]["typed"] = json!(6);
    done["page"]["type_asked"] = json!(6);
    let text = human(&done, &english().app_control);
    assert!(text.contains("Typed 6 characters; they stay in the draft\n"), "{text}");
}

/// A run measured nothing (a hidden window, a throttled display) still says what it typed and why it
/// stopped: typing goes on with no frames to measure.
#[test]
fn app_chat_drive_unmeasured_summary_still_tells_the_typing() {
    let mut cut = report();
    cut["page"]["measured"] = json!(false);
    cut["page"]["unmeasured_reason"] = json!("hidden");
    cut["page"]["typed"] = json!(2);
    cut["page"]["type_asked"] = json!(6);
    cut["page"]["type_stopped"] = json!("time_up");
    let text = human(&cut, &english().app_control);
    assert!(text.contains("Measured nothing: hidden."), "{text}");
    assert!(!text.contains("Frames:"), "{text}");
    assert!(
        text.contains(
            "Typed 2 of 6 characters, then stopped (time_up); what was typed stays in the draft\n"
        ),
        "{text}"
    );
    cut["page"]["typed"] = json!(6);
    cut["page"]["type_asked"] = json!(6);
    cut["page"]["type_stopped"] = json!(null);
    let text = human(&cut, &english().app_control);
    assert!(text.contains("Typed 6 characters; they stay in the draft\n"), "{text}");
}
