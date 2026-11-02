//! QA chrome-parity-v2-2-2 bug 1 (dogfood 77c95946de09), in the crate that owns the rule: the
//! launch window shows the home workspace (Home's page first, the pane beside it with a terminal
//! and the selected browser tab) before it adopts the saved window record. The record's focused
//! pane then comes as `restoredPane` for the shown workspace. The rule dropped it, so Home kept
//! the focus and typed keys went into Home's Chief message box. The same cases run through the
//! app FFI in cmux-layout-reducer-ffi's focus_rules.rs; this copy runs in the cmux-tui workspace.

use cmux_focus_core::event::FocusEffect;
use cmux_focus_core::reducer;
use cmux_focus_core::state::FocusState;
use serde_json::{Value, json};

fn send(state: &mut FocusState, event: Value) -> Vec<FocusEffect> {
    let mut effects = Vec::new();
    reducer::reduce(state, &serde_json::from_value(event).unwrap(), &mut effects);
    effects
}

fn topology() -> Value {
    json!({"topology": {"_0": {"workspace": "w", "panes": [
        {"id": "home", "tabs": [{"id": "home-tab", "kind": "page"}], "selected": "home-tab"},
        {"id": "right", "selected": "web", "tabs": [
            {"id": "term", "kind": "terminal"}, {"id": "web", "kind": "browser"}]},
    ]}}})
}

fn restore_after_the_workspace_shows(before_record: &[Value]) -> (FocusState, Vec<FocusEffect>) {
    let mut state = FocusState::default();
    send(&mut state, topology());
    for event in before_record {
        send(&mut state, event.clone());
    }
    let effects = send(&mut state, json!({"restoredPane": {"_0": "right", "workspace": "w"}}));
    (state, effects)
}

#[test]
fn restored_pane_for_the_shown_workspace_focuses_its_saved_pane() {
    let browser = json!({"browserPage": {"pane": "right", "tab": "web"}});
    let (state, effects) = restore_after_the_workspace_shows(&[]);
    assert_eq!(json!(state.resolved()), browser, "the saved pane, not the first one");
    assert!(
        effects.iter().any(|e| matches!(e, FocusEffect::MoveResponder { .. })),
        "the responder is not moved to the saved pane: {effects:?}"
    );
    // Home's message box took the keyboard by itself first (a programmatic report): no person's choice.
    let home_took_it =
        json!({"responder": {"_0": {"content": {"pane": "home"}}, "source": "programmatic"}});
    let (state, _) = restore_after_the_workspace_shows(&[home_took_it]);
    assert_eq!(json!(state.resolved()), browser, "a view's own grab does not keep the restore");
}

#[test]
fn restored_pane_never_overrides_the_persons_choice() {
    let clicked = json!({"focusPane": {"_0": "home", "source": "mouse"}});
    let (state, _) = restore_after_the_workspace_shows(&[clicked]);
    assert_eq!(json!(state.resolved()), json!({"page": {"pane": "home", "tab": "home-tab"}}));
}
