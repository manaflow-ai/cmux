//! `layout.bulk` (plans/cmux-next/reopen-closed.md section 5.1, cx-gzh.5):
//! every bulk close preset is one call, one commit and ONE closed-history
//! group, and Reopen Closed (Cmd-Shift-T, `closed.reopen` with no id)
//! brings the whole group back. Driven through `cmux.protocol/2` requests.

use serde_json::json;

use super::tests::{
    Session, empty_workspace, error_code, mutate, pane_id, pane_tab_ids, read, send, tab_id,
    terminal_tabs,
};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspacePresentationUpdate;

fn workspace_of(mux: &Arc<Mux>, surface: SurfaceId) -> WorkspaceId {
    mux.with_state(|state| {
        let (workspace, _) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
        state.workspaces[workspace].id
    })
}

fn workspace_public(mux: &Arc<Mux>, workspace: WorkspaceId) -> String {
    mux.with_state(|state| {
        state.workspaces[state.workspace_index(workspace).unwrap()].public_id.to_string()
    })
}

/// The public ids and names of `workspace`'s screens, in bar order.
fn screens(mux: &Arc<Mux>, workspace: WorkspaceId) -> Vec<(String, Option<String>)> {
    mux.with_state(|state| {
        let index = state.workspace_index(workspace).unwrap();
        state.workspaces[index]
            .screens
            .iter()
            .map(|screen| (screen.public_id.to_string(), screen.name.clone()))
            .collect()
    })
}

fn live_workspaces(mux: &Arc<Mux>) -> usize {
    mux.with_state(|state| state.workspaces.len())
}

fn groups(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "closed.list", json!({})).as_array().unwrap().clone()
}

/// Close Other Tabs keeps the anchor and the pinned tab and closes the
/// other three as one group; one Reopen Closed puts all three back in
/// place. A preset with nothing to close writes no group.
#[test]
fn close_other_tabs_is_one_group_that_keeps_pinned_tabs_and_reopens_whole() {
    let mux = Mux::new_for_test("bulk-tabs", SurfaceOptions::default());
    // tabs[1] is the anchor: it stays, so it names the pane throughout.
    let tabs = terminal_tabs(&mux, 5);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    mutate(&mux, "tab.pin", json!({"tab": ids[3]}), "pin");
    let before = pane_tab_ids(&mux, tabs[1]);

    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "tab", "selector": "others", "anchor": ids[1]}),
        "others",
    );
    assert_eq!(closed["tab_ids"], json!([ids[0], ids[2], ids[4]]));
    assert_eq!(pane_tab_ids(&mux, tabs[1]), vec![ids[3].clone(), ids[1].clone()]);
    let listed = groups(&mux);
    assert_eq!(listed.len(), 1, "one gesture, one group: {listed:?}");
    assert_eq!(listed[0]["kind"], "tab");
    assert_eq!(listed[0]["member_count"], 3);
    assert_eq!(closed["closed_ids"], json!([listed[0]["id"]]), "the call names its group");

    let nothing = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "tab", "selector": "to_right", "anchor": ids[1]}),
        "right-of-last",
    );
    assert_eq!(nothing["tab_ids"], json!([]));
    assert_eq!(nothing["closed_ids"], json!([]));
    assert_eq!(groups(&mux).len(), 1, "a preset that closes nothing writes no group");

    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(reopened["tab_ids"].as_array().unwrap().len(), 3);
    assert_eq!(pane_tab_ids(&mux, tabs[1]).len(), before.len());
    assert!(groups(&mux).is_empty());
}

/// Close Screens to the Right closes two screens as one group of two screen
/// members; Cmd-Shift-T restores both, in order, after the anchor.
#[test]
fn close_screens_to_the_right_is_one_group_and_reopens_every_screen() {
    let mux = Mux::new_for_test("bulk-screens", SurfaceOptions::default());
    let first = terminal_tabs(&mux, 1)[0];
    let workspace = workspace_of(&mux, first);
    for name in ["build", "logs"] {
        let surface = mux.new_screen(Some(workspace), None).unwrap().id;
        let screen = mux.with_state(|state| {
            let (workspace, index) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
            state.workspaces[workspace].screens[index].id
        });
        assert!(mux.rename_screen(screen, name.to_string()));
    }
    let before = screens(&mux, workspace);
    assert_eq!(before.len(), 3);

    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "screen", "selector": "to_right", "anchor": before[0].0}),
        "screens-right",
    );
    assert_eq!(closed["screen_ids"], json!([before[1].0, before[2].0]));
    assert_eq!(screens(&mux, workspace).len(), 1);
    let listed = groups(&mux);
    assert_eq!(listed.len(), 1, "one gesture, one group: {listed:?}");
    assert_eq!(listed[0]["kind"], "screen");
    assert_eq!(listed[0]["member_count"], 2);

    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(reopened["screen_ids"].as_array().unwrap().len(), 2);
    let after = screens(&mux, workspace);
    assert_eq!(after.len(), 3);
    let names = |list: &[(String, Option<String>)]| {
        list.iter().map(|(_, name)| name.clone()).collect::<Vec<_>>()
    };
    assert_eq!(names(&after), names(&before), "the screens come back in their order");
}

/// Close Other Panes closes the screen's other two panes as one group; one
/// reopen brings back every tab they held.
#[test]
fn close_other_panes_is_one_group_and_reopens_every_tab() {
    let mux = Mux::new_for_test("bulk-panes", SurfaceOptions::default());
    let first = terminal_tabs(&mux, 1)[0];
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let right = mux.new_pane_right(pane, 0.5, None).unwrap().id;
    mux.new_tab(mux.with_state(|state| state.pane_of(right)), None, None).unwrap();
    mux.new_pane_right(pane, 0.5, None).unwrap();
    let count = || mux.with_state(|state| state.surfaces.len());
    assert_eq!(count(), 4);

    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "pane", "selector": "others", "anchor": pane_id(&mux, first)}),
        "panes-others",
    );
    assert_eq!(closed["tab_ids"].as_array().unwrap().len(), 3);
    assert_eq!(count(), 1);
    let listed = groups(&mux);
    assert_eq!(listed.len(), 1, "one gesture, one group: {listed:?}");
    assert_eq!(listed[0]["member_count"], 3);

    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(reopened["tab_ids"].as_array().unwrap().len(), 3);
    assert_eq!(count(), 4);
    // Every pane comes back as a pane of its own: the two closed panes were each other's
    // neighbor, and neither one's tabs may join the kept pane (Lawrence 2026-10-23).
    let panes = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(pane).unwrap();
        let mut ids = Vec::new();
        state.workspaces[workspace].screens[screen].root.pane_ids(&mut ids);
        ids.into_iter().map(|id| state.panes[&id].tabs.len()).collect::<Vec<_>>()
    });
    assert_eq!(panes.len(), 3, "one reopen brings back both closed panes: tabs per pane {panes:?}");
    assert_eq!(
        mux.with_state(|state| state.panes[&pane].tabs.len()),
        1,
        "the kept pane keeps only its own tab"
    );
}

/// Close Other Workspaces (in a space) sends the space's other workspaces
/// as a selection: one group of two workspace members, one reopen restores
/// both. A retry with the same key replays and closes nothing more; a
/// selector the level has no order for is refused.
#[test]
fn closing_a_workspace_selection_is_one_group_and_reopens_every_workspace() {
    let mux = Mux::new_for_test("bulk-workspaces", SurfaceOptions::default());
    let kept = terminal_tabs(&mux, 1)[0];
    let first = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 2)[0]));
    let second = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 1)[0]));
    let before = live_workspaces(&mux);

    let request = json!({
        "verb": "close", "level": "workspace", "selector": "selection",
        "ids": [first, second], "end_terminals": true,
    });
    let closed = mutate(&mux, "layout.bulk", request.clone(), "workspaces");
    assert_eq!(closed["workspace_ids"], json!([first, second]));
    assert_eq!(live_workspaces(&mux), before - 2);
    let replay = send(&mux, "layout.bulk", request, Some("workspaces")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(live_workspaces(&mux), before - 2);
    let listed = groups(&mux);
    assert_eq!(listed.len(), 1, "one gesture, one group: {listed:?}");
    assert_eq!(listed[0]["kind"], "workspace");
    assert_eq!(listed[0]["member_count"], 2);

    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(reopened["workspace_ids"].as_array().unwrap().len(), 2);
    assert_eq!(live_workspaces(&mux), before);

    let unordered = send(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "pane", "selector": "to_right", "anchor": pane_id(&mux, kept)}),
        Some("pane-right"),
    );
    assert_eq!(error_code(unordered), "validation.invalid");
}

/// Without an anchor the request's selectors name it, as `cmux tab <selector>
/// close --others` sends them: a tab id, or `current` down to the tab.
#[test]
fn the_request_selectors_name_the_anchor_when_there_is_none() {
    let mux = Mux::new_for_test("bulk-selectors", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 3);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();

    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "tab", "selector": "to_right", "tab": ids[0]}),
        "by-id",
    );
    assert_eq!(closed["tab_ids"], json!([ids[1], ids[2]]));

    let pane = mux.with_state(|state| state.pane_of(tabs[0]));
    mux.new_tab(pane, None, None).unwrap();
    mux.new_tab(pane, None, None).unwrap();
    let current = json!({
        "verb": "close", "level": "tab", "selector": "others",
        "workspace": "current", "screen": "current", "pane": "current", "tab": "current",
    });
    let closed = mutate(&mux, "layout.bulk", current, "current");
    assert_eq!(closed["tab_ids"].as_array().unwrap().len(), 2);
    let left = mux.with_state(|state| state.panes[&pane.unwrap()].tabs.len());
    assert_eq!(left, 1, "only the current tab stays");
    assert_eq!(groups(&mux).len(), 2, "two gestures, two groups");
}

/// Close Other Workspaces from the home workspace closes every other one:
/// home anchors the selector but never closes, not even when a selection
/// names it.
#[test]
fn close_other_workspaces_from_home_closes_the_rest_and_keeps_home() {
    let session = Session::new("bulk-home");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("home")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let first = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 1)[0]));
    let second = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 1)[0]));

    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "workspace", "selector": "others", "anchor": home}),
        "others",
    );
    assert_eq!(closed["workspace_ids"], json!([first, second]));
    let live = mux.with_state(|state| {
        state.workspaces.iter().map(|workspace| workspace.public_id.to_string()).collect::<Vec<_>>()
    });
    assert_eq!(live, vec![home.clone()]);

    let named = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "workspace", "selector": "selection", "ids": [home]}),
        "named-home",
    );
    assert_eq!(named["workspace_ids"], json!([]));
    assert_eq!(live_workspaces(&mux), 1);
    mux.shutdown();
}

/// The result names only the workspaces the call closed: a chosen workspace
/// with no tab has nothing to close and stays.
#[test]
fn a_workspace_selection_reports_only_the_workspaces_it_closed() {
    let mux = Mux::new_for_test("bulk-empty", SurfaceOptions::default());
    let empty = empty_workspace(&mux, "empty");
    let full = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 1)[0]));

    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({"verb": "close", "level": "workspace", "selector": "selection", "ids": [empty, full]}),
        "selection",
    );
    assert_eq!(closed["workspace_ids"], json!([full]));
    let live = mux.with_state(|state| {
        state.workspaces.iter().map(|workspace| workspace.public_id.to_string()).collect::<Vec<_>>()
    });
    assert!(live.contains(&empty), "the empty workspace stays: {live:?}");
}

/// A pinned workspace stays when its siblings close, unless the call
/// includes pinned objects.
#[test]
fn close_other_workspaces_keeps_a_pinned_workspace() {
    let mux = Mux::new_for_test("bulk-pinned-workspace", SurfaceOptions::default());
    let anchor = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 1)[0]));
    let pinned_slot = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let pinned = workspace_public(&mux, pinned_slot);
    let loose = workspace_public(&mux, workspace_of(&mux, terminal_tabs(&mux, 1)[0]));
    mux.set_workspace_metadata(
        Some(pinned_slot),
        None,
        WorkspacePresentationUpdate {
            pinned: Some(true),
            ..WorkspacePresentationUpdate::default()
        },
        None,
        None,
        &WorkspaceMutation::daemon_local("bulk-pin"),
    )
    .unwrap();

    let others =
        json!({"verb": "close", "level": "workspace", "selector": "others", "anchor": anchor});
    let closed = mutate(&mux, "layout.bulk", others.clone(), "others");
    assert_eq!(closed["workspace_ids"], json!([loose]));

    let mut everything = others;
    everything["include_pinned"] = json!(true);
    let closed = mutate(&mux, "layout.bulk", everything, "others-pinned");
    assert_eq!(closed["workspace_ids"], json!([pinned]));
}
