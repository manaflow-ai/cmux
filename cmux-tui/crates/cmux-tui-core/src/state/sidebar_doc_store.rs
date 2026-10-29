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
/// The section patch field that preserves an explicit Remove Remote Group
/// choice when false `host_group` values are omitted on the wire.
pub const HOST_GROUP_OPTOUT_CAPABILITY: &str = "sidebar-host-group-opt-out-v1";
pub(crate) const ITEM_RESOURCE: &str = "sidebar_item";
pub(crate) const SECTION_RESOURCE: &str = "sidebar_section";
/// One change per sidebar batch: `{revision, previous_revision,
/// idempotency_key}` of the document (id `user`).
pub(crate) const DOC_RESOURCE: &str = "sidebar_doc";
pub(crate) const DOC_ID: &str = "user";
const REVISION_KEY: &str = "sidebar_doc_revision";
const MIGRATED_KEY: &str = "sidebar_doc_v1_migrated";
/// Set once the old layout's section `align` and `gap` (and the other values
/// [`backfill_arrangement`] names) are in the document: the migration copies
/// them, and a document migrated before gets them once at open. An older
/// binary that rewrites a section row drops `align` and `gap` (it does not
/// know them), and this flag does not bring them back.
const ARRANGEMENT_KEY: &str = "sidebar_doc_arrangement_v1";
/// A fresh token per document write: the key of the parsed-document cache.
const EPOCH_KEY: &str = "sidebar_doc_epoch";

/// The last document this process wrote or read, by `(registry id, epoch)`.
/// A commit leases it ([`with_doc_mut`]), changes it in place and puts it
/// back under the epoch its write set; a write that rolls back leaves an
/// epoch no row holds, so its entry never matches and the next read parses
/// the rows.
enum Slot {
    Empty,
    Cached {
        registry: String,
        epoch: String,
        doc: Box<Doc>,
    },
    /// A commit holds the document. A reader parses the rows instead; a
    /// nested writer (an old-store sync inside that commit) does too and
    /// marks the lease stale, so the holder does not cache a copy that
    /// missed its write.
    Leased {
        stale: bool,
    },
}

static CACHE: std::sync::Mutex<Slot> = std::sync::Mutex::new(Slot::Empty);

fn cache_key(connection: &Connection) -> anyhow::Result<Option<(String, String)>> {
    let Some(epoch) = meta(connection, EPOCH_KEY)? else { return Ok(None) };
    Ok(meta(connection, "registry_id")?.map(|registry| (registry, epoch)))
}

fn lock() -> std::sync::MutexGuard<'static, Slot> {
    CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

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

/// Run `read` on the stored document (the cached copy when it is current).
pub(crate) fn with_doc<T>(
    connection: &Connection,
    read: impl FnOnce(&Doc) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let key = cache_key(connection)?;
    {
        let slot = lock();
        if let Slot::Leased { .. } = &*slot {
            // A commit holds it: read the rows (a read changes nothing).
            drop(slot);
            return read(&read_rows(connection)?);
        }
        if let Slot::Cached { registry, epoch, doc } = &*slot
            && key.as_ref().is_some_and(|(r, e)| r == registry && e == epoch)
        {
            return read(doc);
        }
    }
    let doc = read_rows(connection)?;
    let value = read(&doc);
    if let Some((registry, epoch)) = key {
        let mut slot = lock();
        if !matches!(*slot, Slot::Leased { .. }) {
            *slot = Slot::Cached { registry, epoch, doc: Box::new(doc) };
        }
    }
    value
}

/// Ends a lease: puts the document back (or drops it), also on unwind.
struct Lease<'c> {
    connection: &'c Connection,
    nested: bool,
    doc: Option<Doc>,
}

impl Drop for Lease<'_> {
    fn drop(&mut self) {
        if self.nested {
            return;
        }
        let mut slot = lock();
        let stale = matches!(*slot, Slot::Leased { stale: true });
        *slot = Slot::Empty;
        if stale {
            return;
        }
        if let (Some(doc), Ok(Some((registry, epoch)))) =
            (self.doc.take(), cache_key(self.connection))
        {
            *slot = Slot::Cached { registry, epoch, doc: Box::new(doc) };
        }
    }
}

/// A commit's work on the stored document, in place: the cached copy when
/// it is current (no copy is made), else the parsed rows. On success it is
/// cached under the epoch the commit wrote ([`write_changes`] sets a new
/// one first); on an error only when unchanged (a refusal leaves it as it
/// was), so a rolled-back change is never cached.
pub(crate) fn with_doc_mut<T>(
    connection: &Connection,
    work: impl FnOnce(&mut Doc) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let key = cache_key(connection)?;
    let (nested, cached) = {
        let mut slot = lock();
        match std::mem::replace(&mut *slot, Slot::Leased { stale: false }) {
            Slot::Leased { .. } => {
                *slot = Slot::Leased { stale: true };
                (true, None)
            }
            Slot::Cached { registry, epoch, doc }
                if key.as_ref().is_some_and(|(r, e)| *r == registry && *e == epoch) =>
            {
                (false, Some(*doc))
            }
            _ => (false, None),
        }
    };
    let mut lease = Lease { connection, nested, doc: None };
    let mut doc = match cached {
        Some(doc) => doc,
        None => read_rows(connection)?,
    };
    let revision = doc.revision;
    let result = work(&mut doc);
    if result.is_ok() || doc.revision == revision {
        lease.doc = Some(doc);
    }
    drop(lease);
    result
}

fn read_rows(connection: &Connection) -> anyhow::Result<Doc> {
    let revision = meta(connection, REVISION_KEY)?.and_then(|v| v.parse().ok()).unwrap_or(0);
    let tables = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sidebar_items'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !tables {
        return Ok(Doc::from_parts(revision, Vec::new(), Vec::new()));
    }
    let mut sections = Vec::new();
    let mut items = Vec::new();
    let mut statement = connection.prepare("SELECT section_json FROM sidebar_sections")?;
    for text in statement.query_map([], |row| row.get::<_, String>(0))? {
        match serde_json::from_str::<Section>(&text?) {
            Ok(section) => sections.push(section),
            Err(error) => eprintln!("cmux-tui: sidebar section row does not parse ({error})"),
        }
    }
    let mut statement = connection.prepare("SELECT item_json FROM sidebar_items")?;
    for text in statement.query_map([], |row| row.get::<_, String>(0))? {
        match serde_json::from_str::<Item>(&text?) {
            Ok(item) => items.push(item),
            Err(error) => eprintln!("cmux-tui: sidebar item row does not parse ({error})"),
        }
    }
    Ok(Doc::from_parts(revision, sections, items))
}

/// The document as `sidebar.get`, `extra.state.sidebar` and results carry it.
pub(crate) fn snapshot_value(doc: &Doc) -> anyhow::Result<Value> {
    Ok(serde_json::to_value(doc)?)
}

pub(crate) fn snapshot(connection: &Connection) -> anyhow::Result<Value> {
    with_doc(connection, snapshot_value)
}

fn write_section(transaction: &Transaction<'_>, section: &Section) -> anyhow::Result<()> {
    let json = serde_json::to_string(section)?;
    anyhow::ensure!(json.len() <= MAX_ROW_BYTES, "bad request: too_many");
    transaction
        .prepare(
            "INSERT INTO sidebar_sections(id, order_key, section_json) VALUES(?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET order_key = excluded.order_key,
                                       section_json = excluded.section_json",
        )?
        .execute(params![section.id, section.order, json])?;
    Ok(())
}

fn write_item(transaction: &Transaction<'_>, item: &Item) -> anyhow::Result<()> {
    let json = serde_json::to_string(item)?;
    anyhow::ensure!(json.len() <= MAX_ROW_BYTES, "bad request: too_many");
    transaction
        .prepare(
            "INSERT INTO sidebar_items(id, section_id, parent_id, order_key, item_json)
         VALUES(?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(id) DO UPDATE SET section_id = excluded.section_id,
                                       parent_id = excluded.parent_id,
                                       order_key = excluded.order_key,
                                       item_json = excluded.item_json",
        )?
        .execute(params![item.id, item.section, item.parent, item.order, json])?;
    Ok(())
}

/// Write `changes` and the new revision; return the `session.events`
/// changes: one upsert or delete per row, then the `sidebar_doc` marker.
/// The epoch changes first, so a document cached for this write never
/// matches the rows if the transaction rolls back.
pub(crate) fn write_changes(
    transaction: &Transaction<'_>,
    previous_revision: u64,
    revision: u64,
    changes: &Changes,
    idempotency_key: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    let epoch = crate::workspace_registry::try_new_uuid_v4()?;
    set_meta(transaction, EPOCH_KEY, &epoch)?;
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
        transaction.prepare("DELETE FROM sidebar_items WHERE id = ?1")?.execute([id])?;
        events.push(state_delete(ITEM_RESOURCE, id));
    }
    for id in &changes.deleted_sections {
        transaction.prepare("DELETE FROM sidebar_sections WHERE id = ?1")?.execute([id])?;
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
    // Another process (an older binary) may have written the rows since this
    // process cached them: read them again. A commit that holds the
    // document (another registry) must not cache it either.
    {
        let mut slot = lock();
        *slot = match *slot {
            Slot::Leased { .. } => Slot::Leased { stale: true },
            _ => Slot::Empty,
        };
    }
    let tx = connection.unchecked_transaction()?;
    create_sidebar_doc_schema(&tx)?;
    super::sidebar_doc_sync::create_triggers(&tx)?;
    if is_migrated(&tx)? {
        // A stored document that breaks an invariant (an older binary's
        // migration, a row edited by hand) would refuse every op: repair it.
        // Url items written before the body had `icon_url` keep it in
        // `extra`: move it into the body (once; a later write is clean).
        let before = read_rows(&tx)?;
        let mut repaired = before.clone();
        let mut changed = cmux_layout_reducer::sidebar_doc::reduce::repair(&mut repaired);
        if changed {
            eprintln!("cmux-tui: repaired the stored sidebar document");
        }
        changed |= lift_icon_urls(&mut repaired);
        if meta(&tx, ARRANGEMENT_KEY)?.is_none() {
            let layout = super::sidebar_layout_store::document(&tx)?;
            changed |= backfill_arrangement(&layout, &mut repaired);
            set_meta(&tx, ARRANGEMENT_KEY, "1")?;
        }
        if changed {
            super::sidebar_doc_sync::commit_derived(&tx, &before, &repaired)?;
        }
        // Old writes (also an older binary's) since the last open.
        super::sidebar_doc_sync::sync_from_legacy(&tx)?;
        tx.commit()?;
        return Ok(());
    }
    let input = super::sidebar_doc_legacy::legacy_input(&tx)?;
    let doc = migrate::migrate(&input);
    if let Err(refusal) = cmux_layout_reducer::sidebar_doc::reduce::check(&doc) {
        eprintln!("cmux-tui: the migrated sidebar document breaks an invariant ({refusal})");
    }
    let (sections, items) = doc.to_parts();
    let changes =
        Changes { sections, deleted_sections: Vec::new(), items, deleted_items: Vec::new() };
    // No journal batch at open: clients read the document with sidebar.get.
    write_changes(&tx, 0, doc.revision, &changes, None)?;
    super::sidebar_doc_sync::clear_dirty(&tx)?;
    set_meta(&tx, MIGRATED_KEY, "1")?;
    set_meta(&tx, ARRANGEMENT_KEY, "1")?;
    tx.commit()?;
    Ok(())
}

/// Copy what the migration now takes from the old layout and an older
/// migration did not into a document migrated before: each section's
/// `align` and `gap`, and unknown keys (`extra`, an arrangement's under
/// `extra.arrangement`) onto the section of the same id; the old workspaces
/// section's `align`, `gap`, `look` and `max_rows` onto every machine
/// section. Only a field still at its default takes the old value.
fn backfill_arrangement(
    layout: &cmux_layout_reducer::sidebar_layout::Document,
    doc: &mut Doc,
) -> bool {
    use cmux_layout_reducer::sidebar_doc::{GAP_RANGE, Look};
    use cmux_layout_reducer::sidebar_layout::{Alignment, Content};
    let (mut sections, items) = doc.to_parts();
    let before = sections.clone();
    for old in &layout.sections {
        let workspaces = old.content == Content::Workspaces;
        for section in &mut sections {
            let matches =
                if workspaces { section.kind.machine().is_some() } else { section.id == old.id };
            if !matches {
                continue;
            }
            if section.align == Alignment::Leading {
                section.align = old.arrangement.align.clone();
            }
            if section.gap.is_none() {
                section.gap = old.arrangement.gap.filter(|gap| GAP_RANGE.contains(gap));
            }
            if workspaces {
                if section.look == Look::List {
                    section.look = old.look.clone();
                }
                if section.max_rows.is_none() {
                    section.max_rows = old.max_rows.filter(|rows| (1..=50).contains(rows));
                }
            } else {
                for (key, value) in &old.extra {
                    section.extra.entry(key.clone()).or_insert_with(|| value.clone());
                }
                if !old.arrangement.extra.is_empty() {
                    section
                        .extra
                        .entry("arrangement".to_string())
                        .or_insert_with(|| Value::Object(old.arrangement.extra.clone()));
                }
            }
        }
    }
    if sections == before {
        return false;
    }
    *doc = Doc::from_parts(doc.revision, sections, items);
    true
}

/// Move every url item's old `extra.icon_url` into its body.
fn lift_icon_urls(doc: &mut Doc) -> bool {
    let old = |item: &Item| {
        matches!(item.body, cmux_layout_reducer::sidebar_doc::Body::Url { .. })
            && item.extra.contains_key("icon_url")
    };
    if !doc.items_unordered().any(old) {
        return false;
    }
    let (sections, mut items) = doc.to_parts();
    let mut changed = false;
    for item in &mut items {
        changed |= item.lift_icon_url();
    }
    if changed {
        *doc = Doc::from_parts(doc.revision, sections, items);
    }
    changed
}
