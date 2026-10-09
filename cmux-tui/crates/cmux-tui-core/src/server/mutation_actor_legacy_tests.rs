//! P8 landing 3b (plans/cmux-next/identity.md section 3): the legacy
//! commands that still recorded the daemon record the actor of their
//! connection, and the older ledgers store it too.

use super::*;

/// The newest rowids of the two ledgers a command writes: a mutation goes to
/// `resource_mutations`, an effectful one (a layout undo, a close) to
/// `resource_effect_receipts`. A command's rows come after them.
fn mark(mux: &Arc<Mux>) -> (i64, i64) {
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT (SELECT COALESCE(MAX(rowid), 0) FROM resource_mutations),
                      (SELECT COALESCE(MAX(rowid), 0) FROM resource_effect_receipts)";
    registry.connection.query_row(sql, [], |row| Ok((row.get(0)?, row.get(1)?))).unwrap()
}

/// The actors of the `operation` rows of either ledger written after `mark`.
fn actors_since(mux: &Arc<Mux>, mark: (i64, i64), operation: &str) -> Vec<String> {
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM resource_mutations WHERE rowid > ?1 AND operation = ?3
               UNION ALL
               SELECT actor FROM resource_effect_receipts WHERE rowid > ?2 AND operation = ?3";
    let mut statement = registry.connection.prepare(sql).unwrap();
    statement
        .query_map(rusqlite::params![mark.0, mark.1, operation], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

/// Runs `request` on `conn`: it succeeds and writes at least one
/// `operation` row, and every one of them is `actor`'s. Returns the data.
fn assert_recorded(
    mux: &Arc<Mux>,
    conn: &Conn,
    request: Value,
    operation: &str,
    actor: &str,
) -> Value {
    let before = mark(mux);
    let reply = send_legacy(mux, conn, &request);
    assert_eq!(reply["ok"], true, "{request} -> {reply}");
    let actors = actors_since(mux, before, operation);
    assert!(!actors.is_empty(), "{request} wrote no {operation} row");
    assert!(actors.iter().all(|stored| stored == actor), "{request}: {operation} by {actors:?}");
    reply["data"].clone()
}

/// One workspace whose only pane holds two tabs: (pane, first, second).
fn two_tabs(mux: &Arc<Mux>) -> (PaneId, SurfaceId, SurfaceId) {
    let first = mux.new_workspace(Some("tabs".into()), Some((80, 22))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id)).unwrap();
    let second = mux.new_tab(Some(pane), None, Some((80, 22))).unwrap();
    (pane, first.id, second.id)
}

/// A non-creation op: the row is read back from `resource_mutations`.
#[test]
fn a_legacy_select_tab_records_the_websocket_peer() {
    let mux = mux("actor-select-tab");
    let (pane, _, _) = two_tabs(&mux);
    let websocket = connect_websocket(&mux);
    let request = json!({"id": 1, "cmd": "select-tab", "pane": pane, "index": 0});
    assert_recorded(&mux, &websocket, request, "tab.select", "peer:websocket");
}

#[test]
fn a_close_that_ends_terminals_records_its_connection() {
    let mux = mux("actor-close-ending");
    let (pane, _, _) = two_tabs(&mux);
    let right = mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
    let right = mux.with_state(|state| state.pane_of(right.id)).unwrap();
    let plain = connect(&mux);
    let request = json!({"id": 1, "cmd": "close-pane", "pane": right, "end_terminals": true});
    assert_recorded(&mux, &plain, request, "pane.close", "user:user_local");
}

#[test]
fn a_tab_drag_records_its_connection() {
    let mux = mux("actor-tab-drag");
    let (pane, _, second) = two_tabs(&mux);
    let websocket = connect_websocket(&mux);
    let request = json!({
        "id": 1, "cmd": "move-tab-to-split", "surface": second, "pane": pane, "edge": "right",
    });
    assert_recorded(&mux, &websocket, request, "tab.drag", "peer:websocket");
}

#[test]
fn a_column_dock_and_its_undo_record_their_connection() {
    let mux = mux("actor-dock");
    let (mut pane, _, _) = two_tabs(&mux);
    for _ in 0..2 {
        let right = mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
        pane = mux.with_state(|state| state.pane_of(right.id)).unwrap();
    }
    let plain = connect(&mux);
    let dock = json!({
        "id": 1, "cmd": "set-column-dock", "pane": pane, "dock": true, "edge": "right",
        "mode": "docked",
    });
    assert_recorded(&mux, &plain, dock, "pane.column_dock.set", "user:user_local");
    let undo = json!({"id": 2, "cmd": "undo-layout", "pane": pane});
    assert_recorded(&mux, &plain, undo, "screen.layout.undo", "user:user_local");
}

#[test]
fn tab_group_commands_record_their_connection() {
    let mux = mux("actor-tab-groups");
    let (_, first, second) = two_tabs(&mux);
    let websocket = connect_websocket(&mux);
    let peer = "peer:websocket";
    let create = json!({"id": 1, "cmd": "create-tab-group", "surfaces": [first, second]});
    let created = assert_recorded(&mux, &websocket, create, "tab.group.create", peer);
    let group = created["group"]["id"].clone();
    let ungroup = json!({"id": 2, "cmd": "ungroup-tab-group", "group": group});
    assert_recorded(&mux, &websocket, ungroup, "tab.group.ungroup", peer);
    let create = json!({"id": 3, "cmd": "create-tab-group", "surfaces": [first, second]});
    let group =
        assert_recorded(&mux, &websocket, create, "tab.group.create", peer)["group"]["id"].clone();
    let save = json!({"id": 4, "cmd": "save-tab-group", "group": group});
    let saved = assert_recorded(&mux, &websocket, save, "tab.group.save", peer)["saved"].clone();
    let delete = json!({"id": 5, "cmd": "delete-saved-tab-group", "saved": saved});
    assert_recorded(&mux, &websocket, delete, "saved_tab_group.delete", peer);
}

/// The newest `notification.create` receipt's actor.
fn newest_notification_actor(mux: &Arc<Mux>) -> Option<String> {
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM resource_effect_receipts
               WHERE operation = 'notification.create' ORDER BY rowid DESC LIMIT 1";
    registry.connection.query_row(sql, [], |row| row.get::<_, String>(0)).ok()
}

#[test]
fn a_legacy_notify_records_its_connection() {
    let mux = mux("actor-notify");
    let plain = connect(&mux);
    let reply =
        send_legacy(&mux, &plain, &json!({"id": 1, "cmd": "notify", "title": "t", "body": ""}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(newest_notification_actor(&mux).as_deref(), Some("user:user_local"));
}

/// A keyed bookmark op stores its connection's actor with the replay row.
#[test]
fn a_keyed_bookmark_op_records_its_connection() {
    let mux = mux("actor-bookmark");
    let websocket = connect_websocket(&mux);
    let request = json!({
        "id": 1, "cmd": "create-bookmark", "browser_profile_id": "default", "parent": "bar",
        "kind": "folder", "title": "Work", "origin": "test-client", "mutation_id": "bookmark-1",
    });
    let reply = send_legacy(&mux, &websocket, &request);
    assert_eq!(reply["ok"], true, "{reply}");
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM bookmark_mutations WHERE mutation_id = 'bookmark-1'";
    let actor = registry.connection.query_row(sql, [], |row| row.get::<_, String>(0));
    assert_eq!(actor.ok().as_deref(), Some("peer:websocket"));
}

/// The terminal ledger stores the actor too: the terminal a creation
/// reserves is the caller's (the runtime's own commits stay the daemon's).
#[test]
fn terminal_ledger_rows_of_a_creation_are_the_callers() {
    let mux = mux("actor-terminal-ledger");
    let plain = connect(&mux);
    let params = json!({"machine": "current", "session": "current", "initial_content": "terminal"});
    let created = send(&mux, &plain, &v2("workspace.create", params, Some("ledger-1"), None));
    assert_eq!(created["ok"], true, "{created}");
    let registry = mux.workspace_registry.lock().unwrap();
    let sql = "SELECT actor FROM terminal_mutations";
    let mut statement = registry.connection.prepare(sql).unwrap();
    let actors = statement
        .query_map([], |row| row.get::<_, Option<String>>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(actors.iter().all(Option::is_some), "a terminal row without an actor: {actors:?}");
    assert!(actors.iter().any(|actor| actor.as_deref() == Some("user:user_local")), "{actors:?}");
}
