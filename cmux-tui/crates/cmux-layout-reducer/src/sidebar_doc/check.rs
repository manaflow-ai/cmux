//! The document invariants:
//! - ids are unique across sections and items;
//! - one machine section per session, with id `sec_m_<session>`;
//! - each workspace ref is placed once (`duplicate_ref`);
//! - an item's parent is a group of the same section; a group may sit in a
//!   group while its tree has at most [`MAX_GROUP_DEPTH`] levels of groups,
//!   and parents never cycle (`nesting`);
//! - the workspaces of one tree (a top-level group and everything under
//!   it) are of one machine, and a machine section holds only its machine's
//!   workspaces and groups (`cross_machine`);
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
                            check_tree(doc, group)?;
                        }
                    }
                }
            }
        }
    }
    // Groups that may have gained a member or moved.
    let mut groups: HashSet<&str> = HashSet::new();
    for (id, old) in items {
        let now = doc.item(id);
        if let Some(item) = now {
            check_item(doc, item)?;
            if item.body.is_group() {
                groups.insert(item.id.as_str());
            }
            if let Some(parent) = &item.parent {
                groups.insert(parent.as_str());
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
    // Each touched group's whole tree (a member deep in a tree must agree
    // with the members elsewhere in it), once per tree.
    let mut roots: HashSet<&str> = HashSet::new();
    for group in groups {
        let Some(item) = doc.item(group) else { continue };
        let root = doc.root(item);
        if root.body.is_group() && roots.insert(root.id.as_str()) {
            check_tree(doc, root)?;
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
        if section.host_group && section.kind.machine().is_none() {
            return Err(Refusal::InvalidValue);
        }
        if section.host_group_opt_out && section.kind.machine().is_none() {
            return Err(Refusal::InvalidValue);
        }
        if section.host_group && section.host_group_opt_out {
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
        if !parent.body.is_group() || parent.section != item.section {
            return Err(Refusal::Nesting);
        }
        if item.body.is_group() {
            if doc.has_parent_cycle(item) {
                return Err(Refusal::Nesting);
            }
            if doc.group_level(item) + doc.group_height(item) - 1 > MAX_GROUP_DEPTH {
                return Err(Refusal::Nesting);
            }
        }
    } else if item.body.is_group() && doc.group_height(item) > MAX_GROUP_DEPTH {
        return Err(Refusal::Nesting);
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

/// `reference` is of the machine the tree's earlier workspaces named.
fn agree<'a>(machine: &mut Option<&'a str>, reference: &'a WorkspaceRef) -> Result<(), Refusal> {
    match machine {
        Some(m) if *m != reference.session_id => Err(Refusal::CrossMachine),
        _ => {
            *machine = Some(reference.session_id.as_str());
            Ok(())
        }
    }
}

/// A tree's workspaces (every workspace under the top-level group `root`,
/// at any depth) are of one machine, and that machine owns the tree's
/// section when it is a machine section.
fn check_tree(doc: &Doc, root: &Item) -> Result<(), Refusal> {
    let mut machine: Option<&str> = None;
    for item in doc.descendants(root) {
        if let Some(reference) = item.body.workspace() {
            agree(&mut machine, reference)?;
        }
    }
    if let Some(machine) = machine
        && let Some(owner) = doc.section(&root.section).and_then(|s| s.kind.machine())
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
    let mut roots = Vec::new();
    for item in doc.items_unordered() {
        check_item(doc, item)?;
        if item.body.is_group() && item.parent.is_none() {
            roots.push(item);
        }
    }
    for root in roots {
        check_tree(doc, root)?;
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
        if section.kind.machine().is_none() {
            section.host_group = false;
            section.host_group_opt_out = false;
        } else if section.host_group && section.host_group_opt_out {
            // An explicit Remove wins over a contradictory grouped flag.
            section.host_group = false;
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
        .filter(|item| item.body.is_group())
        .map(|item| (item.id.clone(), item.section.clone()))
        .collect();
    for item in &mut items {
        if let Body::Group { name, .. } = &mut item.body {
            let fitted = fit_title(name);
            *name = if fitted.is_empty() { "Group".into() } else { fitted };
        }
        if item.span.is_some_and(|span| !(1..=12).contains(&span)) {
            item.span = None;
        }
        let Some(parent) = item.parent.clone() else { continue };
        if parent == item.id || groups.get(&parent) != Some(&item.section) {
            item.parent = None;
        }
    }
    lift_deep_or_cyclic_groups(&mut items);
    // The top-level group of each grouped item, then one machine per tree:
    // a workspace that disagrees with its tree's first one is lifted out.
    let parent_of: HashMap<String, Option<String>> =
        items.iter().map(|item| (item.id.clone(), item.parent.clone())).collect();
    let root_of = |id: &str| -> String {
        let mut current = id.to_string();
        for _ in 0..=MAX_GROUP_DEPTH {
            match parent_of.get(&current).cloned().flatten() {
                Some(parent) => current = parent,
                None => break,
            }
        }
        current
    };
    let mut group_machine: HashMap<String, String> = HashMap::new();
    for item in &mut items {
        let (Some(_), Some(reference)) = (&item.parent, item.body.workspace()) else { continue };
        let root = root_of(&item.id);
        if *group_machine.entry(root).or_insert_with(|| reference.session_id.clone())
            != reference.session_id
        {
            item.parent = None;
        }
    }
    // A tree whose workspaces belong to another machine than its section.
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

/// Lift to the top level of its section every group whose parent chain
/// cycles or puts it (or its subtree) deeper than [`MAX_GROUP_DEPTH`]
/// levels; repeated until every chain fits. Repair never deletes a group.
fn lift_deep_or_cyclic_groups(items: &mut [Item]) {
    loop {
        let parent_of: HashMap<&str, Option<&str>> = items
            .iter()
            .filter(|item| item.body.is_group())
            .map(|item| (item.id.as_str(), item.parent.as_deref()))
            .collect();
        let mut lift: Vec<String> = Vec::new();
        let mut cycle: Option<String> = None;
        for item in items.iter().filter(|item| item.body.is_group()) {
            let mut seen: HashSet<&str> = HashSet::from([item.id.as_str()]);
            let mut level = 1;
            let mut current = item.parent.as_deref();
            while let Some(parent) = current {
                if !seen.insert(parent) {
                    cycle.get_or_insert_with(|| item.id.clone());
                    break;
                }
                level += 1;
                current = parent_of.get(parent).copied().flatten();
            }
            // The first group past the limit; its subtree comes along and
            // is checked again on the next pass.
            if level == MAX_GROUP_DEPTH + 1 {
                lift.push(item.id.clone());
            }
        }
        // A cycle first, alone: lifting one member breaks it.
        let lift = match cycle {
            Some(id) => vec![id],
            None => lift,
        };
        if lift.is_empty() {
            return;
        }
        for item in items.iter_mut() {
            if lift.contains(&item.id) {
                item.parent = None;
            }
        }
    }
}
