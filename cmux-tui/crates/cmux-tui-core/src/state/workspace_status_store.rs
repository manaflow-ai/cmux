//! Per-workspace status: keyed status entries, one progress value, and a
//! bounded log (state-ownership.md: replaces the app's dead
//! `WorkspaceStatusBoard`). Rows are shared state of the workspace's home
//! session, keyed by the public workspace id, and removed when the
//! workspace closes.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// Entries one workspace may hold.
pub(crate) const MAX_STATUS_ENTRIES: usize = 64;
/// Log lines one workspace keeps; older lines are dropped on append.
pub(crate) const MAX_LOG_LINES: i64 = 200;
pub(crate) const MAX_STATUS_TEXT_BYTES: usize = 512;
pub(crate) const MAX_LOG_TEXT_BYTES: usize = 4096;

pub(crate) const LOG_LEVELS: [&str; 5] = ["info", "progress", "success", "warning", "error"];

fn bad_request(message: impl Into<String>) -> anyhow::Error {
    anyhow::anyhow!("bad request: {}", message.into())
}

fn validate_line_text(label: &str, value: &str, maximum: usize) -> anyhow::Result<()> {
    if value.len() > maximum {
        return Err(bad_request(format!("{label} exceeds {maximum} bytes")));
    }
    if value.chars().any(|ch| ch.is_control() && ch != '\t') {
        return Err(bad_request(format!("{label} contains a control character")));
    }
    Ok(())
}

fn validate_status_key(key: &str) -> anyhow::Result<()> {
    if key.is_empty()
        || key.len() > 64
        || !key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b':'))
    {
        return Err(bad_request(
            "status key must be 1-64 ASCII letters, digits, '_', '-', '.', or ':'",
        ));
    }
    Ok(())
}

/// Set or replace one status entry. A new key goes last.
pub(crate) fn set_status(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    key: &str,
    text: &str,
    icon: Option<&str>,
    color: Option<&str>,
    now_ms: u64,
) -> anyhow::Result<()> {
    validate_status_key(key)?;
    validate_line_text("status text", text, MAX_STATUS_TEXT_BYTES)?;
    if let Some(icon) = icon {
        crate::workspace_registry::presentation_store::validate_presentation_icon(icon)?;
    }
    if let Some(color) = color {
        crate::workspace_registry::presentation_store::validate_presentation_color(color)?;
    }
    let existing = transaction
        .query_row(
            "SELECT position FROM workspace_status_entries WHERE workspace_id = ?1 AND status_key = ?2",
            params![workspace_id, key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?;
    let position = match existing {
        Some(position) => position,
        None => {
            let count: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM workspace_status_entries WHERE workspace_id = ?1",
                [workspace_id],
                |row| row.get(0),
            )?;
            if count >= MAX_STATUS_ENTRIES as i64 {
                return Err(bad_request(format!(
                    "a workspace holds at most {MAX_STATUS_ENTRIES} status entries"
                )));
            }
            transaction.query_row(
                "SELECT COALESCE(MAX(position) + 1, 0) FROM workspace_status_entries WHERE workspace_id = ?1",
                [workspace_id],
                |row| row.get(0),
            )?
        }
    };
    transaction.execute(
        "INSERT INTO workspace_status_entries(
           workspace_id, status_key, text, icon, color, updated_at_ms, position
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(workspace_id, status_key) DO UPDATE SET
           text = excluded.text, icon = excluded.icon, color = excluded.color,
           updated_at_ms = excluded.updated_at_ms",
        params![workspace_id, key, text, icon, color, i64::try_from(now_ms)?, position],
    )?;
    Ok(())
}

/// Remove one entry, or every entry when `key` is `None`.
pub(crate) fn clear_status(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    key: Option<&str>,
) -> anyhow::Result<()> {
    match key {
        Some(key) => {
            validate_status_key(key)?;
            transaction.execute(
                "DELETE FROM workspace_status_entries WHERE workspace_id = ?1 AND status_key = ?2",
                params![workspace_id, key],
            )?;
        }
        None => {
            transaction.execute(
                "DELETE FROM workspace_status_entries WHERE workspace_id = ?1",
                [workspace_id],
            )?;
        }
    }
    Ok(())
}

/// Set progress: `value` in `0..=1`, or `None` for indeterminate.
pub(crate) fn set_progress(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    value: Option<f64>,
    label: Option<&str>,
    now_ms: u64,
) -> anyhow::Result<()> {
    if let Some(value) = value
        && !(value.is_finite() && (0.0..=1.0).contains(&value))
    {
        return Err(bad_request("progress value must be between 0 and 1"));
    }
    if let Some(label) = label {
        validate_line_text("progress label", label, MAX_STATUS_TEXT_BYTES)?;
    }
    transaction.execute(
        "INSERT INTO workspace_progress(workspace_id, value, label, updated_at_ms)
         VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(workspace_id) DO UPDATE SET
           value = excluded.value, label = excluded.label, updated_at_ms = excluded.updated_at_ms",
        params![workspace_id, value, label, i64::try_from(now_ms)?],
    )?;
    Ok(())
}

pub(crate) fn clear_progress(
    transaction: &Transaction<'_>,
    workspace_id: &str,
) -> anyhow::Result<()> {
    transaction
        .execute("DELETE FROM workspace_progress WHERE workspace_id = ?1", [workspace_id])?;
    Ok(())
}

/// Append one log line and drop lines beyond the newest [`MAX_LOG_LINES`].
pub(crate) fn append_log(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    level: &str,
    source: Option<&str>,
    text: &str,
    now_ms: u64,
) -> anyhow::Result<()> {
    if !LOG_LEVELS.contains(&level) {
        return Err(bad_request(format!("log level must be one of {}", LOG_LEVELS.join(", "))));
    }
    if text.is_empty() {
        return Err(bad_request("log text cannot be empty"));
    }
    validate_line_text("log text", text, MAX_LOG_TEXT_BYTES)?;
    if let Some(source) = source {
        validate_status_key(source)?;
    }
    let sequence: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sequence) + 1, 1) FROM workspace_log WHERE workspace_id = ?1",
        [workspace_id],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT INTO workspace_log(workspace_id, sequence, level, source, text, at_ms)
         VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![workspace_id, sequence, level, source, text, i64::try_from(now_ms)?],
    )?;
    transaction.execute(
        "DELETE FROM workspace_log WHERE workspace_id = ?1 AND sequence <= ?2",
        params![workspace_id, sequence - MAX_LOG_LINES],
    )?;
    Ok(())
}

pub(crate) fn clear_log(transaction: &Transaction<'_>, workspace_id: &str) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM workspace_log WHERE workspace_id = ?1", [workspace_id])?;
    Ok(())
}

/// Remove every status row of a workspace that closed.
pub(crate) fn forget_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
) -> anyhow::Result<bool> {
    let mut removed = 0;
    for table in ["workspace_status_entries", "workspace_progress", "workspace_log"] {
        removed += transaction
            .execute(&format!("DELETE FROM {table} WHERE workspace_id = ?1"), [workspace_id])?;
    }
    Ok(removed > 0)
}

fn log_line(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "sequence": row.get::<_, i64>(0)?.to_string(),
        "level": row.get::<_, String>(1)?,
        "source": row.get::<_, Option<String>>(2)?,
        "text": row.get::<_, String>(3)?,
        "at_ms": row.get::<_, i64>(4)?.to_string(),
    }))
}

/// The newest `limit` log lines, oldest first.
pub(crate) fn log_lines(
    connection: &Connection,
    workspace_id: &str,
    limit: usize,
) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection.prepare(
        "SELECT sequence, level, source, text, at_ms FROM workspace_log
         WHERE workspace_id = ?1 ORDER BY sequence DESC LIMIT ?2",
    )?;
    let mut lines = statement
        .query_map(params![workspace_id, i64::try_from(limit)?], log_line)?
        .collect::<Result<Vec<_>, _>>()?;
    lines.reverse();
    Ok(lines)
}

/// The `WorkspaceStatusSnapshot` of one workspace.
pub(crate) fn status_snapshot(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Value> {
    let entries = {
        let mut statement = connection.prepare(
            "SELECT status_key, text, icon, color, updated_at_ms FROM workspace_status_entries
             WHERE workspace_id = ?1 ORDER BY position ASC, status_key ASC",
        )?;
        statement
            .query_map([workspace_id], |row| {
                Ok(json!({
                    "key": row.get::<_, String>(0)?,
                    "text": row.get::<_, String>(1)?,
                    "icon": row.get::<_, Option<String>>(2)?,
                    "color": row.get::<_, Option<String>>(3)?,
                    "updated_at_ms": row.get::<_, i64>(4)?.to_string(),
                }))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let progress = connection
        .query_row(
            "SELECT value, label, updated_at_ms FROM workspace_progress WHERE workspace_id = ?1",
            [workspace_id],
            |row| {
                Ok(json!({
                    "value": row.get::<_, Option<f64>>(0)?,
                    "label": row.get::<_, Option<String>>(1)?,
                    "updated_at_ms": row.get::<_, i64>(2)?.to_string(),
                }))
            },
        )
        .optional()?;
    let log_count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM workspace_log WHERE workspace_id = ?1",
        [workspace_id],
        |row| row.get(0),
    )?;
    let last_log = log_lines(connection, workspace_id, 1)?.pop();
    Ok(json!({
        "workspace_id": workspace_id,
        "entries": entries,
        "progress": progress,
        "log_count": log_count,
        "last_log": last_log,
    }))
}

/// Status snapshots of every live workspace that has any status, in
/// workspace order.
pub(crate) fn status_snapshots(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let ids = {
        let mut statement = connection.prepare(
            "SELECT rw.public_id FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.deleted_revision IS NULL AND w.tombstoned = 0
               AND (EXISTS(SELECT 1 FROM workspace_status_entries AS s WHERE s.workspace_id = rw.public_id)
                 OR EXISTS(SELECT 1 FROM workspace_progress AS p WHERE p.workspace_id = rw.public_id)
                 OR EXISTS(SELECT 1 FROM workspace_log AS l WHERE l.workspace_id = rw.public_id))
             ORDER BY w.position ASC",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    ids.iter().map(|id| status_snapshot(connection, id)).collect()
}
