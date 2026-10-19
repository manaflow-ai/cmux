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

use super::check;
use super::doc::{Doc, ListEntry};
use super::model::*;
use super::order_key;

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
        Op::Move { items, to } => place(tx, items, to),
        Op::Pin { items } => pin(tx, items),
        Op::Unpin { items } => unpin(tx, items),
        Op::ItemAdd { item, to } => add_item(tx, item, to, mint),
        Op::ItemRemove { id } => {
            tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
            remove_tree(tx, id);
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
            Ok(())
        }),
        Op::GroupUngroup { id } => {
            let group = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
            if !group.body.is_group() {
                return Err(Refusal::InvalidValue);
            }
            // Its items (workspaces and nested groups) move up into its own
            // parent, at its place.
            let section = group.section.clone();
            let parent = group.parent.clone();
            let children: Vec<ItemId> =
                tx.doc.list(&section, Some(id.as_str())).map(|child| child.id.clone()).collect();
            if !children.is_empty() {
                let to = Target { section, parent, after: Some(id.clone()), ..Target::default() };
                place(tx, &children, &to)?;
            }
            tx.remove_item(id);
            Ok(())
        }
        Op::Adopt { refs, to } => adopt(tx, refs, to.as_ref()),
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
fn neighbors(
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
    if let Some(parent) = &to.parent {
        let group = tx.doc.item(parent).ok_or(Refusal::UnknownItem)?;
        if !group.body.is_group() || group.section != to.section {
            return Err(Refusal::Nesting);
        }
        if moved_set.contains(parent) {
            return Err(Refusal::InvalidTarget);
        }
        // A group into itself or one of its own groups.
        if moved.iter().any(|id| tx.doc.is_within(parent, id)) {
            return Err(Refusal::Nesting);
        }
    }
    // The depth is checked with the other invariants (`too_deep`); the
    // machine is refused here, before any row moves.
    for id in &moved {
        tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        if let Some(target) = &target_machine
            && tx.doc.machines_of(id).iter().any(|machine| machine != target)
        {
            return Err(Refusal::CrossMachine);
        }
    }
    let (low, high) = neighbors(tx.doc, to, &moved_set)?;
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
    // Where each moved group's children are now, before the group moves.
    let groups: Vec<(ItemId, SectionId)> = moved
        .iter()
        .filter_map(|id| tx.doc.item(id))
        .filter(|item| item.body.is_group() && item.section != to.section)
        .map(|item| (item.id.clone(), item.section.clone()))
        .collect();
    for (id, key) in assignments {
        let is_moved = moved_set.contains(&id);
        tx.edit_item(&id, |item| {
            item.order = key;
            if is_moved {
                item.section = to.section.clone();
                item.parent = to.parent.clone();
            }
            Ok(())
        })?;
    }
    // A moved group's items (nested groups' items too) follow it to its
    // section.
    for (group, old_section) in groups {
        let mut pending = vec![group];
        let mut seen: HashSet<ItemId> = HashSet::new();
        while let Some(parent) = pending.pop() {
            if !seen.insert(parent.clone()) {
                continue;
            }
            let children: Vec<ItemId> = tx
                .doc
                .list(&old_section, Some(parent.as_str()))
                .map(|child| child.id.clone())
                .collect();
            for child in children {
                tx.edit_item(&child, |item| {
                    item.section = to.section.clone();
                    Ok(())
                })?;
                pending.push(child);
            }
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

fn pin(tx: &mut Tx, ids: &[ItemId]) -> Result<(), Refusal> {
    ensure_pinned_section(tx);
    let mut moving = Vec::new();
    for id in ids {
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        if !(item.section == PINNED_SECTION_ID && item.parent.is_none()) {
            moving.push(id.clone());
        }
    }
    place(tx, &moving, &Target::end(PINNED_SECTION_ID))
}

/// Back to the machine section: a workspace or a one-machine group to the
/// end of its machine's section; a group with workspaces of several
/// machines splits, each workspace to its own machine section
/// ([`rehome_in_machine_section`]).
fn unpin(tx: &mut Tx, ids: &[ItemId]) -> Result<(), Refusal> {
    for id in ids {
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        let machines = tx.doc.machines_of(id);
        if machines.is_empty() {
            return Err(Refusal::NoMachine);
        }
        if machines.len() == 1
            && tx.doc.section(&item.section).is_some_and(|section| {
                section.kind.machine().is_some_and(|machine| machines.contains(machine))
            })
        {
            continue;
        }
        rehome_in_machine_section(tx, id)?;
    }
    Ok(())
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
        remove_emptied_groups(tx, &item);
    }
}

/// After `removed` left its parent: the groups it leaves empty go, the
/// nearest first, then each group above that the removal empties.
pub(super) fn remove_emptied_groups(tx: &mut Tx, removed: &Item) {
    let mut parent = removed.parent.clone();
    for _ in 0..=MAX_GROUP_DEPTH {
        let Some(id) = parent else { return };
        let Some(group) = tx.doc.item(&id).cloned() else { return };
        if tx.doc.list_len(&group.section, Some(id.as_str())) > 0 {
            return;
        }
        tx.remove_item(&id);
        parent = group.parent;
    }
}

/// Remove `id` and every item under it.
pub(super) fn remove_tree(tx: &mut Tx, id: &str) {
    let below: Vec<ItemId> = tx.doc.descendants(id).iter().map(|item| item.id.clone()).collect();
    for child in below.iter().rev() {
        tx.remove_item(child);
    }
    tx.remove_item(id);
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
    validate_section_numbers(&section)?;
    if tx.doc.section(id) != Some(&section) {
        tx.put_section(section);
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
        rehome_in_machine_section(tx, &item_id)?;
    }
    tx.remove_section(id);
    Ok(())
}

/// Move `id` to the end of its machine's section. A group with workspaces
/// of several machines (a Cloud group) cannot go to one machine section:
/// its workspaces go to the end of their own machine sections, and the
/// groups go. An item with no machine goes, with every item under it.
pub(super) fn rehome_in_machine_section(tx: &mut Tx, id: &str) -> Result<(), Refusal> {
    let machines = tx.doc.machines_of(id);
    match machines.len() {
        0 => remove_tree(tx, id),
        1 => {
            let machine = machines.into_iter().next().unwrap_or_default();
            let target = ensure_machine_section(tx, &machine);
            place(tx, &[id.to_string()], &Target::end(&target))?;
        }
        _ => {
            let workspaces: Vec<(ItemId, String)> = tx
                .doc
                .descendants(id)
                .iter()
                .filter_map(|item| {
                    item.body.workspace().map(|r| (item.id.clone(), r.session_id.clone()))
                })
                .collect();
            for (workspace, machine) in workspaces {
                let target = ensure_machine_section(tx, &machine);
                place(tx, std::slice::from_ref(&workspace), &Target::end(&target))?;
            }
            remove_tree(tx, id);
        }
    }
    Ok(())
}
