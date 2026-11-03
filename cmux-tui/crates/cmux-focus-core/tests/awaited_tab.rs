//! P0 INVERSE-KEY (VIDEO EXTRA smoke gate, dogfood 5b50f8bb57ac, round 5 step 12): Cmd-N showed
//! Home's agent page (a Chromium page in its own child window), then Ctrl-` asked for a new
//! terminal tab. The new tab was not in the window's topology yet (memory pressure), so the focus
//! waited for it and the model still resolved the agent page. The wait moved no responder: the page
//! window kept the keys (and took them again on its own), and the line the person typed for the
//! new terminal went to the page window, not to the cmux window's creation hold.
//!
//! The focus that starts waiting for another tab is a responder change in the same reduction: the
//! app's applier then takes the keys from the page the person left (`FocusEffectApplier`). A wait
//! that ends without landing (a newer intent) applies the target again, so that page gets them back.

use cmux_focus_core::event::FocusEffect;
use cmux_focus_core::reducer;
use cmux_focus_core::state::FocusState;
use serde_json::{Value, json};

fn send(state: &mut FocusState, event: Value) -> Vec<FocusEffect> {
    let mut effects = Vec::new();
    reducer::reduce(state, &serde_json::from_value(event).unwrap(), &mut effects);
    effects
}

fn moves_responder(effects: &[FocusEffect]) -> bool {
    effects.iter().any(|e| matches!(e, FocusEffect::MoveResponder { .. }))
}

/// Home's agent page focused in the new workspace's one pane.
fn home_focused() -> FocusState {
    let mut state = FocusState::default();
    send(
        &mut state,
        json!({"topology": {"_0": {"workspace": "w", "panes": [
            {"id": "home", "tabs": [{"id": "home-tab", "kind": "agent"}], "selected": "home-tab"},
        ]}}}),
    );
    assert_eq!(json!(state.resolved()), json!({"agentPage": {"pane": "home", "tab": "home-tab"}}));
    state
}

/// Ctrl-`: the person's intent, then the new terminal tab the window does not show yet.
fn ask_for_a_new_terminal(state: &mut FocusState) -> Vec<FocusEffect> {
    send(state, json!({"beginIntent": {}}));
    let generation = state.generation;
    send(
        state,
        json!({"expect": {"_0": {"tab": {"_0": "new-term"}}, "target": {"content": {}}, "generation": generation}}),
    )
}

#[test]
fn a_wait_for_a_new_tab_moves_the_responder_off_the_page_in_the_same_reduction() {
    let mut state = home_focused();
    let effects = ask_for_a_new_terminal(&mut state);
    assert!(state.expectation.is_some(), "the focus does not wait for the new terminal");
    assert!(
        moves_responder(&effects),
        "the wait for the new terminal left the responder on Home's page, whose window keeps the keys: {effects:?}"
    );
}

#[test]
fn a_wait_that_a_newer_intent_ends_gives_the_page_its_target_again() {
    let mut state = home_focused();
    ask_for_a_new_terminal(&mut state);
    let effects = send(&mut state, json!({"beginIntent": {}}));
    assert!(state.expectation.is_none());
    assert!(
        moves_responder(&effects),
        "the wait ended without landing and Home's page did not get its target back: {effects:?}"
    );
}

#[test]
fn the_new_tab_landing_moves_the_responder_to_it() {
    let mut state = home_focused();
    ask_for_a_new_terminal(&mut state);
    let effects = send(
        &mut state,
        json!({"topology": {"_0": {"workspace": "w", "panes": [
            {"id": "home", "selected": "home-tab", "tabs": [
                {"id": "home-tab", "kind": "agent"}, {"id": "new-term", "kind": "terminal"}]},
        ]}}}),
    );
    assert!(state.expectation.is_none());
    assert_eq!(json!(state.resolved()), json!({"terminal": {"pane": "home", "tab": "new-term"}}));
    assert!(moves_responder(&effects));
}

/// A wait for the focused tab itself (a dropped tab that focus follows into its new pane) is no
/// focus move away from it: its page keeps the keys, with no extra responder change.
#[test]
fn a_wait_for_the_focused_tab_itself_moves_no_responder() {
    let mut state = home_focused();
    let effects = send(
        &mut state,
        json!({"dragEnded": {"_0": {"dropped": {"tabs": ["home-tab"], "awayFrom": "home"}}}}),
    );
    assert!(state.expectation.is_some(), "the drop asked for no focus");
    assert!(!moves_responder(&effects), "the page's own wait moved the responder: {effects:?}");
}

/// A new tab the window shows in the key's turn lands at once: no wait, one responder change.
#[test]
fn a_new_tab_shown_at_once_never_waits() {
    let mut state = FocusState::default();
    send(
        &mut state,
        json!({"topology": {"_0": {"workspace": "w", "panes": [
            {"id": "home", "selected": "home-tab", "tabs": [
                {"id": "home-tab", "kind": "agent"}, {"id": "new-term", "kind": "terminal"}]},
        ]}}}),
    );
    let effects = ask_for_a_new_terminal(&mut state);
    assert!(state.expectation.is_none());
    assert_eq!(
        effects.iter().filter(|e| matches!(e, FocusEffect::MoveResponder { .. })).count(),
        1
    );
}
