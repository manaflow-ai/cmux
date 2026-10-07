//! Keep-layout records (`end-terminals-keep-layout-v1`), workspace-store
//! state (plans/cmux-next/OWNERSHIP-PRINCIPLES.md: keep-layout records
//! belong to the workspace store, never to PTY code).
//!
//! `shutdown-daemon end_terminals keep_layout` ends every terminal but keeps
//! the tabs of placed ones. The kept tabs, with the directory their shell
//! was in and the title their terminal last showed, live here. A terminal's
//! exit never removes a tab listed here; the raw tree reports each as
//! `relaunch: {cwd}` once its terminal ended, and the v2 tab snapshot as
//! `extra.relaunch: {cwd}` (null for other tabs). With no surface behind it
//! (after a restart), the raw tree reports the tab's resource name and the
//! recorded title as its `name` and `title`.
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

/// One kept tab: where its terminal's shell was and what it was called
/// when it ended. A restarted owner has no surface behind a kept tab, so
/// the tree reads the tab's name and title from here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeptTabRecord {
    pub cwd: Option<String>,
    /// The tab resource's own name (`tab.rename`), read from the live tab.
    pub name: Option<String>,
    /// The terminal's last title (OSC 0/2) when the record was written.
    pub title: Option<String>,
}

/// One tab to record as kept (public tab id, shell directory, last title).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct KeptTab {
    pub tab_id: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
}

/// Longest accepted directory, in bytes.
pub(crate) const MAX_KEPT_TAB_CWD_BYTES: usize = 4096;
/// Longest kept title, in bytes; a longer one is cut at a char boundary.
pub(crate) const MAX_KEPT_TAB_TITLE_BYTES: usize = 4096;

pub(crate) fn create_kept_tab_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS kept_tabs (
           tab_id TEXT PRIMARY KEY NOT NULL,
           cwd TEXT,
           title TEXT
         );",
    )?;
    // Additive: a table an older build created has no title column. Older
    // builds name their columns, so they keep reading and writing it.
    let has_title = transaction
        .prepare("PRAGMA table_info(kept_tabs)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "title");
    if !has_title {
        transaction.execute_batch("ALTER TABLE kept_tabs ADD COLUMN title TEXT;")?;
    }
    Ok(())
}

/// Kept rows of live tabs, by public tab id.
pub(crate) fn read_kept_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, KeptTabRecord>> {
    let mut statement = connection.prepare(
        "SELECT k.tab_id, k.cwd, t.name, k.title FROM kept_tabs AS k
         JOIN resource_tabs AS t ON t.public_id = k.tab_id
         WHERE t.deleted_revision IS NULL",
    )?;
    let rows = statement.query_map([], |row| {
        let record = KeptTabRecord { cwd: row.get(1)?, name: row.get(2)?, title: row.get(3)? };
        Ok((row.get::<_, String>(0)?, record))
    })?;
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
pub(crate) fn validate_kept_tabs(tabs: &[KeptTab]) -> anyhow::Result<()> {
    for KeptTab { tab_id, cwd, .. } in tabs {
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

/// A title cut to [`MAX_KEPT_TAB_TITLE_BYTES`]; an empty one is none.
pub(crate) fn kept_title(title: &str) -> Option<String> {
    let mut end = title.len().min(MAX_KEPT_TAB_TITLE_BYTES);
    while !title.is_char_boundary(end) {
        end -= 1;
    }
    let title = &title[..end];
    (!title.is_empty()).then(|| title.to_owned())
}

/// Record `tabs` as kept, replacing an earlier row of the same tab and
/// pruning rows of closed tabs.
pub(crate) fn write_kept_tabs(
    transaction: &Transaction<'_>,
    tabs: &[KeptTab],
) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM kept_tabs WHERE tab_id NOT IN (
           SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL
         )",
        [],
    )?;
    for KeptTab { tab_id, cwd, title } in tabs {
        transaction.execute(
            "INSERT INTO kept_tabs(tab_id, cwd, title) VALUES(?1, ?2, ?3)
             ON CONFLICT(tab_id) DO UPDATE SET cwd = excluded.cwd, title = excluded.title",
            params![tab_id, cwd, title],
        )?;
    }
    if !tabs.is_empty() {
        let subjects = tabs
            .iter()
            .map(|tab| JournalSubject { kind: "tab".into(), id: tab.tab_id.clone() })
            .collect();
        let records = tabs
            .iter()
            .map(|tab| json!({"tab_id": tab.tab_id, "cwd": tab.cwd, "title": tab.title}))
            .collect::<Vec<_>>();
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A table an older build created gains the title column; its rows stay.
    #[test]
    fn kept_tab_schema_adds_the_title_column_to_an_older_table() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE kept_tabs (tab_id TEXT PRIMARY KEY NOT NULL, cwd TEXT);
                 INSERT INTO kept_tabs(tab_id, cwd) VALUES('tab_old', '/tmp');",
            )
            .unwrap();
        for _ in 0..2 {
            let transaction = connection.transaction().unwrap();
            create_kept_tab_schema(&transaction).unwrap();
            transaction.commit().unwrap();
        }
        let row = connection
            .query_row("SELECT cwd, title FROM kept_tabs WHERE tab_id = 'tab_old'", [], |row| {
                Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?))
            })
            .unwrap();
        assert_eq!(row, (Some("/tmp".into()), None));
    }

    #[test]
    fn kept_title_drops_empty_and_cuts_long_titles_at_a_char_boundary() {
        assert_eq!(kept_title(""), None);
        assert_eq!(kept_title("vim"), Some("vim".into()));
        let long = "é".repeat(MAX_KEPT_TAB_TITLE_BYTES);
        let cut = kept_title(&long).unwrap();
        assert!(cut.len() <= MAX_KEPT_TAB_TITLE_BYTES && cut.chars().all(|c| c == 'é'));
    }
}
