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
    /// A frontend starts it when its workspace is first shown, not when it
    /// connects (`relaunch.on_show`): a parked tab (`park-tabs`), and a kept
    /// tab of End Sessions, Keep Layout whose terminal ran no agent.
    pub on_show: bool,
}

/// One tab to record as kept (public tab id, shell directory, last title).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct KeptTab {
    pub tab_id: String,
    pub cwd: Option<String>,
    pub title: Option<String>,
    /// Started on its workspace's first show, not at connect (see
    /// [`KeptTabRecord::on_show`]).
    pub on_show: bool,
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
           title TEXT,
           on_show INTEGER NOT NULL DEFAULT 0
         );",
    )?;
    // Additive: a table an older build created has no title column. Older
    // builds name their columns, so they keep reading and writing it.
    let columns = transaction
        .prepare("PRAGMA table_info(kept_tabs)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !columns.iter().any(|column| column == "title") {
        transaction.execute_batch("ALTER TABLE kept_tabs ADD COLUMN title TEXT;")?;
    }
    // Additive as `title` (`tab-park-v1`); an older build leaves it 0.
    if !columns.iter().any(|column| column == "on_show") {
        transaction.execute_batch(
            "ALTER TABLE kept_tabs ADD COLUMN on_show INTEGER NOT NULL DEFAULT 0;",
        )?;
    }
    Ok(())
}

/// Kept rows of live tabs, by public tab id.
pub(crate) fn read_kept_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, KeptTabRecord>> {
    let mut statement = connection.prepare(
        "SELECT k.tab_id, k.cwd, t.name, k.title, k.on_show FROM kept_tabs AS k
         JOIN resource_tabs AS t ON t.public_id = k.tab_id
         WHERE t.deleted_revision IS NULL",
    )?;
    let rows = statement.query_map([], |row| {
        let record = KeptTabRecord {
            cwd: row.get(1)?,
            name: row.get(2)?,
            title: row.get(3)?,
            on_show: row.get::<_, i64>(4)? != 0,
        };
        Ok((row.get::<_, String>(0)?, record))
    })?;
    Ok(rows.collect::<Result<HashMap<_, _>, _>>()?)
}

/// The `extra.relaunch` of one tab: `{cwd}` for a kept tab (with
/// `on_show: true` for a parked one), else null.
pub(crate) fn relaunch_value(connection: &Connection, tab_id: &str) -> anyhow::Result<Value> {
    let row = connection
        .query_row("SELECT cwd, on_show FROM kept_tabs WHERE tab_id = ?1", [tab_id], |row| {
            Ok((row.get::<_, Option<String>>(0)?, row.get::<_, i64>(1)? != 0))
        })
        .optional()?;
    Ok(row.map_or(Value::Null, |(cwd, on_show)| relaunch_json(cwd.as_deref(), on_show)))
}

/// `{cwd}`, with `on_show: true` for a tab parked by `park-tabs`.
pub(crate) fn relaunch_json(cwd: Option<&str>, on_show: bool) -> Value {
    if on_show { json!({"cwd": cwd, "on_show": true}) } else { json!({"cwd": cwd}) }
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
    for KeptTab { tab_id, cwd, title, on_show } in tabs {
        transaction.execute(
            "INSERT INTO kept_tabs(tab_id, cwd, title, on_show) VALUES(?1, ?2, ?3, ?4)
             ON CONFLICT(tab_id) DO UPDATE SET cwd = excluded.cwd, title = excluded.title, on_show = excluded.on_show",
            params![tab_id, cwd, title, i64::from(*on_show)],
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
    /// The kept rows of `tab_ids` (a restart of a kept tab reads them under
    /// the registry lock, `terminal_respawn/manual.rs`).
    pub(crate) fn kept_tabs_of(&self, tab_ids: &[String]) -> anyhow::Result<Vec<KeptTab>> {
        let db = self.connection.get();
        let mut statement =
            db.prepare("SELECT cwd, title, on_show FROM kept_tabs WHERE tab_id = ?1")?;
        let mut rows = Vec::new();
        for tab_id in tab_ids {
            let row = statement
                .query_row([tab_id], |row| {
                    Ok(KeptTab {
                        tab_id: tab_id.clone(),
                        cwd: row.get(0)?,
                        title: row.get(1)?,
                        on_show: row.get::<_, i64>(2)? != 0,
                    })
                })
                .optional()?;
            rows.extend(row);
        }
        Ok(rows)
    }

    /// Whether any of `tab_ids` is a kept tab.
    pub fn any_kept_tab(&self, tab_ids: &[String]) -> anyhow::Result<bool> {
        let db = self.connection.get();
        let mut statement = db.prepare("SELECT 1 FROM kept_tabs WHERE tab_id = ?1")?;
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
