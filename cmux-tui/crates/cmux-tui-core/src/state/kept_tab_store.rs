//! Keep-layout records (`end-terminals-keep-layout-v1`), workspace-store
//! state (plans/cmux-next/OWNERSHIP-PRINCIPLES.md: keep-layout records
//! belong to the workspace store, never to PTY code).
//!
//! `shutdown-daemon end_terminals keep_layout` ends every terminal but keeps
//! the tabs of placed ones. The kept tabs, with the directory their shell
//! was in, live here. A terminal's exit never removes a tab listed here; the
//! raw tree reports each as `relaunch: {cwd}` once its terminal ended, and
//! the v2 tab snapshot as `extra.relaunch: {cwd}` (null for other tabs).
//!
//! Writes go through the state commit path (`state/kept_tabs.rs`): one
//! transaction with a resource revision, a replay record and a
//! `session.events` batch that restates the tabs, so the snapshot and the
//! event stream converge. The table has its own `CREATE TABLE IF NOT
//! EXISTS`, so an older binary ignores it. Rows naming a closed tab are
//! inert (reads join live tabs) and are pruned on the next write.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use crate::workspace_registry::presentation_store::append_presentation_record;
use crate::workspace_registry::{JournalSubject, WorkspaceRegistry};

/// One kept tab: where its terminal's shell was when it ended.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeptTabRecord {
    pub cwd: Option<String>,
}

/// Longest accepted directory, in bytes.
pub(crate) const MAX_KEPT_TAB_CWD_BYTES: usize = 4096;

pub(crate) fn create_kept_tab_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS kept_tabs (
           tab_id TEXT PRIMARY KEY NOT NULL,
           cwd TEXT
         );",
    )?;
    Ok(())
}

/// Kept rows of live tabs, by public tab id.
pub(crate) fn read_kept_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, KeptTabRecord>> {
    let mut statement = connection.prepare(
        "SELECT k.tab_id, k.cwd FROM kept_tabs AS k
         JOIN resource_tabs AS t ON t.public_id = k.tab_id
         WHERE t.deleted_revision IS NULL",
    )?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, KeptTabRecord { cwd: row.get(1)? })))?;
    Ok(rows.collect::<Result<HashMap<_, _>, _>>()?)
}

/// The `extra.relaunch` of one tab: `{cwd}` for a kept tab, else null.
pub(crate) fn relaunch_value(connection: &Connection, tab_id: &str) -> anyhow::Result<Value> {
    let cwd = connection
        .query_row("SELECT cwd FROM kept_tabs WHERE tab_id = ?1", [tab_id], |row| {
            row.get::<_, Option<String>>(0)
        })
        .optional()?;
    Ok(cwd.map_or(Value::Null, |cwd| json!({"cwd": cwd})))
}

/// Validate kept rows before a commit.
pub(crate) fn validate_kept_tabs(tabs: &[(String, Option<String>)]) -> anyhow::Result<()> {
    for (tab_id, cwd) in tabs {
        anyhow::ensure!(
            tab_id.starts_with("tab_") && tab_id.len() <= 64,
            "bad request: invalid tab id {tab_id}"
        );
        anyhow::ensure!(
            cwd.as_ref().is_none_or(|cwd| cwd.len() <= MAX_KEPT_TAB_CWD_BYTES),
            "kept tab {tab_id} directory is too long"
        );
    }
    Ok(())
}

/// Record `tabs` (public tab id, shell directory) as kept, replacing an
/// earlier row of the same tab and pruning rows of closed tabs.
pub(crate) fn write_kept_tabs(
    transaction: &Transaction<'_>,
    tabs: &[(String, Option<String>)],
) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM kept_tabs WHERE tab_id NOT IN (
           SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL
         )",
        [],
    )?;
    for (tab_id, cwd) in tabs {
        transaction.execute(
            "INSERT INTO kept_tabs(tab_id, cwd) VALUES(?1, ?2)
             ON CONFLICT(tab_id) DO UPDATE SET cwd = excluded.cwd",
            params![tab_id, cwd],
        )?;
    }
    if !tabs.is_empty() {
        let subjects = tabs
            .iter()
            .map(|(id, _)| JournalSubject { kind: "tab".into(), id: id.clone() })
            .collect();
        let records =
            tabs.iter().map(|(id, cwd)| json!({"tab_id": id, "cwd": cwd})).collect::<Vec<_>>();
        append_presentation_record(
            transaction,
            "tab.kept_layout.recorded",
            subjects,
            &json!({"tabs": records}),
        )?;
    }
    Ok(())
}

/// Remove the records of `tab_ids` (a cancelled keep-layout handoff).
/// Returns the ids that had a record.
pub(crate) fn delete_kept_tabs(
    transaction: &Transaction<'_>,
    tab_ids: &[String],
) -> anyhow::Result<Vec<String>> {
    let mut removed = Vec::new();
    for tab_id in tab_ids {
        if transaction.execute("DELETE FROM kept_tabs WHERE tab_id = ?1", [tab_id])? > 0 {
            removed.push(tab_id.clone());
        }
    }
    if !removed.is_empty() {
        let subjects = removed
            .iter()
            .map(|id| JournalSubject { kind: "tab".into(), id: id.clone() })
            .collect();
        append_presentation_record(
            transaction,
            "tab.kept_layout.forgotten",
            subjects,
            &json!({"tabs": removed}),
        )?;
    }
    Ok(removed)
}

impl WorkspaceRegistry {
    /// Whether any of `tab_ids` is a kept tab.
    pub fn any_kept_tab(&self, tab_ids: &[String]) -> anyhow::Result<bool> {
        let mut statement = self.connection.prepare("SELECT 1 FROM kept_tabs WHERE tab_id = ?1")?;
        for tab_id in tab_ids {
            if statement.exists([tab_id])? {
                return Ok(true);
            }
        }
        Ok(false)
    }
}
