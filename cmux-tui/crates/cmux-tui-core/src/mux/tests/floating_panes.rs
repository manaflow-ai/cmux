//! Durability of floating panes (`floating-panes-v1`): the list survives a
//! daemon restart through `resource_floating_panes`, with its order and its
//! frames, and load applies the rules of the list to what the table holds.

use cmux_layout_reducer::floating_panes::{FloatFrame, FloatMode, Floating};

use super::*;
use crate::workspace_registry::RegistryRow;
use std::path::PathBuf;

mod acts;
mod follow;
mod load;

fn open_restart_mux(root: &Path, session: &str) -> Arc<Mux> {
    Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        WorkspaceRegistry::open(root, session).unwrap(),
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

/// Seeds the restore fixture with its first screen changed by `edit`.
fn seed(name: &str, edit: impl FnOnce(&mut RegistryScreen)) -> (PathBuf, String) {
    seed_screens(name, |screens| {
        let first = restore_screen_id(1);
        edit(screens.iter_mut().find(|screen| screen.public_id == first).unwrap());
    })
}

/// Seeds the restore fixture with its screens changed by `edit`.
fn seed_screens(name: &str, edit: impl FnOnce(&mut [RegistryScreen])) -> (PathBuf, String) {
    let root = std::env::temp_dir()
        .join(format!("cmux-floating-{name}-{}", WorkspacePublicId::random().unwrap()));
    let session = format!("floating-{name}");
    let (fixture_snapshot, mut fixture_topology) = resource_restore_fixture();
    edit(fixture_topology.screens.as_mut_slice());
    let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon(format!("seed-floating-{name}"), "test").unwrap(),
            "session.restore_fixture",
            &serde_json::json!({"fixture":"floating"}),
            None,
            Some(0),
            &resource_restore_patch(&fixture_snapshot, &fixture_topology),
            &serde_json::json!({"restored":true}),
            &serde_json::json!([{"event":"session.restored"}]),
        )
        .unwrap();
    (root, session)
}

/// The stored list of the fixture's first screen.
fn stored_list(root: &Path, session: &str) -> Vec<Floating<PanePublicId>> {
    stored_list_in(&WorkspaceRegistry::open(root, session).unwrap())
}

/// The stored list of the fixture's first screen, read from the store of a mux that runs.
fn stored_list_of(mux: &Mux) -> Vec<Floating<PanePublicId>> {
    stored_list_in(&mux.workspace_registry.lock().unwrap())
}

fn stored_list_in(registry: &WorkspaceRegistry) -> Vec<Floating<PanePublicId>> {
    let topology = registry.resource_topology_snapshot().unwrap();
    topology
        .screens
        .into_iter()
        .find(|screen| screen.public_id == restore_screen_id(1))
        .unwrap()
        .floating
}

/// The live list of the first screen, by the public ids of its panes.
fn live_list(mux: &Mux) -> Vec<Floating<PanePublicId>> {
    mux.with_state(|state| {
        state.workspaces[0].screens[0]
            .floating
            .iter()
            .map(|entry| Floating {
                pane: state.panes[&entry.pane].public_id.clone(),
                frame: entry.frame,
            })
            .collect()
    })
}

/// The live list of the screen `screen`, by the public ids of its panes, and the rows of each of its columns.
fn live_screen(mux: &Mux, screen: &ScreenPublicId) -> (Vec<Floating<PanePublicId>>, Vec<usize>) {
    mux.with_state(|state| {
        let screen = state
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .find(|item| item.public_id == *screen)
            .unwrap();
        let list = screen
            .floating
            .iter()
            .map(|entry| Floating {
                pane: state.panes[&entry.pane].public_id.clone(),
                frame: entry.frame,
            })
            .collect::<Vec<_>>();
        let rows = screen.layout_columns.iter().map(|column| column.rows.len()).collect::<Vec<_>>();
        (list, rows)
    })
}

fn live_pane(mux: &Mux, public_id: &PanePublicId) -> PaneId {
    mux.with_state(|state| {
        state.panes.values().find(|pane| pane.public_id == *public_id).map(|pane| pane.id).unwrap()
    })
}

#[test]
fn floating_panes_persist_across_restart() {
    let (root, session) = seed("restart", |_| {});
    // The fixture's first screen: a stack of panes 1 and 2 above pane 3 in one column, pane 4 in the next.
    let right = restore_pane_id(4);
    let low = restore_pane_id(3);
    let moved = FloatFrame { x: 100_000, y: 200_000, w: 400_000, h: 500_000 };
    let centered = FloatFrame { x: 200_000, y: 200_000, w: 600_000, h: 600_000 };
    let expected = vec![
        Floating { pane: right.clone(), frame: moved },
        Floating { pane: low.clone(), frame: centered },
    ];
    assert!(stored_list(&root, &session).is_empty(), "the fixture has no floating pane");

    let mux = open_restart_mux(&root, &session);
    assert!(live_list(&mux).is_empty());
    let outcome = mux
        .float_pane_as(&Actor::Daemon, live_pane(&mux, &right), FloatMode::On, Some(moved), None)
        .unwrap();
    assert_eq!(outcome.frame, Some(moved));
    assert!(outcome.changed);
    let outcome = mux
        .float_pane_as(&Actor::Daemon, live_pane(&mux, &low), FloatMode::Toggle, None, None)
        .unwrap();
    assert_eq!(outcome.frame, Some(centered));
    assert_eq!(live_list(&mux), expected);
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_list(&root, &session), expected, "the store keeps the order and the frames");

    let mux = open_restart_mux(&root, &session);
    assert_eq!(live_list(&mux), expected, "a restart keeps the order and the frames");
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.root.pane_ids_vec().len(), 4, "a floating pane stays a pane of the tree");
    });
    // Putting the front pane back is durable too.
    let outcome = mux
        .float_pane_as(&Actor::Daemon, live_pane(&mux, &low), FloatMode::Off, None, None)
        .unwrap();
    assert_eq!(outcome.frame, None);
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_list(&root, &session), expected[..1].to_vec());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn floating_pane_records_load_by_the_rules() {
    let right = restore_pane_id(4);
    let low = restore_pane_id(3);
    let (root, session) = seed("rules", |screen| {
        screen.floating = vec![
            // A pane that is not a pane of this screen: an older build closed it.
            Floating { pane: restore_pane_id(77), frame: FloatFrame::centered(600_000, 600_000) },
            // A frame that reaches past the screen and is too small.
            Floating {
                pane: low.clone(),
                frame: FloatFrame { x: 950_000, y: 0, w: 10, h: 400_000 },
            },
            Floating { pane: right.clone(), frame: FloatFrame::centered(500_000, 500_000) },
            // A second entry of one pane: the table has one record for each pane, so it is not written.
            Floating { pane: low.clone(), frame: FloatFrame::centered(300_000, 300_000) },
        ];
    });
    let expected = vec![
        Floating { pane: low, frame: FloatFrame { x: 850_000, y: 0, w: 150_000, h: 400_000 } },
        Floating {
            pane: right,
            frame: FloatFrame { x: 250_000, y: 250_000, w: 500_000, h: 500_000 },
        },
    ];
    assert_eq!(stored_list(&root, &session), expected);

    let mux = open_restart_mux(&root, &session);
    assert_eq!(live_list(&mux), expected);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// The store has the list of the live screen after each act that changes the list with no float request: a
/// focus that brings a floating pane to the front, and a close of a pane.
#[test]
fn floating_panes_in_the_store_follow_a_focus_and_a_close() {
    let (root, session) = seed("follow", |_| {});
    let [one, two, low, right] = [1, 2, 3, 4].map(restore_pane_id);
    let order = |list: &[Floating<PanePublicId>]| {
        list.iter().map(|entry| entry.pane.clone()).collect::<Vec<_>>()
    };

    let mux = open_restart_mux(&root, &session);
    for pane in [&right, &low] {
        mux.float_pane_as(&Actor::Daemon, live_pane(&mux, pane), FloatMode::On, None, None)
            .unwrap();
    }
    assert_eq!(order(&live_list(&mux)), [right.clone(), low.clone()]);
    assert_eq!(stored_list_of(&mux), live_list(&mux), "after the two floats");

    // The focus goes to a tiled pane, then to the floating pane behind: that pane comes to the front.
    assert!(mux.focus_pane(live_pane(&mux, &one)));
    assert!(mux.focus_pane(live_pane(&mux, &right)));
    assert_eq!(order(&live_list(&mux)), [low.clone(), right.clone()]);
    assert_eq!(stored_list_of(&mux), live_list(&mux), "after the focus");

    // A tiled pane closes: the list stays.
    assert!(mux.close_pane(live_pane(&mux, &two)).unwrap());
    assert_eq!(order(&live_list(&mux)), [low.clone(), right.clone()]);
    assert_eq!(stored_list_of(&mux), live_list(&mux), "after the close of a tiled pane");

    // The front floating pane closes: it leaves the list.
    assert!(mux.close_pane(live_pane(&mux, &right)).unwrap());
    let expected = live_list(&mux);
    assert_eq!(order(&expected), [low]);
    assert_eq!(stored_list_of(&mux), expected, "after the close of a floating pane");
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_list(&root, &session), expected, "the store at rest");
    let mux = open_restart_mux(&root, &session);
    assert_eq!(live_list(&mux), expected, "a restart loads the same list");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A pane of a column with rows never floats. A pane of another column of the same screen floats.
#[test]
fn floating_pane_refuses_a_pane_of_a_column_with_rows() {
    let (root, session) = seed("rows", |screen| {
        // The first column: the stack of panes 1 and 2 in the first row, pane 3 in the second row. The heights
        // agree with the ratio 0.6 of the fixture's row split, as each record that the product writes does.
        screen.viewport.columns[0].rows = vec![
            RegistryRow { id: restore_split_id(9), height: 600 },
            RegistryRow { id: restore_split_id(1), height: 400 },
        ];
    });
    let mux = open_restart_mux(&root, &session);
    mux.with_state(|state| {
        let rows = state.workspaces[0].screens[0].layout_columns[0].rows.len();
        assert_eq!(rows, 2, "the first column has its two rows");
    });
    let low = live_pane(&mux, &restore_pane_id(3));
    assert_eq!(
        mux.float_pane_as(&Actor::Daemon, low, FloatMode::On, None, None),
        Err(FloatPaneError::FixedPane)
    );
    assert!(live_list(&mux).is_empty());

    let right = live_pane(&mux, &restore_pane_id(4));
    mux.float_pane_as(&Actor::Daemon, right, FloatMode::On, None, None).unwrap();
    assert_eq!(live_list(&mux).len(), 1);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A member of a stack never floats. A pane of the same column that is not in the stack floats.
#[test]
fn floating_pane_refuses_a_member_of_a_stack() {
    let (root, session) = seed("stack", |_| {});
    let mux = open_restart_mux(&root, &session);
    // The first column has no rows and no dock: the stack of panes 1 and 2 is above pane 3 in one split.
    for member in [1, 2].map(restore_pane_id) {
        let pane = live_pane(&mux, &member);
        assert_eq!(
            mux.float_pane_as(&Actor::Daemon, pane, FloatMode::On, None, None),
            Err(FloatPaneError::FixedPane),
            "{member}"
        );
    }
    assert!(live_list(&mux).is_empty());

    let low = live_pane(&mux, &restore_pane_id(3));
    mux.float_pane_as(&Actor::Daemon, low, FloatMode::On, None, None).unwrap();
    assert_eq!(live_list(&mux).len(), 1);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// The rows of the second column of the first screen.
fn second_column_rows(mux: &Mux) -> usize {
    mux.with_state(|state| state.workspaces[0].screens[0].layout_columns[1].rows.len())
}

/// The path of a person: `new-row` makes the rows of a column, then a pane of the other column floats, and a
/// restart keeps the rows and the list.
#[test]
fn floating_pane_floats_beside_rows_that_new_row_made() {
    let (root, session) = seed("new-row", |_| {});
    let mux = open_restart_mux(&root, &session);
    // The second column gets its second row from the act of the product.
    let right = live_pane(&mux, &restore_pane_id(4));
    mux.new_row_with_options(right, 500, Default::default(), Some((38, 10)), None).unwrap();
    assert_eq!(second_column_rows(&mux), 2, "the second column has its two rows");
    assert_eq!(
        mux.float_pane_as(&Actor::Daemon, right, FloatMode::On, None, None),
        Err(FloatPaneError::FixedPane)
    );
    assert!(live_list(&mux).is_empty());

    // Pane 3 is a pane of the first column, which has no rows.
    let low = live_pane(&mux, &restore_pane_id(3));
    mux.float_pane_as(&Actor::Daemon, low, FloatMode::On, None, None).unwrap();
    let expected = live_list(&mux);
    assert_eq!(expected.len(), 1);
    assert_eq!(stored_list_of(&mux), expected, "after the float");
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_list(&root, &session), expected, "the store at rest");
    let mux = open_restart_mux(&root, &session);
    assert_eq!(second_column_rows(&mux), 2, "a restart keeps the rows");
    assert_eq!(live_list(&mux), expected, "a restart keeps the list");
    // The screen that the restart loaded takes a float request: the pane goes back into the tiled panes.
    let low = live_pane(&mux, &restore_pane_id(3));
    mux.float_pane_as(&Actor::Daemon, low, FloatMode::Off, None, None).unwrap();
    assert!(live_list(&mux).is_empty(), "the request after the restart commits");
    assert_eq!(second_column_rows(&mux), 2, "the rows stay");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
