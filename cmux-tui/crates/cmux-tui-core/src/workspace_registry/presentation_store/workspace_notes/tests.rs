use super::*;
use rusqlite::Connection;

/// A table from before the notes gains both columns once; a second open
/// changes nothing.
#[test]
fn notes_columns_are_added_once() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE workspace_presentation (workspace_key TEXT PRIMARY KEY NOT NULL,
                   group_id TEXT, color TEXT, icon TEXT, title TEXT,
                   pinned INTEGER NOT NULL DEFAULT 0, marked_unread INTEGER NOT NULL DEFAULT 0);
                 INSERT INTO workspace_presentation(workspace_key, pinned) VALUES('one', 1);",
        )
        .unwrap();
    for _ in 0..2 {
        let transaction = connection.transaction().unwrap();
        migrate_workspace_presentation_add_notes(&transaction).unwrap();
        transaction.commit().unwrap();
    }
    let (description, status): (Option<String>, Option<String>) = connection
            .query_row(
                "SELECT description, task_status FROM workspace_presentation WHERE workspace_key = 'one'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
    assert_eq!((description, status), (None, None));
}

#[test]
fn descriptions_take_lines_and_statuses_take_the_classic_lanes() {
    assert!(validate_workspace_description("Ship the release\n- notes\tdone").is_ok());
    assert!(validate_workspace_description("  ").is_err());
    assert!(validate_workspace_description("bell\u{7}").is_err());
    assert!(
        validate_workspace_description(&"x".repeat(MAX_WORKSPACE_DESCRIPTION_CHARS + 1)).is_err()
    );
    for status in WORKSPACE_TASK_STATUSES {
        assert!(validate_workspace_task_status(status).is_ok());
    }
    assert!(validate_workspace_task_status("inProgress").is_err());
    assert!(validate_workspace_task_status("auto").is_err(), "automatic is null, not a value");
}
