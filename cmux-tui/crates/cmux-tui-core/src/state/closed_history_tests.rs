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

/// A group whose window record is live is never reopened from another
/// window: a press in another window refuses, the group stays, and its own
/// window still reopens it (decision P1-2).
#[test]
fn a_group_of_a_live_window_is_never_reopened_from_another_window() {
    let mux = Mux::new_for_test("closed-v2-live-window", SurfaceOptions::default());
    let first = terminal_tabs(&mux, 2);
    let second = terminal_tabs(&mux, 2);
    put_window(&mux, "win_1", &[&workspace_key(&mux, first[0])]);
    put_window(&mux, "win_2", &[&workspace_key(&mux, second[0])]);
    assert!(mux.close_surface(second[1]).unwrap());
    let group = read(&mux, "closed.list", json!({}))[0]["id"].clone();

    let other = send(&mux, "closed.reopen", json!({"window": "install_a/win_1"}), Some("w1"));
    assert_eq!(error_code(other), "resource.not_found");
    assert!(
        read(&mux, "closed.list", json!({"window": "install_a/win_1"}))
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(read(&mux, "closed.list", json!({}))[0]["id"], group);
    assert_eq!(pane_tab_ids(&mux, second[0]).len(), 1);

    let own = mutate(&mux, "closed.reopen", json!({"window": "install_a/win_2"}), "w2");
    assert_eq!(own["closed_id"], group);
    assert_eq!(pane_tab_ids(&mux, second[0]).len(), 2);
}

const V1_TABLE: &str = "CREATE TABLE closed_history (
    closed_id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('tab','screen','workspace')),
    record_json TEXT NOT NULL,
    closed_at_ms INTEGER NOT NULL CHECK(closed_at_ms >= 0),
    sequence INTEGER NOT NULL
);";

/// What a v1 daemon writes for one closed workspace.
fn insert_v1(connection: &rusqlite::Connection, name: &str, sequence: i64) {
    let id = format!("closed_{name}");
    let record = json!({"id": id, "kind": "workspace", "name": name, "workspace_id": null,
        "pane_id": null, "index": 3, "closed_at_ms": "1000",
        "screens": [{"name": null, "tabs": [{"kind": "terminal", "name": null,
            "cwd": "/tmp", "url": null, "browser_profile_id": null, "pinned": false}]}]});
    connection
        .execute(
            "INSERT INTO closed_history VALUES(?1, 'workspace', ?2, ?3, ?4)",
            rusqlite::params![id, record.to_string(), sequence * 1000, sequence],
        )
        .unwrap();
}

fn open_schema(connection: &mut rusqlite::Connection) {
    let transaction = connection.transaction().unwrap();
    crate::state::closed_history_store::create_closed_history_schema(&transaction).unwrap();
    transaction.commit().unwrap();
}

fn v1_names(connection: &rusqlite::Connection) -> Vec<String> {
    let mut statement =
        connection.prepare("SELECT closed_id FROM closed_history ORDER BY sequence").unwrap();
    statement.query_map([], |row| row.get::<_, String>(0)).unwrap().map(Result::unwrap).collect()
}

/// A registry from before groups: every v1 item is COPIED to a one-member
/// group with the same id, newest first. The v1 table stays untouched for
/// one release, so a downgraded daemon still reads its history.
#[test]
fn v1_closed_items_are_copied_to_one_member_groups_and_v1_stays_readable() {
    use crate::state::closed_history_store::closed_items;
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    insert_v1(&connection, "older", 1);
    insert_v1(&connection, "newer", 2);
    open_schema(&mut connection);

    let items = closed_items(&connection).unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["id"], "closed_newer");
    assert_eq!(items[0]["name"], "newer");
    assert_eq!(items[0]["member_count"], 1);
    assert_eq!(items[0]["window"], Value::Null);
    assert_eq!(items[0]["members"][0]["index"], 3);
    assert_eq!(items[0]["members"][0]["screens"][0]["tabs"][0]["cwd"], "/tmp");
    // An old reader on the migrated store sees its rows.
    assert_eq!(v1_names(&connection), vec!["closed_older", "closed_newer"]);
}

/// The copy is idempotent: opening twice gives the same groups, a group
/// reopened after the copy does not come back, and rows a downgraded v1
/// daemon added meanwhile are copied once, as the newest groups.
#[test]
fn the_v1_copy_is_idempotent_across_reopens_and_downgrades() {
    use crate::state::closed_history_store::closed_items;
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    insert_v1(&connection, "older", 1);
    insert_v1(&connection, "newer", 2);
    open_schema(&mut connection);
    let first = closed_items(&connection).unwrap();
    open_schema(&mut connection);
    assert_eq!(closed_items(&connection).unwrap(), first, "a second open copies nothing");

    connection.execute("DELETE FROM closed_groups WHERE closed_id = 'closed_newer'", []).unwrap();
    open_schema(&mut connection);
    let ids = |items: Vec<Value>| items.iter().map(|i| i["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids(closed_items(&connection).unwrap()), vec![json!("closed_older")]);

    // A downgraded daemon closes one more workspace (v1 sequences restart
    // at 1 when its table empties, so the copy keys on ids, not sequences).
    insert_v1(&connection, "downgraded", 1);
    open_schema(&mut connection);
    assert_eq!(
        ids(closed_items(&connection).unwrap()),
        vec![json!("closed_downgraded"), json!("closed_older")]
    );
    open_schema(&mut connection);
    assert_eq!(closed_items(&connection).unwrap().len(), 2);
}

fn group_ids(connection: &rusqlite::Connection) -> Vec<Value> {
    crate::state::closed_history_store::closed_items(connection)
        .unwrap()
        .iter()
        .map(|item| item["id"].clone())
        .collect()
}

/// A downgraded v1 daemon reopens a copied item (its v1 row goes): the next
/// upgrade removes that group too, so the item is never reopened twice. A
/// v1 daemon also evicts its oldest rows past 50; a row older than every
/// remaining row of a full table may only have been evicted, so its group
/// stays (history is kept).
#[test]
fn an_item_a_downgraded_daemon_reopened_leaves_v2_at_the_next_upgrade() {
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    for sequence in 1..=3 {
        insert_v1(&connection, &format!("small{sequence}"), sequence);
    }
    open_schema(&mut connection);
    // The table never overflowed: every removed row was reopened.
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_small1'", []).unwrap();
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection), vec![json!("closed_small3"), json!("closed_small2")]);
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection).len(), 2, "a second upgrade changes nothing");

    // A full table: the older daemon closes one more item (evicting its
    // oldest row, full1) and reopens full10.
    connection.execute("DELETE FROM closed_history", []).unwrap();
    open_schema(&mut connection);
    assert!(group_ids(&connection).is_empty(), "an empty v1 means all were reopened");
    for sequence in 1..=50 {
        insert_v1(&connection, &format!("full{sequence}"), sequence);
    }
    open_schema(&mut connection);
    connection
        .execute(
            "DELETE FROM closed_history WHERE closed_id IN ('closed_full1', 'closed_full10')",
            [],
        )
        .unwrap();
    insert_v1(&connection, "full51", 51);
    open_schema(&mut connection);
    let ids = group_ids(&connection);
    assert_eq!(ids.len(), 50);
    assert_eq!(ids[0], json!("closed_full51"));
    assert!(ids.contains(&json!("closed_full1")), "an evicted row keeps its group");
    assert!(!ids.contains(&json!("closed_full10")), "a reopened row loses its group");
}

/// Delete Permanently and Clear Recently Closed (`closed.delete`): a group,
/// chosen members of a group, every group, or every group closed at or
/// after `since_ms`. A deleted group cannot be reopened.
#[test]
fn closed_delete_removes_groups_members_and_clears() {
    let mux = Mux::new_for_test("closed-v2-delete", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 4);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    let group = mutate(&mux, "tab_group.create", json!({"tabs": [ids[1], ids[2]]}), "group");
    mutate(&mux, "tab_group.close", json!({"tab_group": group["id"]}), "group-close");
    assert!(mux.close_surface(tabs[3]).unwrap());
    let listed = read(&mux, "closed.list", json!({}));
    let (single, pair) = (listed[0]["id"].clone(), listed[1]["id"].clone());

    let partial = mutate(&mux, "closed.delete", json!({"closed": pair, "members": [0]}), "d1");
    assert_eq!(partial["deleted"], json!([]));
    assert_eq!(partial["updated"], json!([pair]));
    assert_eq!(read(&mux, "closed.list", json!({}))[1]["member_count"], 1);

    let whole = mutate(&mux, "closed.delete", json!({"closed": single}), "d2");
    assert_eq!(whole["deleted"], json!([single]));
    let replay = send(&mux, "closed.delete", json!({"closed": single}), Some("d2")).unwrap();
    assert_eq!(replay["replayed"], true);
    let gone = send(&mux, "closed.reopen", json!({"closed": single}), Some("r1"));
    assert_eq!(error_code(gone), "resource.not_found");

    let future =
        mutate(&mux, "closed.delete", json!({"all": true, "since_ms": "99999999999999"}), "d3");
    assert_eq!(future["deleted"], json!([]));
    let cleared = mutate(&mux, "closed.delete", json!({"all": true}), "d4");
    assert_eq!(cleared["deleted"], json!([pair]));
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());

    for (key, params) in [
        ("bad-1", json!({})),
        ("bad-2", json!({"all": true, "closed": pair})),
        ("bad-3", json!({"all": true, "members": [0]})),
        ("bad-4", json!({"closed": pair, "since_ms": "1"})),
    ] {
        let error = send(&mux, "closed.delete", params.clone(), Some(key));
        assert_eq!(error_code(error), "validation.invalid", "{params}");
    }
}
