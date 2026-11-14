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
mod tests;
