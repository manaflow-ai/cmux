//! Parity with `ChiefWelcomeTests` and `ChiefWelcomeShortcutTests`.

use cmux_home_rules::call;
use cmux_home_rules::welcome::script::{
    ABOUT_CLIENT_ID, ABOUT_TEXT, AboutRequest, BACKGROUND_CLIENT_ID, Beat, HELLO_CLIENT_ID,
    HELLO_TEXT, Shortcut, Step, Texts, about_text, beats, play_steps, reading_pause, typing_time,
};
use serde_json::{Value, json};

const AT: f64 = 1_793_404_800.25;

fn keys() -> Vec<&'static str> {
    vec![HELLO_CLIENT_ID, ABOUT_CLIENT_ID, BACKGROUND_CLIENT_ID]
}

#[test]
fn each_message_arrives_after_its_own_quiet_and_dots() {
    let list = beats(&Texts::default());
    assert_eq!(list.iter().map(|b| b.client_id.as_str()).collect::<Vec<_>>(), keys());
    let expected: Vec<Step> = list
        .iter()
        .enumerate()
        .flat_map(|(i, b)| {
            [
                Step::Wait { ms: b.quiet_ms },
                Step::Typing { on: true },
                Step::Wait { ms: b.typing_ms },
                Step::Import { beats: vec![i] },
                Step::Typing { on: false },
            ]
        })
        .collect();
    assert_eq!(play_steps(&list, true), expected);
}

#[test]
fn the_pacing_stays_in_messages_range() {
    let list = beats(&Texts::default());
    assert_eq!(list[0].quiet_ms, 600);
    assert!(list[1..].iter().all(|b| (600..=1000).contains(&b.quiet_ms)));
    assert_eq!(list[0].typing_ms, 1200);
    assert!(list.iter().all(|b| (1200..=2000).contains(&b.typing_ms)));
    assert!(list[1].typing_ms > list[0].typing_ms);
    assert_eq!(typing_time(&"x".repeat(1000)), 2000);
    assert_eq!(reading_pause("hi"), 600);
    let total: u64 = list.iter().map(|b| b.quiet_ms + b.typing_ms).sum();
    assert!(total <= 8000);
}

#[test]
fn the_welcome_is_chiefs_own_three_messages_with_fixed_keys() {
    let out = call("welcome.importRequest", &json!({"conversation": "conv", "now": AT})).unwrap();
    let request = &out["request"];
    assert_eq!(request["conversation"], "conv");
    let messages = request["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert!(messages.iter().all(|m| m["author"] == "agent_mux"));
    assert!(messages.iter().all(|m| m["created_at"] == "2026-10-31T00:00:00.250Z"));
    assert_eq!(messages[0]["parts"], json!([{"type": "text", "text": HELLO_TEXT}]));
    assert_eq!(
        messages.iter().map(|m| m["client_msg_id"].as_str().unwrap()).collect::<Vec<_>>(),
        keys()
    );
    assert!(HELLO_TEXT.contains("cmux") && !HELLO_TEXT.contains('\n'));
    assert!(!ABOUT_TEXT.is_empty());
    assert!(
        messages[2]["parts"][0]["text"].as_str().unwrap().contains("(cmux://settings/background)")
    );
}

#[test]
fn reduce_motion_sends_at_once_without_dots_or_pauses() {
    let list = beats(&Texts::default());
    assert_eq!(
        play_steps(&list, false),
        vec![Step::Import { beats: vec![0, 1, 2] }, Step::Typing { on: false }]
    );
    let out = call("welcome.playSteps", &json!({"showsTyping": false})).unwrap();
    assert_eq!(
        out["steps"],
        json!([{"kind": "import", "beats": [0, 1, 2]}, {"kind": "typing", "on": false}])
    );
}

#[test]
fn the_stored_welcome_keeps_the_shortcuts_before_the_background_offer() {
    let shortcut =
        |keys: &str, title: &str| Shortcut { keys: keys.into(), then: None, title: title.into() };
    let text = about_text(&AboutRequest {
        shortcuts: vec![shortcut("⌘N", "New Workspace"), shortcut("⇧⌘P", "Command Palette")],
        ..AboutRequest::default()
    });
    assert_eq!(
        text,
        format!("{ABOUT_TEXT}\n\nMore shortcuts:\n- `⌘N` New Workspace\n- `⇧⌘P` Command Palette")
    );
    assert!(!text.contains(HELLO_TEXT));
    let list = beats(&Texts { about: Some(text.clone()), ..Texts::default() });
    assert_eq!(list[1].text, text);
    let steps = play_steps(&list, true);
    assert_eq!(
        steps[7],
        Step::Wait { ms: typing_time(&text) },
        "the about types for its own length"
    );
    assert_eq!(
        steps[10],
        Step::Wait { ms: reading_pause(&text) },
        "and the background waits for it to be read"
    );
    let imports =
        steps.iter().filter(|s| matches!(s, Step::Import { beats } if beats.len() == 1)).count();
    assert_eq!(imports, 3, "one import per beat");
}

#[test]
fn the_about_text_through_the_op() {
    let out = call(
        "welcome.aboutText",
        &json!({
            "shortcuts": [{"keys": "⌃B", "then": "C", "title": "Split"}],
            "anyApp": {"keys": "⌥Space", "title": "Start an agent"},
        }),
    )
    .unwrap();
    assert_eq!(
        out["text"],
        format!(
            "{ABOUT_TEXT}\n\nMore shortcuts:\n- `⌃B` then `C` Split\n- `⌥Space` Start an agent (off until you [turn it on](cmux://settings/start-agent-from-any-app))"
        )
    );
}

#[test]
fn a_shortcut_drops_the_trailing_ellipsis() {
    let out =
        call("welcome.shortcut", &json!({"steps": ["⌘P"], "title": "Open Browser…"})).unwrap();
    assert_eq!(out["shortcut"]["title"], "Open Browser");
    assert_eq!(out["shortcut"]["markdown"], "`⌘P`");
    let none = call("welcome.shortcut", &json!({"steps": [], "title": "x"})).unwrap();
    assert_eq!(none["shortcut"], Value::Null);
}

#[test]
fn beats_round_trip_through_the_ops() {
    let out = call("welcome.beats", &json!({})).unwrap();
    let list: Vec<Beat> = serde_json::from_value(out["beats"].clone()).unwrap();
    assert_eq!(list, beats(&Texts::default()));
    assert_eq!(out["beats"][0]["clientID"], HELLO_CLIENT_ID);
    assert_eq!(call("welcome.typingTime", &json!({"text": "hi"})).unwrap()["ms"], 1200);
}
