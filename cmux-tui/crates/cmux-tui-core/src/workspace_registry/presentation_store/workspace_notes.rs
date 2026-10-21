//! A workspace's description (`workspace-description-v1`) and its manual task
//! status (`workspace-status-v1`): two nullable columns of
//! `workspace_presentation`, set through `workspace.update` and shown as the
//! workspace snapshot's `extra.description` and `extra.task_status`.

use rusqlite::Transaction;

/// The longest description, in characters (the classic sidebar drew at most
/// this many).
pub(super) const MAX_WORKSPACE_DESCRIPTION_CHARS: usize = 4096;

/// The task lanes a person can pin a workspace to, in cycle order (classic
/// cmux `WorkspaceTaskStatus`). No status (null) is automatic.
pub(super) const WORKSPACE_TASK_STATUSES: [&str; 5] =
    ["todo", "working", "needs-attention", "review", "done"];

/// Add the description and task status to registries created before the
/// columns existed. Older builds name their columns, so they keep reading and
/// writing the table; one that empties a row of every field it knows drops
/// these with it (a rollback can lose them, as for pins).
pub(super) fn migrate_workspace_presentation_add_notes(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let columns = transaction
        .prepare("PRAGMA table_info(workspace_presentation)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    for column in ["description", "task_status"] {
        if !columns.iter().any(|existing| existing == column) {
            transaction.execute_batch(&format!(
                "ALTER TABLE workspace_presentation ADD COLUMN {column} TEXT;"
            ))?;
        }
    }
    Ok(())
}

/// A description is free text of 1 to 4096 characters; line breaks and tabs
/// are allowed, other control characters are not.
pub(super) fn validate_workspace_description(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.trim().is_empty(), "bad request: workspace description cannot be empty");
    anyhow::ensure!(
        value.chars().count() <= MAX_WORKSPACE_DESCRIPTION_CHARS,
        "bad request: workspace description exceeds {MAX_WORKSPACE_DESCRIPTION_CHARS} characters"
    );
    anyhow::ensure!(
        !value.chars().any(|c| c.is_control() && c != '\n' && c != '\t'),
        "bad request: workspace description contains a control character"
    );
    Ok(())
}

/// A task status is one of [`WORKSPACE_TASK_STATUSES`].
pub(super) fn validate_workspace_task_status(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        WORKSPACE_TASK_STATUSES.contains(&value),
        "bad request: workspace task_status must be one of {}",
        WORKSPACE_TASK_STATUSES.join(", ")
    );
    Ok(())
}

#[cfg(test)]
mod tests {
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
            validate_workspace_description(&"x".repeat(MAX_WORKSPACE_DESCRIPTION_CHARS + 1))
                .is_err()
        );
        for status in WORKSPACE_TASK_STATUSES {
            assert!(validate_workspace_task_status(status).is_ok());
        }
        assert!(validate_workspace_task_status("inProgress").is_err());
        assert!(validate_workspace_task_status("auto").is_err(), "automatic is null, not a value");
    }
}
