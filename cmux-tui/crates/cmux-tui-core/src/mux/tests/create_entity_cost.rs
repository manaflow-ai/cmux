//! #32408: a 512-workspace classic upgrade got about four times slower per workspace by its end.
//! Each create's exact delta (`screen-added`, `tab-added`) took its entity from the whole tree:
//! `tree_entity_json` serialized every workspace, screen, pane and tab of the session under the
//! registry and state locks, so a create cost O(session). A create's delta must cost O(changed):
//! the panes it serializes do not grow with the number of workspaces.

use super::*;

/// Panes serialized while one workspace with its first terminal and one more tab are made.
fn panes_built_by_one_create(mux: &Arc<Mux>) -> u64 {
    let before = crate::server::panes_built_for_test();
    let surface = mux.new_workspace(Some("measured".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    crate::server::panes_built_for_test() - before
}

fn session_of(workspaces: usize) -> Arc<Mux> {
    let mux = test_mux();
    for index in 0..workspaces {
        mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap();
    }
    mux
}

#[test]
fn a_create_serializes_no_more_of_the_tree_in_a_bigger_session() {
    let small = panes_built_by_one_create(&session_of(4));
    let large = panes_built_by_one_create(&session_of(48));
    assert!(
        large <= small,
        "one create serialized {small} panes in a 4-workspace session and {large} in a 48-workspace one: \
         its delta is built from the whole tree"
    );
}
