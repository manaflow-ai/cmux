//! Where the sidebar document puts the list's rows, moved from Swift's `SidebarDocListing.swift` and the space rules
//! it reads in `SidebarDocProjection.Group` (sidebar-v2, spaces.md, #25776).
//!
//! The app maps each machine's rows and builds the row values; these rules decide membership and order: which band
//! groups another window lists or this space leaves out, which document sections draw before and after the machine
//! lists and which groups they hold (pulled here, a header alone, or none), a machine section's rows in document
//! order with its links and the rows not placed yet, a group's link, tab and app members and the workspace each
//! follows, which rows draw archived or pinned in their group, and each group's sort. The app keeps the formatting
//! (titles, tints, icons) and the name collation a Name sort ranks by.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

/// The default space's id (`SidebarDocItem.defaultRoom`).
pub const DEFAULT_ROOM: &str = "default";

/// The space an item storing `room` belongs to while `spaces` exist (`SidebarDocItem.owningRoom`): its own, else the
/// default space's. `spaces` none: every stored space counts.
pub fn owning_room(room: Option<&str>, spaces: Option<&BTreeSet<String>>) -> String {
    match room {
        Some(room) if room == DEFAULT_ROOM || spaces.is_none_or(|spaces| spaces.contains(room)) => {
            room.to_owned()
        }
        _ => DEFAULT_ROOM.to_owned(),
    }
}

/// A band group (`SidebarDocProjection.Group`), the fields these rules read.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BandGroup {
    pub id: String,
    /// The document section that holds it.
    #[serde(default)]
    pub section: String,
    #[serde(default)]
    pub parent: Option<String>,
    /// The space it was made in; none: made before groups carried one.
    #[serde(default)]
    pub room: Option<String>,
    /// Its open workspace members (opaque refs).
    #[serde(default)]
    pub open_members: Vec<String>,
    #[serde(default)]
    pub collapsed: bool,
}

impl BandGroup {
    /// Whether a window on space `room` lists it when it lists none of its workspaces (`Group.lists(inRoom:spaces:)`).
    pub fn lists(&self, room: Option<&str>, spaces: Option<&BTreeSet<String>>) -> bool {
        let Some(room) = room else { return true };
        if self.parent.is_some() {
            return true;
        }
        match &self.room {
            Some(own) => owning_room(Some(own), spaces) == room,
            None => room == DEFAULT_ROOM && self.open_members.is_empty(),
        }
    }
}

fn first_by_id(groups: &[BandGroup]) -> HashMap<&str, &BandGroup> {
    let mut by_id = HashMap::new();
    for group in groups {
        by_id.entry(group.id.as_str()).or_insert(group);
    }
    by_id
}

/// The band groups holding an open workspace another window lists (`elsewhere`), themselves or in a group under them.
pub fn listed_elsewhere(groups: &[BandGroup], elsewhere: &BTreeSet<String>) -> BTreeSet<String> {
    let by_id = first_by_id(groups);
    let mut open = BTreeSet::new();
    for group in groups
        .iter()
        .filter(|group| group.open_members.iter().any(|member| elsewhere.contains(member)))
    {
        let mut id = Some(group.id.clone());
        while let Some(current) = id {
            if !open.insert(current.clone()) {
                break;
            }
            id = by_id.get(current.as_str()).and_then(|group| group.parent.clone());
        }
    }
    open
}

/// The band groups whose header this window leaves out when it lists none of their workspaces: those another window
/// lists and those not of space `room`, with the groups under them. `listed_here` and the groups above them stay.
pub fn not_listed_here(
    groups: &[BandGroup],
    elsewhere: &BTreeSet<String>,
    room: Option<&str>,
    spaces: Option<&BTreeSet<String>>,
    listed_here: &BTreeSet<String>,
) -> BTreeSet<String> {
    let mut hidden = listed_elsewhere(groups, elsewhere);
    if room.is_none() {
        return hidden;
    }
    let by_id = first_by_id(groups);
    let mut kept: HashSet<String> = HashSet::new();
    for id in listed_here {
        let mut at = Some(id.clone());
        while let Some(current) = at {
            if !kept.insert(current.clone()) {
                break;
            }
            at = by_id.get(current.as_str()).and_then(|group| group.parent.clone());
        }
    }
    struct Walk<'a> {
        by_id: HashMap<&'a str, &'a BandGroup>,
        kept: HashSet<String>,
        shows: HashMap<String, bool>,
        count: usize,
        room: Option<&'a str>,
        spaces: Option<&'a BTreeSet<String>>,
    }
    fn lists(walk: &mut Walk<'_>, group: &BandGroup, depth: usize) -> bool {
        if let Some(known) = walk.shows.get(&group.id) {
            return *known;
        }
        // Kept, or past as many steps as there are groups (a parent cycle the reducer refuses anyway): it lists, and
        // the walk stops before it climbs again.
        if walk.kept.contains(&group.id) || depth > walk.count {
            walk.shows.insert(group.id.clone(), true);
            return true;
        }
        let parent = group.parent.as_deref().and_then(|parent| walk.by_id.get(parent).copied());
        let parent_lists = match parent {
            Some(parent) => lists(walk, parent, depth + 1),
            None => true,
        };
        let result = parent_lists && group.lists(walk.room, walk.spaces);
        walk.shows.insert(group.id.clone(), result);
        result
    }
    let mut walk = Walk { by_id, kept, shows: HashMap::new(), count: groups.len(), room, spaces };
    for group in groups {
        if !lists(&mut walk, group, 0) {
            hidden.insert(group.id.clone());
        }
    }
    hidden
}

/// A document section of the layout: its id and what it holds (`workspaces` marks the machine lists' place, `app`
/// an app's view; anything else is a band of items).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LayoutSection {
    pub id: String,
    #[serde(default)]
    pub content: String,
}

/// A band group a list section draws: pulled from a machine list (this window lists a workspace of it), or its header
/// alone with its confirmed fold.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SectionGroup {
    pub id: String,
    pub pulled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<bool>,
}

/// A list section of the document and the groups it draws.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListSection {
    pub id: String,
    pub groups: Vec<SectionGroup>,
}

/// The document's list sections in order, split at the machine lists' place: those before draw their items and
/// groups, those after only their groups (an app section draws its view with none).
#[allow(clippy::too_many_arguments)]
pub fn sections(
    layout: &[LayoutSection],
    groups: &[BandGroup],
    pulled: &BTreeSet<String>,
    elsewhere: &BTreeSet<String>,
    room: Option<&str>,
    spaces: Option<&BTreeSet<String>>,
    folds: Option<&BTreeMap<String, bool>>,
) -> (Vec<ListSection>, Vec<ListSection>) {
    let hidden = not_listed_here(groups, elsewhere, room, spaces, pulled);
    let (mut before, mut after) = (Vec::new(), Vec::new());
    let mut passed_machines = false;
    for section in layout {
        if section.content == "workspaces" {
            passed_machines = true;
            continue;
        }
        let drawn: Vec<SectionGroup> = groups
            .iter()
            .filter(|group| group.section == section.id)
            .filter_map(|group| {
                if pulled.contains(&group.id) {
                    return Some(SectionGroup {
                        id: group.id.clone(),
                        pulled: true,
                        collapsed: None,
                    });
                }
                if hidden.contains(&group.id) {
                    return None;
                }
                let collapsed = folds
                    .and_then(|folds| folds.get(&group.id).copied())
                    .unwrap_or(group.collapsed);
                Some(SectionGroup {
                    id: group.id.clone(),
                    pulled: false,
                    collapsed: Some(collapsed),
                })
            })
            .collect();
        if passed_machines && drawn.is_empty() && section.content != "app" {
            continue;
        }
        let list = ListSection { id: section.id.clone(), groups: drawn };
        if passed_machines { after.push(list) } else { before.push(list) }
    }
    (before, after)
}

/// A row's identity (`SidebarNode.ID`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeId {
    Workspace(String),
    Group(String),
    Item(String),
}

/// A mapped row of a machine section: its identity and the document item that places it (a workspace's item, a
/// group's id, a listed item's id; none while its item is on the way).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MappedNode {
    pub id: NodeId,
    #[serde(default)]
    pub item: Option<String>,
}

/// One entry of a machine's document order: a workspace's item, a group or a link, by document item id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Entry {
    Workspace(String),
    Group(String),
    Link(String),
}

/// A machine section's row: a mapped row, or a document link the app makes a row of.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Placed {
    Node(NodeId),
    Link(String),
}

/// A machine section's rows in document order with its link rows (`machineNodes`); a row the document does not place
/// yet keeps its slot right before the placed row that follows it, and the rest end the list. No order, or one with
/// no link: the mapped rows as they are.
pub fn machine_nodes(nodes: &[MappedNode], order: Option<&[Entry]>) -> Vec<Placed> {
    let unchanged = || nodes.iter().map(|node| Placed::Node(node.id.clone())).collect();
    let Some(order) = order else { return unchanged() };
    if !order.iter().any(|entry| matches!(entry, Entry::Link(_))) {
        return unchanged();
    }
    let mut by_item: HashMap<&str, &NodeId> = HashMap::new();
    for node in nodes {
        if let Some(item) = &node.item {
            by_item.entry(item.as_str()).or_insert(&node.id);
        }
    }
    let key = |entry: &Entry| -> String {
        match entry {
            Entry::Workspace(item) | Entry::Group(item) | Entry::Link(item) => item.clone(),
        }
    };
    let placed_ids: HashSet<&NodeId> =
        order.iter().filter_map(|entry| by_item.get(key(entry).as_str()).copied()).collect();
    let mut before: HashMap<NodeId, Vec<NodeId>> = HashMap::new();
    let mut waiting: Vec<NodeId> = Vec::new();
    for node in nodes {
        if !placed_ids.contains(&node.id) {
            waiting.push(node.id.clone());
            continue;
        }
        if !waiting.is_empty() {
            before.insert(node.id.clone(), std::mem::take(&mut waiting));
        }
        waiting.clear();
    }
    let mut out: Vec<Placed> = Vec::new();
    let mut append = |out: &mut Vec<Placed>, id: NodeId, placed: Placed| {
        out.extend(before.remove(&id).unwrap_or_default().into_iter().map(Placed::Node));
        out.push(placed);
    };
    for entry in order {
        match entry {
            Entry::Workspace(item) | Entry::Group(item) => {
                if let Some(id) = by_item.remove(item.as_str()) {
                    append(&mut out, id.clone(), Placed::Node(id.clone()));
                }
            }
            Entry::Link(item) => {
                by_item.remove(item.as_str());
                append(&mut out, NodeId::Item(item.clone()), Placed::Link(item.clone()));
            }
        }
    }
    out.extend(waiting.into_iter().map(Placed::Node));
    out
}

/// The space of each band group's top-level group (a nested group's space is its top-level group's); the walk stops
/// after as many steps as there are groups (a parent cycle).
pub fn top_rooms(groups: &[BandGroup]) -> BTreeMap<String, Option<String>> {
    let by_id = first_by_id(groups);
    let mut rooms = BTreeMap::new();
    for group in groups {
        let mut top = group;
        for _ in 0..by_id.len() {
            let Some(parent) = top.parent.as_deref().and_then(|parent| by_id.get(parent)) else {
                break;
            };
            top = parent;
        }
        rooms.entry(group.id.clone()).or_insert_with(|| top.room.clone());
    }
    rooms
}

/// A group's url, tab or app member (`Group.Listed`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Listed {
    pub id: String,
    /// The workspace member's item it follows; none: first.
    #[serde(default)]
    pub after: Option<String>,
    /// The space it stores (`Listed.room`).
    #[serde(default)]
    pub room: Option<String>,
    /// The space its list item carries (`SidebarListItem.room`).
    #[serde(default)]
    pub item_room: Option<String>,
}

impl Listed {
    /// Whether a window on space `room` draws it in its group, whose own space is `group_room` (`Listed.lists`).
    pub fn lists(
        &self,
        room: Option<&str>,
        group_room: Option<&str>,
        spaces: Option<&BTreeSet<String>>,
    ) -> bool {
        let (Some(room), Some(own)) = (room, self.room.as_deref()) else { return true };
        let owner = owning_room(Some(own), spaces);
        owner == room || owner != owning_room(group_room, spaces)
    }
}

/// A member item a group draws and the workspace row it follows (none: first).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupItem {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
}

/// What a group's members are drawn from.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct Members {
    #[serde(default)]
    pub listed: Vec<Listed>,
    /// The workspace members' items in document order.
    #[serde(default)]
    pub member_items: Vec<String>,
    /// The workspace row each shown member item draws, by item.
    #[serde(default)]
    pub shown: BTreeMap<String, String>,
    /// It is a Pinned group.
    #[serde(default)]
    pub pinned: bool,
    /// It is a band group (its members carry its space filter).
    #[serde(default)]
    pub band: bool,
    /// Its top-level group's space (`top_rooms`).
    #[serde(default)]
    pub group_room: Option<String>,
    #[serde(default)]
    pub room: Option<String>,
    #[serde(default)]
    pub spaces: Option<BTreeSet<String>>,
}

/// A group's link, tab and app members (`withMemberItems`): each follows the workspace member it follows in the
/// document, else the nearest one before it that draws here. None: it has none, its rows stay as they are.
pub fn member_items(members: &Members) -> Option<Vec<GroupItem>> {
    if members.listed.is_empty() {
        return None;
    }
    let room = members.room.as_deref();
    let spaces = members.spaces.as_ref();
    let items = members
        .listed
        .iter()
        .filter(|listed| !members.band || listed.lists(room, members.group_room.as_deref(), spaces))
        .filter(|listed| match (members.pinned, listed.item_room.as_deref(), room) {
            (true, Some(item_room), Some(window)) => owning_room(Some(item_room), spaces) == window,
            _ => true,
        })
        .map(|listed| {
            let after = listed.after.as_ref().and_then(|after| {
                let index = members.member_items.iter().position(|item| item == after)?;
                members.member_items[..=index]
                    .iter()
                    .rev()
                    .find_map(|item| members.shown.get(item).cloned())
            });
            GroupItem { id: listed.id.clone(), after }
        })
        .collect();
    Some(items)
}

/// A row to mark: its document item (none while unplaced) and whether it is a group member.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MarkRow {
    #[serde(default)]
    pub item: Option<String>,
    #[serde(default)]
    pub in_group: bool,
}

/// A row's marks: it draws archived; it draws its pin mark (only a member).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mark {
    pub archived: bool,
    pub pinned_in_group: bool,
}

/// Each row's marks (`markingDocMarks`).
pub fn marks(
    rows: &[MarkRow],
    archived: &BTreeSet<String>,
    pinned: &BTreeSet<String>,
) -> Vec<Mark> {
    rows.iter()
        .map(|row| {
            let item = row.item.as_ref();
            Mark {
                archived: item.is_some_and(|item| archived.contains(item)),
                pinned_in_group: row.in_group && item.is_some_and(|item| pinned.contains(item)),
            }
        })
        .collect()
}

/// Each group's sort (`sortingGroups`): its stored one, else manual.
pub fn sorts(groups: &[String], group_sorts: &BTreeMap<String, Sort>) -> Vec<Sort> {
    groups.iter().map(|group| group_sorts.get(group).copied().unwrap_or_default()).collect()
}

/// A group's sort (`SidebarGroupSort`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Sort {
    #[default]
    Manual,
    Name,
    Recent,
}

/// A group member a sort orders.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SortMember {
    /// Pinned in its group: it stays first.
    #[serde(default)]
    pub pinned: bool,
    /// Archived: it stays last.
    #[serde(default)]
    pub archived: bool,
    /// Its title's place in the app's name order (Finder's order: equal titles share one).
    #[serde(default)]
    pub name_rank: i64,
    /// Its latest activity, seconds since 1970.
    #[serde(default)]
    pub last_activity: Option<f64>,
}

/// The members' indexes in `sort` (`SidebarGroupSort.ordered`): pinned first and archived last, as the document lists
/// them; inside each band Name by `name_rank` and Recent latest first with none after; ties keep the stored order.
pub fn ordered(sort: Sort, members: &[SortMember]) -> Vec<usize> {
    let mut indexes: Vec<usize> = (0..members.len()).collect();
    if sort == Sort::Manual || members.len() <= 1 {
        return indexes;
    }
    let band = |member: &SortMember| {
        if member.pinned {
            0
        } else if member.archived {
            2
        } else {
            1
        }
    };
    indexes.sort_by(|&a, &b| {
        let (left, right) = (&members[a], &members[b]);
        band(left).cmp(&band(right)).then_with(|| {
            let within = match sort {
                Sort::Manual => std::cmp::Ordering::Equal,
                Sort::Name => left.name_rank.cmp(&right.name_rank),
                Sort::Recent => match (left.last_activity, right.last_activity) {
                    (Some(x), Some(y)) if x != y => {
                        y.partial_cmp(&x).unwrap_or(std::cmp::Ordering::Equal)
                    }
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    _ => std::cmp::Ordering::Equal,
                },
            };
            within.then(a.cmp(&b))
        })
    });
    indexes
}

/// A request to the `sidebar_doc_listing` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{groups}`.
    ListedElsewhere {
        #[serde(default)]
        groups: Vec<BandGroup>,
        #[serde(default)]
        elsewhere: BTreeSet<String>,
    },
    /// `{groups}`.
    NotListedHere {
        #[serde(default)]
        groups: Vec<BandGroup>,
        #[serde(default)]
        elsewhere: BTreeSet<String>,
        #[serde(default)]
        room: Option<String>,
        #[serde(default)]
        spaces: Option<BTreeSet<String>>,
        #[serde(default)]
        listed_here: BTreeSet<String>,
    },
    /// `{before, after}`.
    Sections {
        #[serde(default)]
        layout: Vec<LayoutSection>,
        #[serde(default)]
        groups: Vec<BandGroup>,
        #[serde(default)]
        pulled: BTreeSet<String>,
        #[serde(default)]
        elsewhere: BTreeSet<String>,
        #[serde(default)]
        room: Option<String>,
        #[serde(default)]
        spaces: Option<BTreeSet<String>>,
        #[serde(default)]
        folds: Option<BTreeMap<String, bool>>,
    },
    /// `{nodes}`.
    MachineNodes {
        #[serde(default)]
        nodes: Vec<MappedNode>,
        #[serde(default)]
        order: Option<Vec<Entry>>,
    },
    /// `{rooms}`.
    TopRooms {
        #[serde(default)]
        groups: Vec<BandGroup>,
    },
    /// `{items}` (null: unchanged).
    MemberItems {
        #[serde(flatten)]
        members: Members,
    },
    /// `{marks}`.
    Marks {
        #[serde(default)]
        rows: Vec<MarkRow>,
        #[serde(default)]
        archived: BTreeSet<String>,
        #[serde(default)]
        pinned: BTreeSet<String>,
    },
    /// `{order}`: the members' indexes.
    Ordered {
        #[serde(default)]
        sort: Sort,
        #[serde(default)]
        members: Vec<SortMember>,
    },
    /// `{sorts}`.
    Sorts {
        #[serde(default)]
        groups: Vec<String>,
        #[serde(default)]
        group_sorts: BTreeMap<String, Sort>,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::ListedElsewhere { groups, elsewhere } => {
            json!({"groups": listed_elsewhere(&groups, &elsewhere)})
        }
        Request::NotListedHere { groups, elsewhere, room, spaces, listed_here } => {
            json!({"groups": not_listed_here(&groups, &elsewhere, room.as_deref(), spaces.as_ref(), &listed_here)})
        }
        Request::Sections { layout, groups, pulled, elsewhere, room, spaces, folds } => {
            let (before, after) = sections(
                &layout,
                &groups,
                &pulled,
                &elsewhere,
                room.as_deref(),
                spaces.as_ref(),
                folds.as_ref(),
            );
            json!({"before": before, "after": after})
        }
        Request::MachineNodes { nodes, order } => {
            json!({"nodes": machine_nodes(&nodes, order.as_deref())})
        }
        Request::TopRooms { groups } => json!({"rooms": top_rooms(&groups)}),
        Request::MemberItems { members } => json!({"items": member_items(&members)}),
        Request::Marks { rows, archived, pinned } => {
            json!({"marks": marks(&rows, &archived, &pinned)})
        }
        Request::Ordered { sort, members } => json!({"order": ordered(sort, &members)}),
        Request::Sorts { groups, group_sorts } => json!({"sorts": sorts(&groups, &group_sorts)}),
    }
}

#[cfg(test)]
#[path = "sidebar_doc_listing_tests.rs"]
mod tests;
