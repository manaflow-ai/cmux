//! Both directions between the old personal stores and the sidebar document
//! (`sidebar-doc-v1`), so old and new clients see one sidebar.
//!
//! Old -> document, incremental: SQLite triggers record each changed old
//! row in `sidebar_doc_dirty` (a personal row inserted, regrouped or
//! renamed; a group created, changed, reslotted or deleted; a pin flag
//! changed: only a set flag is followed, see `sync_flag`), and a row move
//! records its row ([`mark_moved`]). Every old write
//! path then calls [`sync_from_legacy`] in its transaction, which reads only
//! the dirty rows (and, per row, its neighbor by an indexed query), applies
//! the matching document ops, and queues the changes into the commit's
//! `session.events` batch. A write with no dirty row costs one query. The
//! decision for a row is from state, not history: a row moves when its item
//! is not already right after the item of its old-order neighbor. A
//! workspace the user keeps outside its machine section (Pinned, custom) is
//! moved only when an old write puts it into a group.
//!
//! Document -> old ([`write_back`]), after each `sidebar.*` commit, for the
//! items it changed: a workspace's personal row gets its group and a place
//! after the row of the nearest earlier workspace in document order; a group
//! item gets its personal group row (name, color, icon, collapse, room,
//! `pinned` = in Pinned) and a slot before its next loose workspace; a
//! removed group item deletes its group row. Approximate where the old model
//! has no place: a loose workspace in Pinned or a custom section keeps its
//! old row (group and place, as a pinned tile did), with no pin flag
//! written, and is no anchor for the machine order; url, app and
//! other non-workspace items, sections, and a group's place among other
//! groups at the same slot are not written. The rows it writes are not
//! synced back (the dirty marks are cleared at the end).
//!
//! Closes ([`close_workspaces`]): a tombstoned workspace leaves its machine
//! section (and an emptied group there); in Pinned and custom sections it
//! stays.

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use cmux_layout_reducer::sidebar_doc::migrate::LegacyWorkspace;
use cmux_layout_reducer::sidebar_doc::reduce::{self, Applied, Batch};
use cmux_layout_reducer::sidebar_doc::{
    Body, Doc, GroupPatch, Item, ItemId, Op, PINNED_SECTION_ID, Patch, Section, SectionPlace,
    Target, WorkspaceRef, group_item_id, machine_section_id,
};

use super::sidebar_doc_legacy::mint_item_id;
use super::sidebar_doc_store as store;
use super::values::local_registry_id;

/// The dirty table, its triggers, and the order index of the personal rows
/// (the neighbor queries and row moves; it replaces the older position
/// index, which an older binary makes again at its own open). Run at every open (after the personal and presentation
/// tables exist); additive, so an older binary keeps working (and its own
/// writes are marked too).
pub(crate) fn create_triggers(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS sidebar_doc_dirty (
           kind TEXT NOT NULL,
           a TEXT NOT NULL,
           b TEXT NOT NULL DEFAULT '',
           PRIMARY KEY(kind, a, b)
         );
         DROP INDEX IF EXISTS sidebar_doc_personal_position;
         CREATE INDEX IF NOT EXISTS personal_workspaces_order
           ON personal_workspaces(position, session_id, workspace_key);
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_row_insert AFTER INSERT ON personal_workspaces
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a, b)
               VALUES('ws', NEW.session_id, NEW.workspace_key); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_row_update
           AFTER UPDATE OF group_id, workspace_key ON personal_workspaces
           WHEN OLD.group_id IS NOT NEW.group_id OR OLD.workspace_key IS NOT NEW.workspace_key
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a, b)
               VALUES('ws', NEW.session_id, NEW.workspace_key); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_group_insert AFTER INSERT ON personal_groups
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a) VALUES('group', NEW.group_id); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_group_update AFTER UPDATE ON personal_groups
           WHEN OLD.name IS NOT NEW.name OR OLD.color IS NOT NEW.color
             OR OLD.collapsed IS NOT NEW.collapsed OR OLD.profile_id IS NOT NEW.profile_id
             OR OLD.icon IS NOT NEW.icon OR OLD.pinned IS NOT NEW.pinned
             OR OLD.top_position IS NOT NEW.top_position OR OLD.position IS NOT NEW.position
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a) VALUES('group', NEW.group_id); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_group_delete AFTER DELETE ON personal_groups
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a) VALUES('group', OLD.group_id); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_flag_insert AFTER INSERT ON workspace_presentation
           WHEN NEW.pinned = 1
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a) VALUES('flag', NEW.workspace_key); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_flag_update
           AFTER UPDATE OF pinned ON workspace_presentation WHEN OLD.pinned IS NOT NEW.pinned
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a) VALUES('flag', NEW.workspace_key); END;
         CREATE TRIGGER IF NOT EXISTS sidebar_doc_flag_delete AFTER DELETE ON workspace_presentation
           WHEN OLD.pinned = 1
         BEGIN INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a) VALUES('flag', OLD.workspace_key); END;",
    )?;
    Ok(())
}

fn dirty_table(connection: &Connection) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sidebar_doc_dirty'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// Mark a moved personal row (a position change fires no trigger: a move
/// renumbers every row, and only the moved one changed its neighbors).
pub(crate) fn mark_moved(
    transaction: &Transaction<'_>,
    session: &str,
    key: &str,
) -> anyhow::Result<()> {
    if dirty_table(transaction)? {
        transaction.execute(
            "INSERT OR IGNORE INTO sidebar_doc_dirty(kind, a, b) VALUES('ws', ?1, ?2)",
            params![session, key],
        )?;
    }
    Ok(())
}

pub(crate) fn clear_dirty(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if dirty_table(transaction)? {
        transaction.execute("DELETE FROM sidebar_doc_dirty", [])?;
    }
    Ok(())
}

/// Apply one op to the running document; a refusal is logged and skipped
/// (an old write the document cannot follow, for example a group of two
/// machines, leaves the document as it was).
fn try_apply(batch: &mut Batch<'_>, op: Op) {
    let mut mint = mint_item_id;
    if let Err(refusal) = batch.apply(std::slice::from_ref(&op), &mut mint) {
        eprintln!("cmux-tui: sidebar doc does not follow an old write ({refusal})");
    }
}

/// Store `doc` (derived from `before` by a whole-document repair at open)
/// and queue its changes into the current commit's batch.
pub(crate) fn commit_derived(
    transaction: &Transaction<'_>,
    before: &Doc,
    doc: &Doc,
) -> anyhow::Result<()> {
    let changes = reduce::diff(before, doc);
    if changes.is_empty() {
        return Ok(());
    }
    let events =
        store::write_changes(transaction, before.revision, before.revision + 1, &changes, None)?;
    for event in &events {
        super::closed_history_store::queue_change(transaction, event)?;
    }
    Ok(())
}

/// Store a finished batch's changes (the document is at `revision`) and
/// queue them into the current commit's batch.
fn commit_applied(
    transaction: &Transaction<'_>,
    previous_revision: u64,
    revision: u64,
    applied: &Applied,
) -> anyhow::Result<()> {
    if applied.changes.is_empty() {
        return Ok(());
    }
    let events =
        store::write_changes(transaction, previous_revision, revision, &applied.changes, None)?;
    // One row per change: the open path queues outside a journaled commit,
    // so its rows wait for the next commit, which an older binary may run.
    for event in &events {
        super::closed_history_store::queue_change(transaction, event)?;
    }
    Ok(())
}

/// A personal row as the neighbor queries read it.
#[derive(Debug, Clone)]
struct Row {
    session: String,
    key: String,
    position: i64,
    group: Option<String>,
}

fn row(connection: &Connection, session: &str, key: &str) -> anyhow::Result<Option<Row>> {
    Ok(connection
        .query_row(
            "SELECT w.position, g.group_id FROM personal_workspaces AS w
             LEFT JOIN personal_groups AS g ON g.group_id = w.group_id
             WHERE w.session_id = ?1 AND w.workspace_key = ?2",
            params![session, key],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?)),
        )
        .optional()?
        .map(|(position, group)| Row { session: session.into(), key: key.into(), position, group }))
}

/// The last loose row before `position` (a row whose group does not exist
/// counts as loose).
fn loose_before(connection: &Connection, position: i64) -> anyhow::Result<Option<Row>> {
    Ok(connection
        .query_row(
            "SELECT w.session_id, w.workspace_key, w.position FROM personal_workspaces AS w
             WHERE w.position < ?1
               AND (w.group_id IS NULL
                    OR NOT EXISTS (SELECT 1 FROM personal_groups AS g WHERE g.group_id = w.group_id))
             ORDER BY w.position DESC LIMIT 1",
            [position],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)),
        )
        .optional()?
        .map(|(session, key, position)| Row { session, key, position, group: None }))
}

/// What shows right before a row in the old order.
enum Neighbor {
    Row(Row),
    Group(String),
}

/// The old-order neighbor of a loose row at `position`: the last group
/// slotted between the previous loose row and it, else that row.
fn loose_neighbor(connection: &Connection, position: i64) -> anyhow::Result<Option<Neighbor>> {
    let previous = loose_before(connection, position)?;
    let floor = previous.as_ref().map_or(i64::MIN, |row| row.position);
    let group: Option<String> = connection
        .query_row(
            "SELECT group_id FROM personal_groups
             WHERE top_position IS NOT NULL AND top_position <= ?1 AND top_position > ?2
             ORDER BY top_position DESC, position DESC LIMIT 1",
            params![position, floor],
            |r| r.get(0),
        )
        .optional()?;
    Ok(match group {
        Some(group) => Some(Neighbor::Group(group)),
        None => previous.map(Neighbor::Row),
    })
}

/// The previous member of `group` before `position`.
fn member_before(
    connection: &Connection,
    group: &str,
    position: i64,
) -> anyhow::Result<Option<Row>> {
    Ok(connection
        .query_row(
            "SELECT session_id, workspace_key, position FROM personal_workspaces
             WHERE group_id = ?1 AND position < ?2 ORDER BY position DESC LIMIT 1",
            params![group, position],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)),
        )
        .optional()?
        .map(|(session, key, position)| Row { session, key, position, group: Some(group.into()) }))
}

/// The public form of a personal row (None: a closed local workspace).
fn legacy_workspace(
    connection: &Connection,
    local: &str,
    session: &str,
    key: &str,
) -> anyhow::Result<Option<LegacyWorkspace>> {
    if session != local {
        return Ok(Some(LegacyWorkspace {
            session_id: session.into(),
            workspace_key: key.into(),
            workspace_id: None,
        }));
    }
    Ok(super::values::workspace_public_id_for_key(connection, key)?.map(|id| LegacyWorkspace {
        session_id: session.into(),
        workspace_key: key.into(),
        workspace_id: Some(id),
    }))
}

fn row_item<'a>(doc: &'a Doc, workspace: &LegacyWorkspace) -> Option<&'a Item> {
    let reference = workspace.reference();
    doc.workspace_item(&reference)
        .or_else(|| doc.placement_item(&workspace.session_id, &workspace.workspace_key))
}

/// The document item of an old group id: `itm_g_<id>` (migrated or synced)
/// or the id itself (a group the document made, written back).
fn group_item<'a>(doc: &'a Doc, group: &str) -> Option<&'a Item> {
    doc.item(&group_item_id(group)).or_else(|| doc.item(group)).filter(|item| item.body.is_group())
}

/// The old group id of a group item (the inverse of [`group_item`]).
pub(crate) fn legacy_group_id(item: &str) -> String {
    item.strip_prefix("itm_g_").unwrap_or(item).to_string()
}

fn neighbor_item(
    connection: &Connection,
    doc: &Doc,
    local: &str,
    neighbor: &Neighbor,
) -> anyhow::Result<Option<ItemId>> {
    Ok(match neighbor {
        Neighbor::Group(group) => group_item(doc, group).map(|item| item.id.clone()),
        Neighbor::Row(row) => legacy_workspace(connection, local, &row.session, &row.key)?
            .and_then(|workspace| row_item(doc, &workspace).map(|item| item.id.clone())),
    })
}

/// Where an item lands among `(section, parent)`: right after `anchor`
/// when it is a sibling; first when there is no neighbor; else at the end.
fn anchored(
    section: &str,
    parent: Option<&str>,
    anchor: Option<&Item>,
    has_neighbor: bool,
) -> Target {
    let sibling = anchor.filter(|item| item.section == section && item.parent.as_deref() == parent);
    Target {
        section: section.into(),
        parent: parent.map(str::to_string),
        after: sibling.map(|item| item.id.clone()),
        index: (sibling.is_none() && !has_neighbor).then_some(0),
        before: None,
    }
}

/// Whether `item` already sits at `target` (right after its anchor, or
/// first).
fn already_at(doc: &Doc, item: &Item, target: &Target) -> bool {
    if item.section != target.section || item.parent != target.parent {
        return false;
    }
    let Some(list) = doc.list_entries(&target.section, target.parent.as_deref()) else {
        return false;
    };
    let previous = list.range(..(item.order.clone(), item.id.clone())).next_back();
    match (&target.after, target.index) {
        (Some(anchor), _) => previous.is_some_and(|(_, id)| id == anchor),
        (None, Some(0)) => previous.is_none(),
        (None, None) => true,
        _ => false,
    }
}

fn sync_row(
    connection: &Connection,
    batch: &mut Batch<'_>,
    local: &str,
    row: &Row,
) -> anyhow::Result<()> {
    let Some(workspace) = legacy_workspace(connection, local, &row.session, &row.key)? else {
        return Ok(());
    };
    let doc = batch.doc();
    let placed = row_item(doc, &workspace).cloned();
    let group = row.group.as_deref().and_then(|group| group_item(doc, group)).cloned();
    let (section, parent) = match &group {
        Some(group) => (group.section.clone(), Some(group.id.clone())),
        None => (machine_section_id(&workspace.session_id), None),
    };
    if let Some(item) = &placed {
        let in_machine =
            doc.section(&item.section).is_some_and(|section| section.kind.machine().is_some());
        let regrouped = group.as_ref().is_some_and(|group| item.parent.as_ref() != Some(&group.id));
        if !in_machine && !regrouped {
            // The user keeps it in Pinned or a custom section.
            return Ok(());
        }
    }
    let neighbor = match &row.group {
        Some(group) if parent.is_some() => {
            member_before(connection, group, row.position)?.map(Neighbor::Row)
        }
        _ => loose_neighbor(connection, row.position)?,
    };
    let anchor = match &neighbor {
        Some(neighbor) => neighbor_item(connection, doc, local, neighbor)?,
        None => None,
    };
    let anchor_item = anchor.as_deref().and_then(|id| doc.item(id)).cloned();
    let target = anchored(&section, parent.as_deref(), anchor_item.as_ref(), neighbor.is_some());
    match placed {
        Some(item) if already_at(doc, &item, &target) => {}
        Some(item) => try_apply(batch, Op::Move { items: vec![item.id], to: target }),
        None => {
            let reference = workspace.reference();
            if doc.section(&section).is_none() {
                try_apply(batch, Op::Adopt { refs: vec![reference], to: None });
                if let Some(item) = row_item(batch.doc(), &workspace).cloned() {
                    try_apply(batch, Op::Move { items: vec![item.id], to: target });
                }
            } else {
                try_apply(batch, Op::Adopt { refs: vec![reference], to: Some(target) });
            }
        }
    }
    Ok(())
}

struct GroupRow {
    name: String,
    color: Option<String>,
    icon: Option<String>,
    collapsed: bool,
    profile: String,
    pinned: bool,
    top_position: Option<i64>,
    position: i64,
}

fn group_row(connection: &Connection, id: &str) -> anyhow::Result<Option<GroupRow>> {
    Ok(connection
        .query_row(
            "SELECT name, color, icon, collapsed, profile_id, pinned, top_position, position
             FROM personal_groups WHERE group_id = ?1",
            [id],
            |r| {
                // Old names may be longer than the document allows.
                let name = reduce::fit_title(&r.get::<_, String>(0)?);
                Ok(GroupRow {
                    name: if name.is_empty() { "Group".into() } else { name },
                    color: r.get(1)?,
                    icon: r.get(2)?,
                    collapsed: r.get::<_, i64>(3)? != 0,
                    profile: r.get(4)?,
                    pinned: r.get::<_, i64>(5)? != 0,
                    top_position: r.get(6)?,
                    position: r.get(7)?,
                })
            },
        )
        .optional()?)
}

fn sync_group(
    connection: &Connection,
    batch: &mut Batch<'_>,
    local: &str,
    id: &str,
    slot: bool,
) -> anyhow::Result<()> {
    let Some(group) = group_row(connection, id)? else {
        if let Some(item) = group_item(batch.doc(), id).cloned() {
            try_apply(batch, Op::GroupUngroup { id: item.id });
        }
        return Ok(());
    };
    if group_item(batch.doc(), id).is_none() {
        let machine: String = connection
            .query_row(
                "SELECT session_id FROM personal_workspaces WHERE group_id = ?1
                 ORDER BY position LIMIT 1",
                [id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_else(|| local.to_string());
        let section = machine_section_id(&machine);
        if batch.doc().section(&section).is_none() {
            let section = Section::machine(&machine);
            try_apply(batch, Op::SectionAdd { section, place: SectionPlace::default() });
        }
        try_apply(
            batch,
            Op::GroupCreate {
                id: Some(group_item_id(id)),
                name: group.name.clone(),
                color: group.color.clone(),
                icon: group.icon.clone(),
                profile: Some(group.profile.clone()),
                items: Vec::new(),
                to: Some(Target::end(&section)),
            },
        );
    }
    let Some(item) = group_item(batch.doc(), id).cloned() else { return Ok(()) };
    if let Body::Group { name, color, icon, collapsed, profile } = &item.body {
        let field = |old: &Option<String>, new: &Option<String>| match (old == new, new) {
            (true, _) => Patch::Keep,
            (false, Some(value)) => Patch::Set(value.clone()),
            (false, None) => Patch::Clear,
        };
        let patch = GroupPatch {
            name: (*name != group.name).then(|| group.name.clone()),
            color: field(color, &group.color),
            icon: field(icon, &group.icon),
            collapsed: (*collapsed != group.collapsed).then_some(group.collapsed),
            profile: field(profile, &Some(group.profile.clone())),
            auto_archive: Patch::Keep,
        };
        if patch != GroupPatch::default() {
            try_apply(batch, Op::GroupUpdate { id: item.id.clone(), patch });
        }
    }
    let in_pinned = item.section == PINNED_SECTION_ID;
    if group.pinned && !in_pinned {
        try_apply(batch, Op::Pin { items: vec![item.id] });
        return Ok(());
    }
    if !group.pinned && in_pinned {
        try_apply(batch, Op::Unpin { items: vec![item.id.clone()] });
    }
    // Its slot, while it is in its machine section's top level.
    if !slot {
        return Ok(());
    }
    let doc = batch.doc();
    let Some(item) = doc.item(&item.id).cloned() else { return Ok(()) };
    if doc.section(&item.section).is_none_or(|section| section.kind.machine().is_none()) {
        return Ok(());
    }
    let neighbor = match group.top_position {
        Some(top) => loose_before(connection, top)?.map(Neighbor::Row),
        None => {
            // After every loose workspace, then by group order.
            let previous: Option<String> = connection
                .query_row(
                    "SELECT group_id FROM personal_groups
                     WHERE top_position IS NULL AND position < ?1
                     ORDER BY position DESC LIMIT 1",
                    [group.position],
                    |r| r.get(0),
                )
                .optional()?;
            match previous {
                Some(previous) => Some(Neighbor::Group(previous)),
                None => loose_before(connection, i64::MAX)?.map(Neighbor::Row),
            }
        }
    };
    let anchor = match &neighbor {
        Some(neighbor) => neighbor_item(connection, doc, local, neighbor)?,
        None => None,
    };
    let anchor_item = anchor.as_deref().and_then(|id| doc.item(id)).cloned();
    let target = anchored(&item.section, None, anchor_item.as_ref(), neighbor.is_some());
    if !already_at(doc, &item, &target) {
        try_apply(batch, Op::Move { items: vec![item.id], to: target });
    }
    Ok(())
}

fn sync_flag(
    connection: &Connection,
    batch: &mut Batch<'_>,
    local: &str,
    key: &str,
) -> anyhow::Result<()> {
    let Some(id) = super::values::workspace_public_id_for_key(connection, key)? else {
        return Ok(());
    };
    let pinned = connection
        .query_row(
            "SELECT pinned FROM workspace_presentation WHERE workspace_key = ?1",
            [key],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(0)
        != 0;
    // Only a set flag is followed. The current app clears the flag as its
    // "moved into a pinned tile" mark (after it shows the tile), so a
    // cleared flag is not an unpin: following it would undo every pin the
    // TUI or iOS makes. Unpin goes through `sidebar.unpin` or the tiles.
    if !pinned {
        return Ok(());
    }
    let reference = WorkspaceRef::new(local, &id);
    if batch.doc().workspace_item(&reference).is_none() {
        try_apply(batch, Op::Adopt { refs: vec![reference.clone()], to: None });
    }
    if let Some(item) = batch.doc().workspace_item(&reference)
        && item.section != PINNED_SECTION_ID
    {
        let id = item.id.clone();
        try_apply(batch, Op::Pin { items: vec![id] });
    }
    Ok(())
}

/// Follow the old writes marked since the last sync (see the module doc).
pub(crate) fn sync_from_legacy(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if !super::store::state_tables_ready(transaction)?
        || !dirty_table(transaction)?
        || !store::is_migrated(transaction)?
    {
        return Ok(());
    }
    let dirty: Vec<(String, String, String)> = {
        let mut statement = transaction.prepare("SELECT kind, a, b FROM sidebar_doc_dirty")?;
        statement
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<_, _>>()?
    };
    if dirty.is_empty() {
        return Ok(());
    }
    transaction.execute("DELETE FROM sidebar_doc_dirty", [])?;
    let local = local_registry_id(transaction)?;
    let groups: Vec<&str> =
        dirty.iter().filter(|(kind, ..)| kind == "group").map(|(_, a, _)| a.as_str()).collect();
    let mut rows = Vec::new();
    for (_, session, key) in dirty.iter().filter(|(kind, ..)| kind == "ws") {
        if let Some(row) = row(transaction, session, key)? {
            rows.push(row);
        }
    }
    rows.sort_by_key(|row| row.position);
    store::with_doc_mut(transaction, |doc| {
        let previous_revision = doc.revision;
        let mut batch = Batch::new(doc);
        // Groups before their members; a group's slot after the rows (it
        // can name a row placed here), in one pass when no row is dirty.
        for group in &groups {
            sync_group(transaction, &mut batch, &local, group, rows.is_empty())?;
        }
        for row in &rows {
            sync_row(transaction, &mut batch, &local, row)?;
        }
        if !rows.is_empty() {
            for group in &groups {
                sync_group(transaction, &mut batch, &local, group, true)?;
            }
        }
        for (_, key, _) in dirty.iter().filter(|(kind, ..)| kind == "flag") {
            sync_flag(transaction, &mut batch, &local, key)?;
        }
        let applied = batch.finish();
        commit_applied(transaction, previous_revision, doc.revision, &applied)
    })
}

/// Workspaces of this machine that closed (tombstoned in this commit).
pub(crate) fn close_workspaces(
    transaction: &Transaction<'_>,
    ids: &[String],
) -> anyhow::Result<()> {
    if ids.is_empty()
        || !super::store::state_tables_ready(transaction)?
        || !store::is_migrated(transaction)?
    {
        return Ok(());
    }
    let local = local_registry_id(transaction)?;
    let refs: Vec<WorkspaceRef> = ids.iter().map(|id| WorkspaceRef::new(&local, id)).collect();
    store::with_doc_mut(transaction, |doc| {
        let previous_revision = doc.revision;
        let mut batch = Batch::new(doc);
        try_apply(&mut batch, Op::Close { refs });
        let applied = batch.finish();
        commit_applied(transaction, previous_revision, doc.revision, &applied)
    })
}

/// The old key of a workspace item: this machine's by its public id, another
/// machine's by its placement reference.
fn item_key(
    connection: &Connection,
    local: &str,
    reference: &WorkspaceRef,
) -> anyhow::Result<Option<String>> {
    if let Some(key) = reference.placement_ref() {
        return Ok(Some(key.to_string()));
    }
    if reference.session_id != local {
        return Ok(None);
    }
    Ok(connection
        .query_row(
            "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
            [reference.workspace_id.as_str()],
            |r| r.get(0),
        )
        .optional()?)
}

fn position_of(connection: &Connection, session: &str, key: &str) -> anyhow::Result<Option<i64>> {
    Ok(connection
        .query_row(
            "SELECT position FROM personal_workspaces WHERE session_id = ?1 AND workspace_key = ?2",
            params![session, key],
            |r| r.get(0),
        )
        .optional()?)
}

fn in_machine_section(doc: &Doc, item: &Item) -> bool {
    doc.section(&item.section).is_some_and(|section| section.kind.machine().is_some())
}

/// The personal row of the nearest workspace before item `id` in document
/// order, as `(session, key)`.
fn previous_row(
    connection: &Connection,
    doc: &Doc,
    local: &str,
    id: &str,
) -> anyhow::Result<Option<(String, String)>> {
    let mut cursor = doc.previous_in_order(id);
    while let Some(item) = cursor {
        // Rows of items outside machine sections stay where they were, so
        // they are no anchor for the machine order.
        if !in_machine_section(doc, item) {
            cursor = doc.last_before_section(&item.section);
            continue;
        }
        if let Some(reference) = item.body.workspace()
            && let Some(key) = item_key(connection, local, reference)?
            && position_of(connection, &reference.session_id, &key)?.is_some()
        {
            return Ok(Some((reference.session_id.clone(), key)));
        }
        cursor = doc.previous_in_order(&item.id);
    }
    Ok(None)
}

/// Write the items a commit changed back to the old stores (see the module
/// doc). Returns whether an old row changed.
pub(crate) fn write_back(
    transaction: &Transaction<'_>,
    after: &Doc,
    applied: &Applied,
) -> anyhow::Result<bool> {
    let local = local_registry_id(transaction)?;
    let mut wrote = false;
    // The changed items in document order: a workspace's place follows the
    // row of the workspace before it, which may have moved in this commit.
    let mut changed: Vec<&Item> =
        applied.changes.items.iter().filter_map(|item| after.item(&item.id)).collect();
    changed.sort_by_cached_key(|item| after.display_key(item));
    // Groups first, so their members can name them.
    for item in &changed {
        let Body::Group { name, color, icon, collapsed, profile } = &item.body else { continue };
        let id = legacy_group_id(&item.id);
        let profile = profile.clone().unwrap_or_else(|| {
            crate::workspace_registry::personal_store::DEFAULT_PROFILE_ID.into()
        });
        let pinned = item.section == PINNED_SECTION_ID;
        let exists = transaction
            .query_row("SELECT 1 FROM personal_groups WHERE group_id = ?1", [&id], |_| Ok(()))
            .optional()?
            .is_some();
        if exists {
            transaction.execute(
                "UPDATE personal_groups SET name = ?2, color = ?3, icon = ?4, collapsed = ?5,
                   profile_id = ?6, pinned = ?7 WHERE group_id = ?1",
                params![id, name, color, icon, i64::from(*collapsed), profile, i64::from(pinned)],
            )?;
        } else {
            transaction.execute(
                "INSERT INTO personal_groups(group_id, profile_id, name, color, collapsed, position, icon, pinned)
                 VALUES(?1, ?2, ?3, ?4, ?5, (SELECT COALESCE(MAX(position) + 1, 0) FROM personal_groups), ?6, ?7)",
                params![id, profile, name, color, i64::from(*collapsed), icon, i64::from(pinned)],
            )?;
        }
        wrote = true;
    }
    for id in &applied.changes.deleted_items {
        let was_group = applied
            .previous_items
            .get(id)
            .and_then(Option::as_ref)
            .is_some_and(|item| item.body.is_group());
        if was_group {
            let group = legacy_group_id(id);
            transaction.execute(
                "UPDATE personal_workspaces SET group_id = NULL WHERE group_id = ?1",
                [&group],
            )?;
            wrote |= transaction
                .execute("DELETE FROM personal_groups WHERE group_id = ?1", [&group])?
                > 0;
        }
    }
    // Workspaces, in document order.
    for item in &changed {
        let Some(reference) = item.body.workspace() else { continue };
        let Some(key) = item_key(transaction, &local, reference)? else { continue };
        let session = reference.session_id.as_str();
        let group = item.parent.as_deref().map(legacy_group_id);
        if position_of(transaction, session, &key)?.is_none() {
            if session != local {
                continue;
            }
            transaction.execute(
                "INSERT INTO personal_workspaces(session_id, workspace_key, position)
                 VALUES(?1, ?2, ?3)",
                params![
                    session,
                    key,
                    crate::workspace_registry::personal_store::next_workspace_position(
                        transaction
                    )?
                ],
            )?;
            // The new last row, and the live workspaces with no row (they
            // follow every row and moved down by one): restated for
            // `workspace_placement` readers without `sidebar-doc-v1`.
            if let Some(index) = super::personal::row_index(transaction, session, &key)? {
                super::placement_shift::queue(transaction, index, None)?;
            }
            wrote = true;
        }
        // A loose workspace in Pinned or a custom section keeps its old row
        // (group and place), as a pinned tile did: the old model has no
        // place for it. Coming back loose into its machine section (unpin),
        // the row also stays: old clients see it where it was before the
        // pin, as they did with tiles; the document places it at the end.
        if item.parent.is_none() && !in_machine_section(after, item) {
            continue;
        }
        let came_back = item.parent.is_none()
            && applied
                .previous_items
                .get(&item.id)
                .and_then(Option::as_ref)
                .is_some_and(|old| !in_machine_section(after, old));
        if came_back {
            continue;
        }
        let index_before = super::personal::row_index(transaction, session, &key)?;
        transaction.execute(
            "UPDATE personal_workspaces SET group_id = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
            params![session, key, group],
        )?;
        // Right after the row of the nearest earlier workspace.
        let previous = previous_row(transaction, after, &local, &item.id)?;
        crate::workspace_registry::WorkspaceRegistry::move_personal_row_after(
            transaction,
            session,
            &key,
            previous.as_ref().map(|(s, k)| (s.as_str(), k.as_str())),
        )?;
        // The row (its group or place) and the rows it passed: restated for
        // `workspace_placement` readers without `sidebar-doc-v1`.
        if let Some(index_after) = super::personal::row_index(transaction, session, &key)? {
            let index_before = index_before.unwrap_or(index_after);
            super::placement_shift::queue(
                transaction,
                index_before.min(index_after),
                Some(index_before.max(index_after)),
            )?;
        }
        wrote = true;
    }
    // Group slots: before the next loose workspace of the group's section.
    for item in &changed {
        if !item.body.is_group() || item.parent.is_some() {
            continue;
        }
        if !in_machine_section(after, item) {
            continue;
        }
        let mut slot = None;
        let entry = (item.order.clone(), item.id.clone());
        let next = after
            .list_entries(&item.section, None)
            .into_iter()
            .flat_map(|set| {
                set.range((std::ops::Bound::Excluded(entry.clone()), std::ops::Bound::Unbounded))
            })
            .filter_map(|(_, id)| after.item(id));
        for next in next {
            let Some(reference) = next.body.workspace() else { continue };
            let Some(key) = item_key(transaction, &local, reference)? else { continue };
            if let Some(position) = position_of(transaction, &reference.session_id, &key)? {
                slot = Some(position);
                break;
            }
        }
        transaction.execute(
            "UPDATE personal_groups SET top_position = ?2 WHERE group_id = ?1",
            params![legacy_group_id(&item.id), slot],
        )?;
        wrote = true;
    }
    clear_dirty(transaction)?;
    Ok(wrote)
}
