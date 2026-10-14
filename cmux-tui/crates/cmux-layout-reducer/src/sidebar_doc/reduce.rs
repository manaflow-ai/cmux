//! The reducer: every op, the document invariants, the changed rows and the
//! inverse ops (undo/redo through `sidebar.apply`).
//!
//! [`apply`] runs a list of ops on a copy of the document, checks the
//! invariants once at the end, and returns the new document (revision + 1
//! when anything changed), the changed sections and items, and the inverse:
//! raw `*.put` / `*.delete` ops that restore every changed row. The inverse
//! of an inverse is the redo.
//!
//! Invariants ([`check`]):
//! - ids are unique across sections and items;
//! - one machine section per session, with id `sec_m_<session>`;
//! - each workspace ref is placed once (`duplicate_ref`);
//! - an item's parent is a group of the same section at the top level, and
//!   a group has no parent (`nesting`);
//! - a group's workspaces are of one machine, and a machine section holds
//!   only its machine's workspaces and groups (`cross_machine`);
//! - an app section holds no items (`provider_owned`).

use std::collections::{HashMap, HashSet};

use super::model::*;
use super::order_key;

/// The result of [`apply`].
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub doc: Doc,
    pub changes: Changes,
    /// Restores the document `apply` started from.
    pub inverse: Vec<Op>,
}

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

/// Apply `ops` in order. `mint` makes the id of an item an op adds without
/// one (the daemon mints random ids; the app's mirror local ones).
pub fn apply(doc: &Doc, ops: &[Op], mint: &mut dyn FnMut() -> ItemId) -> Result<Outcome, Refusal> {
    let mut next = doc.clone();
    for op in ops {
        apply_one(&mut next, op, mint)?;
    }
    check(&next)?;
    next.normalize();
    let changes = diff(doc, &next);
    if changes.is_empty() {
        let mut same = doc.clone();
        same.normalize();
        return Ok(Outcome { doc: same, changes, inverse: Vec::new() });
    }
    next.revision = doc.revision + 1;
    let inverse = inverse_of(doc, &changes);
    Ok(Outcome { doc: next, changes, inverse })
}

/// The rows that differ between `before` and `after`.
pub fn diff(before: &Doc, after: &Doc) -> Changes {
    let old_sections: HashMap<&str, &Section> =
        before.sections.iter().map(|s| (s.id.as_str(), s)).collect();
    let new_sections: HashSet<&str> = after.sections.iter().map(|s| s.id.as_str()).collect();
    let old_items: HashMap<&str, &Item> = before.items.iter().map(|i| (i.id.as_str(), i)).collect();
    let new_items: HashSet<&str> = after.items.iter().map(|i| i.id.as_str()).collect();
    Changes {
        sections: after
            .sections
            .iter()
            .filter(|s| old_sections.get(s.id.as_str()).is_none_or(|old| *old != *s))
            .cloned()
            .collect(),
        deleted_sections: before
            .sections
            .iter()
            .filter(|s| !new_sections.contains(s.id.as_str()))
            .map(|s| s.id.clone())
            .collect(),
        items: after
            .items
            .iter()
            .filter(|i| old_items.get(i.id.as_str()).is_none_or(|old| *old != *i))
            .cloned()
            .collect(),
        deleted_items: before
            .items
            .iter()
            .filter(|i| !new_items.contains(i.id.as_str()))
            .map(|i| i.id.clone())
            .collect(),
    }
}

fn inverse_of(before: &Doc, changes: &Changes) -> Vec<Op> {
    let mut ops = Vec::new();
    for section in &changes.sections {
        match before.section(&section.id) {
            Some(old) => ops.push(Op::SectionPut { section: old.clone() }),
            None => ops.push(Op::SectionDelete { id: section.id.clone() }),
        }
    }
    for id in &changes.deleted_sections {
        if let Some(old) = before.section(id) {
            ops.push(Op::SectionPut { section: old.clone() });
        }
    }
    for item in &changes.items {
        match before.item(&item.id) {
            Some(old) => ops.push(Op::ItemPut { item: old.clone() }),
            None => ops.push(Op::ItemDelete { id: item.id.clone() }),
        }
    }
    for id in &changes.deleted_items {
        if let Some(old) = before.item(id) {
            ops.push(Op::ItemPut { item: old.clone() });
        }
    }
    ops
}

/// Apply one op without the final invariant check.
pub fn apply_one(doc: &mut Doc, op: &Op, mint: &mut dyn FnMut() -> ItemId) -> Result<(), Refusal> {
    match op {
        Op::Move { items, to } => place(doc, items, to),
        Op::Pin { items } => pin(doc, items),
        Op::Unpin { items } => unpin(doc, items),
        Op::ItemAdd { item, to } => {
            let id = item.id.clone().unwrap_or_else(&mut *mint);
            ensure_new_id(doc, &id)?;
            if let Some(reference) = item.body.workspace()
                && doc.workspace_item(reference).is_some()
            {
                return Err(Refusal::DuplicateRef);
            }
            validate_span(item.span)?;
            if let Body::Group { name, .. } = &item.body {
                validate_title(name)?;
            }
            section_index(doc, &to.section)?;
            doc.items.push(Item {
                id: id.clone(),
                section: to.section.clone(),
                parent: None,
                order: String::new(),
                body: item.body.clone(),
                shows_label: item.shows_label,
                span: item.span,
                extra: item.extra.clone(),
            });
            place(doc, &[id], to)
        }
        Op::ItemRemove { id } => {
            doc.item(id).ok_or(Refusal::UnknownItem)?;
            doc.items.retain(|item| item.id != *id && item.parent.as_deref() != Some(id));
            Ok(())
        }
        Op::ItemUpdate { id, patch } => update_item(doc, id, patch),
        Op::SectionAdd { section, place } => add_section(doc, section, place),
        Op::SectionUpdate { id, patch } => update_section(doc, id, patch),
        Op::SectionMove { id, place } => {
            let index = section_index(doc, id)?;
            let mut section = doc.sections.remove(index);
            let result = place_section(doc, &mut section, place);
            doc.sections.push(section);
            result
        }
        Op::SectionRemove { id } => remove_section(doc, id),
        Op::GroupCreate { id, name, color, icon, profile, items, to } => {
            validate_title(name)?;
            let id = id.clone().unwrap_or_else(&mut *mint);
            ensure_new_id(doc, &id)?;
            let target = match to {
                Some(to) => to.clone(),
                None => {
                    let first = items.first().ok_or(Refusal::InvalidTarget)?;
                    let first = doc.item(first).ok_or(Refusal::UnknownItem)?;
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
            if target.parent.is_some() {
                return Err(Refusal::Nesting);
            }
            section_index(doc, &target.section)?;
            doc.items.push(Item::new(
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
            place(doc, std::slice::from_ref(&id), &target)?;
            if !items.is_empty() {
                let into = Target {
                    section: target.section.clone(),
                    parent: Some(id.clone()),
                    ..Target::default()
                };
                place(doc, items, &into)?;
            }
            Ok(())
        }
        Op::GroupUpdate { id, patch } => {
            let item = doc.item_mut(id).ok_or(Refusal::UnknownItem)?;
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
        }
        Op::GroupUngroup { id } => {
            let group = doc.item(id).ok_or(Refusal::UnknownItem)?;
            if !group.body.is_group() {
                return Err(Refusal::InvalidValue);
            }
            let section = group.section.clone();
            let children: Vec<ItemId> =
                doc.children(&section, Some(id)).iter().map(|c| c.id.clone()).collect();
            if !children.is_empty() {
                let to = Target { section, after: Some(id.clone()), ..Target::default() };
                place(doc, &children, &to)?;
            }
            doc.items.retain(|item| item.id != *id);
            Ok(())
        }
        Op::Adopt { refs, to } => adopt(doc, refs, to.as_ref()),
        Op::ItemPut { item } => {
            match doc.items.iter_mut().find(|existing| existing.id == item.id) {
                Some(existing) => *existing = item.clone(),
                None => doc.items.push(item.clone()),
            }
            Ok(())
        }
        Op::ItemDelete { id } => {
            doc.items.retain(|item| item.id != *id);
            Ok(())
        }
        Op::SectionPut { section } => {
            match doc.sections.iter_mut().find(|existing| existing.id == section.id) {
                Some(existing) => *existing = section.clone(),
                None => doc.sections.push(section.clone()),
            }
            Ok(())
        }
        Op::SectionDelete { id } => {
            doc.sections.retain(|section| section.id != *id);
            Ok(())
        }
    }
}

/// Check every invariant of the document.
pub fn check(doc: &Doc) -> Result<(), Refusal> {
    if doc.sections.len() > MAX_SECTIONS || doc.items.len() > MAX_ITEMS {
        return Err(Refusal::TooMany);
    }
    let mut ids = HashSet::new();
    let mut machines = HashSet::new();
    let mut sections = HashMap::new();
    for section in &doc.sections {
        if !ids.insert(section.id.as_str()) {
            return Err(Refusal::DuplicateId);
        }
        if let Some(session) = section.kind.machine()
            && (!machines.insert(session) || section.id != machine_section_id(session))
        {
            return Err(Refusal::DuplicateRef);
        }
        if matches!(section.kind, SectionKind::Pinned) && section.id != PINNED_SECTION_ID {
            return Err(Refusal::DuplicateId);
        }
        if !order_key::is_valid(&section.order) {
            return Err(Refusal::InvalidValue);
        }
        if let Some(title) = &section.title {
            validate_title(title)?;
        }
        validate_section_numbers(section.columns, section.max_rows)?;
        sections.insert(section.id.as_str(), section);
    }
    let items: HashMap<&str, &Item> = doc.items.iter().map(|i| (i.id.as_str(), i)).collect();
    let mut refs = HashSet::new();
    let mut group_machine: HashMap<&str, &str> = HashMap::new();
    for item in &doc.items {
        if !ids.insert(item.id.as_str()) {
            return Err(Refusal::DuplicateId);
        }
        let section = sections.get(item.section.as_str()).ok_or(Refusal::UnknownSection)?;
        if matches!(section.kind, SectionKind::App { .. }) {
            return Err(Refusal::ProviderOwned);
        }
        if !order_key::is_valid(&item.order) {
            return Err(Refusal::InvalidValue);
        }
        validate_span(item.span)?;
        if let Body::Group { name, .. } = &item.body {
            validate_title(name)?;
        }
        if let Some(parent) = &item.parent {
            let parent = items.get(parent.as_str()).ok_or(Refusal::UnknownItem)?;
            if !parent.body.is_group()
                || parent.parent.is_some()
                || parent.section != item.section
                || item.body.is_group()
            {
                return Err(Refusal::Nesting);
            }
        }
        if let Some(reference) = item.body.workspace() {
            if !refs.insert((reference.session_id.as_str(), reference.workspace_id.as_str())) {
                return Err(Refusal::DuplicateRef);
            }
            if let Some(machine) = section.kind.machine()
                && machine != reference.session_id
            {
                return Err(Refusal::CrossMachine);
            }
            if let Some(parent) = &item.parent {
                let machine =
                    group_machine.entry(parent.as_str()).or_insert(reference.session_id.as_str());
                if *machine != reference.session_id {
                    return Err(Refusal::CrossMachine);
                }
            }
        }
    }
    for (group, machine) in group_machine {
        let section = &items[group].section;
        if let Some(owner) = sections[section.as_str()].kind.machine()
            && owner != machine
        {
            return Err(Refusal::CrossMachine);
        }
    }
    Ok(())
}

fn validate_title(title: &str) -> Result<(), Refusal> {
    if title.is_empty() || title.chars().count() > MAX_TITLE_CHARS {
        return Err(Refusal::InvalidTitle);
    }
    Ok(())
}

fn validate_span(span: Option<i64>) -> Result<(), Refusal> {
    match span {
        Some(span) if !(1..=12).contains(&span) => Err(Refusal::InvalidValue),
        _ => Ok(()),
    }
}

fn ensure_new_id(doc: &Doc, id: &str) -> Result<(), Refusal> {
    if id.is_empty() || doc.item(id).is_some() || doc.section(id).is_some() {
        return Err(Refusal::DuplicateId);
    }
    Ok(())
}

fn section_index(doc: &Doc, id: &str) -> Result<usize, Refusal> {
    doc.sections.iter().position(|section| section.id == id).ok_or(Refusal::UnknownSection)
}

/// Move `ids` (in this order, as one run) to `to`.
pub(crate) fn place(doc: &mut Doc, ids: &[ItemId], to: &Target) -> Result<(), Refusal> {
    let mut moved: Vec<ItemId> = Vec::with_capacity(ids.len());
    for id in ids {
        if !moved.contains(id) {
            moved.push(id.clone());
        }
    }
    if moved.is_empty() {
        return Ok(());
    }
    let section = doc.section(&to.section).ok_or(Refusal::UnknownSection)?.clone();
    if matches!(section.kind, SectionKind::App { .. }) {
        return Err(Refusal::ProviderOwned);
    }
    let target_machine = section.kind.machine().map(str::to_string);
    let mut parent_machine = None;
    if let Some(parent) = &to.parent {
        let group = doc.item(parent).ok_or(Refusal::UnknownItem)?;
        if !group.body.is_group() || group.parent.is_some() || group.section != to.section {
            return Err(Refusal::Nesting);
        }
        if moved.contains(parent) {
            return Err(Refusal::InvalidTarget);
        }
        parent_machine = doc
            .children(&group.section, Some(parent))
            .iter()
            .filter(|child| !moved.contains(&child.id))
            .find_map(|child| child.body.workspace().map(|r| r.session_id.clone()));
    }
    let mut moved_machine: Option<String> = None;
    for id in &moved {
        let item = doc.item(id).ok_or(Refusal::UnknownItem)?;
        if to.parent.is_some() && item.body.is_group() {
            return Err(Refusal::Nesting);
        }
        if let Some(machine) = doc.item_machine(item) {
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
    let siblings: Vec<(ItemId, String)> = doc
        .children(&to.section, to.parent.as_deref())
        .into_iter()
        .filter(|item| !moved.contains(&item.id))
        .map(|item| (item.id.clone(), item.order.clone()))
        .collect();
    let position = match (&to.before, &to.after, to.index) {
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
    let keys = order_key::sequence(low, high, moved.len());
    let mut assignments: Vec<(ItemId, String)> = moved.iter().cloned().zip(keys).collect();
    if order_key::needs_spread(low, high)
        || assignments.iter().any(|(_, key)| key.len() > MAX_ORDER_KEY_CHARS)
    {
        let run: Vec<ItemId> = siblings[..position]
            .iter()
            .map(|(id, _)| id.clone())
            .chain(moved.iter().cloned())
            .chain(siblings[position..].iter().map(|(id, _)| id.clone()))
            .collect();
        assignments = run.iter().cloned().zip(order_key::spread(run.len())).collect();
    }
    let moved_set: HashSet<&ItemId> = moved.iter().collect();
    let index: HashMap<ItemId, usize> =
        doc.items.iter().enumerate().map(|(i, item)| (item.id.clone(), i)).collect();
    for (id, key) in assignments {
        let is_moved = moved_set.contains(&id);
        if let Some(item) = index.get(&id).map(|&i| &mut doc.items[i]) {
            item.order = key;
            if is_moved {
                item.section = to.section.clone();
                item.parent = to.parent.clone();
            }
        }
    }
    // A moved group's children follow it to its section.
    for id in &moved {
        if doc.item(id).is_some_and(|item| item.body.is_group()) {
            for item in &mut doc.items {
                if item.parent.as_deref() == Some(id.as_str()) {
                    item.section = to.section.clone();
                }
            }
        }
    }
    Ok(())
}

/// The machine section of `session`, made at the end of the machine
/// sections when missing.
fn ensure_machine_section(doc: &mut Doc, session: &str) -> SectionId {
    if let Some(section) = doc.machine_section(session) {
        return section.id.clone();
    }
    let mut section = Section::machine(session);
    let last_machine = doc
        .sections
        .iter()
        .filter(|s| s.kind.machine().is_some() && s.region == section.region)
        .map(|s| s.id.clone())
        .max_by(|a, b| {
            let order = |id: &str| doc.section(id).map(|s| s.order.clone()).unwrap_or_default();
            order(a).cmp(&order(b))
        });
    let place = SectionPlace { after: last_machine, ..SectionPlace::default() };
    let _ = place_section(doc, &mut section, &place);
    let id = section.id.clone();
    doc.sections.push(section);
    id
}

fn ensure_pinned_section(doc: &mut Doc) {
    if doc.section(PINNED_SECTION_ID).is_some() {
        return;
    }
    let mut section = Section::pinned();
    let _ =
        place_section(doc, &mut section, &SectionPlace { index: Some(0), ..Default::default() });
    doc.sections.push(section);
}

fn pin(doc: &mut Doc, ids: &[ItemId]) -> Result<(), Refusal> {
    ensure_pinned_section(doc);
    let mut moving = Vec::new();
    for id in ids {
        let item = doc.item(id).ok_or(Refusal::UnknownItem)?;
        if !(item.section == PINNED_SECTION_ID && item.parent.is_none()) {
            moving.push(id.clone());
        }
    }
    place(doc, &moving, &Target::end(PINNED_SECTION_ID))
}

fn unpin(doc: &mut Doc, ids: &[ItemId]) -> Result<(), Refusal> {
    for id in ids {
        let item = doc.item(id).ok_or(Refusal::UnknownItem)?;
        let machine = doc.item_machine(item).ok_or(Refusal::NoMachine)?;
        if doc
            .section(&item.section)
            .is_some_and(|section| section.kind.machine() == Some(machine.as_str()))
        {
            continue;
        }
        let section = ensure_machine_section(doc, &machine);
        place(doc, std::slice::from_ref(id), &Target::end(&section))?;
    }
    Ok(())
}

fn adopt(doc: &mut Doc, refs: &[WorkspaceRef], to: Option<&Target>) -> Result<(), Refusal> {
    let mut adopted = Vec::new();
    for reference in refs {
        if doc.workspace_item(reference).is_some() {
            continue;
        }
        // Resolve an item placed by workspace key before its id was known.
        if let Some(key) = reference.placement_ref()
            && let Some(item) = doc.items.iter_mut().find(|item| {
                item.body.workspace().is_some_and(|placed| {
                    placed.session_id == reference.session_id && placed.placement_ref() == Some(key)
                })
            })
        {
            let mut resolved = reference.clone();
            resolved.extra.remove("unresolved");
            item.body = Body::Workspace { reference: resolved };
            continue;
        }
        let section = match to {
            Some(to) => to.section.clone(),
            None => ensure_machine_section(doc, &reference.session_id),
        };
        let item = Item::workspace(reference.clone(), &section);
        if doc.item(&item.id).is_some() {
            continue;
        }
        let id = item.id.clone();
        doc.items.push(item);
        if to.is_none() {
            place(doc, std::slice::from_ref(&id), &Target::end(&section))?;
        }
        adopted.push(id);
    }
    if let Some(to) = to {
        place(doc, &adopted, to)?;
    }
    Ok(())
}

fn update_item(doc: &mut Doc, id: &str, patch: &ItemPatch) -> Result<(), Refusal> {
    let item = doc.item_mut(id).ok_or(Refusal::UnknownItem)?;
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
    if !patch.title.is_keep() {
        let Body::Url { title, .. } = &mut item.body else { return Err(Refusal::InvalidValue) };
        patch.title.apply(title);
    }
    Ok(())
}

fn add_section(doc: &mut Doc, section: &Section, place: &SectionPlace) -> Result<(), Refusal> {
    if doc.section(&section.id).is_some() || doc.item(&section.id).is_some() {
        return Err(Refusal::DuplicateId);
    }
    match &section.kind {
        SectionKind::Machine { session_id } => {
            if doc.machine_section(session_id).is_some() {
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
    validate_section_numbers(section.columns, section.max_rows)?;
    let mut section = section.clone();
    place_section(doc, &mut section, place)?;
    doc.sections.push(section);
    Ok(())
}

fn validate_section_numbers(columns: Option<i64>, max_rows: Option<i64>) -> Result<(), Refusal> {
    if columns.is_some_and(|c| !(1..=12).contains(&c))
        || max_rows.is_some_and(|r| !(1..=50).contains(&r))
    {
        return Err(Refusal::InvalidValue);
    }
    Ok(())
}

fn update_section(doc: &mut Doc, id: &str, patch: &SectionPatch) -> Result<(), Refusal> {
    let index = section_index(doc, id)?;
    let section = &mut doc.sections[index];
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
    patch.columns.apply(&mut section.columns);
    patch.max_rows.apply(&mut section.max_rows);
    patch.room.apply(&mut section.room);
    if let Some(keeps_closed) = patch.keeps_closed {
        section.keeps_closed = keeps_closed;
    }
    validate_section_numbers(section.columns, section.max_rows)
}

/// Give `section` (not in `doc.sections`) its region and order key.
fn place_section(
    doc: &mut Doc,
    section: &mut Section,
    place: &SectionPlace,
) -> Result<(), Refusal> {
    if let Some(region) = &place.region {
        section.region = region.clone();
    }
    let mut siblings: Vec<(SectionId, String)> = doc
        .sections
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
        } else if let Some(existing) = doc.sections.iter_mut().find(|s| s.id == id) {
            existing.order = key;
        }
    }
    Ok(())
}

fn remove_section(doc: &mut Doc, id: &str) -> Result<(), Refusal> {
    let section = doc.section(id).ok_or(Refusal::UnknownSection)?;
    if section.kind.machine().is_some() {
        return Err(Refusal::MachineRequired);
    }
    let top: Vec<ItemId> = doc.children(id, None).iter().map(|item| item.id.clone()).collect();
    for item_id in top {
        let Some(item) = doc.item(&item_id) else { continue };
        match doc.item_machine(item) {
            Some(machine) => {
                let target = ensure_machine_section(doc, &machine);
                place(doc, std::slice::from_ref(&item_id), &Target::end(&target))?;
            }
            None => {
                doc.items.retain(|i| i.id != item_id && i.parent.as_deref() != Some(&item_id));
            }
        }
    }
    doc.sections.retain(|section| section.id != id);
    Ok(())
}
