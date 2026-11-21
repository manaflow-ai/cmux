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

/// #35765: a terminal's reader can change the tab's title (or another live field) on its own thread
/// while a delta for that tab is built elsewhere (the terminal publisher commits its directory). The
/// test-only check in `tree_entity_json` built the entity, then the whole tree, and compared them: a
/// title set between the two builds failed it, and the failure, under the state lock, poisoned the
/// session for the rest of the test. The check must compare the two builders on one set of inputs.
#[test]
fn the_entity_check_holds_when_a_reader_changes_the_title_between_its_builds() {
    let mux = test_mux();
    let surface = mux.new_workspace(Some("titled".into()), Some((80, 24))).unwrap();
    surface.set_test_title("before");
    let decorations = mux.tree_decorations();
    let moving = surface.clone();
    crate::server::set_entity_check_hook_for_test(move || moving.set_test_title("after"));
    let entity = mux.with_state(|state| {
        crate::server::tree_entity_json(state, &decorations, TreeDeltaKind::TabChanged, surface.id)
    });
    assert!(entity.is_some(), "the tab has an entity");
    assert_eq!(surface.title(), "after", "the hook ran between the two builds");
}
