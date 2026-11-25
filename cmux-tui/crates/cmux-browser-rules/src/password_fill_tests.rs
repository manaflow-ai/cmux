//! The saved-password fill rule and the per-tab switch, from `PasswordFillPolicy`'s doc comments.

use crate::ops;
use crate::password_fill::*;
use serde_json::json;

#[test]
fn only_a_person_driven_tab_of_an_allowing_profile_fills() {
    assert!(fills(false, true));
    assert!(!fills(true, true));
    assert!(!fills(false, false));
    assert!(!fills(true, false));
}

#[test]
fn the_switch_sends_only_a_change() {
    let mut state = PasswordFillState::default();
    // Chromium fills by default: a filling tab never turned off sends nothing.
    assert_eq!(state.next_switch_value(false), None);
    // An agent takes the tab: off once.
    assert_eq!(state.next_switch_value(true), Some(0));
    assert_eq!(state.next_switch_value(true), None);
    // The person again: on once.
    assert_eq!(state.next_switch_value(false), Some(1));
    assert_eq!(state.next_switch_value(false), None);
    // The profile turns autofill off.
    assert!(state.set_allowed_by_profile(false));
    assert!(!state.set_allowed_by_profile(false));
    assert!(!state.fills(false));
    assert_eq!(state.next_switch_value(false), Some(0));
    assert!(!PasswordFillState::new(false).fills(false));
}

#[test]
fn the_ops_carry_the_state() {
    assert_eq!(
        ops::call(
            "browser_rules_password_fills",
            json!({"agentDriven": true, "profileAllows": true})
        ),
        Ok(json!(false))
    );
    let off =
        ops::call("browser_rules_password_fill_switch", json!({"agentDriven": true})).unwrap();
    assert_eq!(off, json!({"state": {"allowedByProfile": true, "switchedOff": true}, "value": 0}));
    let same = ops::call(
        "browser_rules_password_fill_switch",
        json!({"state": off["state"], "agentDriven": true}),
    )
    .unwrap();
    assert_eq!(same["value"], json!(null));
    let set =
        ops::call("browser_rules_password_fill_set_allowed", json!({"allowed": false})).unwrap();
    assert_eq!(
        set,
        json!({"state": {"allowedByProfile": false, "switchedOff": false}, "changed": true})
    );
}
