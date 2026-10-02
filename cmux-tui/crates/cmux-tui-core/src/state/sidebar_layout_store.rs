//! The sidebar section layout (`sidebar-layout-v1`,
//! plans/cmux-next/sidebar-sections.md sections 4 and 5): one per-user
//! document, personal state of the home session. The reducer is
//! [`super::sidebar_layout`]; this module stores the document.

use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::Value;

use super::sidebar_layout::{self, Document};

/// `sidebar_layout.get|update` and `extra.state.sidebar_layout`.
pub const CAPABILITY: &str = "sidebar-layout-v1";
/// The resource kind of the layout on `session.events`.
pub(crate) const RESOURCE: &str = "sidebar_layout";
/// The id of the one layout (per user, so per home session).
pub(crate) const ID: &str = "user";

pub(crate) fn create_sidebar_layout_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS sidebar_layout (
           id INTEGER PRIMARY KEY CHECK(id = 1),
           document_json TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// The stored document, or the defaults when it was never written.
pub(crate) fn document(connection: &Connection) -> anyhow::Result<Document> {
    let stored: Option<String> = connection
        .query_row("SELECT document_json FROM sidebar_layout WHERE id = 1", [], |row| row.get(0))
        .optional()?;
    Ok(match stored {
        Some(text) => serde_json::from_str(&text)?,
        None => sidebar_layout::defaults(),
    })
}

pub(crate) fn write_document(transaction: &Transaction<'_>, document: &Document) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO sidebar_layout(id, document_json) VALUES(1, ?1)
         ON CONFLICT(id) DO UPDATE SET document_json = excluded.document_json",
        [serde_json::to_string(document)?],
    )?;
    Ok(())
}

/// The document as `sidebar_layout.get`, the mutation result, the
/// `state_upsert` value and `extra.state.sidebar_layout` carry it
/// (`SidebarLayoutSnapshot`: the revision as a decimal string).
pub(crate) fn snapshot_value(document: &Document) -> anyhow::Result<Value> {
    let mut value = serde_json::to_value(document)?;
    value["revision"] = Value::String(document.revision.to_string());
    Ok(value)
}

pub(crate) fn snapshot(connection: &Connection) -> anyhow::Result<Value> {
    snapshot_value(&document(connection)?)
}
