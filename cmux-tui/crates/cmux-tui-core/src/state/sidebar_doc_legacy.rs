//! The old sidebar verbs on top of the sidebar document, so clients that
//! do not know `sidebar-doc-v1` keep working unchanged:
//!
//! - Reads of the old stores into the migration input ([`legacy_input`]).
//! - Old writes become document ops ([`sync_from_legacy`]): every personal
//!   commit (`commit_personal`: `workspace_group.*`, `workspace.place`,
//!   `set-personal-workspace`, `move-workspace-to-group`, ...), every
//!   workspace pin flag write (`set-workspace-metadata {pinned}`) and every
//!   creation's personal row compare the old stores with the copy the
//!   document was last synced from (`meta` `sidebar_doc_legacy_shadow`) and
//!   apply the difference: a new group is a group item in its machine
//!   section, a deleted group is ungrouped, a group's fields follow, a
//!   pinned group goes to Pinned (unpinned: back to its machine section), a
//!   moved or regrouped workspace moves after its old neighbor, a new row
//!   (a new workspace) is adopted at the place the old order gave it, and
//!   a pin flag pins or unpins the workspace. A workspace the user put in
//!   Pinned or a custom section is not pulled out by an old reorder.
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

use rusqlite::{Connection, Transaction};
use serde::{Deserialize, Serialize};

use cmux_layout_reducer::sidebar_doc::migrate::{
    LegacyEntry, LegacyGroup, LegacyInput, LegacyMachine, LegacyWorkspace, body_of_layout_ref,
    layout_ref_of_body,
};
use cmux_layout_reducer::sidebar_doc::reduce;
use cmux_layout_reducer::sidebar_doc::{
    Body, Doc, GroupPatch, Item, ItemId, NewItem, Op, PINNED_SECTION_ID, Patch, Section,
    SectionPlace, Target, WorkspaceRef, group_item_id, machine_section_id,
};
use cmux_layout_reducer::sidebar_layout::{self, Document};

use super::sidebar_doc_store as store;
use super::values::{local_registry_id, workspace_public_id_for_key};
use crate::workspace_registry::personal_store::{read_groups, read_sessions, read_workspaces};

const SHADOW_KEY: &str = "sidebar_doc_legacy_shadow";

/// A random item id (`itm_<uuid>`).
pub(crate) fn mint_item_id() -> ItemId {
    let uuid = crate::workspace_registry::try_new_uuid_v4().unwrap_or_default();
    format!("itm_{}", uuid.replace('-', ""))
}

/// One personal row as the old order shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ShadowRow {
    workspace: LegacyWorkspace,
    group: Option<String>,
}

/// The old stores, as far as the sidebar shows them.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
struct Shadow {
    groups: Vec<LegacyGroup>,
    rows: Vec<ShadowRow>,
    /// The top-level order: loose workspaces and groups (see [`token`]).
    #[serde(default)]
    top: Vec<String>,
    /// This machine's workspace keys with the old pin flag.
    flags: Vec<String>,
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
    for session in read_sessions(connection)? {
        if session.session_id == local {
            machines[0].title = session.machine_name.clone();
        } else {
            machines.push(LegacyMachine {
                session_id: session.session_id.clone(),
                title: session.machine_name.clone(),
            });
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

fn shadow_of(state: &LegacyState) -> Shadow {
    let mut shadow = Shadow::default();
    for entry in &state.entries {
        match entry {
            LegacyEntry::Workspace { workspace } => {
                shadow.top.push(workspace_token(workspace));
                shadow.rows.push(ShadowRow { workspace: workspace.clone(), group: None });
            }
            LegacyEntry::Group { group, members } => {
                shadow.top.push(group_token(&group.id));
                shadow.groups.push(group.clone());
                shadow.rows.extend(members.iter().map(|workspace| ShadowRow {
                    workspace: workspace.clone(),
                    group: Some(group.id.clone()),
                }));
            }
        }
    }
    shadow.flags = state.flags.iter().map(|(key, _)| key.clone()).collect();
    shadow
}

fn read_shadow(connection: &Connection) -> anyhow::Result<Option<Shadow>> {
    let text: Option<String> = connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [SHADOW_KEY], |row| row.get(0))
        .ok();
    Ok(text.and_then(|text| serde_json::from_str(&text).ok()))
}

fn write_shadow(transaction: &Transaction<'_>, shadow: &Shadow) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![SHADOW_KEY, serde_json::to_string(shadow)?],
    )?;
    Ok(())
}

/// Record the old stores as the document's sync point (after migration).
pub(crate) fn store_shadow(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    write_shadow(transaction, &shadow_of(&read_state(transaction)?))
}

/// The item that places a personal row's workspace.
fn row_item<'a>(doc: &'a Doc, workspace: &LegacyWorkspace) -> Option<&'a Item> {
    let reference = workspace.reference();
    doc.workspace_item(&reference).or_else(|| {
        doc.items.iter().find(|item| {
            item.body.workspace().is_some_and(|placed| {
                placed.session_id == workspace.session_id
                    && placed.placement_ref() == Some(workspace.workspace_key.as_str())
            })
        })
    })
}

/// Apply one op to the running document; a refusal is logged and skipped
/// (an old write the document cannot follow, for example a group of two
/// machines, leaves the document as it was).
fn try_apply(doc: &mut Doc, op: Op) {
    let mut mint = mint_item_id;
    match reduce::apply(doc, std::slice::from_ref(&op), &mut mint) {
        Ok(outcome) => *doc = outcome.doc,
        Err(refusal) => eprintln!("cmux-tui: sidebar doc does not follow an old write ({refusal})"),
    }
}

fn workspace_token(workspace: &LegacyWorkspace) -> String {
    format!("w\u{1f}{}\u{1f}{}", workspace.session_id, workspace.workspace_key)
}

fn group_token(group: &str) -> String {
    format!("g\u{1f}{group}")
}

/// The previous token of each token in `sequence`.
fn predecessors(sequence: &[String]) -> HashMap<String, Option<String>> {
    let mut result = HashMap::new();
    let mut previous: Option<String> = None;
    for token in sequence {
        result.insert(token.clone(), previous.clone());
        previous = Some(token.clone());
    }
    result
}

/// The member tokens of each group, in order.
fn member_sequences(shadow: &Shadow) -> HashMap<String, Vec<String>> {
    let mut sequences: HashMap<String, Vec<String>> = HashMap::new();
    for row in &shadow.rows {
        if let Some(group) = &row.group {
            sequences.entry(group.clone()).or_default().push(workspace_token(&row.workspace));
        }
    }
    sequences
}

/// The document item of a token.
fn token_item<'a>(
    doc: &'a Doc,
    token: &str,
    rows: &HashMap<String, &ShadowRow>,
) -> Option<&'a Item> {
    match token.split_once('\u{1f}') {
        Some(("g", group)) => doc.item(&group_item_id(group)),
        _ => rows.get(token).and_then(|row| row_item(doc, &row.workspace)),
    }
}

/// Where `token` lands among the siblings `(section, parent)`: after the
/// nearest earlier token of `sequence` whose item is a sibling; first when
/// it has no earlier token; last when none of them is a sibling.
fn anchored_target(
    doc: &Doc,
    token: &str,
    predecessors: &HashMap<String, Option<String>>,
    rows: &HashMap<String, &ShadowRow>,
    section: &str,
    parent: Option<&str>,
) -> Target {
    let mut cursor = predecessors.get(token).cloned().flatten();
    let had_predecessor = cursor.is_some();
    while let Some(previous) = cursor {
        if let Some(item) = token_item(doc, &previous, rows)
            && item.section == section
            && item.parent.as_deref() == parent
        {
            return Target {
                section: section.into(),
                parent: parent.map(str::to_string),
                after: Some(item.id.clone()),
                ..Target::default()
            };
        }
        cursor = predecessors.get(&previous).cloned().flatten();
    }
    Target {
        section: section.into(),
        parent: parent.map(str::to_string),
        index: (!had_predecessor).then_some(0),
        ..Target::default()
    }
}

/// Follow the old writes since the last sync point (see the module doc).
/// Queues the document changes into the current commit's batch.
pub(crate) fn sync_from_legacy(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if !super::store::state_tables_ready(transaction)? || !store::is_migrated(transaction)? {
        return Ok(());
    }
    let state = read_state(transaction)?;
    let now = shadow_of(&state);
    let Some(old) = read_shadow(transaction)? else {
        return write_shadow(transaction, &now);
    };
    if old == now {
        return Ok(());
    }
    let before = store::read_doc(transaction)?;
    let mut doc = before.clone();
    let local = state.local.clone();
    let old_groups: HashMap<&str, &LegacyGroup> =
        old.groups.iter().map(|group| (group.id.as_str(), group)).collect();
    let new_groups: HashMap<&str, &LegacyGroup> =
        now.groups.iter().map(|group| (group.id.as_str(), group)).collect();
    // Deleted groups: their workspaces stay where the group was.
    for group in &old.groups {
        let id = group_item_id(&group.id);
        if !new_groups.contains_key(group.id.as_str()) && doc.item(&id).is_some() {
            try_apply(&mut doc, Op::GroupUngroup { id });
        }
    }
    // New groups, then field changes and pins.
    for group in &now.groups {
        let id = group_item_id(&group.id);
        if doc.item(&id).is_none() {
            let machine = now
                .rows
                .iter()
                .find(|row| row.group.as_deref() == Some(group.id.as_str()))
                .map_or_else(|| local.clone(), |row| row.workspace.session_id.clone());
            let section = machine_section_id(&machine);
            if doc.section(&section).is_none() {
                let section = Section::machine(&machine);
                try_apply(&mut doc, Op::SectionAdd { section, place: SectionPlace::default() });
            }
            try_apply(
                &mut doc,
                Op::GroupCreate {
                    id: Some(id.clone()),
                    name: group.name.clone(),
                    color: group.color.clone(),
                    icon: group.icon.clone(),
                    profile: group.profile.clone(),
                    items: Vec::new(),
                    to: Some(Target::end(&section)),
                },
            );
            if group.pinned {
                try_apply(&mut doc, Op::Pin { items: vec![id.clone()] });
            }
            if group.collapsed {
                let patch = GroupPatch { collapsed: Some(true), ..GroupPatch::default() };
                try_apply(&mut doc, Op::GroupUpdate { id, patch });
            }
            continue;
        }
        let Some(previous) = old_groups.get(group.id.as_str()) else { continue };
        let field = |old: &Option<String>, new: &Option<String>| match (old == new, new) {
            (true, _) => Patch::Keep,
            (false, Some(value)) => Patch::Set(value.clone()),
            (false, None) => Patch::Clear,
        };
        let patch = GroupPatch {
            name: (previous.name != group.name).then(|| group.name.clone()),
            color: field(&previous.color, &group.color),
            icon: field(&previous.icon, &group.icon),
            collapsed: (previous.collapsed != group.collapsed).then_some(group.collapsed),
            profile: field(&previous.profile, &group.profile),
        };
        if patch != GroupPatch::default() {
            try_apply(&mut doc, Op::GroupUpdate { id: id.clone(), patch });
        }
        if previous.pinned != group.pinned {
            let op = if group.pinned {
                Op::Pin { items: vec![id] }
            } else {
                Op::Unpin { items: vec![id] }
            };
            try_apply(&mut doc, op);
        }
    }
    // Order: the top level (loose workspaces and groups), then each
    // group's members, each after its old neighbor. New, regrouped or
    // reordered entries move; a workspace the user keeps outside its machine
    // section (Pinned, custom) is not pulled back by a reorder.
    let rows: HashMap<String, &ShadowRow> =
        now.rows.iter().map(|row| (workspace_token(&row.workspace), row)).collect();
    let old_rows: HashMap<String, &ShadowRow> =
        old.rows.iter().map(|row| (workspace_token(&row.workspace), row)).collect();
    let old_top = predecessors(&old.top);
    let new_top = predecessors(&now.top);
    let old_members: HashMap<String, Option<String>> =
        member_sequences(&old).values().flat_map(|seq| predecessors(seq)).collect();
    let new_member_sequences = member_sequences(&now);
    let new_members: HashMap<String, Option<String>> =
        new_member_sequences.values().flat_map(|seq| predecessors(seq)).collect();
    let live_keys: HashMap<String, String> = now
        .rows
        .iter()
        .filter_map(|row| {
            let id = row.workspace.workspace_id.clone()?;
            Some((id, row.workspace.workspace_key.clone()))
        })
        .collect();
    let placed_tokens: HashSet<String> = doc
        .items
        .iter()
        .filter_map(|item| item.body.workspace())
        .flat_map(|reference| {
            let key = reference
                .placement_ref()
                .map(|key| format!("w\u{1f}{}\u{1f}{key}", reference.session_id));
            let local = live_keys
                .get(&reference.workspace_id)
                .map(|key| format!("w\u{1f}{}\u{1f}{key}", reference.session_id));
            key.into_iter().chain(local)
        })
        .collect();
    let mut order: Vec<String> = now.top.clone();
    for token in &now.top {
        if let Some(group) = token.strip_prefix("g\u{1f}") {
            order.extend(new_member_sequences.get(group).cloned().unwrap_or_default());
        }
    }
    for token in &order {
        if let Some(group) = token.strip_prefix("g\u{1f}") {
            // A group: follow a slot change while it is in its machine
            // section's top level.
            if old_top.get(token) == new_top.get(token) && old_groups.contains_key(group) {
                continue;
            }
            let Some(item) = doc.item(&group_item_id(group)).cloned() else { continue };
            let in_machine =
                doc.section(&item.section).is_some_and(|section| section.kind.machine().is_some());
            if !in_machine {
                continue;
            }
            let to = anchored_target(&doc, token, &new_top, &rows, &item.section, None);
            try_apply(&mut doc, Op::Move { items: vec![item.id], to });
            continue;
        }
        let Some(row) = rows.get(token) else { continue };
        let previous = old_rows.get(token);
        let regrouped = previous.is_none_or(|old| old.group != row.group);
        let reordered = match &row.group {
            Some(_) => old_members.get(token) != new_members.get(token),
            None => old_top.get(token) != new_top.get(token),
        };
        // An unchanged row (the common case) costs no document scan.
        if !regrouped && !reordered && placed_tokens.contains(token) {
            continue;
        }
        let placed = row_item(&doc, &row.workspace).cloned();
        if placed.is_some() && !regrouped && !reordered {
            continue;
        }
        let group_item = row.group.as_ref().map(|group| group_item_id(group));
        let (section, parent) = match group_item.as_ref().and_then(|id| doc.item(id)) {
            Some(group) => (group.section.clone(), Some(group.id.clone())),
            None => (machine_section_id(&row.workspace.session_id), None),
        };
        if let Some(item) = &placed
            && !regrouped
            && (item.section != section || item.parent != parent)
        {
            continue;
        }
        let sequence = if row.group.is_some() { &new_members } else { &new_top };
        let to = anchored_target(&doc, token, sequence, &rows, &section, parent.as_deref());
        match placed {
            Some(item) => try_apply(&mut doc, Op::Move { items: vec![item.id], to }),
            None => {
                let reference = row.workspace.reference();
                if doc.section(&section).is_none() {
                    try_apply(&mut doc, Op::Adopt { refs: vec![reference], to: None });
                    if let Some(item) = row_item(&doc, &row.workspace).cloned() {
                        try_apply(&mut doc, Op::Move { items: vec![item.id], to });
                    }
                } else {
                    try_apply(&mut doc, Op::Adopt { refs: vec![reference], to: Some(to) });
                }
            }
        }
    }
    // Pin flags.
    let old_flags: HashSet<&String> = old.flags.iter().collect();
    let new_flags: HashSet<&String> = now.flags.iter().collect();
    for (key, reference) in &state.flags {
        if old_flags.contains(key) {
            continue;
        }
        if doc.workspace_item(reference).is_none() {
            try_apply(&mut doc, Op::Adopt { refs: vec![reference.clone()], to: None });
        }
        if let Some(item) = doc.workspace_item(reference) {
            let id = item.id.clone();
            try_apply(&mut doc, Op::Pin { items: vec![id] });
        }
    }
    for key in old.flags.iter().filter(|key| !new_flags.contains(key)) {
        let Ok(Some(id)) = workspace_public_id_for_key(transaction, key) else { continue };
        let reference = WorkspaceRef::new(&local, &id);
        if let Some(item) = doc.workspace_item(&reference)
            && item.section == PINNED_SECTION_ID
        {
            let id = item.id.clone();
            try_apply(&mut doc, Op::Unpin { items: vec![id] });
        }
    }
    write_shadow(transaction, &now)?;
    commit_derived(transaction, &before, &doc)
}

/// Store `doc` (derived from `before` by the daemon, not by a client
/// request) and queue its changes into the current commit's batch.
fn commit_derived(transaction: &Transaction<'_>, before: &Doc, doc: &Doc) -> anyhow::Result<()> {
    let changes = reduce::diff(before, doc);
    if changes.is_empty() {
        return Ok(());
    }
    let revision = before.revision + 1;
    let events = store::write_changes(transaction, before.revision, revision, &changes, None)?;
    for event in &events {
        super::closed_history_store::queue_change(transaction, event)?;
    }
    Ok(())
}

/// The old layout with the document's Pinned items as the `sec_pinned`
/// tiles (groups are not shown: the old layout has no group tile).
pub(crate) fn project_layout(stored: &Document, doc: &Doc) -> Document {
    let mut projected = stored.clone();
    projected.revision = stored.revision + doc.revision;
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
        if item.body.workspace().is_some() || item.body.is_group() {
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
    let doc = store::read_doc(connection)?;
    let mut seen = HashSet::new();
    let mut order = Vec::new();
    for item in &doc.items {
        if let Some(reference) = item.body.workspace()
            && reference.session_id == local
            && seen.insert(reference.workspace_id.clone())
        {
            order.push(reference.workspace_id.clone());
        }
    }
    for id in legacy {
        if seen.insert(id.clone()) {
            order.push(id);
        }
    }
    Ok(order)
}
