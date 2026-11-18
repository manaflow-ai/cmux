//! `private-tabs-v1`: a private tab sits in any workspace beside normal tabs
//! (Leo, 2026-11-18: "drop the 9/30 rule and allow private tabs anywhere").
//! It keeps no closed history, the next daemon start closes it and keeps
//! its neighbours in order, Home reopens without it ("ofc reopening home if
//! they were prev on home is fine"), and a tab moves between an incognito and
//! a normal workspace (staying private), while panes and screens still do not.

use serde_json::json;

use super::tests::{
    Session, changes_after, mutate, pane_id, read, revision, send, snapshot, tab_id, terminal_tabs,
};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

fn tab_ids_of_pane(mux: &Mux, pane: &str) -> Vec<String> {
    snapshot(mux)["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|tab| tab["pane_id"] == pane)
        .map(|tab| tab["id"].as_str().unwrap().to_string())
        .collect()
}

fn private_flag(mux: &Mux, tab: &str) -> bool {
    let tabs = snapshot(mux)["tabs"].as_array().unwrap().clone();
    tabs.iter().find(|value| value["id"] == tab).unwrap()["extra"]["private"] == true
}

fn closed(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "closed.list", json!({})).as_array().unwrap().clone()
}

fn workspace_of(mux: &Mux, surface: SurfaceId) -> WorkspaceId {
    mux.with_state(|state| {
        let (workspace, _) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
        state.workspaces[workspace].id
    })
}

/// An incognito workspace with `count` terminal tabs in its first pane.
fn incognito_tabs(mux: &Arc<Mux>, count: usize) -> Vec<SurfaceId> {
    let created = mutate(
        mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "terminal", "ephemeral": true}),
        "create-incognito",
    );
    let workspace = created["workspace_id"].as_str().unwrap().to_string();
    let first = mux
        .with_state(|state| {
            state.surfaces.keys().copied().find(|surface| {
                state.pane_of(*surface).and_then(|pane| state.screen_of(pane)).is_some_and(
                    |(index, _)| state.workspaces[index].public_id.as_str() == workspace,
                )
            })
        })
        .unwrap();
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let mut tabs = vec![first];
    for _ in 1..count {
        tabs.push(mux.new_tab(Some(pane), None, None).unwrap().id);
    }
    tabs
}

/// Closing a private tab of a normal workspace, then the workspace, records
/// the workspace and its normal tabs only.
#[test]
fn a_private_tab_leaves_no_closed_history() {
    let mux = Mux::new_for_test("private-tab-closed", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 4);
    mux.mark_tab_private(tabs[1]).unwrap();
    mux.mark_tab_private(tabs[2]).unwrap();
    let still_private = tab_id(&mux, tabs[2]);
    assert!(mux.close_surface(tabs[1]).unwrap());
    assert!(closed(&mux).is_empty(), "the private tab was recorded");

    let workspace = mux.with_state(|state| {
        let (index, _) = state.screen_of(state.pane_of(tabs[0]).unwrap()).unwrap();
        state.workspaces[index].public_id.to_string()
    });
    mutate(&mux, "workspace.close", json!({"workspace": workspace}), "close-mixed");
    let records = closed(&mux);
    assert_eq!(records.len(), 1, "{records:?}");
    let recorded = serde_json::to_string(&records[0]).unwrap();
    assert!(!recorded.contains(still_private.as_str()), "{recorded}");
    mux.shutdown();
}

/// A workspace whose every tab is private closes without a record: no empty
/// container reopens in its place.
#[test]
fn a_workspace_of_only_private_tabs_is_not_recorded() {
    let mux = Mux::new_for_test("private-tab-only", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    for tab in &tabs {
        mux.mark_tab_private(*tab).unwrap();
    }
    let workspace = mux.with_state(|state| {
        let (index, _) = state.screen_of(state.pane_of(tabs[0]).unwrap()).unwrap();
        state.workspaces[index].public_id.to_string()
    });
    mutate(&mux, "workspace.close", json!({"workspace": workspace}), "close-private-only");
    let records = closed(&mux);
    assert!(records.is_empty(), "{records:?}");
    mux.shutdown();
}

/// Restore of a mix: the next start closes the private tabs and keeps the
/// normal ones, in their order, in the same normal workspace.
#[test]
fn restore_of_a_mix_keeps_the_normal_tabs_in_order_without_the_private_ones() {
    let session = Session::new("private-tab-restore");
    let mux = session.open();
    let tabs = terminal_tabs(&mux, 5);
    let pane = pane_id(&mux, tabs[0]);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    let before = revision(&mux);
    mux.mark_tab_private(tabs[1]).unwrap();
    mux.mark_tab_private(tabs[3]).unwrap();
    // `session.events` carries each mark on the tab's upsert (the app's mirror reads it there).
    let changes = changes_after(&mux, before);
    for id in [&ids[1], &ids[3]] {
        assert!(
            changes.iter().any(|change| change["kind"] == "upsert"
                && change["resource"] == "tab"
                && change["id"] == id.as_str()
                && change["value"]["extra"]["private"] == true),
            "no private upsert for {id}: {changes:?}"
        );
    }
    assert!(private_flag(&mux, &ids[1]) && private_flag(&mux, &ids[3]));
    assert!(!private_flag(&mux, &ids[0]) && !private_flag(&mux, &ids[2]));
    drop(mux);

    let mux = session.open();
    assert_eq!(tab_ids_of_pane(&mux, &pane), vec![ids[0].clone(), ids[2].clone(), ids[4].clone()]);
    assert!(closed(&mux).is_empty(), "a restart's close of a private tab was recorded");
    // The closed tabs' marks are gone too: the table never grows with every private tab ever opened.
    let marks = mux.read_registry_state(crate::state::private_tabs::marked_tabs).unwrap();
    assert!(marks.is_empty(), "{marks:?}");
    drop(mux);

    // A second start finds nothing more to close.
    let mux = session.open();
    assert_eq!(tab_ids_of_pane(&mux, &pane).len(), 3);
}

/// Home reopen: a private tab on Home is gone after a restart, and Home
/// reopens with its normal tab.
#[test]
fn home_reopens_without_its_private_tab() {
    let session = Session::new("private-tab-home");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("home")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let home_id = mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == home).map(|item| item.id)
    });
    let normal = mux.create_terminal_in_workspace(home_id.unwrap(), None, None, None, None);
    let normal = normal.unwrap().surface;
    let pane = mux.with_state(|state| state.pane_of(normal)).unwrap();
    let private = mux.new_tab(Some(pane), None, None).unwrap().id;
    mux.mark_tab_private(private).unwrap();
    let (normal, private) = (tab_id(&mux, normal), tab_id(&mux, private));
    drop(mux);

    let mux = session.open();
    let workspaces = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    assert!(workspaces.iter().any(|value| value["id"] == home.as_str()), "Home did not reopen");
    let tabs = snapshot(&mux)["tabs"].as_array().unwrap().clone();
    assert!(tabs.iter().any(|tab| tab["id"] == normal.as_str()));
    assert!(!tabs.iter().any(|tab| tab["id"] == private.as_str()), "the private tab reopened");

    // Its last tab private: Home still reopens (it never closes), empty of it.
    let home_id = mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == home).map(|item| item.id)
    });
    let surfaces = mux.with_state(|state| {
        state
            .resource_indexes
            .tab_ids
            .iter()
            .filter(|(_, id)| id.as_str() == normal)
            .map(|(surface, _)| *surface)
            .collect::<Vec<_>>()
    });
    let only = mux.create_terminal_in_workspace(home_id.unwrap(), None, None, None, None);
    let only = only.unwrap().surface;
    for surface in surfaces {
        assert!(mux.close_surface(surface).unwrap());
    }
    mux.mark_tab_private(only).unwrap();
    drop(mux);
    let mux = session.open();
    let workspaces = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    assert!(workspaces.iter().any(|value| value["id"] == home.as_str()), "Home did not reopen");
}

/// A tab moves out of an incognito workspace into a normal one and stays
/// private there; a normal tab moves into the incognito one. Screens still
/// never move between the two.
#[test]
fn tabs_move_between_incognito_and_normal_workspaces_keeping_their_privacy() {
    let mux = Mux::new_for_test("private-tab-moves", SurfaceOptions::default());
    let normal = terminal_tabs(&mux, 2);
    let incognito = incognito_tabs(&mux, 3);
    let (normal_workspace, incognito_workspace) =
        (workspace_of(&mux, normal[0]), workspace_of(&mux, incognito[0]));

    let out = tab_id(&mux, incognito[0]);
    mux.move_tab_to_workspace(incognito[0], Some(normal_workspace)).unwrap();
    assert_eq!(workspace_of(&mux, incognito[0]), normal_workspace);
    assert!(private_flag(&mux, &out), "the tab lost its privacy in the normal workspace");
    assert!(!private_flag(&mux, &tab_id(&mux, normal[0])));

    // A normal tab never enters the incognito workspace; a private one may.
    assert!(mux.move_tab_to_workspace(normal[0], Some(incognito_workspace)).is_err());
    assert_eq!(workspace_of(&mux, normal[0]), normal_workspace);
    mux.mark_tab_private(normal[0]).unwrap();
    mux.move_tab_to_workspace(normal[0], Some(incognito_workspace)).unwrap();
    assert_eq!(workspace_of(&mux, normal[0]), incognito_workspace);

    let screen = mux.new_screen(Some(incognito_workspace), None).unwrap().id;
    let screen = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(state.pane_of(screen).unwrap()).unwrap();
        state.workspaces[workspace].screens[screen].id
    });
    let destination =
        ScreenDestination::Workspace { workspace: Some(normal_workspace), index: None };
    let error = mux.move_screen(screen, destination).unwrap_err();
    assert!(format!("{error:#}").contains("ephemeral"), "{error:#}");

    // The moved private tab closes without a record.
    assert!(mux.close_surface(incognito[0]).unwrap());
    assert!(closed(&mux).is_empty(), "{:?}", closed(&mux));
    mux.shutdown();
}
