//! The old sidebar verbs on top of the sidebar document, so clients that
//! do not know `sidebar-doc-v1` keep working unchanged:
//!
//! - Reads of the old stores into the migration input ([`legacy_input`]).
//! - Old writes become document ops, and document ops are written back:
//!   see [`super::sidebar_doc_sync`].
//! - `sidebar_layout.get` (and `extra.state.sidebar_layout`) shows the
//!   document's Pinned items as the `sec_pinned` tiles
//!   ([`project_layout`]); its revision is the layout's plus the
//!   document's, so it advances when either changes. `sidebar_layout.update`
//!   reduces on that projection, stores the rest of the layout as before,
//!   and turns a tile added, removed or reordered into Pinned ops
//!   ([`pinned_ops`]).
//! - `workspace.list {order: personal}` is the document order of this
//!   machine's workspaces ([`workspace_order`]).

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;

use cmux_layout_reducer::sidebar_doc::migrate::{
    LegacyEntry, LegacyGroup, LegacyInput, LegacyMachine, LegacyWorkspace, body_of_layout_ref,
    layout_ref_of_body,
};
use cmux_layout_reducer::sidebar_doc::{
    Body, Doc, ItemId, NewItem, Op, PINNED_SECTION_ID, Patch, SectionPatch, Target, WorkspaceRef,
};
use cmux_layout_reducer::sidebar_layout::{self, Document};

use super::sidebar_doc_store as store;
use super::values::local_registry_id;
use crate::workspace_registry::personal_store::{read_groups, read_workspaces};

/// A random item id (`itm_<uuid>`).
pub(crate) fn mint_item_id() -> ItemId {
    // An empty fallback made every item `itm_` (one id for all of them):
    // a failed random source gets a process-unique id instead.
    match crate::workspace_registry::try_new_uuid_v4() {
        Ok(uuid) => format!("itm_{}", uuid.replace('-', "")),
        Err(_) => {
            static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos());
            format!("itm_{nanos:024x}{:08x}", u32::try_from(n & 0xffff_ffff).unwrap_or(0))
        }
    }
}

struct LegacyState {
    local: String,
    machines: Vec<LegacyMachine>,
    entries: Vec<LegacyEntry>,
    flags: Vec<(String, WorkspaceRef)>,
}

fn read_state(connection: &Connection) -> anyhow::Result<LegacyState> {
    let local = local_registry_id(connection)?;
    let mut machines = vec![LegacyMachine { session_id: local.clone(), title: None }];
    // Only the id and name: the full reader fails on a bad transport or
    // capabilities blob, and this runs at registry open.
    let sessions: Vec<(String, Option<String>)> = {
        let mut statement = connection
            .prepare("SELECT session_id, machine_name FROM sessions ORDER BY session_id")?;
        statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?.collect::<Result<_, _>>()?
    };
    for (session_id, machine_name) in sessions {
        if session_id == local {
            machines[0].title = machine_name;
        } else {
            machines.push(LegacyMachine { session_id, title: machine_name });
        }
    }
    let rows = read_workspaces(connection)?;
    let groups = read_groups(connection)?;
    let known: HashSet<&str> = groups.iter().map(|group| group.id.as_str()).collect();
    // The public form of each row; a closed local workspace is left out.
    let live: HashMap<String, String> = {
        let mut statement = connection.prepare(
            "SELECT workspace_key, public_id FROM resource_workspaces
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<_, _>>()?
    };
    let mut workspaces: Vec<Option<LegacyWorkspace>> = Vec::with_capacity(rows.len());
    for row in &rows {
        if row.session_id == local {
            workspaces.push(live.get(&row.workspace_key).cloned().map(|id| LegacyWorkspace {
                session_id: row.session_id.clone(),
                workspace_key: row.workspace_key.clone(),
                workspace_id: Some(id),
            }));
        } else {
            workspaces.push(Some(LegacyWorkspace {
                session_id: row.session_id.clone(),
                workspace_key: row.workspace_key.clone(),
                workspace_id: None,
            }));
        }
    }
    let legacy_group =
        |group: &crate::workspace_registry::personal_store::PersonalGroup| LegacyGroup {
            id: group.id.clone(),
            name: group.name.clone(),
            color: group.color.clone(),
            icon: group.icon.clone(),
            collapsed: group.collapsed,
            profile: Some(group.profile.clone()),
            pinned: group.pinned,
        };
    let members = |group: &str| -> Vec<LegacyWorkspace> {
        rows.iter()
            .zip(&workspaces)
            .filter(|(row, _)| row.group.as_deref() == Some(group))
            .filter_map(|(_, workspace)| workspace.clone())
            .collect()
    };
    let mut entries = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        for group in groups.iter().filter(|group| group.top_index == Some(index)) {
            entries.push(LegacyEntry::Group {
                group: legacy_group(group),
                members: members(&group.id),
            });
        }
        if row.group.as_deref().is_none_or(|group| !known.contains(group))
            && let Some(workspace) = &workspaces[index]
        {
            entries.push(LegacyEntry::Workspace { workspace: workspace.clone() });
        }
    }
    for group in groups.iter().filter(|group| group.top_index.is_none_or(|top| top >= rows.len())) {
        entries
            .push(LegacyEntry::Group { group: legacy_group(group), members: members(&group.id) });
    }
    // Pin flags, in the personal order.
    let mut flagged: HashSet<String> = HashSet::new();
    let mut statement =
        connection.prepare("SELECT workspace_key FROM workspace_presentation WHERE pinned = 1")?;
    for key in statement.query_map([], |row| row.get::<_, String>(0))? {
        flagged.insert(key?);
    }
    let mut flags = Vec::new();
    let order: Vec<&LegacyWorkspace> = entries
        .iter()
        .flat_map(|entry| match entry {
            LegacyEntry::Workspace { workspace } => vec![workspace],
            LegacyEntry::Group { members, .. } => members.iter().collect(),
        })
        .collect();
    let mut seen = HashSet::new();
    for workspace in order {
        if workspace.session_id == local && flagged.contains(&workspace.workspace_key) {
            seen.insert(workspace.workspace_key.clone());
            flags.push((workspace.workspace_key.clone(), workspace.reference()));
        }
    }
    let mut rest: Vec<&String> = flagged.iter().filter(|key| !seen.contains(*key)).collect();
    rest.sort();
    for key in rest {
        if let Some(id) = live.get(key) {
            flags.push((key.clone(), WorkspaceRef::new(&local, id)));
        }
    }
    Ok(LegacyState { local, machines, entries, flags })
}

/// The migration input: the old stores as they are now.
pub(crate) fn legacy_input(connection: &Connection) -> anyhow::Result<LegacyInput> {
    let state = read_state(connection)?;
    Ok(LegacyInput {
        local_session: state.local,
        machines: state.machines,
        layout: super::sidebar_layout_store::document(connection)?,
        entries: state.entries,
        pinned_flags: state.flags.into_iter().map(|(_, reference)| reference).collect(),
        labels: Vec::new(),
    })
}

/// The old layout with the document's Pinned items as the `sec_pinned`
/// tiles (groups are not shown: the old layout has no group tile), and each
/// section's `align` and `gap` from the document (the workspaces section's
/// from the first machine section).
pub(crate) fn project_layout(stored: &Document, doc: &Doc) -> Document {
    let mut projected = stored.clone();
    projected.revision = stored.revision + doc.revision;
    let first_machine =
        doc.sections().iter().filter(|s| s.kind.machine().is_some()).min_by(|a, b| {
            (a.region_rank(), &a.order, &a.id).cmp(&(b.region_rank(), &b.order, &b.id))
        });
    for section in &mut projected.sections {
        let source = if section.content == sidebar_layout::Content::Workspaces {
            first_machine
        } else {
            doc.section(&section.id)
        };
        if let Some(source) = source {
            section.arrangement.align = source.align.clone();
            section.arrangement.gap = source.gap;
        }
    }
    let items: Vec<sidebar_layout::Item> = doc
        .children(PINNED_SECTION_ID, None)
        .into_iter()
        .filter_map(|item| {
            let reference = layout_ref_of_body(&item.body)?;
            let mut tile: sidebar_layout::Item = serde_json::from_value(serde_json::json!({
                "id": item.id,
                "ref": reference,
                "shows_label": item.shows_label,
            }))
            .ok()?;
            tile.span = item.span;
            tile.extra = item.extra.clone();
            // Old clients read a url tile's favicon from `extra.icon_url`.
            if let Body::Url { icon_url: Some(icon_url), .. } = &item.body {
                tile.extra.insert("icon_url".into(), icon_url.clone().into());
            }
            Some(tile)
        })
        .collect();
    match projected.sections.iter_mut().find(|section| section.id == PINNED_SECTION_ID) {
        Some(section) => section.items = items,
        None if !items.is_empty() => {
            let mut section = sidebar_layout::Section::new(
                PINNED_SECTION_ID,
                sidebar_layout::Region::Top,
                sidebar_layout::Look::BuiltIn,
                sidebar_layout::Content::Items,
            );
            section.arrangement = sidebar_layout::Arrangement::new(
                sidebar_layout::ArrangementLayout::Grid,
                sidebar_layout::Alignment::Leading,
            );
            section.items = items;
            let at = projected
                .sections
                .iter()
                .position(|s| s.id == "sec_top")
                .map(|i| i + 1)
                .or_else(|| {
                    projected.sections.iter().position(|s| s.region == sidebar_layout::Region::Top)
                })
                .unwrap_or(0);
            projected.sections.insert(at, section);
        }
        None => {}
    }
    projected
}

/// The document ops that follow an old layout section's changed `align` or
/// `gap` (`sidebar_layout.update` `section.update`): onto the document
/// section of the same id, or every machine section for the old
/// workspaces section.
pub(crate) fn section_field_ops(before: &Document, after: &Document, doc: &Doc) -> Vec<Op> {
    let mut ops = Vec::new();
    for section in &after.sections {
        let Some(old) = before.sections.iter().find(|old| old.id == section.id) else { continue };
        let (align, gap) = (&section.arrangement.align, section.arrangement.gap);
        if old.arrangement.align == *align && old.arrangement.gap == gap {
            continue;
        }
        let targets: Vec<String> = if section.content == sidebar_layout::Content::Workspaces {
            doc.sections()
                .iter()
                .filter(|s| s.kind.machine().is_some())
                .map(|s| s.id.clone())
                .collect()
        } else {
            doc.section(&section.id).map(|s| s.id.clone()).into_iter().collect()
        };
        // Only the fields this write changed: the document may hold a newer
        // value of the other one.
        let patch = SectionPatch {
            align: (old.arrangement.align != *align).then(|| align.clone()),
            gap: if old.arrangement.gap == gap {
                Patch::Keep
            } else {
                gap.map_or(Patch::Clear, Patch::Set)
            },
            ..SectionPatch::default()
        };
        for id in targets {
            ops.push(Op::SectionUpdate { id, patch: patch.clone() });
        }
    }
    ops
}

fn pinned_tiles(layout: &Document) -> Vec<sidebar_layout::Item> {
    layout
        .sections
        .iter()
        .find(|section| section.id == PINNED_SECTION_ID)
        .map(|section| section.items.clone())
        .unwrap_or_default()
}

/// The document ops a `sidebar_layout.update` makes when it adds, removes or
/// reorders `sec_pinned` tiles (`before` is the projection it reduced on).
pub(crate) fn pinned_ops(before: &Document, after: &Document, doc: &Doc) -> Vec<Op> {
    let old = pinned_tiles(before);
    let new = pinned_tiles(after);
    let old_ids: HashSet<&str> = old.iter().map(|tile| tile.id.as_str()).collect();
    let new_ids: HashSet<&str> = new.iter().map(|tile| tile.id.as_str()).collect();
    let mut ops = Vec::new();
    for tile in old.iter().filter(|tile| !new_ids.contains(tile.id.as_str())) {
        let Some(item) = doc.item(&tile.id) else { continue };
        // A tile dragged out of Pinned into a document section moves there;
        // a tile removed from the layout leaves the document.
        let landed = after
            .sections
            .iter()
            .filter(|section| {
                section.id != PINNED_SECTION_ID
                    && doc.section(&section.id).is_some_and(|s| s.kind.machine().is_none())
            })
            .find_map(|section| {
                let index = section.items.iter().position(|other| other.id == tile.id)?;
                Some(Target {
                    section: section.id.clone(),
                    index: i64::try_from(index).ok(),
                    ..Target::default()
                })
            });
        if let Some(to) = landed {
            ops.push(Op::Move { items: vec![item.id.clone()], to });
        } else if item.body.workspace().is_some() || item.body.is_group() {
            ops.push(Op::Unpin { items: vec![item.id.clone()] });
        } else {
            ops.push(Op::ItemRemove { id: item.id.clone() });
        }
    }
    let mut previous: Option<ItemId> = None;
    let mut order: Vec<ItemId> = Vec::new();
    for tile in &new {
        let to = Target {
            section: PINNED_SECTION_ID.into(),
            after: previous.clone(),
            index: previous.is_none().then_some(0),
            ..Target::default()
        };
        let id = if old_ids.contains(tile.id.as_str()) {
            tile.id.clone()
        } else {
            match body_of_layout_ref(&tile.reference) {
                Body::Workspace { reference } => {
                    let id = match doc.workspace_item(&reference) {
                        Some(item) => {
                            ops.push(Op::Move { items: vec![item.id.clone()], to });
                            item.id.clone()
                        }
                        None => {
                            ops.push(Op::Adopt { refs: vec![reference.clone()], to: Some(to) });
                            cmux_layout_reducer::sidebar_doc::workspace_item_id(&reference)
                        }
                    };
                    previous = Some(id.clone());
                    order.push(id);
                    continue;
                }
                // A tile that already sits in another section (a custom
                // one, after the migration) moves; adding it again would
                // fail with `duplicate_id`.
                _ if doc.item(&tile.id).is_some() => {
                    ops.push(Op::Move { items: vec![tile.id.clone()], to });
                    tile.id.clone()
                }
                body => {
                    ops.push(Op::ItemAdd {
                        item: NewItem {
                            id: Some(tile.id.clone()),
                            body,
                            shows_label: tile.shows_label,
                            span: tile.span,
                            extra: tile.extra.clone(),
                        },
                        to,
                    });
                    tile.id.clone()
                }
            }
        };
        previous = Some(id.clone());
        order.push(id);
    }
    let kept_before: Vec<&str> =
        old.iter().map(|tile| tile.id.as_str()).filter(|id| new_ids.contains(id)).collect();
    let kept_after: Vec<&str> =
        new.iter().map(|tile| tile.id.as_str()).filter(|id| old_ids.contains(id)).collect();
    if kept_before != kept_after {
        ops.push(Op::Move {
            items: order,
            to: Target { section: PINNED_SECTION_ID.into(), index: Some(0), ..Target::default() },
        });
    }
    ops
}

/// This machine's live workspace ids in document order (Pinned, custom and
/// machine sections, groups' children in place), then the old personal
/// order for any the document does not place.
pub(crate) fn workspace_order(connection: &Connection) -> anyhow::Result<Vec<String>> {
    let legacy = super::personal_order::sidebar_workspace_ids(connection)?;
    if !store::is_migrated(connection)? {
        return Ok(legacy);
    }
    let local = local_registry_id(connection)?;
    let mut seen = HashSet::new();
    let mut order = Vec::new();
    store::with_doc(connection, |doc| {
        for item in doc.items_in_order() {
            if let Some(reference) = item.body.workspace()
                && reference.session_id == local
                && seen.insert(reference.workspace_id.clone())
            {
                order.push(reference.workspace_id.clone());
            }
        }
        Ok(())
    })?;
    for id in legacy {
        if seen.insert(id.clone()) {
            order.push(id);
        }
    }
    Ok(order)
}
