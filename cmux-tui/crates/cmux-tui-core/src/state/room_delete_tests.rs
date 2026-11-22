//! SPACE-DELETE-CLOSES-ITS-WORKSPACES and RECOVERABLE-BY-DEFAULT: deleting a
//! space (a room) closes every workspace that only that space shows, in one
//! closed-history group, and Reopen Closed (Cmd-Shift-T) restores the space
//! with its name, order and membership, and its workspaces. Driven through
//! `cmux.protocol/2` requests.

use serde_json::json;

use super::tests::{mutate, read, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// The public id of the workspace that shows `surface`.
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

fn rooms(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "room.list", json!({})).as_array().cloned().unwrap_or_default()
}

fn pinned_workspaces(room: &Value) -> Vec<String> {
    room["pins"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|pin| pin["workspace_id"].as_str().map(str::to_string))
        .collect()
}

#[test]
fn deleting_a_space_closes_its_workspaces_and_cmd_shift_t_restores_the_space() {
    let mux = Mux::new_for_test("room-delete-closes", SurfaceOptions::default());
    let kept = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let first = workspace_of(&mux, terminal_tabs(&mux, 2)[0]);
    let second = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let left = mutate(&mux, "room.create", json!({"name": "Left"}), "room-left");
    let room = mutate(&mux, "room.create", json!({"name": "Side", "icon": "star"}), "room-1");
    let room_id = room["id"].as_str().unwrap().to_string();
    let index = room["index"].clone();
    mutate(&mux, "room.pin", json!({"room": room_id, "workspace": first}), "pin-1");
    mutate(&mux, "room.pin", json!({"room": room_id, "workspace": second}), "pin-2");
    let before = live_workspaces(&mux).len();

    mutate(&mux, "room.delete", json!({"room": room_id}), "delete");

    let after = live_workspaces(&mux);
    assert_eq!(after.len(), before - 2, "both workspaces of the space close: {after:?}");
    assert!(after.contains(&kept), "a workspace of another space stays open");
    assert!(!after.contains(&first) && !after.contains(&second));
    assert!(rooms(&mux).iter().all(|room| room["id"] != room_id), "the space is gone");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 1, "one delete, one group: {closed}");
    assert_eq!(closed[0]["kind"], "workspace");
    assert_eq!(closed[0]["member_count"], 2);

    // Cmd-Shift-T: the newest group, no id.
    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(reopened["workspace_ids"].as_array().unwrap().len(), 2);
    assert_eq!(live_workspaces(&mux).len(), before);
    let restored = rooms(&mux)
        .into_iter()
        .find(|room| room["id"] == room_id)
        .expect("Cmd-Shift-T restores the space with its id");
    assert_eq!(restored["name"], "Side");
    assert_eq!(restored["icon"], "star");
    assert_eq!(restored["index"], index, "the space keeps its place in the order");
    let mut pinned = pinned_workspaces(&restored);
    pinned.sort();
    let mut expected = reopened["workspace_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| id.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    expected.sort();
    assert_eq!(pinned, expected, "the reopened workspaces are in the space again");
    assert!(rooms(&mux).iter().any(|room| room["id"] == left["id"]));
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

#[test]
fn deleting_an_empty_space_is_one_group_and_reopen_restores_the_space() {
    let mux = Mux::new_for_test("room-delete-empty", SurfaceOptions::default());
    let kept = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let room = mutate(&mux, "room.create", json!({"name": "Empty", "color": "green"}), "room");
    let room_id = room["id"].as_str().unwrap().to_string();

    mutate(&mux, "room.delete", json!({"room": room_id}), "delete");
    assert!(live_workspaces(&mux).contains(&kept));
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 1, "the delete is recorded: {closed}");
    assert_eq!(closed[0]["member_count"], 0);

    mutate(&mux, "closed.reopen", json!({"closed": closed[0]["id"]}), "reopen");
    let restored = rooms(&mux).into_iter().find(|room| room["id"] == room_id);
    assert_eq!(restored.expect("the empty space comes back")["name"], "Empty");
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

#[test]
fn deleting_a_space_moving_to_another_keeps_the_workspaces_open() {
    let mux = Mux::new_for_test("room-delete-move", SurfaceOptions::default());
    let workspace = workspace_of(&mux, terminal_tabs(&mux, 1)[0]);
    let target = mutate(&mux, "room.create", json!({"name": "Target"}), "target");
    let room = mutate(&mux, "room.create", json!({"name": "Side"}), "room");
    mutate(&mux, "room.pin", json!({"room": room["id"], "workspace": workspace}), "pin");

    mutate(&mux, "room.delete", json!({"room": room["id"], "move_to": target["id"]}), "delete");
    assert!(live_workspaces(&mux).contains(&workspace), "an explicit move keeps it open");
    let target = rooms(&mux).into_iter().find(|room| room["id"] == target["id"]).unwrap();
    assert_eq!(pinned_workspaces(&target), vec![workspace]);
}
