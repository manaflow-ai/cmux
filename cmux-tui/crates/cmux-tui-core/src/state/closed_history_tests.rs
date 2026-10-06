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
    insert_v1_at(connection, name, sequence, sequence * 1000);
}

/// A v1 row with an explicit close time (one v1 close writes several rows
/// in the same millisecond).
fn insert_v1_at(connection: &rusqlite::Connection, name: &str, sequence: i64, closed_at_ms: i64) {
    let id = format!("closed_{name}");
    let record = json!({"id": id, "kind": "workspace", "name": name, "workspace_id": null,
        "pane_id": null, "index": 3, "closed_at_ms": "1000",
        "screens": [{"name": null, "tabs": [{"kind": "terminal", "name": null,
            "cwd": "/tmp", "url": null, "browser_profile_id": null, "pinned": false}]}]});
    connection
        .execute(
            "INSERT INTO closed_history VALUES(?1, 'workspace', ?2, ?3, ?4)",
            rusqlite::params![id, record.to_string(), closed_at_ms, sequence],
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

/// The v1 daemon evicts by sequence, lowest first. A removed copied row
/// with an OLDER copied row still present was reopened (eviction would have
/// taken the older row first), so its group leaves v2 and is never
/// reopened twice. Any other removed row may have been evicted, so its
/// group stays: history is kept (a row the older daemon reopened from the
/// bottom of the table can then be reopened once more; v1 cannot tell).
#[test]
fn an_item_a_downgraded_daemon_reopened_leaves_v2_at_the_next_upgrade() {
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    for sequence in 1..=3 {
        insert_v1(&connection, &format!("small{sequence}"), sequence);
    }
    open_schema(&mut connection);
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_small2'", []).unwrap();
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection), vec![json!("closed_small3"), json!("closed_small1")]);
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection).len(), 2, "a second upgrade changes nothing");
    // The oldest row may have been evicted: its group stays.
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_small1'", []).unwrap();
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection), vec![json!("closed_small3"), json!("closed_small1")]);
}

/// A full v1 table (50 rows): the older daemon closes one more item, which
/// evicts full1, and the user reopens that new item. full1 was evicted, not
/// reopened, so its group stays. Ties in close time do not matter.
#[test]
fn an_evicted_row_keeps_its_group_even_when_the_new_row_was_reopened() {
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    for sequence in 1..=50 {
        insert_v1_at(&connection, &format!("full{sequence}"), sequence, 1000);
    }
    open_schema(&mut connection);
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_full1'", []).unwrap();
    insert_v1_at(&connection, "full51", 51, 1000);
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_full51'", []).unwrap();
    // And the user reopens full10 in the older daemon.
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_full10'", []).unwrap();
    open_schema(&mut connection);
    let ids = group_ids(&connection);
    assert_eq!(ids.len(), 49);
    assert!(ids.contains(&json!("closed_full1")), "an evicted row keeps its group");
    assert!(!ids.contains(&json!("closed_full10")), "a reopened row loses its group");
}

/// Reopening or deleting a copied group in v2 also removes its v1 row, so a
/// downgraded daemon cannot reopen the item a second time.
#[test]
fn a_copied_group_reopened_in_v2_leaves_v1_too() {
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    insert_v1(&connection, "a", 1);
    insert_v1(&connection, "b", 2);
    open_schema(&mut connection);
    let transaction = connection.transaction().unwrap();
    assert!(crate::state::closed_history_query::remove_closed(&transaction, "closed_b").unwrap());
    transaction.commit().unwrap();
    assert_eq!(v1_names(&connection), vec!["closed_a"]);
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection), vec![json!("closed_a")]);
}

/// A registry that S1 (closed_at_ms ledger) already migrated keeps working:
/// the ledger gains the v1 sequence of every row still in v1. A row removed
/// before that fill has no known sequence, so its group stays.
#[test]
fn a_ledger_from_the_first_v2_build_gains_sequences() {
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    connection.execute_batch(V1_TABLE).unwrap();
    for sequence in 1..=3 {
        insert_v1(&connection, &format!("old{sequence}"), sequence);
    }
    open_schema(&mut connection);
    connection
        .execute_batch(
            "DROP TABLE closed_v1_copied;
             CREATE TABLE closed_v1_copied (closed_id TEXT PRIMARY KEY NOT NULL,
                                            closed_at_ms INTEGER NOT NULL);
             INSERT INTO closed_v1_copied
               SELECT closed_id, closed_at_ms FROM closed_history;",
        )
        .unwrap();
    // The first open of this build fills the sequences of rows still in v1.
    open_schema(&mut connection);
    connection.execute("DELETE FROM closed_history WHERE closed_id = 'closed_old2'", []).unwrap();
    open_schema(&mut connection);
    assert_eq!(group_ids(&connection), vec![json!("closed_old3"), json!("closed_old1")]);
}
