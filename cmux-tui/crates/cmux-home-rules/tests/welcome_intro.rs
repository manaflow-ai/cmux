//! Parity with `ChiefIntroTests` and the switch-keys card.

use cmux_home_rules::call;
use cmux_home_rules::welcome::intro::{IntroKind, IntroState, intro, mark_shown};
use serde_json::json;

#[test]
fn the_only_chief_welcomes_and_a_new_chief_beside_others_asks_for_a_focus() {
    let mut state = IntroState::default();
    assert_eq!(intro(&state, "chief-first", 0), Some(IntroKind::Welcome));
    state = mark_shown(&state, IntroKind::Welcome, "chief-first");
    assert_eq!(intro(&state, "chief-first", 0), None);
    assert_eq!(intro(&state, "chief-second", 1), Some(IntroKind::AskFocus));
    state = mark_shown(&state, IntroKind::AskFocus, "chief-second");
    assert_eq!(intro(&state, "chief-second", 1), None, "each Chief introduces itself once");
    assert_eq!(intro(&state, "chief-third", 2), Some(IntroKind::AskFocus));
}

#[test]
fn the_welcome_shows_once_per_install() {
    let state = mark_shown(&IntroState::default(), IntroKind::Welcome, "chief-first");
    assert_eq!(intro(&state, "chief-second", 0), None);
}

#[test]
fn an_older_install_that_saw_the_welcome_still_gets_the_question() {
    let out = call(
        "welcome.intro",
        &json!({"state": {"shown": true}, "conversation": "chief-first", "otherChiefs": 0}),
    )
    .unwrap();
    assert_eq!(out["kind"], json!(null));
    let out = call(
        "welcome.intro",
        &json!({"state": {"shown": true}, "conversation": "chief-second", "otherChiefs": 3}),
    )
    .unwrap();
    assert_eq!(out["kind"], "askFocus");
}

#[test]
fn mark_shown_names_its_write() {
    let out = call(
        "welcome.markShown",
        &json!({"state": {"asked": ["b"]}, "kind": "askFocus", "conversation": "a"}),
    )
    .unwrap();
    assert_eq!(out["state"]["asked"], json!(["a", "b"]));
    assert_eq!(out["write"], json!({"key": "home.firstRun.chiefIntroAsked", "value": ["a", "b"]}));
    let out = call("welcome.markShown", &json!({"kind": "welcome", "conversation": "a"})).unwrap();
    assert_eq!(out["write"], json!({"key": "home.firstRun.chiefIntroShown", "value": true}));
}

#[test]
fn the_switch_card_warns_of_a_desktop_conflict_only_while_shown() {
    let out = call(
        "welcome.switchKeys",
        &json!({"hasTabByNumberModifiers": true, "missionControlConflicts": true}),
    )
    .unwrap();
    assert_eq!(out["shows"], true);
    assert_eq!(out["desktopConflict"], true);
    let out = call(
        "welcome.switchKeys",
        &json!({"hidden": true, "hasTabByNumberModifiers": true, "missionControlConflicts": true}),
    )
    .unwrap();
    assert_eq!(out["shows"], false);
    assert_eq!(out["desktopConflict"], false);
    assert_eq!(out["hiddenKey"], "home.firstRun.switchKeysHidden");
}
