//! The reducer: every op, the changed rows and the inverse ops (undo/redo
//! through `sidebar.apply`).
//!
//! Ops change the document in place through a journal that keeps the first
//! old copy of each row they touch. [`Batch::apply`] runs a list of ops,
//! then checks only the invariants of the touched rows
//! ([`super::check::touched`]); a refusal restores the touched rows from
//! the journal, so the document is as before. [`Batch::finish`] returns the
//! changed sections and items and the inverse: raw `*.put` / `*.delete` ops
//! that restore every changed row (the inverse of an inverse is the redo).
//! Nothing here copies, sorts or scans the whole document: lookups go
//! through the indexes of [`Doc`].

use std::collections::{HashMap, HashSet};

use super::archive::{archive, archived_side, unarchive, wake_groups_of};
use super::check;
use super::doc::{Doc, ListEntry};
use super::model::*;
use super::order_key;
use serde_json::Value;

pub use super::check::{check, diff, fit_title, repair};

/// The rows one apply changed.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Changes {
    pub sections: Vec<Section>,
    pub deleted_sections: Vec<SectionId>,
    pub items: Vec<Item>,
    pub deleted_items: Vec<ItemId>,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        self.sections.is_empty()
            && self.deleted_sections.is_empty()
            && self.items.is_empty()
            && self.deleted_items.is_empty()
    }
}

/// What a finished [`Batch`] changed.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Applied {
    pub changes: Changes,
    pub inverse: Vec<Op>,
    /// The old copy of each changed or deleted item (None: it was added).
    pub previous_items: HashMap<ItemId, Option<Item>>,
}

/// Apply `ops` to `doc` atomically: on a refusal `doc` is unchanged. The
/// revision advances by one when a row changed.
pub fn apply_in_place(
    doc: &mut Doc,
    ops: &[Op],
    mint: &mut dyn FnMut() -> ItemId,
) -> Result<Applied, Refusal> {
    let mut batch = Batch::new(doc);
    batch.apply(ops, mint)?;
    Ok(batch.finish())
}

/// Apply raw row ops (`item.put`, `item.delete`, `section.put`,
/// `section.delete`: an echoed batch or an inverse) with no invariant
/// check; other ops are skipped. The revision is the caller's.
pub fn apply_rows(doc: &mut Doc, ops: &[Op]) {
    for op in ops {
        match op {
            Op::ItemPut { item } => {
                doc.replace_item(item.clone());
            }
            Op::ItemDelete { id } => {
                doc.remove_item(id);
            }
            Op::SectionPut { section } => {
                doc.replace_section(section.clone());
            }
            Op::SectionDelete { id } => {
                doc.remove_section(id);
            }
            _ => {}
        }
    }
}

/// Several op lists on one document, each atomic, finished as one change
/// (one revision): the old-store sync applies one op per old row and skips
/// the ones the document refuses.
/// A batch dropped without [`Batch::finish`] (the caller stopped on an
/// error) restores every row it changed, so the document is as before.
pub struct Batch<'d> {
    doc: &'d mut Doc,
    start_revision: u64,
    items: HashMap<ItemId, Option<Item>>,
    sections: HashMap<SectionId, Option<Section>>,
}

impl Drop for Batch<'_> {
    fn drop(&mut self) {
        restore(self.doc, std::mem::take(&mut self.items), std::mem::take(&mut self.sections));
    }
}

/// Put back the old copies of a journal's rows.
fn restore(
    doc: &mut Doc,
    items: HashMap<ItemId, Option<Item>>,
    sections: HashMap<SectionId, Option<Section>>,
) {
    for (id, old) in items {
        match old {
            Some(item) => {
                doc.replace_item(item);
            }
            None => {
                doc.remove_item(&id);
            }
        }
    }
    for (id, old) in sections {
        match old {
            Some(section) => {
                doc.replace_section(section);
            }
            None => {
                doc.remove_section(&id);
            }
        }
    }
}

impl<'d> Batch<'d> {
    pub fn new(doc: &'d mut Doc) -> Self {
        let start_revision = doc.revision;
        Batch { doc, start_revision, items: HashMap::new(), sections: HashMap::new() }
    }

    pub fn doc(&self) -> &Doc {
        self.doc
    }

    /// Apply `ops` in order and check the rows they touched; a refusal
    /// restores those rows.
    pub fn apply(&mut self, ops: &[Op], mint: &mut dyn FnMut() -> ItemId) -> Result<(), Refusal> {
        let mut tx = Tx { doc: &mut *self.doc, items: HashMap::new(), sections: HashMap::new() };
        let result = ops
            .iter()
            .try_for_each(|op| apply_op(&mut tx, op, mint))
            .and_then(|()| check::touched(tx.doc, &tx.items, &tx.sections));
        match result {
            Ok(()) => {
                let Tx { items, sections, .. } = tx;
                for (id, old) in items {
                    self.items.entry(id).or_insert(old);
                }
                for (id, old) in sections {
                    self.sections.entry(id).or_insert(old);
                }
                Ok(())
            }
            Err(refusal) => {
                tx.rollback();
                Err(refusal)
            }
        }
    }

    /// The changed rows and the inverse; the revision advances by one when
    /// a row changed.
    pub fn finish(mut self) -> Applied {
        let items = std::mem::take(&mut self.items);
        let sections = std::mem::take(&mut self.sections);
        let mut applied = Applied::default();
        let mut section_ids: Vec<&SectionId> = sections.keys().collect();
        section_ids.sort();
        for id in section_ids {
            let old = &sections[id];
            let now = self.doc.section(id);
            if old.as_ref() == now {
                continue;
            }
            match now {
                Some(section) => applied.changes.sections.push(section.clone()),
                None => applied.changes.deleted_sections.push(id.clone()),
            }
            applied.inverse.push(match old {
                Some(section) => Op::SectionPut { section: section.clone() },
                None => Op::SectionDelete { id: id.clone() },
            });
        }
        let mut item_ids: Vec<&ItemId> = items.keys().collect();
        item_ids.sort();
        for id in item_ids {
            let old = &items[id];
            let now = self.doc.item(id);
            if old.as_ref() == now {
                continue;
            }
            match now {
                Some(item) => applied.changes.items.push(item.clone()),
                None => applied.changes.deleted_items.push(id.clone()),
            }
            applied.inverse.push(match old {
                Some(item) => Op::ItemPut { item: item.clone() },
                None => Op::ItemDelete { id: id.clone() },
            });
            applied.previous_items.insert(id.clone(), old.clone());
        }
        if !applied.changes.is_empty() {
            self.doc.revision = self.start_revision + 1;
        }
        applied
    }
}

/// The rows one op list touched, with their first old copies.
pub(super) struct Tx<'a> {
    pub(super) doc: &'a mut Doc,
    items: HashMap<ItemId, Option<Item>>,
    sections: HashMap<SectionId, Option<Section>>,
}

impl Tx<'_> {
    pub(super) fn touch_item(&mut self, id: &str) {
        if !self.items.contains_key(id) {
            self.items.insert(id.to_string(), self.doc.item(id).cloned());
        }
    }

    pub(super) fn touch_section(&mut self, id: &str) {
        if !self.sections.contains_key(id) {
            self.sections.insert(id.to_string(), self.doc.section(id).cloned());
        }
    }

    pub(super) fn put_item(&mut self, item: Item) {
        self.touch_item(&item.id);
        self.doc.replace_item(item);
    }

    pub(super) fn remove_item(&mut self, id: &str) {
        self.touch_item(id);
        self.doc.remove_item(id);
    }

    /// Change one item with `edit` (its indexes follow).
    pub(super) fn edit_item(
        &mut self,
        id: &str,
        edit: impl FnOnce(&mut Item) -> Result<(), Refusal>,
    ) -> Result<(), Refusal> {
        let mut item = self.doc.item(id).cloned().ok_or(Refusal::UnknownItem)?;
        edit(&mut item)?;
        if self.doc.item(id) != Some(&item) {
            self.put_item(item);
        }
        Ok(())
    }

    pub(super) fn put_section(&mut self, section: Section) {
        self.touch_section(&section.id);
        self.doc.replace_section(section);
    }

    pub(super) fn remove_section(&mut self, id: &str) {
        self.touch_section(id);
        self.doc.remove_section(id);
    }

    fn rollback(self) {
        restore(self.doc, self.items, self.sections);
    }
}

fn apply_op(tx: &mut Tx, op: &Op, mint: &mut dyn FnMut() -> ItemId) -> Result<(), Refusal> {
    match op {
        Op::Move { items, to } => {
            place(tx, items, to)?;
            wake_groups_of(tx, items)
        }
        Op::Pin { items } => pin(tx, items),
        Op::Unpin { items } => unpin(tx, items),
        Op::Archive { items } => archive(tx, items),
        Op::Unarchive { items } => unarchive(tx, items),
        Op::ItemAdd { item, to } => add_item(tx, item, to, mint),
        Op::ItemRemove { id } => {
            let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
            let children: Vec<ItemId> =
                tx.doc.descendants(item).into_iter().map(|child| child.id.clone()).collect();
            for child in children {
                tx.remove_item(&child);
            }
            tx.remove_item(id);
            Ok(())
        }
        Op::ItemUpdate { id, patch } => update_item(tx, id, patch),
        Op::ItemRemoveRef { reference } => super::reset::remove_ref(tx, reference),
        Op::Reset => super::reset::reset(tx),
        Op::SectionAdd { section, place } => add_section(tx, section, place),
        Op::SectionUpdate { id, patch } => update_section(tx, id, patch),
        Op::SectionMove { id, place } => {
            let mut section = tx.doc.section(id).cloned().ok_or(Refusal::UnknownSection)?;
            place_section(tx, &mut section, place)?;
            tx.put_section(section);
            Ok(())
        }
        Op::SectionRemove { id } => remove_section(tx, id),
        Op::GroupCreate { id, name, color, icon, profile, items, to } => {
            validate_title(name)?;
            let id = id.clone().unwrap_or_else(&mut *mint);
            ensure_new_id(tx.doc, &id)?;
            let target = match to {
                Some(to) => to.clone(),
                None => {
                    let first = items.first().ok_or(Refusal::InvalidTarget)?;
                    let first = tx.doc.item(first).ok_or(Refusal::UnknownItem)?;
                    match &first.parent {
                        None => Target {
                            section: first.section.clone(),
                            before: Some(first.id.clone()),
                            ..Target::default()
                        },
                        Some(parent) => Target {
                            section: first.section.clone(),
                            after: Some(parent.clone()),
                            ..Target::default()
                        },
                    }
                }
            };
            tx.doc.section(&target.section).ok_or(Refusal::UnknownSection)?;
            tx.put_item(Item::new(
                &id,
                &target.section,
                Body::Group {
                    name: name.clone(),
                    color: color.clone(),
                    icon: icon.clone(),
                    collapsed: false,
                    profile: profile.clone(),
                },
            ));
            place(tx, std::slice::from_ref(&id), &target)?;
            if !items.is_empty() {
                let into = Target {
                    section: target.section.clone(),
                    parent: Some(id.clone()),
                    ..Target::default()
                };
                place(tx, items, &into)?;
            }
            Ok(())
        }
        Op::GroupUpdate { id, patch } => tx.edit_item(id, |item| {
            let Body::Group { name, color, icon, collapsed, profile } = &mut item.body else {
                return Err(Refusal::InvalidValue);
            };
            if let Some(new_name) = &patch.name {
                validate_title(new_name)?;
                *name = new_name.clone();
            }
            patch.color.apply(color);
            patch.icon.apply(icon);
            patch.profile.apply(profile);
            if let Some(value) = patch.collapsed {
                *collapsed = value;
            }
            match &patch.auto_archive {
                Patch::Keep => {}
                Patch::Clear => {
                    item.extra.remove(AUTO_ARCHIVE_KEY);
                }
                Patch::Set(value) => {
                    let rule = AutoArchiveRule::read(value).ok_or(Refusal::InvalidValue)?;
                    item.extra.insert(AUTO_ARCHIVE_KEY.into(), rule.value());
                }
            }
            Ok(())
        }),
        Op::GroupUngroup { id } => {
            let group = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
            if !group.body.is_group() {
                return Err(Refusal::InvalidValue);
            }
            let section = group.section.clone();
            let parent = group.parent.clone();
            let children: Vec<ItemId> =
                tx.doc.list(&section, Some(id.as_str())).map(|child| child.id.clone()).collect();
            if !children.is_empty() {
                // Into the ungrouped group's own place: its parent group, or the top level.
                let to = Target { section, parent, after: Some(id.clone()), ..Target::default() };
                place(tx, &children, &to)?;
            }
            tx.remove_item(id);
            Ok(())
        }
        Op::Adopt { refs, to } => {
            adopt(tx, refs, to.as_ref())?;
            let placed: Vec<ItemId> = refs
                .iter()
                .filter_map(|reference| {
                    tx.doc.workspace_item(reference).map(|item| item.id.clone())
                })
                .collect();
            wake_groups_of(tx, &placed)
        }
        Op::Close { refs } => {
            close(tx, refs);
            Ok(())
        }
        Op::ItemPut { item } => {
            tx.put_item(item.clone());
            Ok(())
        }
        Op::ItemDelete { id } => {
            if tx.doc.item(id).is_some() {
                tx.remove_item(id);
            }
            Ok(())
        }
        Op::SectionPut { section } => {
            tx.put_section(section.clone());
            Ok(())
        }
        Op::SectionDelete { id } => {
            if tx.doc.section(id).is_some() {
                tx.remove_section(id);
            }
            Ok(())
        }
    }
}

/// Whether a client-sent `ops` list turns an app section into another kind
/// or another kind into an app section (raw `section.put`, `sidebar.apply`):
/// that would make a provider's section take drops. Echoes and inverses
/// never do it, so only the daemon's ingress checks it, not the reducer
/// (the client mirror applies echoed rows with it).
pub fn changes_app_kind(doc: &Doc, ops: &[Op]) -> bool {
    ops.iter().any(|op| match op {
        Op::SectionPut { section } => doc.section(&section.id).is_some_and(|existing| {
            existing.kind != section.kind
                && (matches!(existing.kind, SectionKind::App { .. })
                    || matches!(section.kind, SectionKind::App { .. }))
        }),
        _ => false,
    })
}

pub(crate) fn validate_title(title: &str) -> Result<(), Refusal> {
    if title.is_empty() || title.chars().count() > MAX_TITLE_CHARS {
        return Err(Refusal::InvalidTitle);
    }
    Ok(())
}

pub(crate) fn validate_span(span: Option<i64>) -> Result<(), Refusal> {
    match span {
        Some(span) if !(1..=12).contains(&span) => Err(Refusal::InvalidValue),
        _ => Ok(()),
    }
}

pub(crate) fn validate_section_numbers(section: &Section) -> Result<(), Refusal> {
    if section.columns.is_some_and(|c| !(1..=12).contains(&c))
        || section.max_rows.is_some_and(|r| !(1..=50).contains(&r))
        || section.gap.is_some_and(|gap| !GAP_RANGE.contains(&gap))
    {
        return Err(Refusal::InvalidValue);
    }
    Ok(())
}

fn ensure_new_id(doc: &Doc, id: &str) -> Result<(), Refusal> {
    if id.is_empty() || doc.item(id).is_some() || doc.section(id).is_some() {
        return Err(Refusal::DuplicateId);
    }
    Ok(())
}

fn add_item(
    tx: &mut Tx,
    item: &NewItem,
    to: &Target,
    mint: &mut dyn FnMut() -> ItemId,
) -> Result<(), Refusal> {
    let id = item.id.clone().unwrap_or_else(&mut *mint);
    ensure_new_id(tx.doc, &id)?;
    if let Some(reference) = item.body.workspace()
        && tx.doc.workspace_item(reference).is_some()
    {
        return Err(Refusal::DuplicateRef);
    }
    validate_span(item.span)?;
    if let Body::Group { name, .. } = &item.body {
        validate_title(name)?;
    }
    tx.doc.section(&to.section).ok_or(Refusal::UnknownSection)?;
    let mut new = Item {
        id: id.clone(),
        section: to.section.clone(),
        parent: None,
        order: String::new(),
        body: item.body.clone(),
        shows_label: item.shows_label,
        span: item.span,
        extra: item.extra.clone(),
    };
    new.lift_icon_url();
    tx.put_item(new);
    place(tx, &[id], to)
}

/// The two entries around the place `to` names among the siblings that do
/// not move: `(low, high)` (either absent at an end).
pub(super) fn neighbors(
    doc: &Doc,
    to: &Target,
    moved: &HashSet<ItemId>,
) -> Result<(Option<ListEntry>, Option<ListEntry>), Refusal> {
    let skip = |id: &str| moved.contains(id);
    let empty = std::collections::BTreeSet::new();
    let list = doc.list_entries(&to.section, to.parent.as_deref()).unwrap_or(&empty);
    let anchor = |id: &ItemId| -> Result<ListEntry, Refusal> {
        let item = doc
            .item(id)
            .filter(|item| {
                item.section == to.section && item.parent == to.parent && !moved.contains(id)
            })
            .ok_or(Refusal::InvalidTarget)?;
        Ok((item.order.clone(), item.id.clone()))
    };
    Ok(match (&to.before, &to.after, to.index) {
        (Some(before), _, _) => {
            let high = anchor(before)?;
            (Doc::entry_before(list, &high, &skip).cloned(), Some(high))
        }
        (None, Some(after), _) => {
            let low = anchor(after)?;
            let high = Doc::entry_after(list, &low, &skip).cloned();
            (Some(low), high)
        }
        (None, None, Some(index)) => {
            let index = usize::try_from(index.max(0)).unwrap_or(usize::MAX);
            let mut low = None;
            let mut high = None;
            for (at, entry) in list.iter().filter(|(_, id)| !skip(id)).enumerate() {
                if at == index {
                    high = Some(entry.clone());
                    break;
                }
                low = Some(entry);
            }
            (low.cloned(), high)
        }
        (None, None, None) => (list.iter().rev().find(|(_, id)| !skip(id)).cloned(), None),
    })
}

/// Move `ids` (in this order, as one run) to `to`.
pub(super) fn place(tx: &mut Tx, ids: &[ItemId], to: &Target) -> Result<(), Refusal> {
    let mut moved: Vec<ItemId> = Vec::with_capacity(ids.len());
    for id in ids {
        if !moved.contains(id) {
            moved.push(id.clone());
        }
    }
    if moved.is_empty() {
        return Ok(());
    }
    let moved_set: HashSet<ItemId> = moved.iter().cloned().collect();
    let section = tx.doc.section(&to.section).ok_or(Refusal::UnknownSection)?;
    if matches!(section.kind, SectionKind::App { .. }) {
        return Err(Refusal::ProviderOwned);
    }
    let target_machine = section.kind.machine().map(str::to_string);
    let mut parent_machine = None;
    let mut parent_level = 0;
    if let Some(parent) = &to.parent {
        let group = tx.doc.item(parent).ok_or(Refusal::UnknownItem)?;
        if !group.body.is_group() || group.section != to.section {
            return Err(Refusal::Nesting);
        }
        // Not into itself or anything under a moved group.
        if moved_set.contains(parent)
            || tx.doc.ancestors(group).iter().any(|ancestor| moved_set.contains(&ancestor.id))
        {
            return Err(Refusal::InvalidTarget);
        }
        parent_level = tx.doc.group_level(group);
        let root = tx.doc.root(group);
        parent_machine = tx
            .doc
            .descendants(root)
            .into_iter()
            .filter(|child| {
                !moved_set.contains(&child.id)
                    && !tx.doc.ancestors(child).iter().any(|a| moved_set.contains(&a.id))
            })
            .find_map(|child| child.body.workspace().map(|r| r.session_id.clone()));
    }
    let mut moved_machine: Option<String> = None;
    for id in &moved {
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        if to.parent.is_some()
            && item.body.is_group()
            && parent_level + tx.doc.group_height(item) > MAX_GROUP_DEPTH
        {
            return Err(Refusal::Nesting);
        }
        if let Some(machine) = tx.doc.item_machine(item) {
            if target_machine.as_ref().is_some_and(|target| *target != machine)
                || parent_machine.as_ref().is_some_and(|group| *group != machine)
            {
                return Err(Refusal::CrossMachine);
            }
            if to.parent.is_some() {
                match &moved_machine {
                    Some(previous) if *previous != machine => return Err(Refusal::CrossMachine),
                    _ => moved_machine = Some(machine),
                }
            }
        }
    }
    // Archived items list last (archiving-DESIGN.md): a run that mixes both
    // goes in two steps, and each keeps to its side.
    let (archived, unarchived): (Vec<ItemId>, Vec<ItemId>) =
        moved.iter().cloned().partition(|id| tx.doc.item(id).is_some_and(Item::archived));
    if !archived.is_empty() && !unarchived.is_empty() {
        place(tx, &unarchived, to)?;
        return place(tx, &archived, to);
    }
    let archived = !archived.is_empty();
    if let Some(group) = &to.parent {
        // A group lists its pinned members first (pinning-DESIGN.md): a run
        // that mixes both goes in two steps, and each keeps to its side.
        let stays_pinned = |id: &ItemId| {
            tx.doc
                .item(id)
                .is_some_and(|item| item.pinned_in_group() && item.parent.as_ref() == Some(group))
        };
        let (pinned, unpinned): (Vec<ItemId>, Vec<ItemId>) =
            moved.iter().cloned().partition(|id| stays_pinned(id));
        if !pinned.is_empty() && !unpinned.is_empty() {
            place(tx, &pinned, to)?;
            return place(tx, &unpinned, to);
        }
        let to = pinned_side(tx.doc, to, group, &moved_set, !pinned.is_empty())?;
        let to = archived_side(tx.doc, &to, &moved_set, archived)?;
        return place_run(tx, &moved, &moved_set, &to);
    }
    let to = archived_side(tx.doc, to, &moved_set, archived)?;
    place_run(tx, &moved, &moved_set, &to)
}

/// `to` moved to the pinned (or unpinned) side of `group`'s members.
fn pinned_side(
    doc: &Doc,
    to: &Target,
    group: &str,
    moved: &HashSet<ItemId>,
    pinned: bool,
) -> Result<Target, Refusal> {
    let siblings: Vec<&ListEntry> = doc
        .list_entries(&to.section, Some(group))
        .map(|set| set.iter().filter(|(_, id)| !moved.contains(id)).collect())
        .unwrap_or_default();
    let (_, high) = neighbors(doc, to, moved)?;
    let at = high
        .as_ref()
        .and_then(|high| siblings.iter().position(|entry| *entry == high))
        .unwrap_or(siblings.len());
    let run =
        siblings.iter().filter(|(_, id)| doc.item(id).is_some_and(Item::pinned_in_group)).count();
    let clamped = if pinned { at.min(run) } else { at.max(run) };
    if clamped == at {
        return Ok(to.clone());
    }
    let index = i64::try_from(clamped).unwrap_or(i64::MAX);
    Ok(Target {
        section: to.section.clone(),
        parent: to.parent.clone(),
        index: Some(index),
        ..Target::default()
    })
}

/// [`place`] after the checks: order keys, then each moved item's place.
fn place_run(
    tx: &mut Tx,
    moved: &[ItemId],
    moved_set: &HashSet<ItemId>,
    to: &Target,
) -> Result<(), Refusal> {
    let (low, high) = neighbors(tx.doc, to, moved_set)?;
    let (low_key, high_key) =
        (low.as_ref().map(|e| e.0.as_str()), high.as_ref().map(|e| e.0.as_str()));
    let keys = order_key::sequence(low_key, high_key, moved.len());
    let mut assignments: Vec<(ItemId, String)> = moved.iter().cloned().zip(keys).collect();
    if order_key::needs_spread(low_key, high_key)
        || assignments.iter().any(|(_, key)| key.len() > MAX_ORDER_KEY_CHARS)
    {
        // Renumber this one sibling list (rare: keys grew too long, or old
        // keys were out of order).
        let siblings: Vec<ListEntry> = tx
            .doc
            .list_entries(&to.section, to.parent.as_deref())
            .map(|set| set.iter().filter(|(_, id)| !moved_set.contains(id)).cloned().collect())
            .unwrap_or_default();
        let at = match &high {
            Some(high) => siblings.iter().position(|entry| entry == high).unwrap_or(siblings.len()),
            None => siblings.len(),
        };
        let run: Vec<ItemId> = siblings[..at]
            .iter()
            .map(|(_, id)| id.clone())
            .chain(moved.iter().cloned())
            .chain(siblings[at..].iter().map(|(_, id)| id.clone()))
            .collect();
        assignments = run.iter().cloned().zip(order_key::spread(run.len())).collect();
    }
    // Where each moved group's subtree is now, before the group moves.
    let subtrees: Vec<(Vec<ItemId>, SectionId)> = moved
        .iter()
        .filter_map(|id| tx.doc.item(id))
        .filter(|item| item.body.is_group() && item.section != to.section)
        .map(|item| {
            let ids = tx
                .doc
                .descendants(item)
                .into_iter()
                .filter(|child| !moved_set.contains(&child.id))
                .map(|child| child.id.clone())
                .collect();
            (ids, item.section.clone())
        })
        .collect();
    // Where each top-level item entering the Pinned band sat, for Unpin.
    let enters_band = to.section == PINNED_SECTION_ID && to.parent.is_none();
    let unpin_to: HashMap<ItemId, Value> = moved
        .iter()
        .filter_map(|id| tx.doc.item(id))
        .filter(|item| enters_band && item.parent.is_none() && item.section != PINNED_SECTION_ID)
        .map(|item| {
            let after = tx.doc.list_entries(&item.section, None).and_then(|set| {
                Doc::entry_before(set, &(item.order.clone(), item.id.clone()), &|id| {
                    moved_set.contains(id)
                })
            });
            let after = after.map_or(Value::Null, |(_, id)| Value::String(id.clone()));
            (item.id.clone(), serde_json::json!({ "section": item.section, "after": after }))
        })
        .collect();
    for (id, key) in assignments {
        let is_moved = moved_set.contains(&id);
        let remembered = unpin_to.get(&id).cloned();
        tx.edit_item(&id, |item| {
            item.order = key;
            if is_moved {
                // A member pinned in its group is pinned there only.
                if item.parent != to.parent {
                    item.extra.remove(PINNED_IN_GROUP_KEY);
                }
                if to.section != PINNED_SECTION_ID {
                    item.extra.remove(UNPIN_TO_KEY);
                }
                if let Some(place) = remembered {
                    item.extra.insert(UNPIN_TO_KEY.into(), place);
                }
                item.section = to.section.clone();
                item.parent = to.parent.clone();
            }
            Ok(())
        })?;
    }
    // A moved group's subtree follows it to its section.
    for (subtree, _old_section) in subtrees {
        for child in subtree {
            tx.edit_item(&child, |item| {
                item.section = to.section.clone();
                Ok(())
            })?;
        }
    }
    Ok(())
}

/// The machine section of `session`, made at the end of the machine
/// sections when missing.
pub(super) fn ensure_machine_section(tx: &mut Tx, session: &str) -> SectionId {
    if let Some(section) = tx.doc.machine_section(session) {
        return section.id.clone();
    }
    let mut section = Section::machine(session);
    let last_machine = tx
        .doc
        .sections()
        .iter()
        .filter(|s| s.kind.machine().is_some() && s.region == section.region)
        .max_by(|a, b| a.order.cmp(&b.order))
        .map(|s| s.id.clone());
    let place = SectionPlace { after: last_machine, ..SectionPlace::default() };
    let _ = place_section(tx, &mut section, &place);
    let id = section.id.clone();
    tx.put_section(section);
    id
}

fn ensure_pinned_section(tx: &mut Tx) {
    if tx.doc.section(PINNED_SECTION_ID).is_some() {
        return;
    }
    let mut section = Section::pinned();
    let _ = place_section(tx, &mut section, &SectionPlace { index: Some(0), ..Default::default() });
    tx.put_section(section);
}

/// Pin (plans/cmux-next/pinning-DESIGN.md). A group member stays in its
/// group, marked pinned, after the group's other pinned members. Any other
/// item goes to the end of the Pinned band; [`place`] remembers where it was.
fn pin(tx: &mut Tx, ids: &[ItemId]) -> Result<(), Refusal> {
    // A pin is not archived: it comes back first.
    unarchive(tx, ids)?;
    let mut moving = Vec::new();
    for id in ids {
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        if let Some(group) = item.parent.clone() {
            if item.pinned_in_group() {
                continue;
            }
            let section = item.section.clone();
            tx.edit_item(id, |item| {
                item.extra.insert(PINNED_IN_GROUP_KEY.into(), Value::Bool(true));
                Ok(())
            })?;
            let index = pinned_members(tx.doc, &section, &group, id);
            let to =
                Target { section, parent: Some(group), index: Some(index), ..Target::default() };
            place(tx, std::slice::from_ref(id), &to)?;
        } else if item.section != PINNED_SECTION_ID {
            moving.push(id.clone());
        }
    }
    if moving.is_empty() {
        return Ok(());
    }
    ensure_pinned_section(tx);
    place(tx, &moving, &Target::end(PINNED_SECTION_ID))
}

/// Unpin. A member pinned in its group goes right under the group's other
/// pinned members; any other group member is not pinned and stays (a tree
/// pinned with its top group unpins with it). An item in the Pinned band (or a custom section) goes
/// back where it was pinned from when that place is still there, else to
/// the top of its own machine section.
fn unpin(tx: &mut Tx, ids: &[ItemId]) -> Result<(), Refusal> {
    for id in ids {
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        if item.pinned_in_group() {
            let (section, group) = (item.section.clone(), item.parent.clone());
            tx.edit_item(id, |item| {
                item.extra.remove(PINNED_IN_GROUP_KEY);
                Ok(())
            })?;
            let index =
                group.as_deref().map_or(0, |group| pinned_members(tx.doc, &section, group, id));
            let to = Target { section, parent: group, index: Some(index), ..Target::default() };
            place(tx, std::slice::from_ref(id), &to)?;
            continue;
        }
        // A member of a group that is not pinned in it is not pinned itself
        // (in a pinned tree, it is pinned with its top group): it stays.
        if item.parent.is_some() {
            continue;
        }
        let machine = tx.doc.item_machine(item).ok_or(Refusal::NoMachine)?;
        if tx
            .doc
            .section(&item.section)
            .is_some_and(|section| section.kind.machine() == Some(machine.as_str()))
        {
            continue;
        }
        let target = remembered_place(tx.doc, item, &machine);
        let target = match target {
            Some(target) => target,
            // Nowhere remembered: the top of its machine section, as Move to Top (Chief's default, 2026-10-20).
            None => Target {
                section: ensure_machine_section(tx, &machine),
                index: Some(0),
                ..Target::default()
            },
        };
        place(tx, std::slice::from_ref(id), &target)?;
    }
    Ok(())
}

/// How many members of `group` other than `except` are pinned in it.
fn pinned_members(doc: &Doc, section: &str, group: &str, except: &str) -> i64 {
    let count = doc
        .list(section, Some(group))
        .filter(|child| child.id != except && child.pinned_in_group())
        .count();
    i64::try_from(count).unwrap_or(i64::MAX)
}

/// Where Unpin puts `item` back: its `extra.unpin_to` place, while that
/// section is `machine`'s own and the neighbor it sat after still sits at
/// that section's top level. Nil: no place is remembered, or it is gone.
fn remembered_place(doc: &Doc, item: &Item, machine: &str) -> Option<Target> {
    let remembered = item.extra.get(UNPIN_TO_KEY)?;
    let section = remembered.get("section")?.as_str()?;
    if doc.section(section)?.kind.machine() != Some(machine) {
        return None;
    }
    match remembered.get("after").and_then(Value::as_str) {
        None => Some(Target { section: section.into(), index: Some(0), ..Target::default() }),
        Some(after) => {
            let anchor = doc.item(after)?;
            (anchor.id != item.id && anchor.section == section && anchor.parent.is_none()).then(
                || Target {
                    section: section.into(),
                    after: Some(after.into()),
                    ..Target::default()
                },
            )
        }
    }
}

fn adopt(tx: &mut Tx, refs: &[WorkspaceRef], to: Option<&Target>) -> Result<(), Refusal> {
    let mut adopted = Vec::new();
    for reference in refs {
        if tx.doc.workspace_item(reference).is_some() {
            continue;
        }
        // Resolve an item placed by workspace key before its id was known.
        if let Some(key) = reference.placement_ref()
            && let Some(id) =
                tx.doc.placement_item(&reference.session_id, key).map(|item| item.id.clone())
        {
            let mut resolved = reference.clone();
            resolved.extra.remove("unresolved");
            resolved.extra.insert("workspace_ref".into(), key.into());
            tx.edit_item(&id, |item| {
                item.body = Body::Workspace { reference: resolved };
                Ok(())
            })?;
            continue;
        }
        let section = match to {
            Some(to) => to.section.clone(),
            None => ensure_machine_section(tx, &reference.session_id),
        };
        let item = Item::workspace(reference.clone(), &section);
        if tx.doc.item(&item.id).is_some() {
            continue;
        }
        let id = item.id.clone();
        tx.put_item(item);
        if to.is_none() {
            place(tx, std::slice::from_ref(&id), &Target::end(&section))?;
        }
        adopted.push(id);
    }
    if let Some(to) = to {
        place(tx, &adopted, to)?;
    }
    Ok(())
}

fn close(tx: &mut Tx, refs: &[WorkspaceRef]) {
    for reference in refs {
        let Some(item) = tx.doc.workspace_item(reference).cloned() else { continue };
        if tx.doc.section(&item.section).is_some_and(|section| section.keeps_closed) {
            continue;
        }
        tx.remove_item(&item.id);
        // Each group it leaves empty goes, up the tree.
        let mut emptied = item.parent.clone();
        while let Some(parent) = emptied {
            if tx.doc.list_len(&item.section, Some(parent.as_str())) != 0 {
                break;
            }
            let Some(group) = tx.doc.item(&parent) else { break };
            emptied = group.parent.clone();
            tx.remove_item(&parent);
        }
    }
}

fn update_item(tx: &mut Tx, id: &str, patch: &ItemPatch) -> Result<(), Refusal> {
    tx.edit_item(id, |item| {
        if let Some(shows_label) = patch.shows_label {
            item.shows_label = shows_label;
        }
        if let Patch::Set(span) = patch.span {
            validate_span(Some(span))?;
        }
        patch.span.apply(&mut item.span);
        match &patch.label {
            Patch::Keep => {}
            Patch::Clear => {
                item.extra.remove("label");
            }
            Patch::Set(label) => {
                item.extra.insert("label".into(), label.clone().into());
            }
        }
        if !patch.title.is_keep() || !patch.icon_url.is_keep() {
            let Body::Url { title, icon_url, .. } = &mut item.body else {
                return Err(Refusal::InvalidValue);
            };
            patch.title.apply(title);
            patch.icon_url.apply(icon_url);
            if !patch.icon_url.is_keep() {
                // The body field replaces an old client's extra copy.
                item.extra.remove("icon_url");
            }
        }
        Ok(())
    })
}

fn add_section(tx: &mut Tx, section: &Section, place: &SectionPlace) -> Result<(), Refusal> {
    if tx.doc.section(&section.id).is_some() || tx.doc.item(&section.id).is_some() {
        return Err(Refusal::DuplicateId);
    }
    match &section.kind {
        SectionKind::Machine { session_id } => {
            if tx.doc.machine_section(session_id).is_some() {
                return Err(Refusal::DuplicateRef);
            }
            if section.id != machine_section_id(session_id) {
                return Err(Refusal::InvalidValue);
            }
        }
        SectionKind::Pinned if section.id != PINNED_SECTION_ID => {
            return Err(Refusal::InvalidValue);
        }
        _ => {}
    }
    validate_host_group_flags(section)?;
    if let Some(title) = &section.title {
        validate_title(title)?;
    }
    validate_section_numbers(section)?;
    let mut section = section.clone();
    place_section(tx, &mut section, place)?;
    tx.put_section(section);
    Ok(())
}

fn update_section(tx: &mut Tx, id: &str, patch: &SectionPatch) -> Result<(), Refusal> {
    let mut section = tx.doc.section(id).cloned().ok_or(Refusal::UnknownSection)?;
    if let Patch::Set(title) = &patch.title {
        validate_title(title)?;
    }
    patch.title.apply(&mut section.title);
    if let Some(shows_title) = patch.shows_title {
        section.shows_title = shows_title;
    }
    if let Some(look) = &patch.look {
        section.look = look.clone();
    }
    if let Some(arrangement) = &patch.arrangement {
        section.arrangement = arrangement.clone();
    }
    if let Some(align) = &patch.align {
        section.align = align.clone();
    }
    patch.gap.apply(&mut section.gap);
    patch.columns.apply(&mut section.columns);
    patch.max_rows.apply(&mut section.max_rows);
    patch.room.apply(&mut section.room);
    if let Some(keeps_closed) = patch.keeps_closed {
        section.keeps_closed = keeps_closed;
    }
    if let Some(scroll) = patch.scroll {
        section.scroll = scroll;
    }
    if let Some(host_group) = patch.host_group {
        if host_group && section.kind.machine().is_none() {
            return Err(Refusal::InvalidValue);
        }
        section.host_group = host_group;
        // Older clients only sent `host_group`; preserve their explicit
        // Remove/mark choice in the durable opt-out field unless a newer
        // client supplied that field explicitly.
        if patch.host_group_opt_out.is_none() {
            section.host_group_opt_out = section.kind.machine().is_some() && !host_group;
        }
    }
    if let Some(opt_out) = patch.host_group_opt_out {
        section.host_group_opt_out = opt_out;
    }
    validate_host_group_flags(&section)?;
    validate_section_numbers(&section)?;
    if tx.doc.section(id) != Some(&section) {
        tx.put_section(section);
    }
    Ok(())
}

fn validate_host_group_flags(section: &Section) -> Result<(), Refusal> {
    if section.host_group_opt_out && section.kind.machine().is_none() {
        return Err(Refusal::InvalidValue);
    }
    if section.host_group && section.host_group_opt_out {
        return Err(Refusal::InvalidValue);
    }
    Ok(())
}

/// Give `section` its region and order key among the other sections of
/// its region (renumbering them when no key fits). A scroll that is the
/// old region's default (the user never changed it) follows the region.
pub(super) fn place_section(
    tx: &mut Tx,
    section: &mut Section,
    place: &SectionPlace,
) -> Result<(), Refusal> {
    if let Some(region) = &place.region
        && *region != section.region
    {
        if section.scroll == Scroll::default_for(&section.kind, &section.region) {
            section.scroll = Scroll::default_for(&section.kind, region);
        }
        section.region = region.clone();
    }
    let mut siblings: Vec<(SectionId, String)> = tx
        .doc
        .sections()
        .iter()
        .filter(|s| s.region == section.region && s.id != section.id)
        .map(|s| (s.id.clone(), s.order.clone()))
        .collect();
    siblings.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    let position = match (&place.before, &place.after, place.index) {
        (Some(anchor), _, _) => {
            siblings.iter().position(|(id, _)| id == anchor).ok_or(Refusal::InvalidTarget)?
        }
        (None, Some(anchor), _) => {
            siblings.iter().position(|(id, _)| id == anchor).ok_or(Refusal::InvalidTarget)? + 1
        }
        (None, None, Some(index)) => index.clamp(0, siblings.len() as i64) as usize,
        (None, None, None) => siblings.len(),
    };
    let low = position.checked_sub(1).map(|i| siblings[i].1.as_str());
    let high = siblings.get(position).map(|(_, order)| order.as_str());
    let key = order_key::between(low, high);
    if key.len() <= MAX_ORDER_KEY_CHARS && !order_key::needs_spread(low, high) {
        section.order = key;
        return Ok(());
    }
    let keys = order_key::spread(siblings.len() + 1);
    let mut run: Vec<SectionId> = siblings.iter().map(|(id, _)| id.clone()).collect();
    run.insert(position, section.id.clone());
    for (id, key) in run.into_iter().zip(keys) {
        if id == section.id {
            section.order = key;
        } else if let Some(mut existing) = tx.doc.section(&id).cloned() {
            existing.order = key;
            tx.put_section(existing);
        }
    }
    Ok(())
}

fn remove_section(tx: &mut Tx, id: &str) -> Result<(), Refusal> {
    let section = tx.doc.section(id).ok_or(Refusal::UnknownSection)?;
    if section.kind.machine().is_some() {
        return Err(Refusal::MachineRequired);
    }
    let top: Vec<ItemId> = tx.doc.list(id, None).map(|item| item.id.clone()).collect();
    for item_id in top {
        let Some(item) = tx.doc.item(&item_id) else { continue };
        match tx.doc.item_machine(item) {
            Some(machine) => {
                let target = ensure_machine_section(tx, &machine);
                place(tx, std::slice::from_ref(&item_id), &Target::end(&target))?;
            }
            None => {
                let children: Vec<ItemId> =
                    tx.doc.list(id, Some(item_id.as_str())).map(|child| child.id.clone()).collect();
                for child in children {
                    tx.remove_item(&child);
                }
                tx.remove_item(&item_id);
            }
        }
    }
    tx.remove_section(id);
    Ok(())
}
