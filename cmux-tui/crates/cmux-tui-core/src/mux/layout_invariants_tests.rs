//! Checker unit tests and property tests for the layout invariants.
//!
//! The property test drives random sequences of layout operations through
//! the public `Mux` entry points on small layouts and checks I1-I4 after
//! every step, plus idempotent replay (invariant 5 in
//! plans/cmux-next/OWNERSHIP-PRINCIPLES.md: an op replayed with the same key
//! has no further effect) and agreement between the durable resource
//! topology and memory. `PROPTEST_CASES` sets the number of sequences
//! (default 64).

use std::collections::BTreeMap;

use super::*;
use crate::mux::{LayoutUndoResult, Mux, ScreenDestination, TabDropEdge, TabGroupDestination};
use crate::resource::ResourceOperation;
use crate::resource_mutation::ResourceMutationPlan;
use crate::workspace_registry::{ResourcePatch, WorkspaceMutation};
use crate::{PaneId, SplitDir, SurfaceId, SurfaceOptions};
use cmux_layout_reducer::{LayoutOpKind, check_state, introduced_violations};
use proptest::prelude::*;

fn test_mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, SurfaceOptions::default())
}

fn pane_of(mux: &Mux, surface: SurfaceId) -> PaneId {
    mux.with_state(|state| state.pane_of(surface)).unwrap()
}

/// Two panes on one screen: the first with two tabs, the second with one.
fn two_pane_mux(name: &str) -> (Arc<Mux>, [SurfaceId; 3]) {
    let mux = test_mux(name);
    let first = mux.new_workspace(None, None).unwrap().id;
    let origin = pane_of(&mux, first);
    let second = mux.new_tab(Some(origin), None, None).unwrap().id;
    let third = mux.split(origin, SplitDir::Right, None).unwrap().id;
    (mux, [first, second, third])
}

#[test]
fn projection_is_valid_and_transitions_are_checked_against_the_reducer() {
    let (mux, [first, second, third]) = two_pane_mux("layout-invariants-projection");
    let state = mux.with_state(Clone::clone);
    let model = project(&state);
    assert!(check_state(&model).is_empty(), "{:?}", check_state(&model));
    assert_eq!(model.tabs.len(), 3);
    let origin = pane_of(&mux, first);
    let other = pane_of(&mux, third);

    // A live move that matches the reducer passes.
    let mut moved = state.clone();
    moved.panes.get_mut(&origin).unwrap().tabs.retain(|tab| *tab != second);
    moved.panes.get_mut(&other).unwrap().tabs.insert(0, second);
    let reduce = |kind| model_result("tab.move", &model, &kind);
    let agreeing = reduce(LayoutOpKind::MoveTab { tab: second, pane: other, index: 0 }).unwrap();
    assert!(transition_problems(&model, Some(&agreeing), &moved).is_empty());
    // The same live result for another index disagrees with the reducer.
    let disagreeing = reduce(LayoutOpKind::MoveTab { tab: second, pane: other, index: 1 }).unwrap();
    let problems = transition_problems(&model, Some(&disagreeing), &moved);
    assert!(problems.iter().any(|problem| problem.contains("disagrees")), "{problems:?}");
    // A reducer rejection rejects the operation with the reason code.
    let error = reduce(LayoutOpKind::MoveTabToSplit {
        tab: third,
        pane: other,
        edge: cmux_layout_reducer::Edge::Left,
        new_pane: u64::MAX,
        respawn: None,
    })
    .unwrap_err();
    let error = error.downcast_ref::<ResourceError>().unwrap();
    assert_eq!(error.details["extra"]["reason_code"], LAYOUT_CONSERVATION_VIOLATION);
    assert!(error.message.contains("rejects"), "{}", error.message);

    // A live result that drops a tab from its pane breaks I2, and one that
    // also drops its runtime breaks I1.
    let mut lost = state.clone();
    lost.panes.get_mut(&origin).unwrap().tabs.retain(|tab| *tab != second);
    let problems = transition_problems(&model, None, &lost);
    assert_eq!(problems, vec![format!("tab {second} has no pane")]);
    lost.surfaces.remove(&second);
    let problems = transition_problems(&model, None, &lost);
    assert_eq!(problems, vec![format!("tab {second} was lost")]);
    // Swapping the runtimes behind two tabs changes their content (I1).
    let mut swapped = state;
    let a = swapped.surfaces[&first].clone();
    let b = swapped.surfaces[&third].clone();
    swapped.surfaces.insert(first, b);
    swapped.surfaces.insert(third, a);
    let problems = transition_problems(&model, None, &swapped);
    assert!(problems.contains(&format!("tab {first} changed its content")), "{problems:?}");
}

#[test]
fn daemon_rejects_a_tab_conserving_plan_that_loses_a_tab_before_commit() {
    let (mux, [first, second, _]) = two_pane_mux("layout-invariants-reject");
    let origin = pane_of(&mux, first);
    let before = mux.with_state(fingerprint);
    let durable = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let error = mux
        .commit_resource_mutation_plan(
            &WorkspaceMutation::local("layout-invariants-test"),
            "tab.move",
            &json!({"operation":"tab.move","test":"drop"}),
            None,
            None,
            |_, _| {
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: Vec::new() },
                    json!({}),
                    json!([]),
                    move |state| {
                        state.panes.get_mut(&origin).unwrap().tabs.retain(|tab| *tab != second);
                    },
                ))
            },
        )
        .unwrap_err();
    let error = error.downcast_ref::<ResourceError>().expect("resource error");
    assert_eq!(error.code, "operation.failed");
    assert_eq!(error.details["extra"]["reason_code"], LAYOUT_CONSERVATION_VIOLATION);
    assert!(error.message.contains(&format!("tab {second} has no pane")), "{}", error.message);
    assert_eq!(mux.with_state(fingerprint), before);
    let after = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    assert_eq!(after.revision, durable.revision);

    // The same plan under a close operation is not a conservation check.
    assert!(!conserves_tabs("tab.close"));
}

#[test]
fn own_position_moves_are_no_ops_or_rejections() {
    let (mux, [first, second, third]) = two_pane_mux("layout-invariants-own-position");
    let origin = pane_of(&mux, first);
    let lone = pane_of(&mux, third);
    let before = mux.with_state(fingerprint);
    // Same pane, same final index: both insertion indexes around the tab.
    assert!(!mux.move_tab(second, origin, 1));
    assert!(!mux.move_tab(second, origin, 2));
    assert!(!mux.move_tab(second, origin, usize::MAX));
    assert_eq!(mux.move_tab_with_undo(first, origin, 0, None), (false, false));
    // Split of its own pane when it is the only tab.
    for edge in [TabDropEdge::Left, TabDropEdge::Right, TabDropEdge::Top, TabDropEdge::Bottom] {
        assert!(mux.move_tab_to_split(third, lone, edge, None, None).is_err());
    }
    assert_eq!(mux.with_state(fingerprint), before);
}

/// The terminal registry move (`move-terminal`) carries a terminal's view
/// into the destination workspace. The resource topology must follow in the
/// same step: a stale durable placement reverts the move on restore, and
/// later moves plan their durable patch from it.
#[test]
fn terminal_registry_move_keeps_durable_topology_in_step() {
    let mux = test_mux("layout-invariants-terminal-move");
    let first = mux.new_workspace(None, None).unwrap().id;
    let origin = pane_of(&mux, first);
    let moved = mux.new_tab(Some(origin), None, None).unwrap().id;
    let torn = mux.move_tab_to_new_workspace(moved, None, None, None).unwrap();
    assert_ne!(pane_of(&mux, moved), origin);
    assert_durable_matches_memory(&mux);

    let (tab_id, home_key) = mux.with_state(|state| {
        (state.resource_indexes.tab_ids[&moved].clone(), state.workspaces[0].key.clone())
    });
    let host = mux
        .workspace_registry
        .lock()
        .unwrap()
        .resource_topology_snapshot()
        .unwrap()
        .tabs
        .into_iter()
        .find(|tab| tab.public_id == tab_id)
        .and_then(|tab| tab.terminal_id)
        .unwrap();
    let before = mux.with_state(Clone::clone);
    mux.move_terminal_with_mutation(
        &host,
        &home_key,
        None,
        None,
        None,
        &WorkspaceMutation::local("layout-invariants-test"),
    )
    .unwrap();
    // The view followed its terminal home, and the torn-off workspace's
    // emptied pane collapsed.
    assert_eq!(pane_of(&mux, moved), origin);
    assert!(mux.with_state(|state| {
        state.workspace_by_id(torn).is_none_or(|workspace| workspace.screens.is_empty())
    }));
    let after = mux.with_state(Clone::clone);
    assert!(transition_problems(&project(&before), None, &after).is_empty());
    assert_durable_matches_memory(&mux);

    // A later move of the same tab plans from the durable topology.
    assert!(mux.move_tab(moved, origin, 0));
    assert_durable_matches_memory(&mux);
}

/// Undo of a cross-pane tab move puts the tab back in its origin pane. When
/// the pane it moved into has meanwhile lost every other tab, putting it
/// back must not leave that pane empty in the layout (I3).
#[test]
fn undo_of_a_tab_move_never_leaves_an_empty_pane() {
    let (mux, [first, second, third]) = two_pane_mux("layout-invariants-undo-empty");
    let origin = pane_of(&mux, first);
    let other = pane_of(&mux, third);
    assert_eq!(mux.move_tab_with_undo(second, other, 1, None), (true, true));
    // The pane's own tab leaves; only the moved tab remains there.
    assert!(mux.move_tab(third, origin, 0));
    assert_eq!(mux.with_state(|state| state.panes[&other].tabs.clone()), vec![second]);
    let before = mux.with_state(Clone::clone);
    let undone = mux.undo_layout(origin, None, false);
    let after = mux.with_state(Clone::clone);
    let violations = check_state(&project(&after));
    assert!(violations.is_empty(), "undo ({undone:?}) broke the layout: {violations:?}");
    assert!(transition_problems(&project(&before), None, &after).is_empty());
    assert_durable_matches_memory(&mux);
}

/// A tab-conserving operation runs its state change before the durable
/// commit. When that commit fails, the previous state comes back exactly and
/// no subscriber sees the tab's new session path, for a closure plan
/// (`tab.move`) and for a plan that hands over a projected state
/// (`tab.drag`).
#[test]
fn failed_commit_after_staging_restores_the_state_and_holds_back_session_paths() {
    let (mux, [first, second, third]) = two_pane_mux("layout-invariants-failed-commit");
    let origin = pane_of(&mux, first);
    let other = pane_of(&mux, third);
    let session = mux.subscribe_surface_session(second).unwrap();
    while session.try_recv().is_ok() {}
    let before = mux.with_state(fingerprint);
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    assert!(!mux.move_tab(second, other, 0));
    assert_eq!(mux.with_state(fingerprint), before);
    assert!(mux.move_tab_to_split(second, origin, TabDropEdge::Right, None, None).is_err());
    assert_eq!(mux.with_state(fingerprint), before);
    assert!(session.try_recv().is_err(), "a failed commit published a session path");
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    assert!(mux.move_tab(second, other, 0));
    assert_durable_matches_memory(&mux);
}

/// Everything observable about the layout, for "unchanged" assertions.
fn fingerprint(state: &State) -> String {
    let workspaces = state
        .workspaces
        .iter()
        .map(|workspace| {
            (
                workspace.id,
                workspace.active_screen,
                workspace
                    .screens
                    .iter()
                    .map(|screen| {
                        (
                            screen.id,
                            screen.layout_revision,
                            format!("{:?}", screen.layout_snapshot()),
                            screen.layout_undo.len(),
                        )
                    })
                    .collect::<Vec<_>>(),
            )
        })
        .collect::<Vec<_>>();
    let mut panes = state
        .panes
        .values()
        .map(|pane| (pane.id, pane.tabs.clone(), pane.active_tab))
        .collect::<Vec<_>>();
    panes.sort_unstable();
    let mut surfaces = state.surfaces.keys().copied().collect::<Vec<_>>();
    surfaces.sort_unstable();
    format!("{:?}", (state.resource_revision, state.active_workspace, workspaces, panes, surfaces))
}

/// The durable topology places every live tab in the pane memory places it.
fn assert_durable_matches_memory(mux: &Mux) {
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    mux.with_state(|state| {
        let memory = state
            .panes
            .values()
            .flat_map(|pane| {
                pane.tabs.iter().map(|surface| {
                    (
                        state.resource_indexes.tab_ids[surface].to_string(),
                        state.resource_indexes.pane_ids[&pane.id].to_string(),
                    )
                })
            })
            .collect::<BTreeMap<_, _>>();
        let durable = topology
            .tabs
            .iter()
            .map(|tab| (tab.public_id.to_string(), tab.pane_id.to_string()))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(memory, durable, "durable tab placement differs from memory");
        let live_panes = state
            .panes
            .keys()
            .map(|pane| state.resource_indexes.pane_ids[pane].to_string())
            .collect::<BTreeSet<_>>();
        let durable_panes =
            topology.panes.iter().map(|pane| pane.public_id.to_string()).collect::<BTreeSet<_>>();
        assert_eq!(live_panes, durable_panes, "durable panes differ from memory");
    });
}

/// One random layout operation. Indexes pick among the live tabs, panes,
/// workspaces and columns modulo their count at execution time, so every
/// generated sequence stays meaningful as the layout changes.
#[derive(Debug, Clone)]
enum Op {
    MoveTab {
        tab: usize,
        pane: usize,
        index: usize,
        undoable: bool,
    },
    Reorder {
        tab: usize,
        index: usize,
    },
    OwnPosition {
        tab: usize,
        after: bool,
    },
    Split {
        tab: usize,
        pane: usize,
        edge: TabDropEdge,
        ratio: Option<f32>,
    },
    SplitOwnPane {
        tab: usize,
        edge: TabDropEdge,
    },
    Column {
        tab: usize,
        pane: usize,
        after_column: Option<usize>,
        width: Option<f32>,
    },
    NewWorkspace {
        tab: usize,
    },
    ToWorkspace {
        tab: usize,
        workspace: Option<usize>,
    },
    SwapPanes {
        pane: usize,
        target: usize,
    },
    GroupMove {
        tab: usize,
        members: usize,
        destination: GroupDestination,
    },
    ScreenMove {
        pane: usize,
        workspace: Option<usize>,
        index: Option<usize>,
    },
    MoveWorkspace {
        workspace: usize,
        index: usize,
    },
    /// `terminal.move`: move a terminal's view to a pane.
    TerminalToPane {
        tab: usize,
        pane: usize,
        index: usize,
    },
    /// The terminal registry move: the terminal's view follows its new
    /// workspace.
    TerminalToWorkspace {
        tab: usize,
        workspace: usize,
    },
    /// `tab.move` sent twice with one idempotency key (invariant 5).
    ReplayedMove {
        tab: usize,
        pane: usize,
        index: usize,
    },
    Undo {
        pane: usize,
    },
    Close {
        tab: usize,
    },
}

#[derive(Debug, Clone)]
enum GroupDestination {
    Strip { pane: usize, index: Option<usize> },
    Split { pane: usize, edge: TabDropEdge },
    Column { pane: usize },
    NewWorkspace,
}

fn edge() -> impl Strategy<Value = TabDropEdge> {
    prop_oneof![
        Just(TabDropEdge::Left),
        Just(TabDropEdge::Right),
        Just(TabDropEdge::Top),
        Just(TabDropEdge::Bottom),
    ]
}

fn insertion_index() -> impl Strategy<Value = usize> {
    prop_oneof![4 => 0..8usize, 1 => Just(usize::MAX)]
}

fn op() -> impl Strategy<Value = Op> {
    let pick = 0..64usize;
    prop_oneof![
        3 => (pick.clone(), pick.clone(), insertion_index(), any::<bool>())
            .prop_map(|(tab, pane, index, undoable)| Op::MoveTab { tab, pane, index, undoable }),
        2 => (pick.clone(), insertion_index()).prop_map(|(tab, index)| Op::Reorder { tab, index }),
        1 => (pick.clone(), any::<bool>()).prop_map(|(tab, after)| Op::OwnPosition { tab, after }),
        3 => (
            pick.clone(),
            pick.clone(),
            edge(),
            prop_oneof![Just(None), (0.0f32..1.0).prop_map(Some)],
        )
            .prop_map(|(tab, pane, edge, ratio)| Op::Split { tab, pane, edge, ratio }),
        1 => (pick.clone(), edge()).prop_map(|(tab, edge)| Op::SplitOwnPane { tab, edge }),
        2 => (
            pick.clone(),
            pick.clone(),
            prop::option::of(pick.clone()),
            prop_oneof![Just(None), (0.0f32..1.5).prop_map(Some)],
        )
            .prop_map(|(tab, pane, after_column, width)| Op::Column {
                tab,
                pane,
                after_column,
                width
            }),
        1 => pick.clone().prop_map(|tab| Op::NewWorkspace { tab }),
        2 => (pick.clone(), prop::option::of(pick.clone()))
            .prop_map(|(tab, workspace)| Op::ToWorkspace { tab, workspace }),
        1 => (pick.clone(), pick.clone()).prop_map(|(pane, target)| Op::SwapPanes { pane, target }),
        1 => (
            pick.clone(),
            1..3usize,
            prop_oneof![
                (pick.clone(), prop::option::of(0..6usize))
                    .prop_map(|(pane, index)| GroupDestination::Strip { pane, index }),
                (pick.clone(), edge()).prop_map(|(pane, edge)| GroupDestination::Split { pane, edge }),
                pick.clone().prop_map(|pane| GroupDestination::Column { pane }),
                Just(GroupDestination::NewWorkspace),
            ],
        )
            .prop_map(|(tab, members, destination)| Op::GroupMove { tab, members, destination }),
        1 => (pick.clone(), prop::option::of(pick.clone()), prop::option::of(0..3usize))
            .prop_map(|(pane, workspace, index)| Op::ScreenMove { pane, workspace, index }),
        1 => (pick.clone(), 0..4usize)
            .prop_map(|(workspace, index)| Op::MoveWorkspace { workspace, index }),
        2 => (pick.clone(), pick.clone(), insertion_index())
            .prop_map(|(tab, pane, index)| Op::TerminalToPane { tab, pane, index }),
        1 => (pick.clone(), pick.clone())
            .prop_map(|(tab, workspace)| Op::TerminalToWorkspace { tab, workspace }),
        2 => (pick.clone(), pick.clone(), insertion_index())
            .prop_map(|(tab, pane, index)| Op::ReplayedMove { tab, pane, index }),
        1 => pick.clone().prop_map(|pane| Op::Undo { pane }),
        1 => pick.prop_map(|tab| Op::Close { tab }),
    ]
}

/// Initial layout: per workspace, per pane, the number of tabs. 1-3
/// workspaces, 1-4 panes per workspace, at most 6 tabs in all.
fn layout() -> impl Strategy<Value = Vec<Vec<usize>>> {
    prop::collection::vec(prop::collection::vec(1..=3usize, 1..=4), 1..=3).prop_map(|mut layout| {
        let mut budget = 6usize;
        for panes in &mut layout {
            for tabs in panes.iter_mut() {
                *tabs = (*tabs).min(budget.max(1));
                budget = budget.saturating_sub(*tabs);
            }
        }
        layout
    })
}

fn build(mux: &Arc<Mux>, layout: &[Vec<usize>]) {
    for (workspace, panes) in layout.iter().enumerate() {
        let first = mux.new_workspace(None, None).unwrap().id;
        let mut pane = pane_of(mux, first);
        for (index, tabs) in panes.iter().enumerate() {
            if index > 0 {
                let dir =
                    if (workspace + index) % 2 == 0 { SplitDir::Right } else { SplitDir::Down };
                pane = pane_of(mux, mux.split(pane, dir, None).unwrap().id);
            }
            for _ in 1..*tabs {
                mux.new_tab(Some(pane), None, None).unwrap();
            }
        }
    }
}

/// Live handles in a stable order, for index picks.
struct Handles {
    tabs: Vec<SurfaceId>,
    panes: Vec<PaneId>,
    workspaces: Vec<crate::WorkspaceId>,
}

fn handles(mux: &Mux) -> Handles {
    mux.with_state(|state| {
        let mut tabs = Vec::new();
        let mut panes = Vec::new();
        for workspace in &state.workspaces {
            for screen in &workspace.screens {
                for pane in screen.root.pane_ids_vec() {
                    panes.push(pane);
                    if let Some(record) = state.panes.get(&pane) {
                        tabs.extend(record.tabs.iter().copied());
                    }
                }
            }
        }
        Handles {
            tabs,
            panes,
            workspaces: state.workspaces.iter().map(|workspace| workspace.id).collect(),
        }
    })
}

fn pick<T: Copy>(items: &[T], index: usize) -> Option<T> {
    (!items.is_empty()).then(|| items[index % items.len()])
}

enum Outcome {
    Accepted,
    Rejected,
    Closed(SurfaceId),
    Skipped,
}

fn accepted<T>(result: anyhow::Result<T>) -> Outcome {
    if result.is_ok() { Outcome::Accepted } else { Outcome::Rejected }
}

fn flag(changed: bool) -> Outcome {
    if changed { Outcome::Accepted } else { Outcome::Rejected }
}

/// Run `op`. A tab group move first creates its group as a separate checked
/// step, then resets `before` and `rejections` to the state after it.
fn run(
    mux: &Arc<Mux>,
    op: &Op,
    groups: &mut usize,
    before: &mut State,
    rejections: &mut usize,
) -> Outcome {
    let live = handles(mux);
    if live.tabs.is_empty() {
        return Outcome::Skipped;
    }
    let tab = |index: usize| live.tabs[index % live.tabs.len()];
    let pane_at = |index: usize| pick(&live.panes, index);
    match op.clone() {
        Op::MoveTab { tab: t, pane, index, undoable } => {
            let (surface, pane) = (tab(t), pane_at(pane).unwrap());
            if undoable {
                flag(mux.move_tab_with_undo(surface, pane, index, None).0)
            } else {
                flag(mux.move_tab(surface, pane, index))
            }
        }
        Op::Reorder { tab: t, index } => {
            let surface = tab(t);
            flag(mux.move_tab(surface, pane_of(mux, surface), index))
        }
        Op::OwnPosition { tab: t, after } => {
            let surface = tab(t);
            let pane = pane_of(mux, surface);
            let position = mux.with_state(|state| {
                state.panes[&pane].tabs.iter().position(|candidate| *candidate == surface).unwrap()
            });
            let moved = mux.move_tab(surface, pane, position + usize::from(after));
            assert!(!moved, "a move onto its own position changed the layout");
            Outcome::Rejected
        }
        Op::Split { tab: t, pane, edge, ratio } => {
            accepted(mux.move_tab_to_split(tab(t), pane_at(pane).unwrap(), edge, ratio, None))
        }
        Op::SplitOwnPane { tab: t, edge } => {
            let surface = tab(t);
            accepted(mux.move_tab_to_split(surface, pane_of(mux, surface), edge, None, None))
        }
        Op::Column { tab: t, pane, after_column, width } => {
            let pane = pane_at(pane).unwrap();
            let after_column = after_column.and_then(|index| {
                mux.with_state(|state| {
                    let (workspace, screen) = state.screen_of(pane)?;
                    let columns = &state.workspaces[workspace].screens[screen].layout_columns;
                    let ids = columns.iter().map(|column| column.id).collect::<Vec<_>>();
                    // Also exercise an unknown column id.
                    pick(&ids, index).or(Some(u64::MAX))
                })
            });
            accepted(mux.move_tab_to_column(tab(t), pane, after_column, width, None, None))
        }
        Op::NewWorkspace { tab: t } => {
            accepted(mux.move_tab_to_new_workspace(tab(t), None, None, None))
        }
        Op::ToWorkspace { tab: t, workspace } => accepted(
            mux.move_tab_to_workspace(tab(t), workspace.and_then(|w| pick(&live.workspaces, w))),
        ),
        Op::SwapPanes { pane, target } => {
            flag(mux.swap_panes(pane_at(pane).unwrap(), pane_at(target).unwrap()))
        }
        Op::GroupMove { tab: t, members, destination } => {
            let surface = tab(t);
            let pane = pane_of(mux, surface);
            let members = mux.with_state(|state| {
                let tabs = &state.panes[&pane].tabs;
                let start = tabs.iter().position(|candidate| *candidate == surface).unwrap();
                tabs[start..].iter().copied().take(members).collect::<Vec<_>>()
            });
            *groups += 1;
            let id = format!("g{groups}");
            // Creating the group is itself a tab-conserving operation; check
            // it on its own before the move.
            let created = mux.create_tab_group(&members, None, None, Some(id.clone()), None);
            check_step(mux, before, &accepted(created), *rejections);
            *before = mux.with_state(Clone::clone);
            *rejections = rejections_on_this_thread();
            let destination = match destination {
                GroupDestination::Strip { pane, index } => {
                    TabGroupDestination::Strip { pane: pane_at(pane).unwrap(), index }
                }
                GroupDestination::Split { pane, edge } => {
                    TabGroupDestination::Split { pane: pane_at(pane).unwrap(), edge, ratio: None }
                }
                GroupDestination::Column { pane } => TabGroupDestination::Column {
                    pane: pane_at(pane).unwrap(),
                    after_column: None,
                    width: None,
                },
                GroupDestination::NewWorkspace => {
                    TabGroupDestination::NewWorkspace { group: None, index: None }
                }
            };
            accepted(mux.move_tab_group(&id, destination, None))
        }
        Op::ScreenMove { pane, workspace, index } => {
            let pane = pane_at(pane).unwrap();
            let screen = mux.with_state(|state| {
                let (workspace, screen) = state.screen_of(pane).unwrap();
                state.workspaces[workspace].screens[screen].id
            });
            let destination = match workspace {
                None => ScreenDestination::NewWorkspace,
                Some(w) => {
                    ScreenDestination::Workspace { workspace: pick(&live.workspaces, w), index }
                }
            };
            accepted(mux.move_screen(screen, destination))
        }
        Op::MoveWorkspace { workspace, index } => {
            let workspace = pick(&live.workspaces, workspace).unwrap();
            flag(mux.move_workspace(workspace, index))
        }
        Op::TerminalToPane { tab: t, pane, index } => {
            let surface = tab(t);
            let Some(terminal) = mux.with_state(|state| {
                state.surfaces[&surface].terminal_public_id().map(ToString::to_string)
            }) else {
                return Outcome::Skipped;
            };
            let selectors = crate::ResourceSelectors {
                terminal: Some(terminal),
                ..Mux::ordinary_resource_selectors()
            };
            let destination = mux.resource_selectors_for_pane(pane_at(pane)).unwrap();
            accepted(mux.resource_move_terminal_selected(
                selectors,
                destination,
                index,
                None,
                &WorkspaceMutation::local("layout-invariants-test"),
            ))
        }
        Op::TerminalToWorkspace { tab: t, workspace } => {
            let surface = tab(t);
            let workspace = pick(&live.workspaces, workspace).unwrap();
            let (host, key) = mux.with_state(|state| {
                let tab_id = state.resource_indexes.tab_ids[&surface].clone();
                let key = state.workspace_by_id(workspace).unwrap().key.clone();
                (tab_id, key)
            });
            let topology =
                mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
            let Some(host) = topology
                .tabs
                .iter()
                .find(|record| record.public_id == host)
                .and_then(|record| record.terminal_id.clone())
            else {
                return Outcome::Skipped;
            };
            let before = mux.with_state(fingerprint);
            match mux.move_terminal_with_mutation(
                &host,
                &key,
                None,
                None,
                None,
                &WorkspaceMutation::local("layout-invariants-test"),
            ) {
                // An unchanged move answers Ok without a layout change.
                Ok(_) if mux.with_state(fingerprint) == before => Outcome::Rejected,
                Ok(_) => Outcome::Accepted,
                Err(_) => Outcome::Rejected,
            }
        }
        Op::ReplayedMove { tab: t, pane, index } => {
            let surface = tab(t);
            let pane = pane_at(pane).unwrap();
            let selectors = mux.ordinary_tab_selectors(surface).unwrap();
            let fields = mux.with_state(|state| {
                let (workspace, screen) = state.screen_of(pane).unwrap();
                let workspace = &state.workspaces[workspace];
                serde_json::Map::from_iter([
                    ("destination_workspace".into(), json!(workspace.public_id.to_string())),
                    (
                        "destination_screen".into(),
                        json!(workspace.screens[screen].public_id.to_string()),
                    ),
                    (
                        "destination_pane".into(),
                        json!(state.resource_indexes.pane_ids[&pane].to_string()),
                    ),
                    ("index".into(), json!(u64::try_from(index).unwrap_or(u64::MAX))),
                ])
            });
            let mutation = WorkspaceMutation::local("layout-invariants-replay");
            let first = mux.commit_resource_topology_operation(
                ResourceOperation::TabMove,
                selectors.clone(),
                fields.clone(),
                None,
                &mutation,
            );
            let first_ok = first.is_ok();
            check_step(mux, before, &accepted(first), *rejections);
            *before = mux.with_state(Clone::clone);
            *rejections = rejections_on_this_thread();
            let replay = mux.commit_resource_topology_operation(
                ResourceOperation::TabMove,
                selectors,
                fields,
                None,
                &mutation,
            );
            if first_ok {
                assert!(replay.unwrap().replayed, "a replayed tab.move was not a replay");
            }
            // The replay must leave everything as the first request did.
            Outcome::Rejected
        }
        Op::Undo { pane } => match mux.undo_layout(pane_at(pane).unwrap(), None, false) {
            Ok(LayoutUndoResult::Undone { .. }) => Outcome::Accepted,
            Ok(LayoutUndoResult::ConfirmationRequired { .. }) | Err(_) => Outcome::Rejected,
        },
        Op::Close { tab: t } => {
            let surface = tab(t);
            match mux.close_surface(surface) {
                Ok(true) => Outcome::Closed(surface),
                Ok(false) | Err(_) => Outcome::Rejected,
            }
        }
    }
}

/// Check one step against the state before it.
fn check_step(mux: &Mux, before: &State, outcome: &Outcome, rejections: usize) {
    // The daemon rejecting a layout operation for a conservation violation
    // is a layout bug that the checker caught, not an ordinary rejection.
    assert_eq!(rejections_on_this_thread(), rejections, "the daemon rejected a broken layout op");
    let after = mux.with_state(Clone::clone);
    match outcome {
        Outcome::Skipped => {}
        // A rejected or no-op operation changes nothing (I4).
        Outcome::Rejected => assert_eq!(
            fingerprint(&after),
            fingerprint(before),
            "a rejected operation changed the layout"
        ),
        Outcome::Accepted | Outcome::Closed(_) => {
            let closed = match outcome {
                Outcome::Closed(surface) => BTreeSet::from([*surface]),
                _ => BTreeSet::new(),
            };
            let violations = introduced_violations(&project(before), &project(&after), &closed);
            assert!(violations.is_empty(), "layout invariants broken: {violations:?}");
            // Every generated layout starts clean, so the absolute check
            // must hold too.
            let violations = check_state(&project(&after));
            assert!(violations.is_empty(), "layout is invalid: {violations:?}");
        }
    }
    assert_durable_matches_memory(mux);
}

fn proptest_cases() -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|cases| cases.parse().ok()).unwrap_or(64)
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: proptest_cases(),
        failure_persistence: None,
        max_shrink_iters: 2_000,
        ..ProptestConfig::default()
    })]

    #[test]
    fn layout_ops_conserve_tabs(layout in layout(), ops in prop::collection::vec(op(), 1..=30)) {
        let mux = test_mux("layout-invariants-proptest");
        build(&mux, &layout);
        let initial = mux.with_state(|state| check_state(&project(state)));
        prop_assert!(initial.is_empty(), "{initial:?}");
        assert_durable_matches_memory(&mux);
        let mut groups = 0;
        for op in &ops {
            let mut before = mux.with_state(Clone::clone);
            let mut rejections = rejections_on_this_thread();
            let outcome = run(&mux, op, &mut groups, &mut before, &mut rejections);
            check_step(&mux, &before, &outcome, rejections);
        }
    }
}
