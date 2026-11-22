//! R102: content of an ephemeral (incognito) workspace stays ephemeral when
//! it moves. A workspace that a move creates from ephemeral content is
//! ephemeral: nothing in it reaches closed history and the daemon closes it
//! at its next start. Content never moves between an ephemeral workspace and
//! a normal one. A move out of a normal workspace is unchanged.

use serde_json::json;

use super::tests::{
    Session, changes_after, mutate, pane_id, read, revision, send, snapshot, tab_id,
};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// A workspace whose first pane holds `count` terminal tabs.
fn workspace_with_tabs(
    mux: &Arc<Mux>,
    name: &str,
    ephemeral: bool,
    count: usize,
) -> (String, Vec<SurfaceId>) {
    let mut params = json!({"name": name, "initial_content": "terminal"});
    if ephemeral {
        params["ephemeral"] = json!(true);
    }
    let created = mutate(mux, "workspace.create", params, &format!("create-{name}"));
    let workspace = created["workspace_id"].as_str().unwrap().to_string();
    let first = mux
        .with_state(|state| {
            state.surfaces.keys().copied().find(|surface| {
                state.pane_of(*surface).and_then(|pane| state.screen_of(pane)).is_some_and(
                    |(index, _)| state.workspaces[index].public_id.to_string() == workspace,
                )
            })
        })
        .expect("the created workspace has a tab");
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let mut tabs = vec![first];
    for _ in 1..count {
        tabs.push(mux.new_tab(Some(pane), None, None).unwrap().id);
    }
    (workspace, tabs)
}

fn workspace_of(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    })
}

fn screen_of(mux: &Mux, surface: SurfaceId) -> ScreenId {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, screen) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].screens[screen].id
    })
}

fn screen_public_id(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, screen) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].screens[screen].public_id.to_string()
    })
}

fn internal_id(mux: &Mux, workspace: &str) -> WorkspaceId {
    mux.with_state(|state| {
        state.workspaces.iter().find(|value| value.public_id.to_string() == workspace).unwrap().id
    })
}

fn public_id(mux: &Mux, workspace: WorkspaceId) -> String {
    mux.with_state(|state| state.workspace_by_id(workspace).unwrap().public_id.to_string())
}

fn flagged(mux: &Mux, workspace: &str) -> bool {
    let workspaces = snapshot(mux)["workspaces"].as_array().unwrap().clone();
    let value = workspaces.iter().find(|value| value["id"] == workspace).unwrap();
    value["extra"]["ephemeral"] == true
}

fn closed(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "closed.list", json!({})).as_array().unwrap().clone()
}

/// Every move into a new workspace (tab, tab group, screen, screen group)
/// copies the source's flag in the move's own commit: the snapshot and the
/// `session.events` upsert of the new workspace carry `extra.ephemeral`.
#[test]
fn every_move_into_a_new_workspace_carries_the_ephemeral_flag() {
    let mux = Mux::new_for_test("ephemeral-move-carry", SurfaceOptions::default());
    let (source, tabs) = workspace_with_tabs(&mux, "incognito", true, 4);
    let before = revision(&mux);

    let by_tab = public_id(&mux, mux.move_tab_to_new_workspace(tabs[0], None, None, None).unwrap());

    let ids = json!([tab_id(&mux, tabs[1]), tab_id(&mux, tabs[2])]);
    let group = mutate(&mux, "tab_group.create", json!({"tabs": ids}), "group");
    let destination = TabGroupDestination::NewWorkspace { group: None, index: None };
    let moved = mux.move_tab_group(group["id"].as_str().unwrap(), destination, None).unwrap();
    let by_group = public_id(&mux, moved.workspace.unwrap());

    let screen =
        screen_of(&mux, mux.new_screen(Some(internal_id(&mux, &source)), None).unwrap().id);
    let by_screen = public_id(
        &mux,
        mux.move_screen(screen, ScreenDestination::NewWorkspace).unwrap().workspace,
    );

    let screen =
        screen_of(&mux, mux.new_screen(Some(internal_id(&mux, &source)), None).unwrap().id);
    let screen_group = mux.create_screen_group(&[screen], None, None).unwrap().group.unwrap().id;
    let by_screen_group = public_id(
        &mux,
        mux.move_screen_group(&screen_group, ScreenDestination::NewWorkspace)
            .unwrap()
            .workspace
            .unwrap(),
    );

    let changes = changes_after(&mux, before);
    for workspace in [&by_tab, &by_group, &by_screen, &by_screen_group] {
        assert_ne!(workspace, &source);
        assert!(flagged(&mux, workspace), "{workspace} lost the ephemeral flag");
        let upserts = changes
            .iter()
            .filter(|change| {
                change["kind"] == "upsert"
                    && change["resource"] == "workspace"
                    && change["id"] == workspace.as_str()
            })
            .collect::<Vec<_>>();
        assert!(!upserts.is_empty(), "no upsert for {workspace}");
        for upsert in upserts {
            assert_eq!(
                upsert["value"]["extra"]["ephemeral"], true,
                "event without the flag: {upsert}"
            );
        }
    }
    mux.shutdown();
}

/// Closing a moved incognito tab, then its new workspace, records nothing.
#[test]
fn content_moved_out_of_an_ephemeral_workspace_leaves_no_closed_history() {
    let mux = Mux::new_for_test("ephemeral-move-unrecorded", SurfaceOptions::default());
    let (_, tabs) = workspace_with_tabs(&mux, "incognito", true, 3);
    let moved = public_id(&mux, mux.move_tab_to_new_workspace(tabs[0], None, None, None).unwrap());
    mux.move_tab_to_workspace(tabs[1], Some(internal_id(&mux, &moved))).unwrap();
    assert_eq!(workspace_of(&mux, tabs[1]), moved);
    assert!(mux.close_surface(tabs[1]).unwrap());
    mutate(&mux, "workspace.close", json!({"workspace": moved}), "close-moved");
    let records = closed(&mux);
    assert!(records.is_empty(), "incognito content was recorded: {records:?}");
    mux.shutdown();
}

/// The daemon closes a workspace made from ephemeral content at its next
/// start, as it closes the source.
#[test]
fn a_workspace_made_from_ephemeral_content_is_closed_at_the_next_start() {
    let session = Session::new("ephemeral-move-restart");
    let mux = session.open();
    let (_, kept) = workspace_with_tabs(&mux, "kept", false, 1);
    let kept = workspace_of(&mux, kept[0]);
    let (source, tabs) = workspace_with_tabs(&mux, "incognito", true, 2);
    let moved = public_id(&mux, mux.move_tab_to_new_workspace(tabs[0], None, None, None).unwrap());
    drop(mux);

    let mux = session.open();
    let workspaces = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    assert!(workspaces.iter().any(|value| value["id"] == kept.as_str()));
    assert!(!workspaces.iter().any(|value| value["id"] == source.as_str()));
    assert!(
        !workspaces.iter().any(|value| value["id"] == moved.as_str()),
        "the moved workspace was restored"
    );
    assert!(closed(&mux).is_empty());
}

/// A move out of a normal workspace makes a normal workspace, and its close
/// is recorded as before.
#[test]
fn a_move_out_of_a_normal_workspace_stays_normal_and_recorded() {
    let mux = Mux::new_for_test("ephemeral-move-normal", SurfaceOptions::default());
    let (_, tabs) = workspace_with_tabs(&mux, "normal", false, 2);
    let moved = public_id(&mux, mux.move_tab_to_new_workspace(tabs[0], None, None, None).unwrap());
    assert!(!flagged(&mux, &moved));
    mutate(&mux, "workspace.close", json!({"workspace": moved}), "close-moved");
    let records = closed(&mux);
    assert_eq!(records.len(), 1, "{records:?}");
    assert_eq!(records[0]["kind"], "workspace");
    mux.shutdown();
}

/// Tabs and screens never move between an ephemeral workspace and an
/// existing normal one, in either direction, through the v2 operation the
/// CLI sends (with the refusal message) or a raw command; the content stays
/// where it was.
#[test]
fn moves_between_an_ephemeral_and_a_normal_workspace_are_refused() {
    let mux = Mux::new_for_test("ephemeral-move-refused", SurfaceOptions::default());
    let (normal, normal_tabs) = workspace_with_tabs(&mux, "normal", false, 2);
    let (incognito, incognito_tabs) = workspace_with_tabs(&mux, "incognito", true, 2);

    for (tab, from, to) in [
        (incognito_tabs[0], &incognito, normal_tabs[1]),
        (normal_tabs[0], &normal, incognito_tabs[1]),
    ] {
        let params = json!({
            "tab": tab_id(&mux, tab),
            "destination_workspace": workspace_of(&mux, to),
            "destination_screen": screen_public_id(&mux, to),
            "destination_pane": pane_id(&mux, to),
            "index": 0,
        });
        let error = send(&mux, "tab.move", params, Some(&format!("move-{tab}"))).unwrap_err();
        assert!(error.message.contains("ephemeral"), "{error:?}");
        assert!(
            mux.move_tab_to_workspace(tab, Some(internal_id(&mux, &workspace_of(&mux, to))))
                .is_err()
        );
        assert_eq!(&workspace_of(&mux, tab), from);
    }

    for (from, to) in [(&incognito, &normal), (&normal, &incognito)] {
        let screen =
            screen_of(&mux, mux.new_screen(Some(internal_id(&mux, from)), None).unwrap().id);
        let destination =
            ScreenDestination::Workspace { workspace: Some(internal_id(&mux, to)), index: None };
        let error = mux.move_screen(screen, destination).unwrap_err();
        assert!(format!("{error:#}").contains("ephemeral"), "{error:#}");
    }
    mux.shutdown();
}
