//! The sidebar's sections from one window's rows ([`view::view`]): what the
//! app's list draws, already regrouped, so the app only maps ids to its own
//! row models.
//!
//! - Every section that is not a machine's is a band section, in document
//!   order, holding its top-level items. A link, tab or app in Pinned
//!   carries its space (`extra.room`, else the default space).
//! - The machine sections become the workspace list: one
//!   [`ProjectedSection::Workspaces`] where the first one sits, carrying that
//!   section (the list shows its alignment and spacing).
//! - Each machine's rows become its nodes in the document's order: a
//!   workspace, a group (with its own members, its url, tab and app members
//!   and the workspace member each follows), or a link (any other item).
//!   Nested groups list flat, each after its parent.
//! - A group of a band section is a band group (in document order), with its
//!   open workspace members (rows that are not dimmed).
//! - A live workspace the document does not place yet is unplaced.
//!
//! The records come from the document the rows were drawn from (the mirror's
//! shown document: the confirmed one with the pending intents), so a pending
//! rename, new group or Chief draws with its rows.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use super::doc::Doc;
use super::model::*;
use super::view::Row;

/// The default space's id: an item that stores no space is its.
pub const DEFAULT_ROOM: &str = "default";

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Projection {
    /// The sections in document order, the workspace list where the first
    /// machine section sits (last when none shows).
    pub sections: Vec<ProjectedSection>,
    /// Each machine's nodes in order, by session id.
    pub machines: BTreeMap<String, Vec<Node>>,
    /// The item that places each workspace (any section).
    pub items: Vec<Member>,
    /// The machine section of each session.
    pub machine_sections: BTreeMap<String, SectionId>,
    /// The machine sections in the document's order.
    pub machine_order: Vec<SectionId>,
    /// Live workspaces the document does not place yet, in live order.
    pub unplaced: Vec<WorkspaceRef>,
    /// The groups of band sections, in document order.
    pub band_groups: Vec<Group>,
    /// The machine sections made remote groups.
    pub host_groups: Vec<SectionId>,
    /// The items whose rows draw archived (archived, or under an archived group).
    pub archived: Vec<ItemId>,
    /// Each group's sort other than manual, by group item.
    pub group_sorts: BTreeMap<ItemId, String>,
    /// The group members pinned inside their group.
    pub pinned_in_group: Vec<ItemId>,
    /// Each group's own chats-per-project cap (0 is All), by group item;
    /// absent: the setting ([`GROUP_ROW_LIMIT_KEY`]).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub group_row_limits: BTreeMap<ItemId, u32>,
    /// The rows each group's "Show N more" revealed past its cap
    /// ([`GROUP_REVEALED_KEY`]), by group item; absent: none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub group_revealed: BTreeMap<ItemId, u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ProjectedSection {
    /// The workspace list; `like` is the first machine section (its
    /// alignment and spacing), absent when no machine section shows.
    Workspaces {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        like: Option<Section>,
    },
    /// A band section (Pinned, custom, app) and its top-level items.
    Band { section: Section, items: Vec<BandItem> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BandItem {
    pub item: Item,
    /// The space a Pinned link, tab or app draws in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Node {
    Workspace {
        #[serde(rename = "ref")]
        reference: WorkspaceRef,
        item: ItemId,
    },
    Group {
        group: Group,
    },
    /// A url, tab or app item (any item that is not a workspace or a group).
    Link {
        item: Item,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Member {
    #[serde(rename = "ref")]
    pub reference: WorkspaceRef,
    pub item: ItemId,
}

/// A url, tab or app member and the workspace member's item it follows
/// (absent: first).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Listed {
    pub item: Item,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<ItemId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    pub id: ItemId,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub collapsed: bool,
    /// The document section that holds it.
    pub section: SectionId,
    /// It sits in the Pinned band.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pinned: bool,
    /// The workspace members, in order.
    pub members: Vec<Member>,
    /// The url, tab and app members, in order.
    pub listed: Vec<Listed>,
    /// The group it sits in (a nested group); absent at the top level.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ItemId>,
    /// Group levels above it: 0 at the top level.
    pub depth: u8,
    /// The open workspace members (a band group only): rows not dimmed.
    pub open_members: Vec<WorkspaceRef>,
    /// The space it was made in (`profile`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
}

impl Group {
    fn new(item: &Item, row: &Row, section: &Section) -> Option<Group> {
        let Body::Group { name, color, icon, collapsed, profile } = &item.body else { return None };
        Some(Group {
            id: item.id.clone(),
            name: name.clone(),
            color: color.clone(),
            icon: icon.clone(),
            collapsed: *collapsed,
            section: section.id.clone(),
            pinned: section.kind == SectionKind::Pinned,
            members: Vec::new(),
            listed: Vec::new(),
            parent: if row.depth > 0 {
                row.parent.clone().or_else(|| item.parent.clone())
            } else {
                None
            },
            depth: row.depth,
            open_members: Vec::new(),
            room: profile.clone(),
        })
    }

    /// A workspace member, or a url, tab or app member after the last
    /// workspace member so far. A group member adds nothing (it is its own node).
    fn add(&mut self, item: &Item) {
        match &item.body {
            Body::Workspace { reference } => {
                self.members.push(Member { reference: reference.clone(), item: item.id.clone() });
            }
            Body::Group { .. } => {}
            _ => self.listed.push(Listed {
                item: item.clone(),
                after: self.members.last().map(|member| member.item.clone()),
            }),
        }
    }
}

/// A Pinned link, tab or app belongs to one space; any other item does not.
fn belongs_to_a_space(body: &Body) -> bool {
    matches!(body, Body::Url { .. } | Body::Tab { .. } | Body::App { .. })
}

/// Each machine's nodes while they are built: a group is held apart until
/// the end, so a member row writes it in place.
#[derive(Default)]
struct MachineNodes {
    slots: BTreeMap<String, Vec<Slot>>,
    groups: Vec<Group>,
    /// The last group listed with an id, by session: a member row goes to it.
    last_group: HashMap<String, HashMap<ItemId, usize>>,
}

enum Slot {
    Node(Box<Node>),
    Group(usize),
}

impl MachineNodes {
    fn push(&mut self, node: Node, session: &str) {
        self.slots.entry(session.to_string()).or_default().push(Slot::Node(Box::new(node)));
    }

    fn push_group(&mut self, group: Group, session: &str) {
        let index = self.groups.len();
        self.last_group.entry(session.to_string()).or_default().insert(group.id.clone(), index);
        self.slots.entry(session.to_string()).or_default().push(Slot::Group(index));
        self.groups.push(group);
    }

    fn add(&mut self, item: &Item, parent: &str, session: &str) {
        if let Some(&at) = self.last_group.get(session).and_then(|groups| groups.get(parent))
            && let Some(group) = self.groups.get_mut(at)
        {
            group.add(item);
        }
    }

    fn nodes(self) -> BTreeMap<String, Vec<Node>> {
        let mut groups: Vec<Option<Group>> = self.groups.into_iter().map(Some).collect();
        self.slots
            .into_iter()
            .map(|(session, slots)| {
                let nodes = slots
                    .into_iter()
                    .filter_map(|slot| match slot {
                        Slot::Node(node) => Some(*node),
                        Slot::Group(index) => groups
                            .get_mut(index)
                            .and_then(Option::take)
                            .map(|group| Node::Group { group }),
                    })
                    .collect();
                (session, nodes)
            })
            .collect()
    }
}

/// The session of a machine section's id (`sec_m_<session>`), else the id.
fn session_of(id: &str) -> &str {
    id.strip_prefix(MACHINE_SECTION_PREFIX).unwrap_or(id)
}

/// The sections `rows` (one window's view of `doc`) draw.
pub fn project(doc: &Doc, rows: &[Row]) -> Projection {
    let mut out = Projection::default();
    let mut machines = MachineNodes::default();
    let mut placed_list = false;
    // Band sections by id: their index in `out.sections`.
    let mut band_index: HashMap<SectionId, usize> = HashMap::new();
    let mut stand_ins: HashMap<SectionId, Section> = HashMap::new();
    for row in rows {
        if row.archived
            && let Some(id) = &row.item
        {
            out.archived.push(id.clone());
        }
        // A live machine without a stored section yet still lists, unplaced.
        let section = match doc.section(&row.section) {
            Some(section) => section,
            None => stand_ins.entry(row.section.clone()).or_insert_with(|| {
                let session = row
                    .reference
                    .as_ref()
                    .map_or_else(|| session_of(&row.section).to_string(), |r| r.session_id.clone());
                let mut section = Section::machine(&session);
                section.id = row.section.clone();
                section
            }),
        };
        let item = row.item.as_deref().and_then(|id| doc.item(id));
        if let Some(session) = section.kind.machine() {
            if !out.machine_sections.contains_key(session) {
                out.machine_order.push(section.id.clone());
            }
            out.machine_sections.insert(session.to_string(), section.id.clone());
            if !placed_list {
                placed_list = true;
                out.sections.push(ProjectedSection::Workspaces { like: Some(section.clone()) });
            }
            let Some(item) = item else {
                if row.item.is_none()
                    && let Some(reference) = &row.reference
                {
                    out.unplaced.push(reference.clone());
                }
                continue;
            };
            let parent =
                (row.depth > 0).then(|| row.parent.as_ref().or(item.parent.as_ref())).flatten();
            match &item.body {
                Body::Workspace { reference } => {
                    out.items.push(Member { reference: reference.clone(), item: item.id.clone() });
                    match parent {
                        Some(parent) => machines.add(item, parent, session),
                        None => machines.push(
                            Node::Workspace { reference: reference.clone(), item: item.id.clone() },
                            session,
                        ),
                    }
                }
                Body::Group { .. } => {
                    if let Some(group) = Group::new(item, row, section) {
                        machines.push_group(group, session);
                    }
                }
                _ => match (row.depth, parent) {
                    (0, _) => machines.push(Node::Link { item: item.clone() }, session),
                    (_, Some(parent)) => machines.add(item, parent, session),
                    (_, None) => {}
                },
            }
            continue;
        }
        let index = *band_index.entry(section.id.clone()).or_insert_with(|| {
            let index = out.sections.len();
            out.sections
                .push(ProjectedSection::Band { section: section.clone(), items: Vec::new() });
            index
        });
        let Some(item) = item else { continue };
        if let Some(reference) = item.body.workspace() {
            // Members of a band group too: they list once.
            out.items.push(Member { reference: reference.clone(), item: item.id.clone() });
        }
        if item.body.is_group() {
            out.band_groups.extend(Group::new(item, row, section));
        } else if row.depth > 0 {
            let parent = row.parent.as_ref().or(item.parent.as_ref());
            if let Some(group) =
                parent.and_then(|parent| out.band_groups.iter_mut().rev().find(|g| &g.id == parent))
            {
                group.add(item);
                if let Some(reference) = item.body.workspace()
                    && !row.dimmed
                {
                    group.open_members.push(reference.clone());
                }
            }
        } else if let Some(ProjectedSection::Band { items, .. }) = out.sections.get_mut(index) {
            let room = (section.kind == SectionKind::Pinned && belongs_to_a_space(&item.body))
                .then(|| {
                    item.extra
                        .get("room")
                        .and_then(|room| room.as_str())
                        .unwrap_or(DEFAULT_ROOM)
                        .to_string()
                });
            items.push(BandItem { item: item.clone(), room });
        }
    }
    if !placed_list {
        out.sections.push(ProjectedSection::Workspaces { like: None });
    }
    out.machines = machines.nodes();
    out.host_groups = doc
        .sections()
        .iter()
        .filter(|section| section.host_group && section.kind.machine().is_some())
        .map(|section| section.id.clone())
        .collect();
    for item in doc.items_unordered() {
        if item.body.is_group()
            && let Some(sort) = item.group_sort().value()
        {
            out.group_sorts.insert(item.id.clone(), sort.to_string());
        }
        if item.body.is_group() {
            if let Some(cap) = item.group_row_limit() {
                out.group_row_limits.insert(item.id.clone(), cap);
            }
            let revealed = item.group_revealed();
            if revealed > 0 {
                out.group_revealed.insert(item.id.clone(), revealed);
            }
        }
        if item.pinned_in_group() {
            out.pinned_in_group.push(item.id.clone());
        }
    }
    out.pinned_in_group.sort();
    out
}
