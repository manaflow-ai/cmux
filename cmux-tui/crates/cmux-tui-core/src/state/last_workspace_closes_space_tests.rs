//! LAST-WORKSPACE-CLOSES-SPACE (Lawrence 2026-11-15: "if you close the last
//! thing in a space, we should close that space. same for screens. same for
//! workspaces. same for panes. make it consistent"): the close that takes a
//! space's last workspace deletes that space in the same commit, by every
//! close path, and one Reopen Closed (Cmd-Shift-T) brings back both. The
//! Default space, a space that still shows another workspace and a space
//! that follows another machine (whose workspaces this daemon cannot see)
//! stay. Driven through `cmux.protocol/2` requests and the mux close paths.

use serde_json::json;

use super::tests::{Session, mutate, read, revision, send, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::state::values::local_registry_id;
use crate::surface::SurfaceOptions;

fn workspace_of(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).expect("tab is placed");
        let (workspace, _) = state.screen_of(pane).expect("pane is on a screen");
        state.workspaces[workspace].public_id.to_string()
    })
}

fn workspace_index(mux: &Mux, workspace: &str) -> WorkspaceId {
    mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .find(|candidate| candidate.public_id.as_str() == workspace)
            .expect("workspace is live")
            .id
    })
}

fn live_workspaces(mux: &Mux) -> Vec<String> {
    mux.with_state(|state| {
        state.workspaces.iter().map(|workspace| workspace.public_id.to_string()).collect()
    })
}

fn room_ids(mux: &Arc<Mux>) -> Vec<String> {
    read(mux, "room.list", json!({}))
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(|room| room["id"].as_str().map(str::to_string))
        .collect()
}

fn room(mux: &Arc<Mux>, id: &str) -> Option<Value> {
    read(mux, "room.list", json!({}))
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .find(|room| room["id"] == id)
}

/// A space named `name` with `surface`'s workspace pinned to it.
fn space_with(mux: &Arc<Mux>, name: &str, surface: SurfaceId) -> String {
    let created = mutate(mux, "room.create", json!({"name": name}), &format!("room-{name}"));
    let id = created["id"].as_str().unwrap().to_string();
    let workspace = workspace_of(mux, surface);
    mutate(mux, "room.pin", json!({"room": id, "workspace": workspace}), &format!("pin-{name}"));
    id
}

/// Closing the last tab of a space's only workspace closes the workspace
/// and deletes the space in that one commit; the closed history holds one
/// group, named by the workspace, and Cmd-Shift-T restores the space with its
/// name, place and pin, and the workspace in it.
#[test]
fn closing_a_spaces_last_workspace_deletes_the_space_in_the_same_commit() {
    let mux = Mux::new_for_test("space-last-commit", SurfaceOptions::default());
    let kept = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let surface = terminal_tabs(&mux, 1)[0];
    let workspace = workspace_of(&mux, surface);
    let space = space_with(&mux, "Side", surface);
    let index = room(&mux, &space).unwrap()["index"].clone();
    let personal_before = mux.personal_snapshot().unwrap().personal_revision;
    let events = mux.subscribe();
    let before = revision(&mux);

    assert!(mux.close_surface(surface).unwrap());

    assert!(!live_workspaces(&mux).contains(&workspace), "the workspace closes");
    assert!(live_workspaces(&mux).contains(&kept));
    assert!(!room_ids(&mux).contains(&space), "the emptied space was kept");
    assert!(room_ids(&mux).contains(&"default".to_string()), "the Default space stays");
    assert_eq!(revision(&mux), before + 1, "the space went in a second commit");
    assert!(
        events.try_iter().any(|event| matches!(
            event,
            MuxEvent::PersonalChanged { personal_revision } if personal_revision > personal_before
        )),
        "clients hear the space go (personal-changed)"
    );
    let closed = read(&mux, "closed.list", json!({}));
    let groups = closed.as_array().unwrap();
    assert_eq!(groups.len(), 1, "one close, one group: {closed}");
    assert_eq!(groups[0]["kind"], "workspace");
    assert_ne!(groups[0]["name"], "Side", "the row names the closed workspace: {closed}");

    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    let restored = room(&mux, &space).expect("one Cmd-Shift-T restores the space");
    assert_eq!(restored["name"], "Side");
    assert_eq!(restored["index"], index, "the space keeps its place");
    let pinned = restored["pins"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|pin| pin["workspace_id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    assert_eq!(
        pinned,
        reopened["workspace_ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|id| id.as_str().unwrap().to_string())
            .collect::<Vec<_>>(),
        "the reopened workspace is in the space again"
    );
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

/// A named way to close the workspace that shows `SurfaceId`.
type ClosePath<'a> = (&'a str, &'a dyn Fn(&Arc<Mux>, SurfaceId));

/// Every close of a space's last workspace deletes the space: the workspace
/// itself (raw and `workspace.close`), its last screen, pane or tab, and
/// `close-tabs`.
#[test]
fn every_close_path_deletes_the_emptied_space() {
    let session = Session::new("space-every-path");
    let mux = session.open();
    let _keep = mux.new_workspace(None, None).unwrap();
    let paths: [ClosePath<'_>; 7] = [
        ("close-workspace", &|mux, surface| {
            let id = workspace_index(mux, &workspace_of(mux, surface));
            assert!(mux.close_workspace(id));
        }),
        ("workspace.close", &|mux, surface| {
            let workspace = workspace_of(mux, surface);
            send(mux, "workspace.close", json!({"workspace": workspace}), Some("ws-close"))
                .unwrap();
        }),
        ("close-screen", &|mux, surface| {
            let screen = mux.with_state(|state| {
                let (workspace, screen) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
                state.workspaces[workspace].screens[screen].id
            });
            assert!(mux.close_screen(screen).unwrap());
        }),
        ("close-pane", &|mux, surface| {
            let pane = mux.with_state(|state| state.pane_of(surface)).unwrap();
            assert!(mux.close_pane(pane).unwrap());
        }),
        ("close-surface", &|mux, surface| {
            assert!(mux.close_surface(surface).unwrap());
        }),
        ("tab.close", &|mux, surface| {
            let tab = tab_id(mux, surface);
            send(mux, "tab.close", json!({"tab": tab}), Some("tab-close")).unwrap();
        }),
        ("close-tabs", &|mux, surface| {
            let mutation = WorkspaceMutation::daemon("close-tabs-space", "test").unwrap();
            mux.close_tabs_for(vec![surface], false, None, &mutation).unwrap();
        }),
    ];
    for (name, close) in paths {
        let surface = mux.new_workspace(None, None).unwrap();
        let space = space_with(&mux, name, surface.id);
        close(&mux, surface.id);
        assert!(!room_ids(&mux).contains(&space), "{name} kept the emptied space");
    }
    mux.shutdown();
}

/// A space that still shows a workspace stays; it goes with its last one.
#[test]
fn a_space_with_another_workspace_stays_until_its_last_closes() {
    let mux = Mux::new_for_test("space-two-workspaces", SurfaceOptions::default());
    let _kept = terminal_tabs(&mux, 1)[0];
    let first = terminal_tabs(&mux, 1)[0];
    let second = terminal_tabs(&mux, 1)[0];
    let space = space_with(&mux, "Side", first);
    mutate(&mux, "room.pin", json!({"room": space, "workspace": workspace_of(&mux, second)}), "p2");

    assert!(mux.close_surface(first).unwrap());
    assert!(room_ids(&mux).contains(&space), "a space that shows a workspace was deleted");

    assert!(mux.close_surface(second).unwrap());
    assert!(!room_ids(&mux).contains(&space), "the space outlived its last workspace");
}

/// A space that follows this Mac shows its unpinned workspaces: it stays
/// while one is open. A space that follows another machine may show that
/// machine's workspaces, which this daemon cannot see: it stays.
#[test]
fn a_followed_session_keeps_the_space_while_it_may_show_a_workspace() {
    let mux = Mux::new_for_test("space-follows", SurfaceOptions::default());
    let local = mux.read_registry_state(local_registry_id).unwrap();
    let unpinned = terminal_tabs(&mux, 1)[0];
    let pinned = terminal_tabs(&mux, 1)[0];
    let follows_here = space_with(&mux, "Here", pinned);
    mutate(&mux, "room.follow", json!({"room": follows_here, "sessions": [local]}), "f-here");
    let remote_pinned = terminal_tabs(&mux, 1)[0];
    let follows_remote = space_with(&mux, "Remote", remote_pinned);
    mutate(
        &mux,
        "room.follow",
        json!({"room": follows_remote, "sessions": ["cloud-vm-1"]}),
        "f-remote",
    );

    assert!(mux.close_surface(pinned).unwrap());
    assert!(room_ids(&mux).contains(&follows_here), "it still shows the unpinned workspace");
    assert!(mux.close_surface(remote_pinned).unwrap());
    assert!(room_ids(&mux).contains(&follows_remote), "it may show the VM's workspaces");
    assert!(live_workspaces(&mux).contains(&workspace_of(&mux, unpinned)));
}

/// A space with a pin of another machine's workspace may still show it: it
/// stays when its last local workspace closes.
#[test]
fn a_remote_pin_keeps_the_space() {
    let mux = Mux::new_for_test("space-remote-pin", SurfaceOptions::default());
    let _kept = terminal_tabs(&mux, 1)[0];
    let surface = terminal_tabs(&mux, 1)[0];
    let space = space_with(&mux, "Mixed", surface);
    mux.personal_mutation(|registry| {
        Ok(((), registry.pin_workspace("cloud-vm-1", "ws-on-the-vm", &space)?))
    })
    .unwrap();

    assert!(mux.close_surface(surface).unwrap());
    assert!(room_ids(&mux).contains(&space), "the VM's workspace still shows there");
}

/// The Default space is never deleted, also when its last workspace closes:
/// cmux always has a space.
#[test]
fn the_default_space_stays_when_its_last_workspace_closes() {
    let mux = Mux::new_for_test("space-default", SurfaceOptions::default());
    let surface = terminal_tabs(&mux, 1)[0];
    let other = terminal_tabs(&mux, 1)[0];
    let space = space_with(&mux, "Side", other);

    assert!(mux.close_surface(surface).unwrap());
    assert!(room_ids(&mux).contains(&"default".to_string()));
    assert!(room_ids(&mux).contains(&space), "closing a Default workspace deleted another space");
}

/// Deleting a space (which closes its workspaces itself) is still one group
/// that reopens the space once: the cascade does not add a second delete.
#[test]
fn delete_space_is_not_doubled_by_the_cascade() {
    let mux = Mux::new_for_test("space-delete-once", SurfaceOptions::default());
    let _kept = terminal_tabs(&mux, 1)[0];
    let surface = terminal_tabs(&mux, 1)[0];
    let space = space_with(&mux, "Side", surface);

    mutate(&mux, "room.delete", json!({"room": space}), "delete");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 1, "{closed}");
    assert_eq!(closed[0]["name"], "Side", "a Delete Space row names the space: {closed}");
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert!(room_ids(&mux).contains(&space));
}
