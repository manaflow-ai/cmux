//! The acts on a floating pane at the mux (`floating-panes-v1`): a float, a frame, a focus, a close and a layout
//! undo, each read from the list of the screen. No test here goes through a command or a restart.

use cmux_layout_reducer::floating_panes::is_normal;

use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode};

/// The frame of a new floating pane that brings none: 60 percent wide and high in the middle.
const CENTERED: FloatFrame = FloatFrame { x: 200_000, y: 200_000, w: 600_000, h: 600_000 };

/// A mux with one workspace whose screen has `count` panes side by side. Returns the panes from left to right.
fn mux_with_panes(count: usize) -> (Arc<Mux>, Vec<PaneId>) {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let mut panes = vec![mux.with_state(|state| state.pane_of(first.id).unwrap())];
    for _ in 1..count {
        let last = *panes.last().unwrap();
        panes.push(pane_right_of(&mux, last));
    }
    (mux, panes)
}

fn pane_right_of(mux: &Arc<Mux>, target: PaneId) -> PaneId {
    let surface = mux.new_pane_right(target, 0.5, Some((38, 22))).unwrap();
    mux.with_state(|state| state.pane_of(surface.id).unwrap())
}

fn float(
    mux: &Arc<Mux>,
    pane: PaneId,
    mode: FloatMode,
) -> Result<FloatPaneOutcome, FloatPaneError> {
    mux.float_pane_as(&Actor::Daemon, pane, mode, None, None)
}

/// Gives `pane` a frame. `transaction` is the transaction of control client 7.
fn float_at(
    mux: &Arc<Mux>,
    pane: PaneId,
    frame: FloatFrame,
    transaction: Option<u64>,
) -> Result<FloatPaneOutcome, FloatPaneError> {
    let transaction = transaction.map(|transaction| (7, transaction));
    mux.float_pane_as(&Actor::Daemon, pane, FloatMode::On, Some(frame), transaction)
}

/// The list of the first screen, back to front.
fn list(mux: &Mux) -> Vec<Floating<PaneId>> {
    mux.with_state(|state| state.workspaces[0].screens[0].floating.clone())
}

/// The floating panes of the first screen, back to front.
fn floating(mux: &Mux) -> Vec<PaneId> {
    list(mux).into_iter().map(|entry| entry.pane).collect()
}

/// Every pane of the first screen's tree.
fn tree_panes(mux: &Mux) -> Vec<PaneId> {
    mux.with_state(|state| state.workspaces[0].screens[0].root.pane_ids_vec())
}

fn layout_revision(mux: &Mux) -> u64 {
    mux.with_state(|state| state.workspaces[0].screens[0].layout_revision)
}

/// The commits of the float operation that the mutation ledger of the store holds.
fn float_commits(mux: &Mux) -> i64 {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT COUNT(*) FROM resource_mutations WHERE operation = 'pane.float'",
            [],
            |row| row.get::<_, i64>(0),
        )?)
    })
    .unwrap()
}

/// The two events of a float among `events`, in the order of `events`: the change of `screen` and the layout
/// change of `screen`.
fn float_events(events: &[MuxEvent], screen: ScreenId) -> Vec<&'static str> {
    events
        .iter()
        .filter_map(|event| match event {
            MuxEvent::TreeDelta(delta)
                if delta.kind == TreeDeltaKind::ScreenChanged && delta.screen == Some(screen) =>
            {
                Some("screen change")
            }
            MuxEvent::LayoutChanged(changed, _) if *changed == screen => Some("layout change"),
            _ => None,
        })
        .collect()
}

/// The rules every act keeps: the list of the screen is the list the rules give for the panes of the tree, and
/// one pane of the tree is tiled.
fn assert_rules(mux: &Mux, context: &str) {
    let panes = tree_panes(mux);
    let list = list(mux);
    assert!(is_normal(&panes, &list), "{context}: {list:?} is not a list of {panes:?}");
    assert!(list.len() < panes.len(), "{context}: no tiled pane is left in {panes:?}");
}

#[test]
fn floating_pane_floats_and_goes_back() {
    let (mux, panes) = mux_with_panes(3);
    assert!(list(&mux).is_empty(), "a new pane is tiled");

    let outcome = float(&mux, panes[1], FloatMode::Toggle).unwrap();
    assert_eq!(outcome.frame, Some(CENTERED), "a new floating pane is centered");
    assert!(outcome.changed);
    assert_eq!(list(&mux), vec![Floating { pane: panes[1], frame: CENTERED }]);
    assert_eq!(tree_panes(&mux).len(), 3, "the floating pane stays a pane of the tree");
    assert_rules(&mux, "after the float");

    let outcome = float(&mux, panes[1], FloatMode::Toggle).unwrap();
    assert_eq!(outcome.frame, None, "a tiled pane has no frame");
    assert!(outcome.changed);
    assert!(list(&mux).is_empty());
    assert_eq!(tree_panes(&mux).len(), 3);
}

#[test]
fn floating_pane_refuses_the_last_tiled_pane_and_an_unknown_pane() {
    let (mux, panes) = mux_with_panes(2);
    float(&mux, panes[0], FloatMode::On).unwrap();
    assert_eq!(float(&mux, panes[1], FloatMode::On), Err(FloatPaneError::LastTiledPane));
    assert_eq!(floating(&mux), vec![panes[0]]);
    assert_rules(&mux, "after the refusal");

    let unknown: PaneId = 987_654;
    assert_eq!(
        float(&mux, unknown, FloatMode::Toggle),
        Err(FloatPaneError::PaneNotFound { pane: unknown })
    );

    let (alone, panes) = mux_with_panes(1);
    assert_eq!(float(&alone, panes[0], FloatMode::Toggle), Err(FloatPaneError::LastTiledPane));
    assert!(list(&alone).is_empty());
}

#[test]
fn floating_pane_refuses_a_pane_of_a_docked_column() {
    let (mux, panes) = mux_with_panes(3);
    let dock = ColumnDock::new(DockEdge::Right, DockMode::Docked);
    mux.set_column_dock(panes[2], Some(dock), None).unwrap();
    assert_eq!(float(&mux, panes[2], FloatMode::On), Err(FloatPaneError::FixedPane));
    assert!(list(&mux).is_empty());

    // A pane of a column that is not docked floats.
    float(&mux, panes[0], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[0]]);
}

#[test]
fn floating_pane_frame_moves_and_raises() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[0], FloatMode::On).unwrap();
    float(&mux, panes[1], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[0], panes[1]], "the last float is the front pane");

    // A frame that reaches past the screen is moved into it; the pane comes to the front.
    let past = FloatFrame { x: 900_000, y: 900_000, w: 500_000, h: 500_000 };
    let outcome = float_at(&mux, panes[0], past, None).unwrap();
    assert_eq!(outcome.frame, Some(FloatFrame { x: 500_000, y: 500_000, w: 500_000, h: 500_000 }));
    assert_eq!(floating(&mux), vec![panes[1], panes[0]]);

    // A frame below the smallest size takes the smallest size.
    let small = FloatFrame { x: 100_000, y: 100_000, w: 10_000, h: 10_000 };
    let outcome = float_at(&mux, panes[1], small, None).unwrap();
    let smallest = FloatFrame { x: 100_000, y: 100_000, w: 150_000, h: 150_000 };
    assert_eq!(outcome.frame, Some(smallest));
    assert_eq!(list(&mux).last(), Some(&Floating { pane: panes[1], frame: smallest }));
    assert_eq!(floating(&mux), vec![panes[0], panes[1]]);
    assert_rules(&mux, "after two frames");
}

#[test]
fn floating_pane_focus_brings_it_to_the_front() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[0], FloatMode::On).unwrap();
    float(&mux, panes[1], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[0], panes[1]]);

    assert!(mux.focus_pane(panes[0]));
    assert_eq!(floating(&mux), vec![panes[1], panes[0]]);
    assert_rules(&mux, "after the focus");

    // A focus of a tiled pane keeps the list.
    assert!(mux.focus_pane(panes[2]));
    assert_eq!(floating(&mux), vec![panes[1], panes[0]]);
}

#[test]
fn floating_pane_undo_layout_puts_the_pane_back() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[1], FloatMode::On).unwrap();
    // One drag: three frames with one transaction are one undo entry.
    for step in [50_000, 100_000, 150_000] {
        let frame = FloatFrame { x: step, y: step, w: 400_000, h: 400_000 };
        float_at(&mux, panes[1], frame, Some(77)).unwrap();
    }
    let dragged = FloatFrame { x: 150_000, y: 150_000, w: 400_000, h: 400_000 };
    assert_eq!(list(&mux), vec![Floating { pane: panes[1], frame: dragged }]);

    let undone = mux.undo_layout(panes[1], None, false).unwrap();
    assert!(matches!(undone, LayoutUndoResult::Undone { .. }), "{undone:?}");
    assert_eq!(
        list(&mux),
        vec![Floating { pane: panes[1], frame: CENTERED }],
        "the drag is undone, the float stays"
    );

    let undone = mux.undo_layout(panes[1], None, false).unwrap();
    assert!(matches!(undone, LayoutUndoResult::Undone { .. }), "{undone:?}");
    assert!(list(&mux).is_empty(), "the float is undone");
    assert_eq!(tree_panes(&mux).len(), 3);
}

#[test]
fn floating_pane_becomes_tiled_when_the_last_tiled_pane_closes() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[0], FloatMode::On).unwrap();
    float(&mux, panes[1], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[0], panes[1]]);

    assert!(mux.close_pane(panes[2]).unwrap());
    assert_eq!(tree_panes(&mux).len(), 2);
    assert_eq!(floating(&mux), vec![panes[0]], "the front floating pane becomes tiled");
    assert_rules(&mux, "after the last tiled pane closed");

    // A floating pane that closes leaves the list.
    assert!(mux.close_pane(panes[0]).unwrap());
    assert!(list(&mux).is_empty());
    assert_eq!(tree_panes(&mux), vec![panes[1]]);
}

#[test]
fn floating_pane_repeated_request_commits_nothing() {
    let (mux, panes) = mux_with_panes(2);
    let frame = FloatFrame { x: 250_000, y: 250_000, w: 500_000, h: 500_000 };
    let first = float_at(&mux, panes[0], frame, None).unwrap();
    assert!(first.changed);
    assert_eq!(list(&mux), vec![Floating { pane: panes[0], frame }]);
    let revision = layout_revision(&mux);
    assert_eq!(float_commits(&mux), 1, "the first request is one commit of the store");
    let events = mux.subscribe();

    let again = float_at(&mux, panes[0], frame, None).unwrap();
    assert!(!again.changed, "the same frame again changes nothing");
    assert_eq!(again.frame, Some(frame));
    let off = float(&mux, panes[1], FloatMode::Off).unwrap();
    assert!(!off.changed, "a tiled pane stays tiled");
    assert_eq!(off.frame, None);
    assert_eq!(layout_revision(&mux), revision, "no change, no layout revision");
    assert_eq!(float_commits(&mux), 1, "no change, no commit of the store");
    let events = events.try_iter().collect::<Vec<_>>();
    assert!(float_events(&events, first.screen).is_empty(), "no change, no event: {events:?}");

    // The newest entry of the layout history is the first request: one undo puts the pane back.
    let undone = mux.undo_layout(panes[0], None, false).unwrap();
    assert!(matches!(undone, LayoutUndoResult::Undone { .. }), "{undone:?}");
    assert!(list(&mux).is_empty(), "the undo goes to the state before the first request");
}

#[test]
fn floating_pane_change_emits_a_screen_change_and_a_layout_change() {
    let (mux, panes) = mux_with_panes(2);
    let events = mux.subscribe();
    let outcome = float_at(&mux, panes[1], CENTERED, Some(5)).unwrap();
    assert_eq!(floating(&mux), vec![panes[1]]);

    let events = events.try_iter().collect::<Vec<_>>();
    assert_eq!(
        float_events(&events, outcome.screen),
        ["screen change", "layout change"],
        "one event of each kind, the screen change first"
    );
    let delta = events
        .iter()
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::ScreenChanged => Some(delta),
            _ => None,
        })
        .expect("a float emits a screen change");
    assert_eq!(delta.transaction.as_deref(), Some("5"), "the change carries the transaction");
}

/// A fixed sequence of acts from a small generator: after each act the list obeys the rules, and each act did
/// what it says.
#[test]
fn floating_pane_sequence_of_acts_keeps_the_rules() {
    let (mux, mut panes) = mux_with_panes(3);
    let mut seed: u64 = 0x5EED_F10A;
    let mut next = |bound: u64| {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) % bound
    };
    let mut floats = 0;
    for step in 0..160 {
        let pane = panes[next(panes.len() as u64) as usize];
        let act = next(8);
        let context = format!("step {step}, act {act}, pane {pane}");
        match act {
            0 | 1 => {
                let floated = floating(&mux).contains(&pane);
                match float(&mux, pane, FloatMode::Toggle) {
                    Ok(_) => {
                        assert_eq!(floating(&mux).contains(&pane), !floated, "{context}");
                        floats += usize::from(!floated);
                    }
                    Err(error) => {
                        assert_eq!(error, FloatPaneError::LastTiledPane, "{context}");
                        assert!(!floated, "{context}: a floating pane always goes back");
                    }
                }
            }
            2 | 3 => {
                // Twentieths of the pane area, in millionths.
                let x = (next(21) * 50_000) as u32;
                let y = (next(21) * 50_000) as u32;
                let w = (next(21) * 50_000) as u32;
                let h = (next(21) * 50_000) as u32;
                let transaction = Some(next(3));
                match float_at(&mux, pane, FloatFrame { x, y, w, h }, transaction) {
                    Ok(_) => {
                        assert_eq!(floating(&mux).last(), Some(&pane), "{context}");
                        floats += 1;
                    }
                    Err(error) => assert_eq!(error, FloatPaneError::LastTiledPane, "{context}"),
                }
            }
            4 => {
                float(&mux, pane, FloatMode::Off).unwrap();
                assert!(!floating(&mux).contains(&pane), "{context}");
            }
            5 => {
                let floated = floating(&mux).contains(&pane);
                assert!(mux.focus_pane(pane), "{context}");
                if floated {
                    assert_eq!(floating(&mux).last(), Some(&pane), "{context}");
                }
            }
            6 if panes.len() > 1 => {
                assert!(mux.close_pane(pane).unwrap(), "{context}");
                panes.retain(|other| *other != pane);
                assert!(!floating(&mux).contains(&pane), "{context}");
            }
            _ if panes.len() < 6 => {
                let added = pane_right_of(&mux, pane);
                panes.push(added);
                assert!(!floating(&mux).contains(&added), "{context}: a new pane is tiled");
            }
            _ => {}
        }
        assert_rules(&mux, &context);
    }
    assert!(floats > 0, "the sequence floated a pane");
}
