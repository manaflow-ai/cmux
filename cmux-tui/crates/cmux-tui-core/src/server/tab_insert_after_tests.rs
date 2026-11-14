//! `new-tab {after}` and `new-conversation-tab {after}` (`tab-insert-after-v1`):
//! a held new-tab key shows its tab right after the current one, and the
//! daemon commits the tab there in the creating commit, with one `tab-added`
//! at that index and no later move, by the slot rule of
//! `new-frontend-browser-tab {after}`.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone())).unwrap_or_default()
}

fn active_tab(mux: &Mux, pane: PaneId) -> usize {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.active_tab)).unwrap()
}

/// The members of each tab group run in `pane`, in strip order.
fn group_runs(mux: &Mux, pane: PaneId) -> Vec<Vec<SurfaceId>> {
    let presentation = mux.presentation_snapshot();
    mux.with_state(|state| {
        crate::mux::pane_tab_groups(state, &presentation, pane)
            .into_iter()
            .map(|run| run.members)
            .collect()
    })
}

/// A pane with three terminal tabs `[a, b, c]`, `a` active.
fn pane_with_three_tabs(label: &str) -> (Arc<Mux>, PaneId, [SurfaceId; 3]) {
    let mux = Mux::new_for_test(format!("tab-insert-{label}"), crate::SurfaceOptions::default());
    let a = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(a)).unwrap();
    let b = mux.new_tab(Some(pane), None, None).unwrap().id;
    let c = mux.new_tab(Some(pane), None, None).unwrap().id;
    mux.select_tab(Some(pane), Some(0), None);
    (mux, pane, [a, b, c])
}

/// The two commands that take `after`.
#[derive(Clone, Copy, Debug)]
enum Kind {
    Terminal,
    Conversation,
}

const KINDS: [Kind; 2] = [Kind::Terminal, Kind::Conversation];

fn create_after(mux: &Arc<Mux>, kind: Kind, pane: PaneId, after: SurfaceId) -> SurfaceId {
    let request = match kind {
        Kind::Terminal => json!({"cmd":"new-tab","pane":pane,"after":after}),
        Kind::Conversation => json!({"cmd":"new-conversation-tab","pane":pane,"after":after,
                                     "agent_session":{"host":"install:mac-test"}}),
    };
    let created = run(mux, request).unwrap();
    created["surface"].as_u64().unwrap()
}

#[test]
fn after_puts_the_tab_right_after_the_anchor_and_activates_it() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = pane_with_three_tabs(&format!("anchor-{kind:?}"));
        let created = create_after(&mux, kind, pane, a);
        assert_eq!(tabs(&mux, pane), vec![a, created, b, c], "{kind:?}");
        assert_eq!(active_tab(&mux, pane), 1, "{kind:?}: the new tab is active");
        mux.shutdown();
    }
}

/// A held new-tab key: each tab goes right after the one before it, so the
/// tabs sit right of the start tab in press order.
#[test]
fn a_burst_after_the_previous_tab_keeps_press_order() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = pane_with_three_tabs(&format!("burst-{kind:?}"));
        let mut previous = a;
        let mut created = Vec::new();
        for _ in 0..8 {
            previous = create_after(&mux, kind, pane, previous);
            created.push(previous);
        }
        let mut expected = vec![a];
        expected.extend(&created);
        expected.extend([b, c]);
        assert_eq!(tabs(&mux, pane), expected, "{kind:?}");
        assert_eq!(active_tab(&mux, pane), 8, "{kind:?}: the last tab is active");
        mux.shutdown();
    }
}

/// An anchor that is not a tab of the pane (unknown, or another pane's)
/// leaves the end, with no error.
#[test]
fn an_unknown_or_foreign_anchor_appends() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = pane_with_three_tabs(&format!("foreign-{kind:?}"));
        let unknown = create_after(&mux, kind, pane, 999_999);
        assert_eq!(tabs(&mux, pane), vec![a, b, c, unknown], "{kind:?}");
        let other = mux.new_pane(pane, None).unwrap().id;
        let foreign = create_after(&mux, kind, pane, other);
        assert_eq!(tabs(&mux, pane), vec![a, b, c, unknown, foreign], "{kind:?}");
        mux.shutdown();
    }
}

/// The creation emits one `tab-added` naming the final index, and no
/// tree change (a move) after it.
#[test]
fn the_creation_is_one_tab_added_at_its_index() {
    for kind in KINDS {
        let (mux, pane, [a, _, _]) = pane_with_three_tabs(&format!("event-{kind:?}"));
        let events = mux.subscribe();
        let created = create_after(&mux, kind, pane, a);
        let mut added = Vec::new();
        let mut tree_changes = 0;
        for event in std::iter::from_fn(|| events.try_recv().ok()) {
            match event {
                MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::TabAdded => {
                    added.push((delta.surface, delta.pane, delta.index));
                }
                MuxEvent::TreeChanged => tree_changes += 1,
                _ => {}
            }
        }
        assert_eq!(added, vec![(Some(created), Some(pane), Some(1))], "{kind:?}");
        assert_eq!(tree_changes, 0, "{kind:?}: no move follows the add");
        mux.shutdown();
    }
}

/// After a grouped tab inside its group's run, the tab joins the group in
/// its slot, as a browser tab opened after a grouped tab does.
#[test]
fn after_a_grouped_tab_joins_the_group_in_its_slot() {
    for kind in KINDS {
        let (mux, pane, [a, b, c]) = pane_with_three_tabs(&format!("group-{kind:?}"));
        mux.create_tab_group(&[a, b], None, Some("green".into()), Some("g1".into()), None).unwrap();
        let created = create_after(&mux, kind, pane, a);
        assert_eq!(tabs(&mux, pane), vec![a, created, b, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), vec![vec![a, created, b]], "{kind:?}");
        // After the group's last tab it joins at the group's end.
        let last = create_after(&mux, kind, pane, b);
        assert_eq!(tabs(&mux, pane), vec![a, created, b, last, c], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), vec![vec![a, created, b, last]], "{kind:?}");
        // After an ungrouped tab it stays ungrouped.
        let outside = create_after(&mux, kind, pane, c);
        assert_eq!(tabs(&mux, pane), vec![a, created, b, last, c, outside], "{kind:?}");
        assert_eq!(group_runs(&mux, pane), vec![vec![a, created, b, last]], "{kind:?}");
        mux.shutdown();
    }
}

#[test]
fn after_with_split_is_a_bad_request() {
    let (mux, pane, [a, _, _]) = pane_with_three_tabs("split");
    let error = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,"after":a,
               "agent_session":{"host":"install:mac-test"},"split":{"direction":"right"}}),
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("bad request: after does not apply with split"), "{error}");
    mux.shutdown();
}

#[test]
fn identify_advertises_tab_insert_after() {
    let mux = Mux::new_for_test("tab-insert-identify", crate::SurfaceOptions::default());
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "tab-insert-after-v1"), "{identity}");
    mux.shutdown();
}
