//! The list facts (moved from the app's CloudWorkspaceRestoreTests' list rules).

use super::*;

fn inputs(
    signed_in: bool,
    restoring: bool,
    loaded: bool,
    loaded_for: Option<[&str; 2]>,
    account: [&str; 2],
) -> Inputs {
    let pair = |pair: [&str; 2]| pair.iter().map(|id| Some((*id).to_owned())).collect::<Vec<_>>();
    Inputs {
        is_signed_in: signed_in,
        is_restoring: restoring,
        has_loaded_machines: loaded,
        loaded_for: loaded_for.map(pair),
        account: pair(account),
        has_loaded_current_machines: None,
    }
}

#[test]
fn a_machine_left_only_when_the_accounts_own_list_says_so() {
    let current = facts(&inputs(true, false, true, Some(["u", "t"]), ["u", "t"]));
    assert!(current.account_list_loaded && current.has_loaded_current_machines);
    assert_eq!(current.settled, Settled::IfMachinesLoaded);
    // After a team switch the old team's list says nothing about the new team's machines.
    let switched = facts(&inputs(true, false, true, Some(["u", "t1"]), ["u", "t2"]));
    assert!(!switched.account_list_loaded);
    assert_eq!(switched.settled, Settled::No);
    // Signed out, or restoring the sign-in: an unlisted machine is only not connected.
    assert!(!facts(&inputs(false, false, true, Some(["u", "t"]), ["u", "t"])).account_list_loaded);
    let restoring = facts(&inputs(true, true, true, Some(["u", "t"]), ["u", "t"]));
    assert!(!restoring.account_list_loaded);
    assert_eq!(restoring.settled, Settled::IfMachinesLoaded);
    assert!(!facts(&inputs(true, false, false, None, ["u", "t"])).account_list_loaded);
}

#[test]
fn signed_out_and_not_restoring_the_cloud_holds_none() {
    assert_eq!(facts(&inputs(false, false, false, None, ["u", "t"])).settled, Settled::Yes);
    assert_eq!(facts(&inputs(false, true, false, None, ["u", "t"])).settled, Settled::No);
}

#[test]
fn a_caller_may_say_the_list_is_current() {
    let given =
        Inputs { is_signed_in: true, has_loaded_current_machines: Some(true), ..Inputs::default() };
    assert!(facts(&given).account_list_loaded);
}
