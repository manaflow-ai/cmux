//! The document, its ops and its refusal codes (CONTRACT.md "Rust").
//!
//! Wire shapes: a section's `kind` and an item's `body` are objects tagged by
//! `type` (`{"type":"machine","session_id":"..."}`,
//! `{"type":"workspace","ref":{"session_id":"...","workspace_id":"..."}}`).
//! Sections, items and workspace refs keep unknown keys in `extra`, so a
//! newer client's fields survive a round trip through an older daemon.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub use crate::sidebar_layout::{ArrangementLayout, Look, Region};

pub type SectionId = String;
pub type ItemId = String;

/// The one Pinned section.
pub const PINNED_SECTION_ID: &str = "sec_pinned";
/// The prefix of a machine section id: `sec_m_<session_id>`.
pub const MACHINE_SECTION_PREFIX: &str = "sec_m_";
/// A key longer than this renumbers its siblings.
pub const MAX_ORDER_KEY_CHARS: usize = 32;
pub const MAX_TITLE_CHARS: usize = 80;
pub const MAX_SECTIONS: usize = 64;
pub const MAX_ITEMS: usize = 20_000;

/// The id of `session_id`'s machine section.
pub fn machine_section_id(session_id: &str) -> SectionId {
    format!("{MACHINE_SECTION_PREFIX}{session_id}")
}

/// The id of a workspace's item. Deterministic, so a client can name the
/// item of a workspace it adopts (`adopt` then `move` in one `sidebar.apply`)
/// and adopting twice is a no-op.
pub fn workspace_item_id(reference: &WorkspaceRef) -> ItemId {
    format!("itm_w_{}_{}", reference.session_id, reference.workspace_id)
}

/// The id of the item of an old personal workspace group.
pub fn group_item_id(group_id: &str) -> ItemId {
    format!("itm_g_{group_id}")
}

/// A workspace on one machine. `workspace_ref` (in `extra`) names a
/// workspace whose public id was not known when it was placed (another
/// machine's row from the old personal store, by the same reference a
/// `workspace_placement` snapshot carries); `adopt` resolves it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceRef {
    pub session_id: String,
    pub workspace_id: String,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl WorkspaceRef {
    pub fn new(session_id: &str, workspace_id: &str) -> Self {
        WorkspaceRef {
            session_id: session_id.into(),
            workspace_id: workspace_id.into(),
            extra: Map::new(),
        }
    }

    /// Same workspace (session and id; `extra` does not count).
    pub fn same(&self, other: &WorkspaceRef) -> bool {
        self.session_id == other.session_id && self.workspace_id == other.workspace_id
    }

    /// The placement reference of an item placed before its public id was
    /// known.
    pub fn placement_ref(&self) -> Option<&str> {
        self.extra.get("workspace_ref").and_then(Value::as_str)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SectionKind {
    Machine { session_id: String },
    Pinned,
    Custom,
    App { contribution: String },
    Builtin,
}

impl SectionKind {
    pub fn machine(&self) -> Option<&str> {
        match self {
            SectionKind::Machine { session_id } => Some(session_id),
            _ => None,
        }
    }

    /// Whether a closed workspace or an empty group stays in the section.
    pub fn keeps_closed_by_default(&self) -> bool {
        matches!(self, SectionKind::Pinned | SectionKind::Custom)
    }
}

fn yes() -> bool {
    true
}

fn middle() -> Region {
    Region::Middle
}

fn list_look() -> Look {
    Look::List
}

fn list_layout() -> ArrangementLayout {
    ArrangementLayout::List
}

/// A string revision on the wire ("12"); a number reads too.
mod decimal {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &u64, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Either {
            Text(String),
            Number(u64),
        }
        match Either::deserialize(deserializer)? {
            Either::Text(text) => text.parse().map_err(serde::de::Error::custom),
            Either::Number(number) => Ok(number),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub id: SectionId,
    pub kind: SectionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default = "yes")]
    pub shows_title: bool,
    #[serde(default = "middle")]
    pub region: Region,
    #[serde(default = "list_look")]
    pub look: Look,
    #[serde(default = "list_layout")]
    pub arrangement: ArrangementLayout,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub columns: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_rows: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    #[serde(default)]
    pub order: String,
    #[serde(default)]
    pub keeps_closed: bool,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Section {
    /// A section of `kind` with the contract's defaults: Pinned and custom
    /// sections keep closed items, Pinned shows no title.
    pub fn new(id: &str, kind: SectionKind, region: Region) -> Self {
        let keeps_closed = kind.keeps_closed_by_default();
        let shows_title = !matches!(kind, SectionKind::Pinned);
        Section {
            id: id.into(),
            kind,
            title: None,
            shows_title,
            region,
            look: Look::List,
            arrangement: ArrangementLayout::List,
            columns: None,
            max_rows: None,
            room: None,
            order: String::new(),
            keeps_closed,
            extra: Map::new(),
        }
    }

    pub fn machine(session_id: &str) -> Self {
        Section::new(
            &machine_section_id(session_id),
            SectionKind::Machine { session_id: session_id.into() },
            Region::Middle,
        )
    }

    pub fn pinned() -> Self {
        let mut section = Section::new(PINNED_SECTION_ID, SectionKind::Pinned, Region::Top);
        section.look = Look::BuiltIn;
        section
    }

    pub fn region_rank(&self) -> u8 {
        match self.region {
            Region::Top => 0,
            Region::Middle => 1,
            Region::Bottom => 2,
            Region::Other(_) => 3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Body {
    Workspace {
        #[serde(rename = "ref")]
        reference: WorkspaceRef,
    },
    Group {
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default)]
        collapsed: bool,
        /// The room (wire name `profile`) of an old personal group.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile: Option<String>,
    },
    Builtin {
        id: String,
    },
    App {
        id: String,
    },
    Url {
        url: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    Tab {
        #[serde(rename = "ref")]
        reference: String,
    },
    Room {
        id: String,
    },
    SavedGroup {
        id: String,
    },
    /// An old layout item ref of a kind this build does not know, kept
    /// verbatim.
    Ref {
        kind: String,
        value: String,
    },
}

impl Body {
    pub fn kind_name(&self) -> &'static str {
        match self {
            Body::Workspace { .. } => "workspace",
            Body::Group { .. } => "group",
            Body::Builtin { .. } => "builtin",
            Body::App { .. } => "app",
            Body::Url { .. } => "url",
            Body::Tab { .. } => "tab",
            Body::Room { .. } => "room",
            Body::SavedGroup { .. } => "saved_group",
            Body::Ref { .. } => "ref",
        }
    }

    pub fn workspace(&self) -> Option<&WorkspaceRef> {
        match self {
            Body::Workspace { reference } => Some(reference),
            _ => None,
        }
    }

    pub fn is_group(&self) -> bool {
        matches!(self, Body::Group { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: ItemId,
    pub section: SectionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ItemId>,
    #[serde(default)]
    pub order: String,
    pub body: Body,
    #[serde(default = "yes")]
    pub shows_label: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span: Option<i64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Item {
    pub fn new(id: &str, section: &str, body: Body) -> Self {
        Item {
            id: id.into(),
            section: section.into(),
            parent: None,
            order: String::new(),
            body,
            shows_label: true,
            span: None,
            extra: Map::new(),
        }
    }

    pub fn workspace(reference: WorkspaceRef, section: &str) -> Self {
        Item::new(&workspace_item_id(&reference), section, Body::Workspace { reference })
    }

    /// The label stored with the item (an old tile's workspace name), drawn
    /// while the workspace is closed.
    pub fn label(&self) -> Option<&str> {
        self.extra.get("label").and_then(Value::as_str)
    }
}

/// The document. `sections` are in display order (region, then order key);
/// `items` in section order, then parent, then order key.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Doc {
    #[serde(with = "decimal")]
    pub revision: u64,
    #[serde(default)]
    pub sections: Vec<Section>,
    #[serde(default)]
    pub items: Vec<Item>,
}

impl Doc {
    pub fn section(&self, id: &str) -> Option<&Section> {
        self.sections.iter().find(|section| section.id == id)
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|item| item.id == id)
    }

    pub fn item_mut(&mut self, id: &str) -> Option<&mut Item> {
        self.items.iter_mut().find(|item| item.id == id)
    }

    /// The item that places `reference`.
    pub fn workspace_item(&self, reference: &WorkspaceRef) -> Option<&Item> {
        self.items
            .iter()
            .find(|item| item.body.workspace().is_some_and(|placed| placed.same(reference)))
    }

    /// The children of `parent` (or the top-level items of `section`), in
    /// order.
    pub fn children(&self, section: &str, parent: Option<&str>) -> Vec<&Item> {
        let mut children: Vec<&Item> = self
            .items
            .iter()
            .filter(|item| item.section == section && item.parent.as_deref() == parent)
            .collect();
        children.sort_by(|a, b| a.order.cmp(&b.order).then_with(|| a.id.cmp(&b.id)));
        children
    }

    /// The machine a group or workspace item belongs to: a workspace's
    /// session, a group's first child's session (None for an empty group or
    /// another body).
    pub fn item_machine(&self, item: &Item) -> Option<String> {
        match &item.body {
            Body::Workspace { reference } => Some(reference.session_id.clone()),
            Body::Group { .. } => self
                .items
                .iter()
                .filter(|child| child.parent.as_deref() == Some(item.id.as_str()))
                .find_map(|child| child.body.workspace().map(|r| r.session_id.clone())),
            _ => None,
        }
    }

    pub fn machine_section(&self, session_id: &str) -> Option<&Section> {
        self.sections.iter().find(|section| section.kind.machine() == Some(session_id))
    }

    /// Sort sections and items into display order.
    pub fn normalize(&mut self) {
        self.sections.sort_by(|a, b| {
            a.region_rank()
                .cmp(&b.region_rank())
                .then_with(|| a.order.cmp(&b.order))
                .then_with(|| a.id.cmp(&b.id))
        });
        let rank: std::collections::HashMap<&str, usize> =
            self.sections.iter().enumerate().map(|(i, s)| (s.id.as_str(), i)).collect();
        let parent_order: std::collections::HashMap<String, String> = self
            .items
            .iter()
            .filter(|item| item.body.is_group())
            .map(|item| (item.id.clone(), item.order.clone()))
            .collect();
        // Display order: section, then the top-level key of the item (its
        // own, or its group's), then children after their group.
        self.items.sort_by(|a, b| {
            let key = |item: &Item| {
                let top = match &item.parent {
                    Some(parent) => parent_order.get(parent).cloned().unwrap_or_default(),
                    None => item.order.clone(),
                };
                let group = item.parent.clone().unwrap_or_else(|| item.id.clone());
                let depth = usize::from(item.parent.is_some());
                (
                    rank.get(item.section.as_str()).copied().unwrap_or(usize::MAX),
                    top,
                    group,
                    depth,
                    item.order.clone(),
                    item.id.clone(),
                )
            };
            key(a).cmp(&key(b))
        });
    }
}

/// Where a moved or added item lands: in `section`, under `parent` (a
/// group) or at its top level, before or after a sibling, or at an index
/// among the siblings (end when none is given).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Target {
    pub section: SectionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<ItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<ItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

impl Target {
    pub fn end(section: &str) -> Self {
        Target { section: section.into(), ..Target::default() }
    }
}

/// Where a section lands among its region's sections.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SectionPlace {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<Region>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<SectionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<SectionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

/// A field that may be absent (keep), null (clear) or set.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Patch<T> {
    #[default]
    Keep,
    Clear,
    Set(T),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Patch<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<T>::deserialize(deserializer)? {
            None => Patch::Clear,
            Some(value) => Patch::Set(value),
        })
    }
}

impl<T: Serialize> Serialize for Patch<T> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Patch::Set(value) => value.serialize(serializer),
            _ => serializer.serialize_none(),
        }
    }
}

impl<T: Clone> Patch<T> {
    pub fn apply(&self, field: &mut Option<T>) {
        match self {
            Patch::Keep => {}
            Patch::Clear => *field = None,
            Patch::Set(value) => *field = Some(value.clone()),
        }
    }

    pub fn is_keep(&self) -> bool {
        matches!(self, Patch::Keep)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SectionPatch {
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub title: Patch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_title: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub look: Option<Look>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arrangement: Option<ArrangementLayout>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub columns: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub max_rows: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub room: Patch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keeps_closed: Option<bool>,
}

/// An item's own fields; a group's fields go through `group.update`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ItemPatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_label: Option<bool>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub span: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub label: Patch<String>,
    /// A url item's title.
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub title: Patch<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GroupPatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub color: Patch<String>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub icon: Patch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<bool>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub profile: Patch<String>,
}

/// A new item: its id (minted by the daemon when absent), body and fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewItem {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<ItemId>,
    pub body: Body,
    #[serde(default = "yes")]
    pub shows_label: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span: Option<i64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// One change, tagged by `op`. The wire methods map onto these
/// (`sidebar.move` is `move`, `sidebar.item.add` is `item.add`, ...);
/// `sidebar.apply` takes a list of them, including the raw `*.put` and
/// `*.delete` ops an inverse is made of.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op")]
pub enum Op {
    #[serde(rename = "move")]
    Move { items: Vec<ItemId>, to: Target },
    #[serde(rename = "pin")]
    Pin { items: Vec<ItemId> },
    #[serde(rename = "unpin")]
    Unpin { items: Vec<ItemId> },
    #[serde(rename = "item.add")]
    ItemAdd { item: NewItem, to: Target },
    #[serde(rename = "item.remove")]
    ItemRemove { id: ItemId },
    #[serde(rename = "item.update")]
    ItemUpdate { id: ItemId, patch: ItemPatch },
    #[serde(rename = "section.add")]
    SectionAdd {
        section: Section,
        #[serde(default)]
        place: SectionPlace,
    },
    #[serde(rename = "section.update")]
    SectionUpdate { id: SectionId, patch: SectionPatch },
    #[serde(rename = "section.move")]
    SectionMove { id: SectionId, place: SectionPlace },
    #[serde(rename = "section.remove")]
    SectionRemove { id: SectionId },
    #[serde(rename = "group.create")]
    GroupCreate {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<ItemId>,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile: Option<String>,
        #[serde(default)]
        items: Vec<ItemId>,
        /// Where the group lands; default: the place of its first item.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<Target>,
    },
    #[serde(rename = "group.update")]
    GroupUpdate { id: ItemId, patch: GroupPatch },
    #[serde(rename = "group.ungroup")]
    GroupUngroup { id: ItemId },
    /// Place live workspaces that have no item yet, at `to` (default: the
    /// end of each one's machine section). A ref whose `workspace_ref`
    /// matches an unresolved item resolves that item in place.
    #[serde(rename = "adopt")]
    Adopt {
        refs: Vec<WorkspaceRef>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<Target>,
    },
    #[serde(rename = "item.put")]
    ItemPut { item: Item },
    #[serde(rename = "item.delete")]
    ItemDelete { id: ItemId },
    #[serde(rename = "section.put")]
    SectionPut { section: Section },
    #[serde(rename = "section.delete")]
    SectionDelete { id: SectionId },
}

/// Why an op was refused; `as_str` is the wire reason
/// (`validation.invalid` with `details.reason`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    UnknownSection,
    UnknownItem,
    DuplicateId,
    DuplicateRef,
    CrossMachine,
    ProviderOwned,
    Nesting,
    InvalidTarget,
    MachineRequired,
    NoMachine,
    InvalidTitle,
    InvalidValue,
    TooMany,
}

impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::UnknownSection => "unknown_section",
            Refusal::UnknownItem => "unknown_item",
            Refusal::DuplicateId => "duplicate_id",
            Refusal::DuplicateRef => "duplicate_ref",
            Refusal::CrossMachine => "cross_machine",
            Refusal::ProviderOwned => "provider_owned",
            Refusal::Nesting => "nesting",
            Refusal::InvalidTarget => "invalid_target",
            Refusal::MachineRequired => "machine_required",
            Refusal::NoMachine => "no_machine",
            Refusal::InvalidTitle => "invalid_title",
            Refusal::InvalidValue => "invalid_value",
            Refusal::TooMany => "too_many",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}
