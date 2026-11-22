//! A tab's identity is its own, never its pane's or its position's: the app keys each tab's view by the
//! `tab_resource_id` the tree carries (`TabModel.identity`), so a tab that moves keeps its view and the pane
//! it left keeps the views of the tabs it still has (Leo, 2026-11-22: "when i move one tab completely to
//! another pane, the original pane flickers a re-render").

use super::*;

/// Each live tab's durable id, as the tree sends it (`tree_json`: the surface's identity, else the index's).
fn identities(mux: &Arc<Mux>) -> HashMap<SurfaceId, String> {
    mux.with_state(|state| {
        let mut ids = HashMap::new();
        for pane in state.panes.values() {
            for slot in &pane.tabs {
                let from_surface = state
                    .surfaces
                    .get(slot)
                    .and_then(|surface| surface.resource_identity())
                    .map(|identity| identity.tab_id.to_string());
                let from_index = state.resource_indexes.tab_ids.get(slot).map(|id| id.to_string());
                assert_eq!(
                    from_surface, from_index,
                    "tab {slot}: its surface and the index disagree"
                );
                ids.insert(*slot, from_index.expect("every placed tab has a durable id"));
            }
        }
        ids
    })
}

fn assert_kept(
    before: &HashMap<SurfaceId, String>,
    after: &HashMap<SurfaceId, String>,
    step: &str,
) {
    for (slot, id) in after {
        if let Some(was) = before.get(slot) {
            assert_eq!(was, id, "{step}: tab {slot} changed identity");
        }
    }
    let unique: HashSet<_> = after.values().collect();
    assert_eq!(unique.len(), after.len(), "{step}: two tabs share an identity");
}

#[test]
fn a_tab_keeps_its_identity_across_move_split_and_a_sibling_close() {
    let mux = test_mux();
    let a = mux.new_workspace(None, None).unwrap();
    let p1 = mux.with_state(|s| s.pane_of(a.id).unwrap());
    let b = mux.new_tab(Some(p1), None, None).unwrap();
    let c = mux.new_tab(Some(p1), None, None).unwrap();
    let d = mux.split(p1, SplitDir::Right, None).unwrap();
    let p2 = mux.with_state(|s| s.pane_of(d.id).unwrap());
    let start = identities(&mux);
    assert_eq!(start.len(), 4);
    assert_kept(&start, &start, "start");

    // A move to another pane that keeps the source's other tabs: same id, new pane.
    assert!(mux.move_tab(a.id, p2, 1));
    let moved = identities(&mux);
    assert_eq!(moved, start, "a move changed a tab's identity");
    mux.with_state(|s| {
        assert_eq!(s.pane_of(a.id), Some(p2));
        assert_eq!(
            s.panes[&p1].tabs,
            vec![b.id, c.id],
            "the source pane kept its other tabs in order"
        );
    });

    // A split of the source pane: its tabs keep their ids, the new tab has its own.
    let e = mux.split(p1, SplitDir::Down, None).unwrap();
    let split = identities(&mux);
    assert_kept(&moved, &split, "split");
    assert_eq!(split.len(), 5);
    assert!(
        !moved.values().any(|id| *id == split[&e.id]),
        "the split's tab took an existing identity"
    );

    // A move into a new split (the tab's pane is new, its identity is not).
    let outcome = mux.move_tab_to_split(b.id, p2, TabDropEdge::Bottom, None, None).unwrap();
    assert_ne!(outcome.pane, p1);
    let dragged = identities(&mux);
    assert_eq!(dragged, split, "a move into a new split changed a tab's identity");

    // A sibling's close: the tabs that stay keep their ids.
    mux.close_surface(c.id).unwrap();
    let closed = identities(&mux);
    assert_kept(&dragged, &closed, "sibling close");
    assert!(!closed.contains_key(&c.id));
    assert_eq!(closed.len(), 4);

    // A move that empties its source pane (e is alone in the split's pane): the tab keeps its id, the pane goes.
    let p_e = mux.with_state(|s| s.pane_of(e.id).unwrap());
    assert!(mux.move_tab(e.id, p2, 0));
    let emptied = identities(&mux);
    assert_eq!(emptied, closed, "a move that empties its pane changed a tab's identity");
    mux.with_state(|s| assert!(!s.panes.contains_key(&p_e), "the emptied pane stays"));
}
