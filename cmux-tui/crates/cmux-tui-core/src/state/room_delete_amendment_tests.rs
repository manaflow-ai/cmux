//! SPACE-DELETE-CLOSES-ITS-WORKSPACES amendment 1 (2026-10-07): a workspace
//! that another space also shows stays open, and a workspace of another
//! session (a remote machine, a Cloud VM) is never closed on its daemon: the
//! delete only drops its pin. Driven through `cmux.protocol/2` requests.

use serde_json::json;

use super::tests::{mutate, read, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::state::values::local_registry_id;
use crate::surface::SurfaceOptions;

fn workspace_of(mux: &Arc<Mux>, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    })
}

fn live_workspaces(mux: &Arc<Mux>) -> Vec<String> {
    mux.with_state(|state| {
        state.workspaces.iter().map(|workspace| workspace.public_id.to_string()).collect()
    })
}

fn local_session(mux: &Arc<Mux>) -> String {
    mux.read_registry_state(local_registry_id).unwrap()
}

#[test]
fn a_workspace_another_space_also_shows_stays_open() {
    let mux = Mux::new_for_test("room-delete-shared", SurfaceOptions::default());
    let shared = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let session = local_session(&mux);
    let side = mutate(&mux, "room.create", json!({"name": "Side"}), "side");
    let other = mutate(&mux, "room.create", json!({"name": "Other"}), "other");
    // Both spaces follow this Mac, so both show its unpinned workspaces.
    mutate(&mux, "room.follow", json!({"room": side["id"], "sessions": [session]}), "f1");
    mutate(&mux, "room.follow", json!({"room": other["id"], "sessions": [session]}), "f2");
    let before = live_workspaces(&mux);

    mutate(&mux, "room.delete", json!({"room": side["id"]}), "delete");

    assert_eq!(live_workspaces(&mux), before, "nothing closes while another space shows it");
    assert!(live_workspaces(&mux).contains(&shared));
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 1, "the delete is still recorded: {closed}");
    assert_eq!(closed[0]["member_count"], 0);
}

#[test]
fn a_workspace_of_another_session_loses_its_pin_and_is_not_closed() {
    let mux = Mux::new_for_test("room-delete-remote", SurfaceOptions::default());
    let local = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let room = mutate(&mux, "room.create", json!({"name": "Remote"}), "room");
    let room_id = room["id"].as_str().unwrap().to_string();
    // A Cloud VM's workspace pinned to the space (its own daemon owns it).
    mux.personal_mutation(|registry| {
        Ok(((), registry.pin_workspace("cloud-vm-1", "ws-on-the-vm", &room_id)?))
    })
    .unwrap();
    let before = live_workspaces(&mux);

    let deleted = mutate(&mux, "room.delete", json!({"room": room_id}), "delete");

    assert_eq!(live_workspaces(&mux), before, "no local workspace closes");
    assert!(live_workspaces(&mux).contains(&local));
    let pins = mux
        .read_registry_state(|connection| {
            Ok(connection
                .prepare("SELECT COUNT(*) FROM profile_pins WHERE session_id = 'cloud-vm-1'")?
                .query_row([], |row| row.get::<_, i64>(0))?)
        })
        .unwrap();
    assert_eq!(pins, 0, "the VM workspace lost its pin: {deleted}");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed[0]["member_count"], 0, "the VM workspace is not a closed member: {closed}");
}
