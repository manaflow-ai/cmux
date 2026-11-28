//! The document invariants:
//! - ids are unique across sections and items;
//! - one machine section per session, with id `sec_m_<session>`;
//! - each workspace ref is placed once (`duplicate_ref`);
//! - an item's parent is a group of the same section at the top level, and
//!   a group has no parent (`nesting`);
//! - a group's workspaces are of one machine, and a machine section holds
//!   only its machine's workspaces and groups (`cross_machine`);
//! - an app section holds no items (`provider_owned`).
//!
//! [`touched`] checks only what an op list can have broken: the rows it
//! touched, the children of a group whose place changed, the groups that
//! gained a member, and the sections it changed. [`check`] is the same check
//! with every row touched (at open, for the migration and the repair).

use std::collections::{HashMap, HashSet};

use super::doc::Doc;
use super::model::*;
use super::order_key;
use super::reduce::{Changes, validate_section_numbers, validate_span, validate_title};

/// Check the invariants the touched rows (with their old copies) can break.
pub(crate) fn touched(
    doc: &Doc,
    items: &HashMap<ItemId, Option<Item>>,
    sections: &HashMap<SectionId, Option<Section>>,
) -> Result<(), Refusal> {
    if doc.sections().len() > MAX_SECTIONS || doc.item_count() > MAX_ITEMS {
        return Err(Refusal::TooMany);
    }
    if !sections.is_empty() {
        check_sections(doc)?;
        for (id, old) in sections {
            match doc.section(id) {
                None => {
                    if doc.section_item_count(id) > 0 {
                        return Err(Refusal::UnknownSection);
                    }
                }
                Some(section) => {
                    let kind_changed = old.as_ref().is_none_or(|old| old.kind != section.kind);
                    if kind_changed && doc.section_item_count(id) > 0 {
                        for item in doc.section_items(id) {
                            check_item(doc, item)?;
                        }
                        for group in doc.list(id, None).filter(|item| item.body.is_group()) {
                            check_group(doc, group, None)?;
                        }
                    }
                }
            }
        }
    }
    // Groups that may have gained a member or moved, and the touched
    // children of each.
    let mut groups: HashSet<&str> = HashSet::new();
    let mut touched_children: HashMap<&str, Vec<&Item>> = HashMap::new();
    for (id, old) in items {
        let now = doc.item(id);
        if let Some(item) = now {
            check_item(doc, item)?;
            if item.body.is_group() {
                groups.insert(item.id.as_str());
            }
            if let Some(parent) = &item.parent {
                groups.insert(parent.as_str());
                touched_children.entry(parent.as_str()).or_default().push(item);
            }
        }
        // Children of a group that went, moved or stopped being a group.
        let same_place = match (old, now) {
            (Some(old), Some(now)) => {
                old.section == now.section
                    && old.parent == now.parent
                    && old.body.is_group() == now.body.is_group()
            }
            _ => false,
        };
        if same_place {
            continue;
        }
        let places =
            [now.map(|item| item.section.as_str()), old.as_ref().map(|item| item.section.as_str())];
        for section in places.into_iter().flatten() {
            for child in doc.list(section, Some(id.as_str())) {
                check_item(doc, child)?;
            }
        }
    }
    for group in groups {
        let Some(item) = doc.item(group) else { continue };
        if item.body.is_group() {
            check_group(doc, item, Some(&touched_children))?;
        }
    }
    Ok(())
}

/// The section rules (at most [`MAX_SECTIONS`] rows, so all of them).
fn check_sections(doc: &Doc) -> Result<(), Refusal> {
    let mut machines = HashSet::new();
    for section in doc.sections() {
        if doc.item(&section.id).is_some() {
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
        validate_section_numbers(section)?;
    }
    Ok(())
}

/// One item's own rules: its section, key, values, parent and ref.
fn check_item(doc: &Doc, item: &Item) -> Result<(), Refusal> {
    let section = doc.section(&item.section).ok_or(Refusal::UnknownSection)?;
    if matches!(section.kind, SectionKind::App { .. }) {
        return Err(Refusal::ProviderOwned);
    }
    if doc.section(&item.id).is_some() {
        return Err(Refusal::DuplicateId);
    }
    if !order_key::is_valid(&item.order) {
        return Err(Refusal::InvalidValue);
    }
    validate_span(item.span)?;
    if let Body::Group { name, .. } = &item.body {
        validate_title(name)?;
    }
    if let Some(parent) = &item.parent {
        let parent = doc.item(parent).ok_or(Refusal::UnknownItem)?;
        if !parent.body.is_group()
            || parent.parent.is_some()
            || parent.section != item.section
            || item.body.is_group()
        {
            return Err(Refusal::Nesting);
        }
    }
    if let Some(reference) = item.body.workspace() {
        if doc.ref_count(reference) > 1 {
            return Err(Refusal::DuplicateRef);
        }
        if let Some(machine) = section.kind.machine()
            && machine != reference.session_id
        {
            return Err(Refusal::CrossMachine);
        }
    }
    Ok(())
}

/// A group's workspaces are of one machine, and that machine owns the
/// group's section when it is a machine section. With `touched` (an op
/// list's touched children by group), the members not touched agreed
/// before, so the first of them names the machine and only the touched ones
/// are compared with it; without it every member is compared.
fn agree<'a>(machine: &mut Option<&'a str>, reference: &'a WorkspaceRef) -> Result<(), Refusal> {
    match machine {
        Some(m) if *m != reference.session_id => Err(Refusal::CrossMachine),
        _ => {
            *machine = Some(reference.session_id.as_str());
            Ok(())
        }
    }
}

fn check_group<'a>(
    doc: &'a Doc,
    group: &'a Item,
    touched: Option<&HashMap<&str, Vec<&'a Item>>>,
) -> Result<(), Refusal> {
    let mut machine: Option<&'a str> = None;
    match touched {
        None => {
            for child in doc.list(&group.section, Some(group.id.as_str())) {
                if let Some(reference) = child.body.workspace() {
                    agree(&mut machine, reference)?;
                }
            }
        }
        Some(touched) => {
            let changed = touched.get(group.id.as_str());
            let is_touched = |id: &str| {
                changed.is_some_and(|children| children.iter().any(|child| child.id == id))
            };
            if let Some(reference) = doc
                .list(&group.section, Some(group.id.as_str()))
                .filter(|child| !is_touched(&child.id))
                .find_map(|child| child.body.workspace())
            {
                agree(&mut machine, reference)?;
            }
            for child in changed.into_iter().flatten() {
                if let Some(reference) = child.body.workspace() {
                    agree(&mut machine, reference)?;
                }
            }
        }
    }
    if let Some(machine) = machine
        && let Some(owner) = doc.section(&group.section).and_then(|s| s.kind.machine())
        && owner != machine
    {
        return Err(Refusal::CrossMachine);
    }
    Ok(())
}

/// Check every invariant of the document.
pub fn check(doc: &Doc) -> Result<(), Refusal> {
    if doc.sections().len() > MAX_SECTIONS || doc.item_count() > MAX_ITEMS {
        return Err(Refusal::TooMany);
    }
    check_sections(doc)?;
    let mut groups = Vec::new();
    for item in doc.items_unordered() {
        check_item(doc, item)?;
        if item.body.is_group() {
            groups.push(item);
        }
    }
    for group in groups {
        check_group(doc, group, None)?;
    }
    Ok(())
}

/// The rows that differ between `before` and `after` (a whole pass: the
/// repair at open uses it, ops do not).
pub fn diff(before: &Doc, after: &Doc) -> Changes {
    Changes {
        sections: after
            .sections()
            .iter()
            .filter(|s| before.section(&s.id).is_none_or(|old| old != *s))
            .cloned()
            .collect(),
        deleted_sections: before
            .sections()
            .iter()
            .filter(|s| after.section(&s.id).is_none())
            .map(|s| s.id.clone())
            .collect(),
        items: after
            .items_in_order()
            .into_iter()
            .filter(|i| before.item(&i.id).is_none_or(|old| old != *i))
            .cloned()
            .collect(),
        deleted_items: before
            .items_in_order()
            .into_iter()
            .filter(|i| after.item(&i.id).is_none())
            .map(|i| i.id.clone())
            .collect(),
    }
}

/// `title` cut to the document limit (old stores allow longer names).
pub fn fit_title(title: &str) -> String {
    title.trim().chars().take(MAX_TITLE_CHARS).collect::<String>().trim_end().to_string()
}

/// Make a document read from old or stored data pass [`check`], so one bad
/// row cannot refuse every later op: titles are cut, numbers out of range
/// are cleared, bad order keys are respread, and rows that cannot be kept
/// (a duplicate id or ref, an unknown section, an item in an app section, a
/// workspace in another machine's section) are dropped. A dropped
/// workspace is unplaced, and adoption puts it back into its machine
/// section. Returns whether anything changed.
pub fn repair(doc: &mut Doc) -> bool {
    if check(doc).is_ok() {
        return false;
    }
    let (mut sections, mut items) = doc.to_parts();
    let mut ids: HashSet<String> = HashSet::new();
    let mut machines: HashSet<String> = HashSet::new();
    sections.retain(|section| {
        if !ids.insert(section.id.clone()) {
            return false;
        }
        if let Some(session) = section.kind.machine()
            && (section.id != machine_section_id(session) || !machines.insert(session.to_string()))
        {
            return false;
        }
        !(matches!(section.kind, SectionKind::Pinned) && section.id != PINNED_SECTION_ID)
    });
    for section in &mut sections {
        if let Some(title) = &section.title {
            let fitted = fit_title(title);
            section.title = (!fitted.is_empty()).then_some(fitted);
        }
        if section.columns.is_some_and(|c| !(1..=12).contains(&c)) {
            section.columns = None;
        }
        if section.max_rows.is_some_and(|r| !(1..=50).contains(&r)) {
            section.max_rows = None;
        }
        if section.gap.is_some_and(|gap| !GAP_RANGE.contains(&gap)) {
            section.gap = None;
        }
    }
    if sections.iter().any(|section| !order_key::is_valid(&section.order)) {
        let keys = order_key::spread(sections.len());
        for (section, key) in sections.iter_mut().zip(keys) {
            section.order = key;
        }
    }
    let kinds: HashMap<String, SectionKind> =
        sections.iter().map(|s| (s.id.clone(), s.kind.clone())).collect();
    let mut refs: HashSet<(String, String)> = HashSet::new();
    items.retain(|item| {
        let Some(kind) = kinds.get(&item.section) else { return false };
        if matches!(kind, SectionKind::App { .. }) || !ids.insert(item.id.clone()) {
            return false;
        }
        match item.body.workspace() {
            Some(reference) => {
                kind.machine().is_none_or(|machine| machine == reference.session_id)
                    && refs.insert((reference.session_id.clone(), reference.workspace_id.clone()))
            }
            None => true,
        }
    });
    items.truncate(MAX_ITEMS);
    let groups: HashMap<String, String> = items
        .iter()
        .filter(|item| item.body.is_group() && item.parent.is_none())
        .map(|item| (item.id.clone(), item.section.clone()))
        .collect();
    let mut group_machine: HashMap<String, String> = HashMap::new();
    for item in &mut items {
        if let Body::Group { name, .. } = &mut item.body {
            let fitted = fit_title(name);
            *name = if fitted.is_empty() { "Group".into() } else { fitted };
        }
        if item.span.is_some_and(|span| !(1..=12).contains(&span)) {
            item.span = None;
        }
        let Some(parent) = item.parent.clone() else { continue };
        let fits = !item.body.is_group() && groups.get(&parent) == Some(&item.section);
        let fits = fits
            && match item.body.workspace() {
                Some(reference) => {
                    *group_machine.entry(parent).or_insert_with(|| reference.session_id.clone())
                        == reference.session_id
                }
                None => true,
            };
        if !fits {
            item.parent = None;
        }
    }
    // A group whose workspaces belong to another machine than its section.
    items.retain(|item| {
        let Some(machine) = group_machine.get(&item.id) else { return true };
        kinds
            .get(&item.section)
            .and_then(|kind| kind.machine())
            .is_none_or(|owner| owner == machine)
    });
    let kept: HashSet<String> = items.iter().map(|item| item.id.clone()).collect();
    for item in &mut items {
        if item.parent.as_ref().is_some_and(|parent| !kept.contains(parent)) {
            item.parent = None;
        }
    }
    let mut lists: HashMap<(String, Option<String>), Vec<usize>> = HashMap::new();
    for (index, item) in items.iter().enumerate() {
        lists.entry((item.section.clone(), item.parent.clone())).or_default().push(index);
    }
    for indexes in lists.values() {
        if indexes.iter().any(|&index| !order_key::is_valid(&items[index].order)) {
            for (&index, key) in indexes.iter().zip(order_key::spread(indexes.len())) {
                items[index].order = key;
            }
        }
    }
    *doc = Doc::from_parts(doc.revision, sections, items);
    true
}
