//! `closed-history-v2` (plans/cmux-next/reopen-closed.md): one close gesture
//! is one restore group, restore puts every member back where it was, and
//! Reopen Closed without an id takes the newest group of the caller's
//! window, else a group of a closed window, never one of another live
//! window. Driven through `cmux.protocol/2` requests.

use serde_json::json;

use super::tests::{error_code, mutate, pane_id, pane_tab_ids, read, send, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// The registry key of the workspace that shows `surface`.
fn workspace_key(mux: &Arc<Mux>, surface: SurfaceId) -> String {
    let public = mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    });
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
            [&public],
            |row| row.get::<_, String>(0),
        )?)
    })
    .unwrap()
}

fn put_window(mux: &Arc<Mux>, window: &str, keys: &[&str]) {
    mutate(
        mux,
        "window_record.put",
        json!({"install_id": "install_a", "window_id": window,
               "record": {"workspace_key": keys[0], "workspace_keys": keys}}),
        &format!("put-{window}"),
    );
}

/// A tab group close is one gesture: one group with two members, and one
/// reopen restores both tabs at their old positions.
#[test]
fn a_bulk_close_is_one_group_and_one_reopen_restores_every_tab_in_place() {
    let mux = Mux::new_for_test("closed-v2-bulk", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 4);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    let group = mutate(&mux, "tab_group.create", json!({"tabs": [ids[1], ids[2]]}), "group");
    mutate(&mux, "tab_group.close", json!({"tab_group": group["id"]}), "group-close");

    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 1, "one gesture, one group: {closed}");
    assert_eq!(closed[0]["kind"], "tab");
    assert_eq!(closed[0]["member_count"], 2);
    assert_eq!(closed[0]["members"].as_array().unwrap().len(), 2);
    assert_eq!(closed[0]["members"][0]["pane_id"], pane_id(&mux, tabs[0]));
    assert_eq!(closed[0]["members"][0]["index"], 1);
    assert_eq!(closed[0]["members"][1]["index"], 2);

    let reopened = mutate(&mux, "closed.reopen", json!({"closed": closed[0]["id"]}), "reopen");
    assert_eq!(reopened["tab_ids"].as_array().unwrap().len(), 2);
    assert_eq!(reopened["remaining"], 0);
    let order = pane_tab_ids(&mux, tabs[0]);
    assert_eq!(order.len(), 4);
    assert_eq!(order[0], ids[0]);
    assert_eq!(order[1], reopened["tab_ids"][0]);
    assert_eq!(order[2], reopened["tab_ids"][1]);
    assert_eq!(order[3], ids[3]);
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

/// Partial restore from the Reopen Closed list: one member comes back, the
/// rest of the group stays listed.
#[test]
fn a_partial_reopen_restores_the_chosen_members_and_keeps_the_rest() {
    let mux = Mux::new_for_test("closed-v2-partial", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 4);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    let group =
        mutate(&mux, "tab_group.create", json!({"tabs": [ids[1], ids[2], ids[3]]}), "group");
    mutate(&mux, "tab_group.close", json!({"tab_group": group["id"]}), "group-close");
    let id = read(&mux, "closed.list", json!({}))[0]["id"].clone();

    let partial = mutate(&mux, "closed.reopen", json!({"closed": id, "members": [1]}), "one");
    assert_eq!(partial["tab_ids"].as_array().unwrap().len(), 1);
    assert_eq!(partial["remaining"], 2);
    let listed = read(&mux, "closed.list", json!({}));
    assert_eq!(listed[0]["id"], id);
    assert_eq!(listed[0]["member_count"], 2);
    assert_eq!(listed[0]["members"][0]["index"], 1);
    assert_eq!(listed[0]["members"][1]["index"], 3);

    let bad = send(&mux, "closed.reopen", json!({"closed": id, "members": [5]}), Some("bad"));
    assert_eq!(error_code(bad), "validation.invalid");

    let rest = mutate(&mux, "closed.reopen", json!({"closed": id}), "rest");
    assert_eq!(rest["tab_ids"].as_array().unwrap().len(), 2);
    assert_eq!(rest["remaining"], 0);
    assert_eq!(pane_tab_ids(&mux, tabs[0]).len(), 4);
}

/// Reopen Closed without an id (Cmd-Shift-T): the newest group of the
/// caller's window; then a group of a closed window; never a group of
/// another live window. A retry with the same key replays, it does not
/// restore a second group.
#[test]
fn reopen_without_an_id_is_scoped_to_the_window() {
    let mux = Mux::new_for_test("closed-v2-window", SurfaceOptions::default());
    let first = terminal_tabs(&mux, 2);
    let second = terminal_tabs(&mux, 2);
    put_window(&mux, "win_1", &[&workspace_key(&mux, first[0])]);
    put_window(&mux, "win_2", &[&workspace_key(&mux, second[0])]);
    assert!(mux.close_surface(first[1]).unwrap());
    assert!(mux.close_surface(second[1]).unwrap());

    let all = read(&mux, "closed.list", json!({}));
    assert_eq!(all.as_array().unwrap().len(), 2);
    assert_eq!(all[0]["window"], "install_a/win_2");
    assert_eq!(all[1]["window"], "install_a/win_1");
    let scoped = read(&mux, "closed.list", json!({"window": "install_a/win_1"}));
    assert_eq!(scoped.as_array().unwrap().len(), 1, "another live window's group: {scoped}");
    assert_eq!(scoped[0]["id"], all[1]["id"]);

    let press = json!({"window": "install_a/win_1"});
    let restored = mutate(&mux, "closed.reopen", press.clone(), "press-1");
    assert_eq!(restored["closed_id"], all[1]["id"]);
    assert_eq!(pane_tab_ids(&mux, first[0]).len(), 2);
    let replay = send(&mux, "closed.reopen", press.clone(), Some("press-1")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(pane_tab_ids(&mux, second[0]).len(), 1, "a replay restores nothing new");
    let empty = send(&mux, "closed.reopen", press.clone(), Some("press-2"));
    assert_eq!(error_code(empty), "resource.not_found");

    // win_2 closes: its group becomes reachable from win_1.
    mutate(
        &mux,
        "window_record.delete",
        json!({"install_id": "install_a", "window_id": "win_2"}),
        "drop-win-2",
    );
    let orphan = mutate(&mux, "closed.reopen", press, "press-3");
    assert_eq!(orphan["closed_id"], all[0]["id"]);
    assert_eq!(pane_tab_ids(&mux, second[0]).len(), 2);
}

/// A registry from before groups: every v1 item becomes a one-member group
/// with the same id, newest first, and the v1 table is dropped.
#[test]
fn v1_closed_items_migrate_to_one_member_groups() {
    use crate::state::closed_history_store::{closed_items, create_closed_history_schema};
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE closed_history (
               closed_id TEXT PRIMARY KEY NOT NULL,
               kind TEXT NOT NULL CHECK(kind IN ('tab','screen','workspace')),
               record_json TEXT NOT NULL,
               closed_at_ms INTEGER NOT NULL CHECK(closed_at_ms >= 0),
               sequence INTEGER NOT NULL
             );",
        )
        .unwrap();
    for (sequence, name) in [(1, "older"), (2, "newer")] {
        let id = format!("closed_{name}");
        let record = json!({"id": id, "kind": "workspace", "name": name, "workspace_id": null,
            "pane_id": null, "index": 3, "closed_at_ms": "1000",
            "screens": [{"name": null, "tabs": [{"kind": "terminal", "name": null,
                "cwd": "/tmp", "url": null, "browser_profile_id": null, "pinned": false}]}]});
        connection
            .execute(
                "INSERT INTO closed_history VALUES(?1, 'workspace', ?2, 1000, ?3)",
                rusqlite::params![id, record.to_string(), sequence],
            )
            .unwrap();
    }
    let transaction = connection.transaction().unwrap();
    create_closed_history_schema(&transaction).unwrap();
    transaction.commit().unwrap();

    let items = closed_items(&connection).unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["id"], "closed_newer");
    assert_eq!(items[0]["name"], "newer");
    assert_eq!(items[0]["member_count"], 1);
    assert_eq!(items[0]["window"], Value::Null);
    assert_eq!(items[0]["members"][0]["index"], 3);
    assert_eq!(items[0]["members"][0]["screens"][0]["tabs"][0]["cwd"], "/tmp");
    let v1_left: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'closed_history'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(v1_left, 0);
}
