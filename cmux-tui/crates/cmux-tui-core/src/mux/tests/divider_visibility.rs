//! `split-divider-visibility-v1` (hide or show a split's divider) and
//! `split-around-v1` (a new pane after a whole split) on the mux.

use super::*;

fn hidden_dividers(mux: &Arc<Mux>) -> Vec<SplitId> {
    mux.with_state(|state| {
        let mut hidden = Vec::new();
        state.workspaces[0].screens[0].root.hidden_dividers(&mut hidden);
        hidden
    })
}

fn registry_split_hidden(node: &RegistryLayoutNode, target: &SplitPublicId) -> Option<bool> {
    match node {
        RegistryLayoutNode::Split { split, divider_hidden, first, second, .. } => {
            if split == target {
                Some(*divider_hidden)
            } else {
                registry_split_hidden(first, target)
                    .or_else(|| registry_split_hidden(second, target))
            }
        }
        RegistryLayoutNode::Leaf { .. } | RegistryLayoutNode::Stack { .. } => None,
    }
}

#[test]
fn hiding_and_showing_a_divider_persists_and_sends_one_layout_change_each() {
    let mux = test_mux();
    let (_, _, _, root_split, inner_split) = seed_split_ratio_tree(&mux);
    let public = mux.with_state(|state| state.resource_indexes.split_ids[&inner_split].clone());
    let events = mux.subscribe();

    mux.set_divider_visible_checked_as(&Actor::Daemon, inner_split, false, Some(7)).unwrap();
    assert_eq!(hidden_dividers(&mux), vec![inner_split]);
    let layout = events
        .try_iter()
        .find_map(|event| match event {
            MuxEvent::LayoutChanged(_, Some(delta)) => Some(delta),
            _ => None,
        })
        .expect("hiding a divider sends layout-changed");
    assert_eq!(layout.layout["hidden_dividers"], serde_json::json!([inner_split]));
    assert_eq!(layout.transaction.as_deref(), Some("7"));
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    assert_eq!(registry_split_hidden(&topology.screens[0].layout, &public), Some(true));

    // The same value again changes nothing and sends nothing.
    let revision = mux.with_state(|state| state.workspaces[0].screens[0].layout_revision);
    mux.set_divider_visible_checked_as(&Actor::Daemon, inner_split, false, None).unwrap();
    assert_eq!(mux.with_state(|state| state.workspaces[0].screens[0].layout_revision), revision);
    assert!(events.try_iter().next().is_none());

    // A ratio change keeps the flag.
    mux.set_split_ratio_checked(inner_split, 0.3).unwrap();
    assert_eq!(hidden_dividers(&mux), vec![inner_split]);
    // The ratio change's own layout-changed (still listing the hidden divider) is not the show's.
    events.try_iter().for_each(drop);

    mux.set_divider_visible_checked_as(&Actor::Daemon, inner_split, true, None).unwrap();
    assert!(hidden_dividers(&mux).is_empty());
    let layout = events
        .try_iter()
        .find_map(|event| match event {
            MuxEvent::LayoutChanged(_, Some(delta)) => Some(delta),
            _ => None,
        })
        .expect("showing a divider sends layout-changed");
    assert!(layout.layout.get("hidden_dividers").is_none());
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    assert_eq!(registry_split_hidden(&topology.screens[0].layout, &public), Some(false));
    assert!(mux.with_state(|state| state.split_screens.contains_key(&root_split)));
}

#[test]
fn an_unknown_split_is_refused() {
    let mux = test_mux();
    seed_split_ratio_tree(&mux);
    assert_eq!(
        mux.set_divider_visible_checked_as(&Actor::Daemon, 999_999, false, None),
        Err(DividerVisibilityError::UnknownSplit { split: 999_999 })
    );
    assert!(hidden_dividers(&mux).is_empty());
}

#[test]
fn a_viewport_column_boundary_is_refused() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
    let boundary = mux.with_state(|state| state.workspaces[0].screens[0].layout_columns[1].id);
    assert_eq!(
        mux.set_divider_visible_checked_as(&Actor::Daemon, boundary, false, None),
        Err(DividerVisibilityError::BoundarySplit { split: boundary })
    );
}

#[test]
fn undo_shows_a_hidden_divider_again() {
    let mux = test_mux();
    let (p1, _, _, _, inner_split) = seed_split_ratio_tree(&mux);
    mux.set_divider_visible_checked_as(&Actor::Daemon, inner_split, false, None).unwrap();
    assert_eq!(hidden_dividers(&mux), vec![inner_split]);
    mux.undo_layout_as(&Actor::Daemon, p1, None, false).unwrap();
    assert!(hidden_dividers(&mux).is_empty());
}

#[test]
fn a_hidden_divider_survives_a_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-divider-restart-{}", WorkspacePublicId::random().unwrap()));
    let (snapshot, mut topology) = resource_restore_fixture();
    let internal = restore_split_id(1);
    fn hide(node: &mut RegistryLayoutNode, target: &SplitPublicId) {
        if let RegistryLayoutNode::Split { split, divider_hidden, first, second, .. } = node {
            if split == target {
                *divider_hidden = true;
            }
            hide(first, target);
            hide(second, target);
        }
    }
    hide(&mut topology.screens[0].layout, &internal);
    hide(&mut topology.screens[0].viewport.columns[0].layout, &internal);
    {
        let mut registry = WorkspaceRegistry::open(&root, "divider-restart").unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon("seed-divider", "test").unwrap(),
                "session.restore_fixture",
                &serde_json::json!({"fixture":"hidden-divider"}),
                None,
                Some(0),
                &resource_restore_patch(&snapshot, &topology),
                &serde_json::json!({"restored":true}),
                &serde_json::json!([{"event":"session.restored"}]),
            )
            .unwrap();
    }
    let mux = open_persistent_test_mux("divider-restart", &root);
    mux.with_state(|state| {
        let split = state.resource_indexes.splits[&internal];
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns[0].root.divider_hidden(split), Some(true));
        assert_eq!(screen.root.divider_hidden(split), Some(true));
        assert!(screen.layout_column_projection_is_consistent());
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_stored_split_without_the_flag_loads_visible() {
    let old = serde_json::json!({
        "kind": "split",
        "split": restore_split_id(1),
        "direction": "right",
        "ratio": 0.5,
        "first": {"kind": "leaf", "pane": restore_pane_id(1)},
        "second": {"kind": "leaf", "pane": restore_pane_id(2)},
    });
    let node: RegistryLayoutNode = serde_json::from_value(old.clone()).unwrap();
    assert!(matches!(node, RegistryLayoutNode::Split { divider_hidden: false, .. }));
    // A visible split is written as before, without the field.
    assert_eq!(serde_json::to_value(&node).unwrap(), old);
}

/// `(X / Y) | B`, with `a` the vertical split of X and Y.
fn seed_around_tree(mux: &Arc<Mux>) -> (PaneId, PaneId, PaneId, SplitId, SplitId) {
    let first = mux.new_workspace(None, None).unwrap();
    let x = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let b = mux.split(x, SplitDir::Right, None).unwrap();
    let b = mux.with_state(|state| state.pane_of(b.id).unwrap());
    let y = mux.split(x, SplitDir::Down, None).unwrap();
    let y = mux.with_state(|state| state.pane_of(y.id).unwrap());
    let (outer, a) = mux.with_state(|state| {
        let Node::Split { id: outer, a, .. } = &state.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        let Node::Split { id: inner, .. } = a.as_ref() else { panic!("a should be split") };
        (*outer, *inner)
    });
    (x, y, b, outer, a)
}

fn split_around(
    mux: &Arc<Mux>,
    pane: PaneId,
    around: Option<SplitId>,
) -> anyhow::Result<PaneSurfaceCreation> {
    mux.split_with_options_as(
        &Actor::Daemon,
        pane,
        SplitDir::Right,
        TerminalSpawnOptions { around, ..TerminalSpawnOptions::default() },
        None,
    )
}

#[test]
fn a_split_around_a_whole_split_puts_the_new_pane_after_it_full_height() {
    let mux = test_mux();
    let (x, y, b, outer, a) = seed_around_tree(&mux);
    let created = split_around(&mux, y, Some(a)).unwrap();
    let new = mux.with_state(|state| state.pane_of(created.surface.id).unwrap());
    mux.with_state(|state| {
        // ((X / Y) | new) | B
        let Node::Split { id, a: left, b: right, .. } = &state.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        assert_eq!(*id, outer);
        assert!(matches!(right.as_ref(), Node::Leaf(pane) if *pane == b));
        let Node::Split { dir: SplitDir::Right, a: wrapped, b: added, .. } = left.as_ref() else {
            panic!("the new split should wrap a");
        };
        assert!(matches!(added.as_ref(), Node::Leaf(pane) if *pane == new));
        let Node::Split { id: kept, dir: SplitDir::Down, a: top, b: bottom, .. } = wrapped.as_ref()
        else {
            panic!("a should be kept whole");
        };
        assert_eq!(*kept, a);
        assert!(matches!(top.as_ref(), Node::Leaf(pane) if *pane == x));
        assert!(matches!(bottom.as_ref(), Node::Leaf(pane) if *pane == y));
    });
}

#[test]
fn a_split_around_a_split_that_does_not_end_at_the_pane_is_refused_unchanged() {
    let mux = test_mux();
    let (x, _, _, _, a) = seed_around_tree(&mux);
    let (before, panes) = mux.with_state(|state| {
        (format!("{:?}", state.workspaces[0].screens[0].root), state.panes.len())
    });
    let error = split_around(&mux, x, Some(a)).err().expect("x is not a's last leaf");
    assert!(
        format!("{error:#}").contains(&format!("around split {a} does not end at pane {x}")),
        "{error:#}"
    );
    mux.with_state(|state| {
        assert_eq!(format!("{:?}", state.workspaces[0].screens[0].root), before);
        assert_eq!(state.panes.len(), panes);
    });
}

#[test]
fn a_split_without_around_still_splits_the_pane_alone() {
    let mux = test_mux();
    let (_, y, _, _, a) = seed_around_tree(&mux);
    let created = split_around(&mux, y, None).unwrap();
    let new = mux.with_state(|state| state.pane_of(created.surface.id).unwrap());
    mux.with_state(|state| {
        let Node::Split { a: left, .. } = &state.workspaces[0].screens[0].root else {
            panic!("root should be split");
        };
        let Node::Split { id, b: bottom, .. } = left.as_ref() else { panic!("a stays") };
        assert_eq!(*id, a);
        let Node::Split { dir: SplitDir::Right, a: kept, b: added, .. } = bottom.as_ref() else {
            panic!("y should be split alone");
        };
        assert!(matches!(kept.as_ref(), Node::Leaf(pane) if *pane == y));
        assert!(matches!(added.as_ref(), Node::Leaf(pane) if *pane == new));
    });
}
