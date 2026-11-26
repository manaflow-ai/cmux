use super::*;

/// A registry the state-resources daemon wrote (screen rows in
/// `screen_state`, groups keyed by the public workspace id) opens with
/// its screens and groups in this storage, and opening it again changes
/// nothing.
#[test]
fn state_resource_screen_rows_move_into_screen_storage_once() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE resource_workspaces (
                   public_id TEXT PRIMARY KEY NOT NULL,
                   workspace_key TEXT UNIQUE NOT NULL,
                   deleted_revision INTEGER
                 );
                 INSERT INTO resource_workspaces(public_id, workspace_key) VALUES('ws_a', 'key-a');
                 CREATE TABLE screen_state (
                   screen_id TEXT PRIMARY KEY NOT NULL,
                   pinned INTEGER NOT NULL DEFAULT 0,
                   color TEXT,
                   icon TEXT
                 );
                 INSERT INTO screen_state VALUES('screen_1', 1, 'red', NULL);
                 CREATE TABLE screen_groups (
                   group_id TEXT PRIMARY KEY NOT NULL,
                   workspace_id TEXT NOT NULL,
                   name TEXT NOT NULL DEFAULT '',
                   color TEXT NOT NULL,
                   collapsed INTEGER NOT NULL DEFAULT 0
                 );
                 INSERT INTO screen_groups VALUES('sgrp_1', 'ws_a', 'Agents', 'blue', 1);
                 INSERT INTO screen_groups VALUES('sgrp_gone', 'ws_gone', 'Gone', 'red', 0);
                 CREATE TABLE screen_group_members (
                   screen_id TEXT PRIMARY KEY NOT NULL,
                   group_id TEXT NOT NULL
                 );
                 INSERT INTO screen_group_members VALUES('screen_2', 'sgrp_1');
                 INSERT INTO screen_group_members VALUES('screen_3', 'sgrp_gone');",
        )
        .unwrap();
    for _ in 0..2 {
        let tx = connection.transaction().unwrap();
        create_screen_schema(&tx).unwrap();
        tx.commit().unwrap();
    }
    let groups = connection
        .prepare(
            "SELECT group_id, workspace_key, name, color, collapsed, saved_id FROM screen_groups",
        )
        .unwrap()
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(
        groups,
        vec![("sgrp_1".into(), "key-a".into(), "Agents".into(), "blue".into(), 1, None)]
    );
    let members = connection
        .prepare("SELECT screen_id, group_id FROM screen_group_members")
        .unwrap()
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(members, vec![("screen_2".to_string(), "sgrp_1".to_string())]);
    let presentation = connection
        .query_row("SELECT screen_id, color, pinned FROM screen_presentation", [], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?, row.get::<_, i64>(2)?))
        })
        .unwrap();
    assert_eq!(presentation, ("screen_1".to_string(), Some("red".to_string()), 1));
    assert!(!table_exists(&connection, "screen_state").unwrap());
    assert!(!table_exists(&connection, "screen_groups_state_v1").unwrap());
}
