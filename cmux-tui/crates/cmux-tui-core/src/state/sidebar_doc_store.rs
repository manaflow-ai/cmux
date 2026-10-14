//! The sidebar document (`sidebar-doc-v1`, sidebar rewrite S2): personal
//! state of the home session, one row per section (`sidebar_sections`) and
//! per item (`sidebar_items`), and the document revision in `meta`. The
//! reducer is [`cmux_layout_reducer::sidebar_doc`]; this module stores it,
//! turns a committed outcome into `session.events` changes, and runs the
//! one-time migration from the old sidebar stores when the registry opens
//! (the old tables stay as they are).

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use cmux_layout_reducer::sidebar_doc::reduce::Changes;
use cmux_layout_reducer::sidebar_doc::{Doc, Item, Section, migrate};

use super::store::{state_delete, state_upsert};

/// `sidebar.*`, `extra.state.sidebar` and the sidebar change resources.
pub const CAPABILITY: &str = "sidebar-doc-v1";
pub(crate) const ITEM_RESOURCE: &str = "sidebar_item";
pub(crate) const SECTION_RESOURCE: &str = "sidebar_section";
/// One change per sidebar batch: `{revision, previous_revision,
/// idempotency_key}` of the document (id `user`).
pub(crate) const DOC_RESOURCE: &str = "sidebar_doc";
pub(crate) const DOC_ID: &str = "user";
const REVISION_KEY: &str = "sidebar_doc_revision";
const MIGRATED_KEY: &str = "sidebar_doc_v1_migrated";
/// The largest stored row.
const MAX_ROW_BYTES: usize = 64 * 1024;

pub(crate) fn create_sidebar_doc_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS sidebar_sections (
           id TEXT PRIMARY KEY NOT NULL,
           order_key TEXT NOT NULL,
           section_json TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS sidebar_items (
           id TEXT PRIMARY KEY NOT NULL,
           section_id TEXT NOT NULL,
           parent_id TEXT,
           order_key TEXT NOT NULL,
           item_json TEXT NOT NULL
         );",
    )?;
    Ok(())
}

fn meta(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
        .optional()?)
}

fn set_meta(transaction: &Transaction<'_>, key: &str, value: &str) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

/// Whether the one-time migration ran (the document exists).
pub(crate) fn is_migrated(connection: &Connection) -> anyhow::Result<bool> {
    Ok(meta(connection, MIGRATED_KEY)?.is_some())
}

/// The stored document. A row that no longer parses is skipped (logged).
pub(crate) fn read_doc(connection: &Connection) -> anyhow::Result<Doc> {
    let revision = meta(connection, REVISION_KEY)?.and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut doc = Doc { revision, sections: Vec::new(), items: Vec::new() };
    let tables = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sidebar_items'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !tables {
        return Ok(doc);
    }
    let mut statement = connection.prepare("SELECT section_json FROM sidebar_sections")?;
    for text in statement.query_map([], |row| row.get::<_, String>(0))? {
        match serde_json::from_str::<Section>(&text?) {
            Ok(section) => doc.sections.push(section),
            Err(error) => eprintln!("cmux-tui: sidebar section row does not parse ({error})"),
        }
    }
    let mut statement = connection.prepare("SELECT item_json FROM sidebar_items")?;
    for text in statement.query_map([], |row| row.get::<_, String>(0))? {
        match serde_json::from_str::<Item>(&text?) {
            Ok(item) => doc.items.push(item),
            Err(error) => eprintln!("cmux-tui: sidebar item row does not parse ({error})"),
        }
    }
    doc.normalize();
    Ok(doc)
}

/// The document as `sidebar.get`, `extra.state.sidebar` and results carry it.
pub(crate) fn snapshot_value(doc: &Doc) -> anyhow::Result<Value> {
    Ok(serde_json::to_value(doc)?)
}

pub(crate) fn snapshot(connection: &Connection) -> anyhow::Result<Value> {
    snapshot_value(&read_doc(connection)?)
}

fn write_section(transaction: &Transaction<'_>, section: &Section) -> anyhow::Result<()> {
    let json = serde_json::to_string(section)?;
    anyhow::ensure!(json.len() <= MAX_ROW_BYTES, "bad request: too_many");
    transaction.execute(
        "INSERT INTO sidebar_sections(id, order_key, section_json) VALUES(?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET order_key = excluded.order_key,
                                       section_json = excluded.section_json",
        params![section.id, section.order, json],
    )?;
    Ok(())
}

fn write_item(transaction: &Transaction<'_>, item: &Item) -> anyhow::Result<()> {
    let json = serde_json::to_string(item)?;
    anyhow::ensure!(json.len() <= MAX_ROW_BYTES, "bad request: too_many");
    transaction.execute(
        "INSERT INTO sidebar_items(id, section_id, parent_id, order_key, item_json)
         VALUES(?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(id) DO UPDATE SET section_id = excluded.section_id,
                                       parent_id = excluded.parent_id,
                                       order_key = excluded.order_key,
                                       item_json = excluded.item_json",
        params![item.id, item.section, item.parent, item.order, json],
    )?;
    Ok(())
}

/// Write `changes` and the new revision; return the `session.events`
/// changes: one upsert or delete per row, then the `sidebar_doc` marker.
pub(crate) fn write_changes(
    transaction: &Transaction<'_>,
    previous_revision: u64,
    revision: u64,
    changes: &Changes,
    idempotency_key: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    let mut events = Vec::new();
    for section in &changes.sections {
        write_section(transaction, section)?;
        events.push(state_upsert(SECTION_RESOURCE, &section.id, serde_json::to_value(section)?));
    }
    for item in &changes.items {
        write_item(transaction, item)?;
        events.push(state_upsert(ITEM_RESOURCE, &item.id, serde_json::to_value(item)?));
    }
    for id in &changes.deleted_items {
        transaction.execute("DELETE FROM sidebar_items WHERE id = ?1", [id])?;
        events.push(state_delete(ITEM_RESOURCE, id));
    }
    for id in &changes.deleted_sections {
        transaction.execute("DELETE FROM sidebar_sections WHERE id = ?1", [id])?;
        events.push(state_delete(SECTION_RESOURCE, id));
    }
    set_meta(transaction, REVISION_KEY, &revision.to_string())?;
    events.push(state_upsert(
        DOC_RESOURCE,
        DOC_ID,
        json!({
            "revision": revision.to_string(),
            "previous_revision": previous_revision.to_string(),
            "idempotency_key": idempotency_key,
        }),
    ));
    Ok(events)
}

/// The one-time migration (at registry open): the old layout, personal
/// order, pinned groups and pin flags become the document; the old tables
/// stay. A second open finds the flag and does nothing.
pub(crate) fn migrate_at_open(connection: &Connection) -> anyhow::Result<()> {
    let tx = connection.unchecked_transaction()?;
    create_sidebar_doc_schema(&tx)?;
    if is_migrated(&tx)? {
        return Ok(());
    }
    let input = super::sidebar_doc_legacy::legacy_input(&tx)?;
    let doc = migrate::migrate(&input);
    let changes = Changes {
        sections: doc.sections.clone(),
        deleted_sections: Vec::new(),
        items: doc.items.clone(),
        deleted_items: Vec::new(),
    };
    // No journal batch at open: clients read the document with sidebar.get.
    write_changes(&tx, 0, doc.revision, &changes, None)?;
    super::sidebar_doc_legacy::store_shadow(&tx)?;
    set_meta(&tx, MIGRATED_KEY, "1")?;
    tx.commit()?;
    Ok(())
}
