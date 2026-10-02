//! Keep-layout records (`end-terminals-keep-layout-v1`).
//!
//! `shutdown-daemon end_terminals keep_layout` ends every terminal but keeps
//! the tabs of placed ones. The kept tabs, with the directory their shell
//! was in, are workspace-store state (plans/cmux-next/OWNERSHIP-PRINCIPLES.md:
//! keep-layout records belong to the workspace store, never to PTY code).
//! A terminal's exit never removes a tab listed here, and the tree reports
//! each as `relaunch: {cwd}` so a frontend starts a new shell in it.
//!
//! One self-contained table with its own `CREATE TABLE IF NOT EXISTS`, so
//! an older binary ignores it and it can move into the v2 state module as a
//! unit. Rows naming a closed tab are inert (reads join live tabs) and are
//! pruned on the next write.

use std::collections::HashMap;

use rusqlite::{Connection, Transaction, params};
use serde_json::json;

use super::presentation_store::append_presentation_record;
use super::{JournalSubject, WorkspaceRegistry};

/// One kept tab: where its terminal's shell was when it ended.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeptTabRecord {
    pub cwd: Option<String>,
}

/// Longest accepted directory, in bytes.
const MAX_KEPT_TAB_CWD_BYTES: usize = 4096;

pub(super) fn create_kept_tab_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS kept_tabs (
           tab_id TEXT PRIMARY KEY NOT NULL,
           cwd TEXT
         );",
    )?;
    Ok(())
}

/// Kept rows of live tabs, by public tab id.
pub(super) fn read_kept_tabs(
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

impl WorkspaceRegistry {
    /// Records `tabs` (public tab id, shell directory) as kept, in one
    /// transaction, replacing an earlier row of the same tab and pruning
    /// rows of closed tabs.
    pub fn put_kept_tabs(&mut self, tabs: &[(String, Option<String>)]) -> anyhow::Result<()> {
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
        let tx = self.connection.transaction()?;
        tx.execute(
            "DELETE FROM kept_tabs WHERE tab_id NOT IN (
               SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL
             )",
            [],
        )?;
        for (tab_id, cwd) in tabs {
            tx.execute(
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
                &tx,
                "tab.kept_layout.recorded",
                subjects,
                &json!({"tabs": records}),
            )?;
        }
        tx.commit()?;
        Ok(())
    }

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

    /// Removes the records of `tab_ids` (a cancelled keep-layout handoff).
    pub fn forget_kept_tabs(&mut self, tab_ids: &[String]) -> anyhow::Result<()> {
        if tab_ids.is_empty() {
            return Ok(());
        }
        let tx = self.connection.transaction()?;
        for tab_id in tab_ids {
            tx.execute("DELETE FROM kept_tabs WHERE tab_id = ?1", [tab_id])?;
        }
        let subjects = tab_ids
            .iter()
            .map(|id| JournalSubject { kind: "tab".into(), id: id.clone() })
            .collect();
        append_presentation_record(
            &tx,
            "tab.kept_layout.forgotten",
            subjects,
            &json!({"tabs": tab_ids}),
        )?;
        tx.commit()?;
        Ok(())
    }
}
