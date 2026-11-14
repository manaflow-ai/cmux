//! The kinds of change that took the full projection, each scoped
//! (`changed_state_projection_locked`, `commit_ordinary_surface_projection`): a move of a
//! column, a column dock, the row heights, a tab drag, a tab pin, a screen pin, a view that an
//! adoption or a browser placed, a move of a pane in its workspace, and a new workspace through
//! the effect path. The views of one terminal that an adoption placed are a case of their own:
//! one terminal can have a view in 2 or more workspaces, and the commit states each of them.
//!
//! THE COUNT, for each kind, after a lost fold (as after a daemon start, before the parts end):
//! the commit runs no full projection, and its record states no workspace value and no tab of a
//! workspace that it did not change. The workspace that had the focus is the one exception: a
//! change that moves the focus states the workspace that the focus left, and a change of no
//! value of the live tree (a screen pin: a presentation row) has the workspace with the focus
//! as its scope. After a lost fold a workspace of the scope is stated whole, one time.
//!
//! THE EQUIVALENCE. Each change runs with the debug cross-check on: the commit compares the
//! scoped projection with the full one and refuses a difference. After it the journal, folded
//! from revision 0, states the session.
//!
//! The changes are made in a workspace that does not have the focus, so a scope that follows
//! the focus and not the change does not pass.

use super::super::workspace_close_cost::session_in;
use super::super::workspaces::assert_journal_states_the_session;
use super::super::*;
use super::lost_fold_journal::{
    changes_after, full_projections, lose_the_fold, tab_ids, workspace_at, workspace_ids,
    workspaces_stated,
};
use crate::model::{ColumnDock, DockEdge, DockMode};
use crate::mux::column_move::ColumnMoveDirection;

/// A session of 4 workspaces. The third one (index 2) has two columns: the seeded pane, and
/// right of it a pane with two tabs. The second workspace (index 1) has the focus.
struct Layout {
    mux: Arc<Mux>,
    /// The public id of the third workspace.
    workspace: String,
    right: PaneId,
    /// The second tab of `right`.
    tab: SurfaceId,
}

fn layout_session() -> Layout {
    let mux = session_in(test_mux(), 4);
    let (_, _, workspace) = workspace_at(&mux, 2);
    let left = mux.with_state(|state| state.workspaces[2].screens[0].active_pane);
    let created = mux.new_pane_right(left, 0.5, Some((38, 22))).unwrap();
    let right = mux.with_state(|state| state.pane_of(created.id)).expect("the new pane");
    let tab = mux.new_tab(Some(right), None, Some((38, 22))).unwrap().id;
    mux.select_workspace(Some(1), None);
    mux.with_state(|state| {
        assert_eq!(state.active_workspace, 1, "the second workspace has the focus");
        assert_eq!(state.workspaces[2].screens[0].layout_columns.len(), 2, "two columns");
        assert_eq!(state.panes[&right].tabs.len(), 2, "two tabs in the right pane");
    });
    Layout { mux, workspace, right, tab }
}

/// Run `change` after a lost fold and return the changes of its records. Asserts the count
/// (module doc) for a change in the workspace `own`.
fn counted(mux: &Arc<Mux>, own: &str, kind: &str, change: impl FnOnce(&Arc<Mux>)) -> Changes {
    let (_, _, had_focus) = workspace_at(mux, mux.with_state(|state| state.active_workspace));
    let other_tabs = workspace_ids(mux)
        .iter()
        .filter(|workspace| workspace.as_str() != own && **workspace != had_focus)
        .flat_map(|workspace| tab_ids(mux, workspace))
        .collect::<BTreeSet<_>>();
    lose_the_fold(mux);
    let (revision, full) = (mux.with_state(|state| state.resource_revision), full_projections(mux));
    change(mux);
    assert_eq!(full_projections(mux), full, "{kind} after a lost fold ran a full projection");
    let changes = changes_after(mux, revision);
    assert!(!changes.is_empty(), "{kind} committed no record");
    for (change, resource, id) in &changes {
        assert!(
            !(resource == "tab" && other_tabs.contains(id)),
            "{kind}: the record has a {change} of tab {id} of a workspace that it did not change"
        );
        assert!(
            !(resource == "workspace" && id != own && *id != had_focus),
            "{kind}: the record has a {change} of workspace {id}, which it did not change"
        );
    }
    assert_journal_states_the_session(mux);
    changes
}

type Changes = Vec<(String, String, String)>;

fn assert_states_the_workspace(changes: &Changes, workspace: &str, kind: &str) {
    assert!(
        changes.contains(&("upsert".into(), "workspace".into(), workspace.to_string())),
        "{kind}: the record does not state the workspace that it changed: {changes:?}"
    );
}

#[test]
fn a_column_move_after_a_lost_fold_states_its_own_workspace_and_no_other() {
    let layout = layout_session();
    let changes = counted(&layout.mux, &layout.workspace, "a column move", |mux| {
        let outcome =
            mux.move_column_as(&Actor::Daemon, layout.right, ColumnMoveDirection::Left).unwrap();
        assert_eq!(outcome.index, 0, "the right column is the first one now: {outcome:?}");
    });
    assert_states_the_workspace(&changes, &layout.workspace, "a column move");
    layout.mux.shutdown();
}

#[test]
fn a_column_dock_after_a_lost_fold_states_its_own_workspace_and_no_other() {
    let layout = layout_session();
    let dock = ColumnDock::new(DockEdge::Right, DockMode::Docked);
    let changes = counted(&layout.mux, &layout.workspace, "a column dock", |mux| {
        assert_eq!(mux.set_column_dock(layout.right, Some(dock), None).unwrap().dock, Some(dock));
    });
    assert_states_the_workspace(&changes, &layout.workspace, "a column dock");
    layout.mux.shutdown();
}

#[test]
fn a_change_of_row_heights_after_a_lost_fold_states_its_own_workspace_and_no_other() {
    let layout = layout_session();
    let mux = &layout.mux;
    mux.new_row_with_options(layout.right, 500, Default::default(), Some((38, 10)), None).unwrap();
    mux.select_workspace(Some(1), None);
    let (column, rows) = mux.with_state(|state| {
        let column = state.workspaces[2].screens[0]
            .layout_columns
            .iter()
            .find(|column| column.root.contains(layout.right))
            .expect("the column of the right pane");
        (column.id, column.rows.iter().map(|row| row.id).collect::<Vec<_>>())
    });
    assert_eq!(rows.len(), 2, "two rows in the right column");
    let changes = counted(mux, &layout.workspace, "a change of row heights", |mux| {
        let outcome =
            mux.set_row_heights(column, &[(rows[0], 300), (rows[1], 700)], true, None).unwrap();
        assert!(outcome.changed);
    });
    assert_states_the_workspace(&changes, &layout.workspace, "a change of row heights");
    layout.mux.shutdown();
}

#[test]
fn a_tab_drag_after_a_lost_fold_states_its_own_workspace_and_no_other() {
    let layout = layout_session();
    let changes = counted(&layout.mux, &layout.workspace, "a tab drag", |mux| {
        mux.move_tab_to_column(layout.tab, layout.right, None, None, None, None).unwrap();
    });
    assert_states_the_workspace(&changes, &layout.workspace, "a tab drag");
    layout.mux.with_state(|state| {
        assert_eq!(state.workspaces[2].screens[0].layout_columns.len(), 3, "the tab's new column");
        // The drag gives the focus to the tab: the record states the workspace that it left.
        assert_eq!(state.active_workspace, 2, "the workspace of the dragged tab has the focus");
    });
    layout.mux.shutdown();
}

/// The pin puts the second tab of its pane first: the tab strip commit.
#[test]
fn a_tab_pin_after_a_lost_fold_states_no_workspace_that_it_does_not_change() {
    let layout = layout_session();
    counted(&layout.mux, &layout.workspace, "a tab pin", |mux| {
        assert!(mux.set_tab_pinned(layout.tab, true).unwrap().changed);
    });
    layout.mux.shutdown();
}

/// The screen request commit. The pin is a presentation row and changes no value of the live
/// tree: the walk has the workspace with the focus as its scope, not the session.
#[test]
fn a_screen_pin_after_a_lost_fold_states_the_workspace_with_the_focus_and_no_other() {
    let layout = layout_session();
    let screen = layout.mux.with_state(|state| state.workspaces[2].screens[0].id);
    let (_, _, has_focus) = workspace_at(&layout.mux, 1);
    let changes = counted(&layout.mux, &layout.workspace, "a screen pin", |mux| {
        assert!(mux.set_screen_pinned(screen, true).unwrap().0);
    });
    assert_states_the_workspace(&changes, &has_focus, "a screen pin");
    layout.mux.shutdown();
}

/// The commit of a view that an adoption or a browser placed (`terminal_adoption.rs`,
/// `browser_create.rs`: both call this one function). A surface that a workspace shows takes
/// the scoped projection of that workspace; a surface that no workspace shows takes the full
/// one, as before.
#[test]
fn the_commit_of_a_placed_view_states_its_own_workspace_and_no_other() {
    let layout = layout_session();
    let mux = &layout.mux;
    let placed = layout.tab;
    let changes = counted(mux, &layout.workspace, "the commit of a placed view", |mux| {
        mux.commit_ordinary_surface_projection(
            &Actor::Daemon,
            "test.view.placed",
            move |_| Some(placed),
            serde_json::json!({}),
        )
        .unwrap();
    });
    assert_states_the_workspace(&changes, &layout.workspace, "the commit of a placed view");

    let full = full_projections(mux);
    mux.commit_ordinary_surface_projection(
        &Actor::Daemon,
        "test.view.not_placed",
        |_| None,
        serde_json::json!({}),
    )
    .unwrap();
    assert_eq!(
        full_projections(mux),
        full + 1,
        "a surface that no workspace shows takes the full projection"
    );
    assert_journal_states_the_session(mux);
    layout.mux.shutdown();
}

/// The host id of the terminal that `session_in` seeded in the workspace at `from`, after a
/// request placed one more view of it in the active pane of each workspace of `into`
/// (`terminal.project`).
fn placed_in_workspaces(mux: &Arc<Mux>, from: usize, into: &[usize]) -> String {
    let host = format!("00000000000040008000{:012x}", from + 1);
    let terminal = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(&host)
        .unwrap()
        .expect("the seeded terminal has a public id");
    for index in into {
        let pane = mux.with_state(|state| state.workspaces[*index].screens[0].active_pane);
        mux.resource_project_terminal_selected(
            crate::ResourceSelectors {
                terminal: Some(terminal.to_string()),
                ..Mux::ordinary_resource_selectors()
            },
            mux.ordinary_pane_selectors(pane).unwrap(),
            usize::MAX,
            None,
            None,
            &WorkspaceMutation::daemon_local("test-one-more-view"),
        )
        .unwrap();
    }
    host
}

/// The public ids of the workspaces that show a view of the terminal `host` of a host.
fn workspaces_that_show(mux: &Mux, host: &str) -> BTreeSet<String> {
    mux.with_state(|state| {
        state
            .surfaces
            .values()
            .filter(|surface| {
                let identity = surface.terminal_host_identity();
                identity.is_some_and(|identity| identity.terminal_id == host)
            })
            .filter_map(|surface| state.pane_of(surface.id))
            .filter_map(|pane| state.screen_of(pane))
            .map(|(workspace, _)| state.workspaces[workspace].public_id.to_string())
            .collect()
    })
}

/// The commit of the views of a terminal that an adoption placed
/// (`commit_placed_terminal_projection`), for a terminal with a view in 2 workspaces: the
/// record states both, with no full projection. A scope of one view (the first that the
/// surface map gives) leaves the other workspace to a later commit. The focus is in a third
/// workspace, and a fourth one shows no view: the record does not state it.
#[test]
fn the_commit_of_a_placed_terminal_states_each_workspace_that_shows_it() {
    let mux = session_in(test_mux(), 4);
    let host = placed_in_workspaces(&mux, 2, &[3]);
    let ids = workspace_ids(&mux);
    assert_eq!(
        workspaces_that_show(&mux, &host),
        BTreeSet::from([ids[2].clone(), ids[3].clone()]),
        "the fixture: 2 workspaces show the terminal"
    );

    lose_the_fold(&mux);
    let (revision, full) =
        (mux.with_state(|state| state.resource_revision), full_projections(&mux));
    mux.commit_placed_terminal_projection("test.terminal.placed", &host).unwrap();
    assert_eq!(full_projections(&mux), full, "the commit ran a full projection");
    let changes = changes_after(&mux, revision);
    assert_states_the_workspace(&changes, &ids[2], "the commit of a placed terminal");
    assert_states_the_workspace(&changes, &ids[3], "the commit of a placed terminal");
    assert!(
        !changes.contains(&("upsert".into(), "workspace".into(), ids[0].clone())),
        "the record states a workspace that shows no view of the terminal: {changes:?}"
    );
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// The limit of that scope. 8 workspaces that show the terminal are each stated by a scoped
/// commit; with a 9th the commit takes the full projection (`CHANGED_WORKSPACES_MAX`).
#[test]
fn the_commit_of_a_placed_terminal_is_scoped_to_8_workspaces_and_full_above() {
    let mux = session_in(test_mux(), 10);
    let host = placed_in_workspaces(&mux, 0, &[1, 2, 3, 4, 5, 6, 7]);
    let ids = workspace_ids(&mux);
    assert_eq!(workspaces_that_show(&mux, &host).len(), 8, "the fixture: 8 workspaces");

    lose_the_fold(&mux);
    let (revision, full) =
        (mux.with_state(|state| state.resource_revision), full_projections(&mux));
    mux.commit_placed_terminal_projection("test.terminal.placed-8", &host).unwrap();
    assert_eq!(full_projections(&mux), full, "8 workspaces took the full projection");
    let changes = changes_after(&mux, revision);
    assert_eq!(workspaces_stated(&changes, &ids[..8]), 8, "{changes:?}");

    placed_in_workspaces(&mux, 0, &[8]);
    assert_eq!(workspaces_that_show(&mux, &host).len(), 9, "the fixture: 9 workspaces");
    let full = full_projections(&mux);
    mux.commit_placed_terminal_projection("test.terminal.placed-9", &host).unwrap();
    assert_eq!(full_projections(&mux), full + 1, "9 workspaces took a scoped projection");
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// One resource request, as a client sends it: its result.
fn send(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Value {
    let mut params = serde_json::json!({"machine": "current", "session": "current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": operation,
        "idempotency_key": key,
        "params": params,
    });
    let response = crate::resource_router::handle_resource_message(mux, &envelope.to_string())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"]["value"].clone()
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_else(|| panic!("no {key} in {value}")).to_string()
}

/// `workspace.create` through the effect path, as a client sends it.
#[test]
fn a_workspace_create_request_after_a_lost_fold_states_no_other_workspace() {
    let mux = session_in(test_mux(), 4);
    let before = workspace_ids(&mux);
    let (_, _, had_focus) = workspace_at(&mux, 1);
    let other_tabs = before.iter().flat_map(|id| tab_ids(&mux, id)).collect::<BTreeSet<_>>();
    lose_the_fold(&mux);
    let (revision, full) =
        (mux.with_state(|state| state.resource_revision), full_projections(&mux));
    let fields = serde_json::json!({"initial_content": "terminal", "name": "after a lost fold"});
    let created = text(&send(&mux, "workspace.create", fields, "kinds-workspace"), "workspace_id");
    assert!(!before.contains(&created), "a new workspace");
    assert_eq!(
        full_projections(&mux),
        full,
        "workspace.create after a lost fold ran a full projection"
    );
    let changes = changes_after(&mux, revision);
    assert_states_the_workspace(&changes, &created, "workspace.create");
    for (change, resource, id) in &changes {
        assert!(
            !(resource == "tab" && other_tabs.contains(id)),
            "the record has a {change} of tab {id} of another workspace"
        );
        assert!(
            !(resource == "workspace" && *id != created && *id != had_focus),
            "the record has a {change} of workspace {id}, which the create did not change"
        );
    }
    assert_journal_states_the_session(&mux);
    mux.shutdown();
}

/// `pane.move` of a pane that merges into another pane of its own workspace. (A pane that
/// moves to ANOTHER workspace keeps the full projection: `changed_state_projection_locked`.)
#[test]
fn a_pane_move_in_one_workspace_after_a_lost_fold_states_its_own_workspace_and_no_other() {
    let mux = session_in(test_mux(), 4);
    let fields = serde_json::json!({"initial_content": "terminal", "name": "pane move"});
    let created = send(&mux, "workspace.create", fields, "kinds-pane-workspace");
    let (workspace, home) = (text(&created, "workspace_id"), text(&created, "pane_id"));
    let fields = serde_json::json!({"pane": home, "direction": "right"});
    let moved = text(&send(&mux, "pane.split", fields, "kinds-pane-split"), "pane_id");
    send(&mux, "tab.create_terminal", serde_json::json!({"pane": moved}), "kinds-pane-tab");

    let changes = counted(&mux, &workspace, "a pane move in one workspace", |mux| {
        let fields = serde_json::json!({"pane": moved, "destination_pane": home});
        let result = send(mux, "pane.move", fields, "kinds-pane-move");
        assert_eq!(result["pane_kept"], false, "{result}");
        assert_eq!(result["tab_ids"].as_array().map(Vec::len), Some(2), "{result}");
    });
    assert_states_the_workspace(&changes, &workspace, "a pane move in one workspace");
    mux.shutdown();
}
