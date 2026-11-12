//! A new browser workspace shows a stand-in tab at the press, and the daemon's tab takes its
//! place when the create answers (cmux-next `BrowserWorkspaceStandIn`). A person who already
//! types in the stand-in's address bar must keep the field across that swap. The rule drops a
//! chrome target when the pane's selected tab changes (`addressBar` falls back to `content`), so
//! the app asks for the address bar on the daemon's tab in the turn of the swap
//! (`WorkspaceSpawner.shown`, commit 6478df5). These cases pin both halves in the crate that owns
//! the rule: the drop the app has to answer, and that its expectation lands on the new tab.

use cmux_focus_core::event::{FocusEffect, FocusEvent, Source};
use cmux_focus_core::reducer;
use cmux_focus_core::state::{ExpectationKey, FocusState, Target};
use serde_json::{Value, json};

fn send(state: &mut FocusState, event: FocusEvent) -> Vec<FocusEffect> {
    let mut effects = Vec::new();
    reducer::reduce(state, &event, &mut effects);
    effects
}

fn topology(tab: &str) -> FocusEvent {
    serde_json::from_value(json!({"topology": {"_0": {"workspace": "w", "panes": [
        {"id": "p", "selected": tab, "tabs": [{"id": tab, "kind": "browser"}]},
    ]}}}))
    .unwrap()
}

fn bar(tab: &str) -> Value {
    json!({"addressBar": {"pane": "p", "tab": tab}})
}

/// The stand-in's address bar has the keyboard (the person pressed Cmd-L and types).
fn typing_in_the_stand_in() -> FocusState {
    let mut state = FocusState::default();
    send(&mut state, topology("pending"));
    send(
        &mut state,
        FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Keyboard },
    );
    assert_eq!(
        json!(state.resolved()),
        bar("pending"),
        "the stand-in's address bar has the keyboard"
    );
    state
}

#[test]
fn the_swap_alone_drops_the_address_bar() {
    let mut state = typing_in_the_stand_in();
    send(&mut state, topology("real"));
    assert_eq!(
        json!(state.resolved()),
        json!({"browserPage": {"pane": "p", "tab": "real"}}),
        "the rule the app answers: a new selected tab takes the keyboard to its page"
    );
}

#[test]
fn the_apps_expectation_keeps_the_address_bar_on_the_daemons_tab() {
    let mut state = typing_in_the_stand_in();
    send(&mut state, topology("real"));
    let generation = state.generation;
    send(
        &mut state,
        FocusEvent::Expect {
            key: ExpectationKey::Tab { id: "real".into() },
            target: Target::AddressBar {},
            away_from: None,
            generation,
        },
    );
    assert_eq!(json!(state.resolved()), bar("real"), "the person's typing lost the address bar");
}

/// The expectation asked for before the swap (the tab is not in the topology yet) lands when
/// the topology brings the tab.
#[test]
fn an_expectation_set_before_the_swap_lands_with_it() {
    let mut state = typing_in_the_stand_in();
    let generation = state.generation;
    send(
        &mut state,
        FocusEvent::Expect {
            key: ExpectationKey::Tab { id: "real".into() },
            target: Target::AddressBar {},
            away_from: None,
            generation,
        },
    );
    send(&mut state, topology("real"));
    assert_eq!(json!(state.resolved()), bar("real"), "the waiting expectation did not land");
}
