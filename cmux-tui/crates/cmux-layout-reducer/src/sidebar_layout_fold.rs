//! The sidebar layout's splices (CmuxNextSidebar/Logic/SidebarLayout+Fold.swift, `+Insert`, `+Selection`,
//! SidebarLayoutKeyIndex.swift and SidebarDragLook.swift): a group's fold, a loose row's insert and removal, and a
//! workspace drag's look, each laid out as `make` (`sidebar_layout_engine`) would lay out the whole list, but spliced
//! into the layout already shown so the cost is the changed rows, not the list's (Leo 2026-11-04: "It should just
//! never, ever ... be acceptable for there to be some sort of linear time growth degradation"). A splice answers
//! nil when it cannot match `make` and the list must be laid out again.
//!
//! Step A of a two-step port: Swift stays the caller until the FFI re-pin. As in the engine, a workspace row's height
//! comes in on the workspace, so `machineLabel` (which only changes that height) has no part here.

use crate::sidebar_layout_engine::{
    Builder, Content, DOC_PINNED_SECTION, FoldId, FoldKind, Gap, Group, GroupItem, Item, Key,
    Layout, Member, Metrics, Node, Options, Row, Section, SectionId, SectionKind, Workspace,
    sole_member,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::ops::Range;

// MARK: - Key index

/// Splices a [`KeyIndex`] keeps before it is built again (`SidebarLayoutKeyIndex.compactAfter`).
pub const COMPACT_AFTER: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Splice {
    start: usize,
    removed: usize,
    inserted: usize,
}

/// `SidebarLayoutKeyIndex`: each row key's position, kept current through splices without rehashing every row. A
/// lookup moves the position it was built with past each splice since; after [`COMPACT_AFTER`] splices the table is
/// built again, once.
#[derive(Debug, Clone, Default)]
pub struct KeyIndex {
    /// Positions as built (valid before every splice).
    base: HashMap<Key, usize>,
    /// Keys a splice inserted: their position right after splice `epoch - 1`.
    added: HashMap<Key, (usize, usize)>,
    splices: Vec<Splice>,
}

impl KeyIndex {
    pub fn new<'a>(keys: impl IntoIterator<Item = &'a Key>) -> KeyIndex {
        let mut base = HashMap::new();
        for (i, key) in keys.into_iter().enumerate() {
            base.insert(key.clone(), i);
        }
        KeyIndex { base, added: HashMap::new(), splices: Vec::new() }
    }

    /// The position of `key`'s row, or nil when no row has it.
    pub fn position(&self, key: &Key) -> Option<usize> {
        if let Some(&(position, epoch)) = self.added.get(key) {
            return self.moved(position, epoch);
        }
        self.base.get(key).and_then(|&p| self.moved(p, 0))
    }

    /// `position` (valid after `epoch` splices) moved past the splices after it; nil when one removed it.
    fn moved(&self, position: usize, epoch: usize) -> Option<usize> {
        let mut p = position;
        for splice in self.splices.get(epoch..).unwrap_or(&[]) {
            if p >= splice.start + splice.removed {
                p = p - splice.removed + splice.inserted;
            } else if p >= splice.start {
                return None;
            }
        }
        Some(p)
    }

    /// The rows (whose keys are `keys`, already spliced) replaced `removed` rows at `start` with `inserted`.
    pub fn splice<'a>(
        &mut self,
        start: usize,
        removed: usize,
        inserted: &[Key],
        keys: impl IntoIterator<Item = &'a Key>,
    ) {
        if self.splices.len() >= COMPACT_AFTER {
            *self = KeyIndex::new(keys);
            return;
        }
        self.splices.push(Splice { start, removed, inserted: inserted.len() });
        let epoch = self.splices.len();
        for (offset, key) in inserted.iter().enumerate() {
            self.added.insert(key.clone(), (start + offset, epoch));
        }
    }
}

// MARK: - A layout with its index

/// A `SidebarLayout` as the list holds it: its rows and their [`KeyIndex`].
#[derive(Debug, Clone)]
pub struct IndexedLayout {
    layout: Layout,
    index: KeyIndex,
}

impl IndexedLayout {
    pub fn new(layout: Layout) -> IndexedLayout {
        let index = KeyIndex::new(layout.rows.iter().map(|r| &r.key));
        IndexedLayout { layout, index }
    }

    pub fn layout(&self) -> &Layout {
        &self.layout
    }

    pub fn into_layout(self) -> Layout {
        self.layout
    }

    /// The position of `key`'s row in the rows, or nil.
    pub fn position(&self, key: &Key) -> Option<usize> {
        self.index.position(key).filter(|&p| p < self.layout.rows.len())
    }

    /// `row(for:)`.
    pub fn row(&self, key: &Key) -> Option<&Row> {
        self.position(key).and_then(|p| self.layout.rows.get(p))
    }

    /// `groupRow`: group `id`'s header, or the one row it draws as.
    pub fn group_row(&self, id: &str) -> Option<&Row> {
        self.row(&Key::Group(id.to_owned())).or_else(|| {
            self.layout.rows.iter().find(|r| r.stands_for_group && r.group.as_deref() == Some(id))
        })
    }

    /// `replaceRows`: `rows[range]` replaced with `new`, every row after them moved by `dy`.
    fn replace_rows(&mut self, range: Range<usize>, new: Vec<Row>, dy: f64) {
        let start = range.start;
        let removed = range.len();
        let keys: Vec<Key> = new.iter().map(|r| r.key.clone()).collect();
        let count = new.len();
        self.layout.rows.splice(range, new);
        if dy != 0.0 {
            for row in self.layout.rows.iter_mut().skip(start + count) {
                row.y += dy;
            }
            self.layout.total_height += dy;
        }
        self.index.splice(start, removed, &keys, self.layout.rows.iter().map(|r| &r.key));
    }

    fn row_at(&self, position: usize) -> Option<&Row> {
        self.layout.rows.get(position)
    }

    fn row_at_mut(&mut self, position: usize) -> Option<&mut Row> {
        self.layout.rows.get_mut(position)
    }
}

fn max_y(row: &Row) -> f64 {
    row.y + row.height
}

fn is_group_header(key: &Key) -> bool {
    matches!(key, Key::Group(_))
}

fn workspaces_only(o: &Options) -> bool {
    o.filter_matches.is_none()
        && o.gap.is_none()
        && o.excluded_group.is_none()
        && o.excluded_item.is_none()
        && !o.grouping.is_grouped()
        && !o.hides_workspaces
}

/// A group member, owned (`SidebarGroupMember`).
#[derive(Debug, Clone, PartialEq)]
enum Owned {
    Workspace(Workspace),
    Item(Item),
}

fn owned(member: &Member<'_>) -> Owned {
    match member {
        Member::Workspace(ws) => Owned::Workspace((*ws).clone()),
        Member::Item(item) => Owned::Item((*item).clone()),
    }
}

/// `SidebarGroup.setMembers`: each item after the workspace before it.
fn set_members(group: &mut Group, members: Vec<Owned>) {
    let (mut workspaces, mut items): (Vec<Workspace>, Vec<GroupItem>) = (Vec::new(), Vec::new());
    for member in members {
        match member {
            Owned::Workspace(ws) => workspaces.push(ws),
            Owned::Item(item) => {
                let after = workspaces.last().map(|w| w.id.clone());
                items.push(GroupItem { item, after });
            }
        }
    }
    group.workspaces = workspaces;
    group.items = items;
}

// MARK: - Fold

/// `folding`: `layout` with `group` folded (`collapsed`) or opened, as `make` lays it out, spliced in place; nil
/// when the fold cannot be spliced (a filter, a drag gap or excluded row, a grouping, the chat history, a nested
/// group or one holding subgroups, Done, settled or archived members, the session tree's lineage, a row limit it
/// passes, changed members, a group drawn as its one member, or a group this layout does not draw).
pub fn folding(
    layout: &IndexedLayout,
    group: &Group,
    collapsed: bool,
    section: &Section,
    base: &Metrics,
    o: &Options,
) -> Option<IndexedLayout> {
    let mut next = layout.clone();
    fold(&mut next, group, collapsed, section, base, o).then_some(next)
}

/// `fold`: [`folding`] in place; false (unchanged) when the fold cannot be spliced.
pub fn fold(
    l: &mut IndexedLayout,
    group: &Group,
    collapsed: bool,
    section: &Section,
    base: &Metrics,
    o: &Options,
) -> bool {
    if !workspaces_only(o) || l.layout.gap_y.is_some() {
        return false;
    }
    let Some(header_index) = l.position(&Key::Group(group.id.clone())) else { return false };
    if l.layout.pinned_chats_y.is_some() || l.layout.earlier_chats_y.is_some() {
        return false;
    }
    let has_subgroups = section.nodes.iter().any(
        |n| matches!(n, Node::Group(child) if child.parent.as_deref() == Some(group.id.as_str())),
    );
    let in_tree = o
        .session_tree
        .as_ref()
        .is_some_and(|tree| group.workspaces.iter().any(|w| tree.parents.contains_key(&w.id)));
    if group.parent.is_some()
        || (o.folds_done && group.workspaces.iter().any(|w| w.done))
        || group.workspaces.iter().any(|w| o.settled.contains(&w.id))
        || (o.folds_archived && group.workspaces.iter().any(|w| w.archived))
        || (o.archive_section && (group.is_archived || group.workspaces.iter().any(|w| w.archived)))
        || in_tree
        || (o.row_limit != 0 && group.members().len() > o.row_limit + 1)
        || has_subgroups
    {
        return false;
    }
    let m = base.resolved(o);
    let Some(header) = l.row_at(header_index).cloned() else { return false };
    let section_id = section.id();
    if header.section != section_id {
        return false;
    }
    // The group's block: its header and the member rows right after it.
    let mut end = header_index + 1;
    while let Some(row) = l.row_at(end) {
        if row.group.as_deref() != Some(group.id.as_str()) || is_group_header(&row.key) {
            break;
        }
        end += 1;
    }
    let last_old = if end > header_index + 1 { l.row_at(end - 1) } else { None };
    let old_end = block_end(&header, last_old, &m);

    let shown: Vec<&Workspace> =
        group.workspaces.iter().filter(|w| !o.excluded_workspaces.contains(&w.id)).collect();
    let shown_ids: HashSet<&str> = shown.iter().map(|w| w.id.as_str()).collect();
    let members: Vec<Member<'_>> = group
        .members()
        .into_iter()
        .filter(|member| match member {
            Member::Workspace(ws) => shown_ids.contains(ws.id.as_str()),
            Member::Item(_) => true,
        })
        .collect();
    // The members changed too: a structural change.
    if members.len() != header.child_count {
        return false;
    }
    // A group of one member named as the group draws that member's row in the header's place: laid out again.
    if sole_member(group, &members, false, o).is_some() {
        return false;
    }
    let parent = header.sibling_index;
    let mut built: Vec<Row> = Vec::new();
    let mut y = max_y(&header) + m.row_spacing;
    // Members sit one level in from their header (`make`).
    let member_depth = group.depth + 1;
    let member_row =
        |key: Key, y: f64, height: f64, child_index: usize, last: bool, content: Content| {
            let mut row = Row::new(key, y, height, section_id.clone());
            row.group = Some(group.id.clone());
            row.sibling_index = child_index;
            row.parent_index = Some(parent);
            row.is_last_in_group = last;
            row.group_color = group.color.clone();
            row.content = Some(content);
            row.depth = member_depth;
            row
        };
    if collapsed {
        // The selected workspace, and one selected here before, stay visible members (`make`).
        let kept: Vec<(usize, &Workspace)> = members
            .iter()
            .enumerate()
            .filter_map(|(i, member)| match member {
                Member::Workspace(ws) if o.shown_in_collapsed(&group.id, &ws.id) => {
                    shown.iter().find(|w| w.id == ws.id).map(|w| (i, *w))
                }
                _ => None,
            })
            .collect();
        for (n, (child_index, ws)) in kept.iter().enumerate() {
            let row = member_row(
                Key::Workspace(ws.id.clone()),
                y,
                ws.height,
                *child_index,
                n + 1 == kept.len(),
                Content::base(ws),
            );
            y += row.height + m.row_spacing;
            built.push(row);
        }
    } else {
        for (child_index, member) in members.iter().enumerate() {
            let last = child_index + 1 == members.len();
            let row = match member {
                Member::Workspace(ws) => member_row(
                    Key::Workspace(ws.id.clone()),
                    y,
                    ws.height,
                    child_index,
                    last,
                    Content::base(ws),
                ),
                Member::Item(item) => member_row(
                    Key::Item(item.id.clone()),
                    y,
                    m.empty_content_height(),
                    child_index,
                    last,
                    Content::default(),
                ),
            };
            y += row.height + m.row_spacing;
            built.push(row);
        }
    }
    let new_end = block_end(&header, built.last(), &m);
    let mut folded = header;
    folded.is_collapsed = collapsed;
    if let Some(slot) = l.row_at_mut(header_index) {
        *slot = folded;
    }
    l.replace_rows(header_index + 1..end, built, new_end - old_end);
    true
}

/// Where the list goes on after a group's block: one row spacing under its last row, open or folded.
fn block_end(header: &Row, last: Option<&Row>, m: &Metrics) -> f64 {
    max_y(last.unwrap_or(header)) + m.row_spacing
}

/// `excerpt`: the rows of `keys` (and of group `id`'s block and its section header), as a small layout.
pub fn excerpt(l: &IndexedLayout, keys: &[Key], id: &str) -> Layout {
    let mut positions: BTreeSet<usize> = keys.iter().filter_map(|k| l.position(k)).collect();
    if let Some(start) = l.position(&Key::Group(id.to_owned())) {
        positions.insert(start);
        let mut end = start + 1;
        while let Some(row) = l.row_at(end) {
            if row.group.as_deref() != Some(id) || is_group_header(&row.key) {
                break;
            }
            end += 1;
        }
        positions.extend(start..end);
        if let Some(section) =
            l.row_at(start).and_then(|r| l.position(&Key::Section(r.section.clone())))
        {
            positions.insert(section);
        }
    }
    Layout {
        rows: positions.into_iter().filter_map(|p| l.row_at(p).cloned()).collect(),
        total_height: l.layout.total_height,
        gap_y: None,
        gap_height: 0.0,
        gap_shift: 0.0,
        row_spacing: l.layout.row_spacing,
        pinned_chats_y: None,
        earlier_chats_y: None,
    }
}

// MARK: - Insert and remove

/// `SidebarRowInsertion`: a set that added a loose row (its section as the set left it, the row's node index).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Insertion {
    pub section: Section,
    pub node: usize,
    #[serde(default)]
    pub workspace: Option<Workspace>,
}

/// `SidebarRowRemoval`: a set that took a loose row out (its section after the removal, the row's node index).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Removal {
    pub section: Section,
    pub node: usize,
    pub workspace: Workspace,
}

fn splices_loose(l: &IndexedLayout, o: &Options) -> bool {
    workspaces_only(o)
        && l.layout.gap_y.is_none()
        && o.session_tree.is_none()
        && o.row_limit == 0
        && l.layout.pinned_chats_y.is_none()
        && l.layout.earlier_chats_y.is_none()
}

/// `insertLoose`: `insertion`'s workspace row spliced in as `make` lays it out with the row added; the rows after it
/// move down by its slot and the section's later rows count one more node before them. False (unchanged) when the
/// row cannot be spliced. `pending`: later nodes a batch splices in after this one (no row has them yet).
pub fn insert_loose(
    l: &mut IndexedLayout,
    insertion: &Insertion,
    base: &Metrics,
    o: &Options,
    pending: &HashSet<usize>,
) -> bool {
    let section = &insertion.section;
    let k = insertion.node;
    let Some(ws) = &insertion.workspace else { return false };
    if !splices_loose(l, o)
        || o.excluded_workspaces.contains(&ws.id)
        || section.machine().is_none()
        || is_doc_section(section)
        || folds(ws, o)
        || l.position(&Key::Workspace(ws.id.clone())).is_some()
    {
        return false;
    }
    // Where `make` puts node k: right before the row of the node after it, or right after the row of the loose
    // node before it, each its node's own top-level row drawn in node order.
    let nodes = &section.nodes;
    let section_id = section.id();
    let mut after = k + 1;
    while pending.contains(&after) {
        after += 1;
    }
    let own_row = |node: &Node| {
        if folds_node(node, o) {
            return None;
        }
        let at = l.position(&row_key(node))?;
        l.row_at(at).filter(|r| is_own_top_row(r, &section_id)).map(|r| (at, r))
    };
    let placed = if let Some((next, row)) = nodes.get(after).and_then(own_row) {
        Some((next, row.y, row.sibling_index))
    } else if let Some((previous, row)) =
        k.checked_sub(1).and_then(|p| nodes.get(p)).filter(|n| is_loose(n)).and_then(own_row)
    {
        Some((previous + 1, max_y(row) + l.layout.row_spacing, row.sibling_index + 1))
    } else {
        None
    };
    let Some((at, y, sibling)) = placed else { return false };
    let m = base.resolved(o);
    if m.row_spacing != l.layout.row_spacing {
        return false;
    }
    let mut row = Row::new(Key::Workspace(ws.id.clone()), y, ws.height, section_id.clone());
    row.sibling_index = sibling;
    row.content = Some(Content::base(ws));
    let slot = ws.height + m.row_spacing;
    l.replace_rows(at..at, vec![row], slot);
    // The section's later rows: a top-level row's node index, and a member's group index, count the new node.
    for later in l.layout.rows.iter_mut().skip(at + 1) {
        if later.section != section_id {
            break;
        }
        if !matches!(later.key, Key::DoneFold(_) | Key::ShowMore(_))
            && later.parent_index.is_none()
            && later.sibling_index >= sibling
        {
            later.sibling_index += 1;
        }
        if let Some(parent) = later.parent_index
            && parent >= sibling
        {
            later.parent_index = Some(parent + 1);
        }
    }
    // The section's header counts its nodes.
    if let Some(header) = l.position(&Key::Section(section_id))
        && let Some(row) = l.row_at_mut(header)
    {
        row.child_count += 1;
    }
    true
}

/// `removeLoose`: `removal`'s workspace row taken out as `make` lays out the sections without it; the rows after it
/// move up by its slot and the section's later rows count one node fewer. False (unchanged) when it cannot be.
pub fn remove_loose(l: &mut IndexedLayout, removal: &Removal, base: &Metrics, o: &Options) -> bool {
    let section = &removal.section;
    let ws = &removal.workspace;
    let k = removal.node;
    let section_id = section.id();
    if !splices_loose(l, o)
        || section.machine().is_none()
        || is_doc_section(section)
        || section.nodes.is_empty()
        || folds(ws, o)
    {
        return false;
    }
    let Some(at) = l.position(&Key::Workspace(ws.id.clone())) else { return false };
    let Some(row) = l.row_at(at).cloned() else { return false };
    if !is_own_top_row(&row, &section_id)
        || row.sibling_index != k
        || base.resolved(o).row_spacing != l.layout.row_spacing
    {
        return false;
    }
    let spacing = l.layout.row_spacing;
    // The row's slot is its height and the spacing to a row of its section beside it.
    let slot = row.height + spacing;
    let next_follows = l
        .row_at(at + 1)
        .is_some_and(|n| n.section == section_id && (n.y - (max_y(&row) + spacing)).abs() < 0.001);
    let previous = at.checked_sub(1).and_then(|p| l.row_at(p));
    let follows_previous = previous
        .is_some_and(|p| p.section == section_id && (row.y - (max_y(p) + spacing)).abs() < 0.001);
    // Another row of the section stays: a section left with only its header draws `make`'s empty placeholder.
    let previous_is_header = previous.is_some_and(|p| p.key == Key::Section(section_id.clone()));
    if !(next_follows || (follows_previous && !previous_is_header)) {
        return false;
    }
    l.replace_rows(at..at + 1, Vec::new(), -slot);
    for later in l.layout.rows.iter_mut().skip(at) {
        if later.section != section_id {
            break;
        }
        if !matches!(later.key, Key::DoneFold(_) | Key::ShowMore(_))
            && later.parent_index.is_none()
            && later.sibling_index > k
        {
            later.sibling_index -= 1;
        }
        if let Some(parent) = later.parent_index
            && parent > k
        {
            later.parent_index = Some(parent - 1);
        }
    }
    if let Some(header) = l.position(&Key::Section(section_id))
        && let Some(row) = l.row_at_mut(header)
    {
        row.child_count = row.child_count.saturating_sub(1);
    }
    true
}

/// Whether `ws` is drawn behind a fold row (Done, Settled, Automatic, archived), out of node order.
fn folds(ws: &Workspace, o: &Options) -> bool {
    ws.archived || (o.folds_done && ws.done) || o.settles(ws) || o.automates(ws)
}

fn folds_node(node: &Node, o: &Options) -> bool {
    match node {
        Node::Workspace(ws) => folds(ws, o),
        Node::Item(item) => item.archived,
        Node::Group(_) => false,
    }
}

fn is_loose(node: &Node) -> bool {
    !matches!(node, Node::Group(_))
}

/// The row key `make` gives a node's own row.
fn row_key(node: &Node) -> Key {
    match node {
        Node::Workspace(ws) => Key::Workspace(ws.id.clone()),
        Node::Group(group) => Key::Group(group.id.clone()),
        Node::Item(item) => Key::Item(item.id.clone()),
    }
}

/// `row` is a top-level row of `section` drawn for its own node, not a member.
fn is_own_top_row(row: &Row, section: &SectionId) -> bool {
    row.section == *section && row.parent_index.is_none() && row.depth == 0 && !row.stands_for_group
}

/// `isDocSection`.
fn is_doc_section(section: &Section) -> bool {
    matches!(section.kind, SectionKind::Custom(_))
}

// MARK: - Selection

/// `SidebarItem`: what the sidebar has selected.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Selected {
    Group(String),
    Workspace(String),
    TopItem(String),
}

/// `selectedRowKey`: the row that stands for `selected` (its workspace or group row, or the collapsed group header
/// that holds a workspace inside it); nil for a row this layout does not show.
pub fn selected_row_key(
    l: &IndexedLayout,
    selected: Option<&Selected>,
    sections: &[Section],
) -> Option<Key> {
    match selected? {
        Selected::Group(id) => l.group_row(id).map(|r| r.key.clone()),
        Selected::Workspace(id) => {
            let key = Key::Workspace(id.clone());
            if l.row(&key).is_some() {
                return Some(key);
            }
            let group = sections.iter().flat_map(|s| &s.nodes).find_map(|node| match node {
                Node::Group(g) if g.is_collapsed && g.workspaces.iter().any(|w| w.id == *id) => {
                    Some(g.id.as_str())
                }
                _ => None,
            })?;
            l.group_row(group).map(|r| r.key.clone())
        }
        Selected::TopItem(id) => {
            let key = Key::Item(id.clone());
            l.row(&key).is_some().then_some(key)
        }
    }
}

// MARK: - Drag look

/// `SidebarEdits.canPlace`: a machine's section takes only its own computer's workspaces.
pub fn can_place(ws: &Workspace, section: &Section) -> bool {
    match &section.kind {
        SectionKind::Pinned | SectionKind::Custom(_) => true,
        SectionKind::Machine { id, .. } => ws.machine_id.as_deref() == Some(id.as_str()),
    }
}

/// One dragged workspace: the section index it leaves and the group it leaves (nil: a loose row).
#[derive(Debug, Clone)]
struct Moving {
    ws: Workspace,
    group: Option<String>,
}

/// `SidebarDragLook`: a workspace drag's look, spliced from the drag's base layout (the list without the dragged
/// rows): the slot's container laid out again, or the dragged rows put in among a section's top-level rows, and the
/// rows after it moved by the difference.
#[derive(Debug, Clone)]
pub struct DragLook {
    base: IndexedLayout,
    sections: Vec<Section>,
    options: Options,
    moving: Vec<Moving>,
    ids: HashSet<String>,
    /// Each group's section and node index.
    groups: HashMap<String, (usize, usize)>,
    /// The groups a group of the list sits in.
    subgroup_parents: HashSet<String>,
    /// Sections whose top-level rows are not their nodes' indexes (a group under a collapsed one, an archive split).
    hiding_sections: HashSet<SectionId>,
    /// With archived rows left out: groups that are archived, hold an archived row, or sit in such a group.
    archive_bound: HashSet<String>,
    /// The loose dragged rows each section loses.
    loose_leaving: HashMap<usize, usize>,
    /// Each section's rows in the base, where they are one run.
    section_rows: HashMap<SectionId, Range<usize>>,
    /// Whether any slot of this drag may splice.
    splices: bool,
}

impl DragLook {
    /// `shown(_:leaving:)`: the look's options, the dragged rows shown and only `leaving` left out.
    pub fn shown(o: &Options, leaving: HashSet<String>) -> Options {
        let mut shown = o.clone();
        shown.excluded_workspaces = leaving;
        shown.excluded_group = None;
        shown.excluded_item = None;
        shown
    }

    /// One pass over the sections and the base's rows, once per drag base.
    pub fn new(
        base: Layout,
        sections: Vec<Section>,
        options: Options,
        dragged: &[String],
    ) -> DragLook {
        let wanted: HashSet<String> = dragged.iter().cloned().collect();
        let archive = options.archive_section && options.filter_matches.is_none();
        let mut seen: HashSet<&str> = HashSet::new();
        let mut repeats = false;
        let mut moving = Vec::new();
        let mut groups = HashMap::new();
        let (mut parents, mut hiding, mut bound) = (HashSet::new(), HashSet::new(), HashSet::new());
        let mut loose_leaving: HashMap<usize, usize> = HashMap::new();
        for (s, section) in sections.iter().enumerate() {
            let id = section.id();
            let mut hidden: HashSet<&str> = HashSet::new();
            let splits = archive
                && id != SectionId::Pinned
                && id != SectionId::Custom(DOC_PINNED_SECTION.to_owned());
            let mut leaves_whole: HashSet<&str> = HashSet::new();
            for (n, node) in section.nodes.iter().enumerate() {
                match node {
                    Node::Workspace(ws) => {
                        if splits
                            && ws.archived
                            && options.active_workspace_id.as_deref() != Some(ws.id.as_str())
                        {
                            hiding.insert(id.clone());
                        }
                        if !seen.insert(ws.id.as_str()) {
                            repeats = true;
                        }
                        if wanted.contains(&ws.id) {
                            moving.push(Moving { ws: ws.clone(), group: None });
                            *loose_leaving.entry(s).or_default() += 1;
                        }
                    }
                    Node::Group(group) => {
                        groups.insert(group.id.clone(), (s, n));
                        if let Some(parent) = &group.parent {
                            parents.insert(parent.clone());
                            if hidden.contains(parent.as_str()) {
                                hidden.insert(group.id.as_str());
                                hiding.insert(id.clone());
                            }
                        }
                        if group.is_collapsed {
                            hidden.insert(group.id.as_str());
                        }
                        let in_bound = group.parent.as_ref().is_some_and(|p| bound.contains(p));
                        if archive
                            && (group.is_archived
                                || group.workspaces.iter().any(|w| w.archived)
                                || group.items.iter().any(|i| i.item.archived)
                                || in_bound)
                        {
                            bound.insert(group.id.clone());
                        }
                        // A group the archive split takes out of its list whole.
                        let in_whole =
                            group.parent.as_deref().is_some_and(|p| leaves_whole.contains(p));
                        if splits
                            && (group.is_archived
                                || (!group.workspaces.is_empty()
                                    && group.workspaces.iter().all(|w| w.archived))
                                || in_whole)
                        {
                            leaves_whole.insert(group.id.as_str());
                            hiding.insert(id.clone());
                        }
                        for ws in &group.workspaces {
                            if !seen.insert(ws.id.as_str()) {
                                repeats = true;
                            }
                            if wanted.contains(&ws.id) {
                                moving
                                    .push(Moving { ws: ws.clone(), group: Some(group.id.clone()) });
                            }
                        }
                    }
                    Node::Item(item) => {
                        if splits && item.archived {
                            hiding.insert(id.clone());
                        }
                    }
                }
            }
        }
        // Each section's rows: a section whose rows are not one run has none.
        let mut ranges: HashMap<SectionId, Range<usize>> = HashMap::new();
        let mut broken: HashSet<SectionId> = HashSet::new();
        let rows = &base.rows;
        let mut i = 0;
        while let Some(first) = rows.get(i) {
            let mut j = i + 1;
            while rows.get(j).is_some_and(|r| r.section == first.section) {
                j += 1;
            }
            if ranges.contains_key(&first.section) {
                broken.insert(first.section.clone());
            } else {
                ranges.insert(first.section.clone(), i..j);
            }
            i = j;
        }
        for id in &broken {
            ranges.remove(id);
        }
        let o = &options;
        let empties_a_section = loose_leaving.iter().any(|(s, count)| {
            sections.get(*s).is_some_and(|section| section.nodes.len() == *count)
        });
        let leaves_bound =
            moving.iter().any(|m| m.group.as_ref().is_some_and(|g| bound.contains(g)));
        let splices = !moving.is_empty()
            && !repeats
            && !empties_a_section
            && !leaves_bound
            && o.filter_matches.is_none()
            && !o.grouping.is_grouped()
            && o.session_tree.is_none()
            && o.chat_history.is_none()
            && o.row_limit == 0
            && !o.hides_workspaces
            && o.gap.is_none()
            && o.excluded_workspaces.is_empty()
            && o.excluded_group.is_none()
            && o.excluded_item.is_none()
            && base.gap_y.is_none()
            && base.pinned_chats_y.is_none()
            && base.earlier_chats_y.is_none();
        DragLook {
            base: IndexedLayout::new(base),
            sections,
            options,
            moving,
            ids: wanted,
            groups,
            subgroup_parents: parents,
            hiding_sections: hiding,
            archive_bound: bound,
            loose_leaving,
            section_rows: ranges,
            splices,
        }
    }

    /// `layout(to:metrics:)`: the look with the dragged rows at `position` (in the base's coordinates), as `make`
    /// lays out the sections the move makes, with the slot's gap over the dragged rows; nil when the splice cannot
    /// lay it out as `make` does.
    pub fn layout(&self, position: &Gap, metrics: &Metrics) -> Option<Layout> {
        if !self.splices {
            return None;
        }
        let s = self.sections.iter().position(|section| section.id() == position.section)?;
        let section = self.sections.get(s)?;
        // The moves `reorder` refuses leave the rows where they were.
        if position.group.is_some() && section.machine().is_none() {
            return None;
        }
        if !self.moving.iter().all(|m| can_place(&m.ws, section)) {
            return None;
        }
        // A section the move leaves with no node, or that had none.
        if section.nodes.len() <= self.leaving(s) {
            return None;
        }
        let m = metrics.resolved(&self.options);
        if m.row_spacing != self.base.layout.row_spacing {
            return None;
        }
        let (layout, slot) = match &position.group {
            Some(group) => self.slot_in_group(group, position.index, s, &m)?,
            None => self.loose(position.index, s, &m)?,
        };
        Some(self.gapped(layout, slot, metrics))
    }

    fn leaving(&self, s: usize) -> usize {
        self.loose_leaving.get(&s).copied().unwrap_or(0)
    }

    /// The base with group `id`'s rows laid out again with the dragged rows among its members at `index`.
    fn slot_in_group(
        &self,
        id: &str,
        index: isize,
        s: usize,
        m: &Metrics,
    ) -> Option<(IndexedLayout, Range<usize>)> {
        let &(listed_section, listed_node) = self.groups.get(id)?;
        if listed_section != s || self.archive_bound.contains(id) {
            return None;
        }
        let section = self.sections.get(s)?;
        let Some(Node::Group(original)) = section.nodes.get(listed_node) else { return None };
        let kept: Vec<Owned> = original
            .members()
            .iter()
            .filter(|member| match member {
                Member::Workspace(ws) => !self.ids.contains(&ws.id),
                Member::Item(_) => true,
            })
            .map(owned)
            .collect();
        let at = clamp(index, kept.len());
        let mut members = kept.clone();
        members.splice(at..at, self.moving.iter().map(|m| Owned::Workspace(m.ws.clone())));
        let mut group = original.clone();
        set_members(&mut group, members);
        // The group's rows in the base: its header (or the one row it draws as) and every row of it under that.
        let start = self.group_start(id, &kept)?;
        let rows = &self.base.layout.rows;
        let mut end = start + 1;
        while rows.get(end).is_some_and(|r| r.group.as_deref() == Some(id)) {
            end += 1;
        }
        let first = rows.get(start)?;
        let last = rows.get(end - 1)?;
        let node = if first.stands_for_group {
            first.parent_index.unwrap_or(first.sibling_index)
        } else {
            first.sibling_index
        };
        let children: Vec<&Workspace> =
            group.workspaces.iter().filter(|w| self.options.visible(w)).collect();
        let mut builder = Builder::at(&self.options, *m, first.y);
        builder.append_group(
            &group,
            &children,
            node,
            &section.id(),
            self.subgroup_parents.contains(id),
            false,
        );
        let (built, y) = builder.finish();
        let dy = y - (max_y(last) + m.row_spacing);
        let count = built.len();
        let mut layout = self.base.clone();
        layout.replace_rows(start..end, built, dy);
        Some((layout, start..start + count))
    }

    /// Where group `id`'s rows start in the base: its header, or the one row it draws as with its members `kept`.
    fn group_start(&self, id: &str, kept: &[Owned]) -> Option<usize> {
        if let Some(header) = self.base.position(&Key::Group(id.to_owned())) {
            return Some(header);
        }
        let [Owned::Workspace(only)] = kept else { return None };
        let at = self.base.position(&Key::Workspace(only.id.clone()))?;
        let row = self.base.row_at(at)?;
        (row.stands_for_group && row.group.as_deref() == Some(id)).then_some(at)
    }

    /// The base with the dragged rows as loose rows of section `s` at node `index`, the section's later rows
    /// counting them.
    fn loose(&self, index: isize, s: usize, m: &Metrics) -> Option<(IndexedLayout, Range<usize>)> {
        let section = self.sections.get(s)?;
        let id = section.id();
        if is_doc_section(section) || self.hiding_sections.contains(&id) {
            return None;
        }
        let range = self.section_rows.get(&id)?.clone();
        // A section that draws its rows out of node order (a Done or Archived fold at its end), folded, or as its
        // empty drop zone.
        for kind in [FoldKind::Done, FoldKind::Archived] {
            let fold = FoldId { section: id.clone(), group: None, kind, folder: None };
            if self.base.position(&Key::DoneFold(fold)).is_some() {
                return None;
            }
        }
        let header = self.base.position(&Key::Section(id.clone()));
        if header.and_then(|h| self.base.row_at(h)).is_some_and(|r| r.is_collapsed) {
            return None;
        }
        if self.base.position(&Key::EmptySection(id.clone())).is_some() {
            return None;
        }
        let q = clamp(index, section.nodes.len().saturating_sub(self.leaving(s)));
        // The first row of node q or after it: the section's rows run in node order.
        let rows = &self.base.layout.rows;
        let (mut low, mut high) = (range.start, range.end);
        while low < high {
            let mid = (low + high) / 2;
            if rows.get(mid).is_some_and(|r| node_of(r) < q as isize) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let at = low;
        let top = match rows.get(at).filter(|_| at < range.end) {
            Some(row) => row.y,
            None => max_y(rows.get(at.checked_sub(1)?)?) + m.row_spacing,
        };
        let mut built = Vec::new();
        let mut y = top;
        for (j, entry) in self.moving.iter().enumerate() {
            let mut row =
                Row::new(Key::Workspace(entry.ws.id.clone()), y, entry.ws.height, id.clone());
            row.sibling_index = q + j;
            row.content = Some(Content::default());
            y += row.height + m.row_spacing;
            built.push(row);
        }
        let k = built.len();
        let mut layout = self.base.clone();
        layout.replace_rows(at..at, built, y - top);
        // The section's later rows: a top-level row's node index, and a member's group index, count the new nodes.
        for later in layout.layout.rows.iter_mut().take(range.end + k).skip(at + k) {
            if !matches!(later.key, Key::DoneFold(_) | Key::ShowMore(_))
                && later.parent_index.is_none()
                && later.sibling_index >= q
            {
                later.sibling_index += k;
            }
            if let Some(parent) = later.parent_index
                && parent >= q
            {
                later.parent_index = Some(parent + k);
            }
        }
        // The section's header counts its nodes.
        if let Some(row) = header.and_then(|h| layout.row_at_mut(h)) {
            row.child_count += k;
        }
        Some((layout, at..at + k))
    }

    /// `layout` with the gap the dragged rows (in `slot`) make.
    fn gapped(&self, layout: IndexedLayout, slot: Range<usize>, metrics: &Metrics) -> Layout {
        let mut layout = layout.into_layout();
        let dragged: Vec<&Row> = layout
            .rows
            .get(slot)
            .unwrap_or(&[])
            .iter()
            .filter(|r| matches!(&r.key, Key::Workspace(id) if self.ids.contains(id)))
            .collect();
        if let (Some(first), Some(last)) = (dragged.first(), dragged.last()) {
            let (gap_y, gap_shift) = (first.y, max_y(last) + metrics.row_spacing - first.y);
            layout.gap_y = Some(gap_y);
            layout.gap_shift = gap_shift;
        }
        layout
    }
}

/// `max(0, min(index, count))`.
fn clamp(index: isize, count: usize) -> usize {
    usize::try_from(index).unwrap_or(0).min(count)
}

/// The node a row of a section belongs to (its own, or its group's); the header and a list heading come first.
fn node_of(row: &Row) -> isize {
    match row.key {
        Key::Section(_) | Key::ListHeader(_) => -1,
        _ => row.parent_index.unwrap_or(row.sibling_index) as isize,
    }
}

// MARK: - Wire

/// `fold`'s inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FoldRequest {
    pub layout: Layout,
    pub group: Group,
    pub collapsed: bool,
    pub section: Section,
    pub metrics: Metrics,
    #[serde(default)]
    pub options: Options,
}

/// `excerpt`'s inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExcerptRequest {
    pub layout: Layout,
    #[serde(default)]
    pub keys: Vec<Key>,
    pub group: String,
}

/// `insertLoose`'s inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InsertRequest {
    pub layout: Layout,
    pub insertion: Insertion,
    pub metrics: Metrics,
    #[serde(default)]
    pub options: Options,
    #[serde(default)]
    pub pending: HashSet<usize>,
}

/// `removeLoose`'s inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveRequest {
    pub layout: Layout,
    pub removal: Removal,
    pub metrics: Metrics,
    #[serde(default)]
    pub options: Options,
}

/// `selectedRowKey`'s inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectionRequest {
    pub layout: Layout,
    #[serde(default)]
    pub selected: Option<Selected>,
    #[serde(default)]
    pub sections: Vec<Section>,
}

/// One splice the key index follows: `removed` keys at `start` replaced with `inserted`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeySplice {
    pub start: usize,
    pub removed: usize,
    #[serde(default)]
    pub inserted: Vec<Key>,
}

/// The key index's inputs: the keys it is built with, the splices after, and the keys looked up.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyIndexRequest {
    pub keys: Vec<Key>,
    #[serde(default)]
    pub splices: Vec<KeySplice>,
    pub lookups: Vec<Key>,
}

/// A drag look's inputs: the drag's base, its sections and options, the dragged ids, and the slot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DragLookRequest {
    pub base: Layout,
    pub sections: Vec<Section>,
    #[serde(default)]
    pub options: Options,
    pub moving: Vec<String>,
    pub position: Gap,
    pub metrics: Metrics,
}

/// One rule of the op.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Request {
    Fold(Box<FoldRequest>),
    Excerpt(Box<ExcerptRequest>),
    InsertLoose(Box<InsertRequest>),
    RemoveLoose(Box<RemoveRequest>),
    SelectedRowKey(Box<SelectionRequest>),
    KeyIndex(Box<KeyIndexRequest>),
    DragLook(Box<DragLookRequest>),
}

/// The answer to one [`Request`]: a layout (nil when the splice refuses), a row key, or positions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reply {
    Layout(Option<Box<Layout>>),
    Key(Option<Key>),
    Positions(Vec<Option<usize>>),
}

fn spliced(applied: bool, layout: IndexedLayout) -> Reply {
    Reply::Layout(applied.then(|| Box::new(layout.into_layout())))
}

/// The op's answer.
pub fn respond(request: &Request) -> Reply {
    match request {
        Request::Fold(r) => {
            let mut layout = IndexedLayout::new(r.layout.clone());
            let applied =
                fold(&mut layout, &r.group, r.collapsed, &r.section, &r.metrics, &r.options);
            spliced(applied, layout)
        }
        Request::Excerpt(r) => {
            let layout = IndexedLayout::new(r.layout.clone());
            Reply::Layout(Some(Box::new(excerpt(&layout, &r.keys, &r.group))))
        }
        Request::InsertLoose(r) => {
            let mut layout = IndexedLayout::new(r.layout.clone());
            let applied =
                insert_loose(&mut layout, &r.insertion, &r.metrics, &r.options, &r.pending);
            spliced(applied, layout)
        }
        Request::RemoveLoose(r) => {
            let mut layout = IndexedLayout::new(r.layout.clone());
            let applied = remove_loose(&mut layout, &r.removal, &r.metrics, &r.options);
            spliced(applied, layout)
        }
        Request::SelectedRowKey(r) => {
            let layout = IndexedLayout::new(r.layout.clone());
            Reply::Key(selected_row_key(&layout, r.selected.as_ref(), &r.sections))
        }
        Request::KeyIndex(r) => {
            let mut keys = r.keys.clone();
            let mut index = KeyIndex::new(&keys);
            for s in &r.splices {
                let end = (s.start + s.removed).min(keys.len());
                let start = s.start.min(end);
                keys.splice(start..end, s.inserted.iter().cloned());
                index.splice(start, end - start, &s.inserted, &keys);
            }
            Reply::Positions(r.lookups.iter().map(|k| index.position(k)).collect())
        }
        Request::DragLook(r) => {
            let look =
                DragLook::new(r.base.clone(), r.sections.clone(), r.options.clone(), &r.moving);
            Reply::Layout(look.layout(&r.position, &r.metrics).map(Box::new))
        }
    }
}

#[cfg(test)]
#[path = "sidebar_layout_fold_tests.rs"]
mod tests;
