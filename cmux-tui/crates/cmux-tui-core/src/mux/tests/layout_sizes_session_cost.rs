//! A layout size command writes one screen: its cost does not follow the
//! size of the session.
//!
//! `set-split-ratio`, `set-viewport-pane-width`, `set-layout-sizes`,
//! `set-divider-visible` and a pane zoom each commit one screen's row. Each
//! of them loaded the whole stored topology to build that row. The three
//! size commands also rebuilt the split index and the public indexes of
//! every workspace after the commit. With a permanent, pinned or agent chat
//! column anywhere in the session, each of the five also cloned the whole
//! session state before the commit.
//!
//! The guard runs on an on-disk registry of 60 and of 600 workspaces, with a
//! permanent column in a workspace that no command names. It counts, on the
//! requesting thread: whole-topology loads, whole-session state clones and
//! workspaces visited by an index rebuild. Counts, not times.
//!
//! It also holds what must stay the same. The screen value that each commit
//! publishes is the value that a read of the whole store gives. The stored
//! row holds the new sizes. No other screen's stored row changes. The echo of
//! a ratio command names its transaction. One undo restores the last change.
//!
//! A size command leaves the splits, the panes and the columns of its screen
//! as they are, so it has no dock rule to check and no index to build again.
//! The last test holds the other branch: on a screen with a stale column
//! projection the width command takes a column away, and then the whole check
//! and the index rebuild run.

use serde_json::Value;

use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode};
use crate::resource_api::public_session_snapshot;
use crate::walk_counters::walk_counts_for_test;

/// A session on an on-disk registry and the panes and splits that the
/// commands name.
struct Session {
    mux: Arc<Mux>,
    root: std::path::PathBuf,
    /// The three columns of the last workspace, left to right.
    columns: [PaneId; 3],
    /// The split of the third column.
    third_split: SplitId,
    /// A pane of the workspace that holds a split tree.
    tree_pane: PaneId,
    /// The inner split of that tree.
    tree_split: SplitId,
}

fn pane_of(mux: &Arc<Mux>, surface: SurfaceId) -> PaneId {
    mux.with_state(|state| state.pane_of(surface).unwrap())
}

/// A session of `workspaces` workspaces. The last three hold panes: two
/// columns with a permanent one, a split tree of three panes, and three
/// columns. The rest are workspace rows only.
///
/// The workspace rows come first: `create_empty_workspace` takes the focus
/// and commits the workspace row and the active workspace alone, so a screen
/// made before it would keep `focused: true` in the journal.
fn session(workspaces: usize) -> Session {
    let root = std::env::temp_dir().join(format!(
        "cmux-layout-sizes-session-cost-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux("layout-sizes-session-cost", &root);
    // The worker would checkpoint and seal on its own ticks.
    mux.stop_journal_maintenance();
    for index in 3..workspaces {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
    }

    // A permanent column in a workspace that no command names.
    let docked = mux.new_workspace(None, Some((80, 22))).unwrap();
    let docked = pane_of(&mux, docked.id);
    mux.new_pane_right(docked, 0.5, Some((38, 22))).unwrap();
    let permanent =
        ColumnDock { permanent: true, ..ColumnDock::new(DockEdge::Left, DockMode::Docked) };
    mux.set_column_dock(docked, Some(permanent), None).unwrap();

    // A split tree: the first pane, split to the right two times.
    let tree_first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let tree_first = pane_of(&mux, tree_first.id);
    let tree_second = mux.split(tree_first, SplitDir::Right, Some((80, 24))).unwrap();
    let tree_pane = pane_of(&mux, tree_second.id);
    mux.split(tree_first, SplitDir::Right, Some((80, 24))).unwrap();
    let tree_split = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(tree_pane).unwrap();
        let Node::Split { a, .. } = &state.workspaces[workspace].screens[screen].root else {
            panic!("setup: the root of the tree is a split");
        };
        let Node::Split { id, .. } = a.as_ref() else {
            panic!("setup: the first child of the root is a split");
        };
        *id
    });

    // Three columns: the first pane and two panes right of it.
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first = pane_of(&mux, first.id);
    let second = mux.new_pane_right(first, 0.5, Some((38, 22))).unwrap();
    let second = pane_of(&mux, second.id);
    let third = mux.new_pane_right(second, 0.5, Some((18, 22))).unwrap();
    let third = pane_of(&mux, third.id);
    let third_split = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(third).unwrap();
        state.workspaces[workspace].screens[screen].layout_columns[2].id
    });

    Session { mux, root, columns: [first, second, third], third_split, tree_pane, tree_split }
}

/// The work one command did on this thread.
#[derive(Debug, Clone, Copy)]
struct Work {
    topology_loads: u64,
    state_clones: u64,
    index_rebuild: u64,
}

impl Work {
    fn now() -> Self {
        Self {
            topology_loads: WorkspaceRegistry::full_topology_reads_for_test(),
            state_clones: ResourceMutationPlan::staged_state_clones_for_test(),
            index_rebuild: walk_counts_for_test().index_rebuild,
        }
    }

    /// Each count since `before` that grows with the session, as a failure of
    /// `command`.
    fn failures_since(self, before: Self, command: &str, failures: &mut Vec<String>) {
        let topology_loads = self.topology_loads - before.topology_loads;
        let state_clones = self.state_clones - before.state_clones;
        let index_rebuild = self.index_rebuild - before.index_rebuild;
        if topology_loads != 0 {
            failures
                .push(format!("{command} loaded the whole stored topology {topology_loads} times"));
        }
        if state_clones != 0 {
            failures.push(format!("{command} cloned the whole session state {state_clones} times"));
        }
        if index_rebuild != 0 {
            failures.push(format!(
                "{command} visited {index_rebuild} workspaces to build the indexes again"
            ));
        }
    }
}

/// Runs `command` and records a failure of it and each count of this thread
/// that grows with the session.
fn counted<E: fmt::Debug>(
    name: &str,
    failures: &mut Vec<String>,
    command: impl FnOnce() -> Result<(), E>,
) {
    let before = Work::now();
    let outcome = command();
    Work::now().failures_since(before, name, failures);
    if let Err(error) = outcome {
        failures.push(format!("{name} failed: {error:?}"));
    }
}

/// The whole stored topology. The read is outside each counted window.
fn stored(mux: &Arc<Mux>) -> ResourceTopologySnapshot {
    mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap()
}

/// The column widths, the layout revision and the undo depth of the screen
/// of `pane`.
fn held(mux: &Arc<Mux>, pane: PaneId) -> (Vec<f32>, u64, usize) {
    mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(pane).unwrap();
        let screen = &state.workspaces[workspace].screens[screen];
        (
            screen.layout_columns.iter().map(|column| column.width).collect(),
            screen.layout_revision,
            screen.layout_undo.len(),
        )
    })
}

fn near(left: f32, right: f32) -> bool {
    (left - right).abs() < 1e-5
}

fn all_near(left: &[f32], right: &[f32]) -> bool {
    left.len() == right.len() && left.iter().zip(right).all(|(left, right)| near(*left, *right))
}

/// The stored ratio and divider flag of the split `target` under `node`.
fn stored_split(node: &RegistryLayoutNode, target: &SplitPublicId) -> Option<(f32, bool)> {
    match node {
        RegistryLayoutNode::Split { split, ratio, divider_hidden, first, second, .. } => {
            if split == target {
                Some((*ratio, *divider_hidden))
            } else {
                stored_split(first, target).or_else(|| stored_split(second, target))
            }
        }
        RegistryLayoutNode::Leaf { .. } | RegistryLayoutNode::Stack { .. } => None,
    }
}

/// The stored ratio and divider flag of the split `target` of the screen
/// `row`, in its tree or in one of its columns.
fn stored_screen_split(row: &RegistryScreen, target: &SplitPublicId) -> Option<(f32, bool)> {
    stored_split(&row.layout, target).or_else(|| {
        row.viewport.columns.iter().find_map(|column| stored_split(&column.layout, target))
    })
}

/// The members of a published screen value that the daemon builds from the
/// stored topology (`resource_screen::screen_value`).
const SCREEN_MEMBERS: [&str; 6] = ["id", "workspace_id", "name", "index", "focused", "layout"];

/// What a command left.
struct Committed {
    /// The whole store after the command.
    store: ResourceTopologySnapshot,
    /// The stored row of the screen that the command changed.
    row: Option<RegistryScreen>,
    /// The focus flag of the screen value that the commit published.
    focused: Option<bool>,
}

/// After `command` changed the screen of `pane`: the commit published the
/// value of that screen, that value is the one that a read of the whole store
/// gives, and each other screen's stored row is its row of `before`.
fn committed(
    mux: &Arc<Mux>,
    command: &str,
    pane: PaneId,
    before: &ResourceTopologySnapshot,
    failures: &mut Vec<String>,
) -> Committed {
    let store = stored(mux);
    let public = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].screens[screen].public_id.clone()
    });
    for row in before.screens.iter().filter(|row| row.public_id != public) {
        if !store.screens.contains(row) {
            failures.push(format!(
                "{command} changed the stored row of the screen {}",
                row.public_id.as_str()
            ));
        }
    }
    // The change that each `session.events` reader gets for the commit.
    let page = mux.resource_events_after(before.revision).unwrap();
    let published: Option<Value> = page.batches.iter().find_map(|batch| {
        batch
            .changes
            .as_array()?
            .iter()
            .find(|change| {
                change["kind"] == "upsert"
                    && change["resource"] == "screen"
                    && change["id"] == public.as_str()
            })
            .map(|change| change["value"].clone())
    });
    let row = store.screens.iter().find(|row| row.public_id == public).cloned();
    let (Some(published), Some(stored_row)) = (published.as_ref(), row.as_ref()) else {
        failures.push(format!(
            "{command}: the screen {} has a published value: {}, a stored row: {}",
            public.as_str(),
            published.is_some(),
            row.is_some()
        ));
        return Committed { store, row, focused: None };
    };
    let whole = {
        let tabs = crate::resource_screen::tabs_by_pane(&store.tabs);
        let panes = crate::resource_screen::panes_by_id(&store.panes);
        crate::resource_screen::public_screen_value(&store, stored_row, &tabs, &panes).unwrap()
    };
    for member in SCREEN_MEMBERS {
        if published[member] != whole[member] {
            failures.push(format!(
                "{command} published `{member}` = {}, a read of the whole store gives {}",
                published[member], whole[member]
            ));
        }
    }
    let focused = published["focused"].as_bool();
    Committed { store, row, focused }
}

/// The stored column widths of `row` are the live `widths`.
fn check_stored_widths(
    command: &str,
    row: Option<&RegistryScreen>,
    widths: &[f32],
    failures: &mut Vec<String>,
) {
    let stored: Vec<f32> = row
        .map(|row| row.viewport.columns.iter().map(|column| column.width).collect())
        .unwrap_or_default();
    if !all_near(&stored, widths) {
        failures
            .push(format!("{command} stored the widths {stored:?}, the session holds {widths:?}"));
    }
}

/// The three size commands on the three columns of the focused workspace,
/// then one undo.
fn column_commands(session: &Session, failures: &mut Vec<String>) {
    let mux = &session.mux;
    let [first, second, _] = session.columns;
    let third_split = session.third_split;

    // One batch: a width and a ratio that uses that width.
    let name = "set-layout-sizes";
    let (_, revision, undo) = held(mux, first);
    let before = stored(mux);
    counted(name, failures, || {
        mux.set_layout_sizes_in_transaction_checked_as(
            &Actor::Daemon,
            &[
                LayoutSizeValue::PaneWidth { pane: first, width: 0.4 },
                LayoutSizeValue::SplitRatio { split: third_split, ratio: 0.5 },
            ],
            7,
            15,
        )
    });
    let after = committed(mux, name, first, &before, failures);
    let (widths, after_revision, after_undo) = held(mux, first);
    if !(near(widths[0], 0.4) && near(widths[2], widths[0] + widths[1])) {
        failures.push(format!("{name} left the widths {widths:?}"));
    }
    if after_revision != revision + 1 || after_undo != undo + 1 {
        failures.push(format!(
            "{name} is not one layout change and one undo step: the revision went from \
             {revision} to {after_revision}, the undo depth from {undo} to {after_undo}"
        ));
    }
    if after.focused != Some(true) {
        failures.push(format!("{name} published the focus flag {:?} (true)", after.focused));
    }
    check_stored_widths(name, after.row.as_ref(), &widths, failures);

    // One ratio of a column boundary, with its echo.
    let name = "set-split-ratio of a column";
    let wanted = (widths[0] + widths[1]) * (1.0 - 0.6) / 0.6;
    let events = mux.subscribe();
    counted(name, failures, || {
        mux.set_split_ratio_in_transaction_checked_as(&Actor::Daemon, third_split, 0.6, 7, 16)
    });
    let echo = events.try_iter().find_map(|event| match event {
        MuxEvent::LayoutChanged(_, Some(delta)) => Some(delta.transaction.clone()),
        _ => None,
    });
    if echo.as_ref().and_then(|transaction| transaction.as_deref()) != Some("16") {
        failures.push(format!("{name} sent the echo {echo:?} (transaction 16)"));
    }
    let after = committed(mux, name, first, &after.store, failures);
    let (widths, ratio_revision, _) = held(mux, first);
    if !(near(widths[2], wanted) && ratio_revision == after_revision + 1) {
        failures.push(format!(
            "{name} left the widths {widths:?} (the third: {wanted}) at the revision \
             {ratio_revision} (one more than {after_revision})"
        ));
    }
    check_stored_widths(name, after.row.as_ref(), &widths, failures);

    // One width, then the undo of it.
    let name = "set-viewport-pane-width";
    counted(name, failures, || {
        mux.set_viewport_pane_width_in_transaction_checked(second, 0.37, 7, 17)
    });
    let after = committed(mux, name, first, &after.store, failures);
    let (changed, width_revision, _) = held(mux, first);
    if !(near(changed[1], 0.37) && width_revision == ratio_revision + 1) {
        failures.push(format!(
            "{name} left the widths {changed:?} (the second: 0.37) at the revision \
             {width_revision} (one more than {ratio_revision})"
        ));
    }
    check_stored_widths(name, after.row.as_ref(), &changed, failures);
    let undone =
        matches!(mux.undo_layout(second, None, false), Ok(LayoutUndoResult::Undone { .. }));
    let restored = held(mux, first).0;
    if !(undone && all_near(&restored, &widths)) {
        failures.push(format!(
            "one undo after {name}: undone = {undone}, the widths are {restored:?}, before the \
             command they were {widths:?}"
        ));
    }
}

/// A ratio, a hidden divider and a zoom on the split tree of a workspace
/// that does not have the focus.
fn tree_commands(session: &Session, failures: &mut Vec<String>) {
    let mux = &session.mux;
    let (pane, split) = (session.tree_pane, session.tree_split);
    let (public_split, public_pane) = mux.with_state(|state| {
        (
            state.resource_indexes.split_ids[&split].clone(),
            state.resource_indexes.pane_ids[&pane].clone(),
        )
    });
    let live = |mux: &Arc<Mux>| {
        mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane).unwrap();
            let screen = &state.workspaces[workspace].screens[screen];
            (screen.root.split_ratio(split), screen.root.divider_hidden(split), screen.zoomed_pane)
        })
    };

    let name = "set-split-ratio of a tree split";
    let before = stored(mux);
    counted(name, failures, || {
        mux.set_split_ratio_in_transaction_checked_as(&Actor::Daemon, split, 0.3, 7, 18)
    });
    let after = committed(mux, name, pane, &before, failures);
    let ratio = live(mux).0;
    let stored_ratio = after
        .row
        .as_ref()
        .and_then(|row| stored_screen_split(row, &public_split))
        .map(|(ratio, _)| ratio);
    if !(ratio.is_some_and(|ratio| near(ratio, 0.3))
        && stored_ratio.is_some_and(|ratio| near(ratio, 0.3)))
    {
        failures.push(format!(
            "{name}: the session holds the ratio {ratio:?}, the store holds {stored_ratio:?} (0.3)"
        ));
    }
    if after.focused != Some(false) {
        failures.push(format!("{name} published the focus flag {:?} (false)", after.focused));
    }

    let name = "set-divider-visible";
    counted(name, failures, || {
        mux.set_divider_visible_checked_as(&Actor::Daemon, split, false, Some(19))
    });
    let after = committed(mux, name, pane, &after.store, failures);
    let hidden = live(mux).1;
    let stored_hidden = after
        .row
        .as_ref()
        .and_then(|row| stored_screen_split(row, &public_split))
        .map(|(_, hidden)| hidden);
    if hidden != Some(true) || stored_hidden != Some(true) {
        failures.push(format!(
            "{name}: the session holds the hidden flag {hidden:?}, the store holds \
             {stored_hidden:?} (true)"
        ));
    }

    let name = "a pane zoom";
    counted(name, failures, || mux.zoom_pane(Some(pane), ZoomMode::Toggle).map(|_| ()));
    let after = committed(mux, name, pane, &after.store, failures);
    let zoomed = live(mux).2;
    let stored_zoom =
        after.row.as_ref().and_then(|row| row.zoomed_pane.as_ref()).map(|pane| pane.as_str());
    if zoomed != Some(pane) || stored_zoom != Some(public_pane.as_str()) {
        failures.push(format!(
            "{name}: the session holds the zoomed pane {zoomed:?} ({pane:?}), the store holds \
             {stored_zoom:?} ({})",
            public_pane.as_str()
        ));
    }
}

fn layout_commands(workspaces: usize) -> Vec<String> {
    let session = session(workspaces);
    let listed = public_session_snapshot(&session.mux).unwrap();
    assert_eq!(listed["workspaces"].as_array().map(Vec::len), Some(workspaces), "setup");
    assert!(
        !session.mux.with_state(|state| permanent_columns(state).is_empty()),
        "setup: the session holds a permanent column"
    );
    let mut failures = Vec::new();
    column_commands(&session, &mut failures);
    tree_commands(&session, &mut failures);
    let Session { mux, root, .. } = session;
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    failures
}

#[test]
fn a_layout_size_command_does_no_session_sized_work_on_60_workspaces() {
    let failures = layout_commands(60);
    assert!(failures.is_empty(), "60 workspaces: {failures:#?}");
}

#[test]
fn a_layout_size_command_does_no_session_sized_work_on_600_workspaces() {
    let failures = layout_commands(600);
    assert!(failures.is_empty(), "600 workspaces: {failures:#?}");
}

/// A size command that changes the columns of its screen takes the whole
/// check and builds the indexes again.
///
/// No command leaves such a screen. The test puts a lone column with no rows
/// on a one-pane screen: a stale column projection. The width command then
/// takes that column away (`project_layout_columns`).
#[test]
fn a_layout_size_command_that_changes_the_columns_builds_the_indexes_again() {
    let session = session(3);
    let mux = Arc::clone(&session.mux);
    let lone = mux.new_workspace(None, Some((80, 22))).unwrap();
    let lone = pane_of(&mux, lone.id);
    let column = mux.next_id();
    let workspaces = {
        let mut state = mux.state.lock().unwrap();
        let (workspace, screen) = state.screen_of(lone).unwrap();
        let screen = state
            .workspaces
            .get_mut(workspace)
            .and_then(|workspace| workspace.screens.get_mut(screen))
            .unwrap();
        screen.layout_columns = vec![LayoutColumn::single(column, 1.0, lone)];
        state.workspaces.len() as u64
    };

    let before = Work::now();
    let outcome = mux.set_viewport_pane_width_in_transaction_checked(lone, 0.5, 7, 21);
    let after = Work::now();
    let (columns, consistent) = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(lone).unwrap();
        let screen = state
            .workspaces
            .get(workspace)
            .and_then(|workspace| workspace.screens.get(screen))
            .unwrap();
        (screen.layout_columns.len(), screen.layout_column_projection_is_consistent())
    });
    let Session { mux: owner, root, .. } = session;
    mux.shutdown();
    drop(mux);
    drop(owner);
    let _ = std::fs::remove_dir_all(&root);

    assert!(outcome.is_ok(), "the width command on the stale screen: {outcome:?}");
    assert_eq!(
        (columns, consistent),
        (0, true),
        "the command takes the lone column away and leaves a consistent screen"
    );
    assert_eq!(
        after.index_rebuild - before.index_rebuild,
        2 * workspaces,
        "the split index and the public indexes each visit the {workspaces} workspaces one time"
    );
    assert_eq!(
        after.state_clones - before.state_clones,
        1,
        "with a permanent column in the session, the dock rules check a clone of the state"
    );
}
