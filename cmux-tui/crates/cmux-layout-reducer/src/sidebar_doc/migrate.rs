//! The one-time move from the old sidebar stores to the document: the
//! section layout (`sidebar-layout-v1`, with its `sec_pinned` tiles), the
//! personal order of workspaces and groups (`personal-mixed-order-v1`), the
//! pinned (saved) groups (`workspace-group-pin-v1`) and the local pin flags
//! (`workspace-pin-v1`). Pure: the daemon reads the old tables into a
//! [`LegacyInput`] and stores the returned document; the old tables stay.
//!
//! Rules:
//! - Layout sections keep their place, title, region, look, arrangement
//!   (layout, align, gap, columns), room, row limit and unknown keys (in
//!   `extra`; an arrangement's unknown keys in `extra.arrangement`). The `workspaces` section becomes one machine
//!   section per machine (this machine first); `sec_pinned` becomes Pinned;
//!   an app section stays an app section; a built-in items section (Home,
//!   App Store, the account band) becomes a built-in section; any other
//!   items section is a custom section. Pinned is made (after `sec_top`,
//!   else first in the top region) when the layout has none.
//! - A workspace is placed once, by the first rule that places it: a layout
//!   item (tile or top row, in section order), then a pin flag (into
//!   Pinned), then a pinned group's membership (the group goes into
//!   Pinned: pinned now means kept), then its personal row.
//! - A group keeps its name, color, icon, collapse and room. Its machine is
//!   its first member's that no earlier rule placed (this machine for an
//!   empty group); members of another machine stay loose in their own
//!   machine section (a group is one machine).
//! - Each sibling list gets short, evenly spaced order keys.
//! - Another machine's personal row has no public workspace id in this
//!   store: it is placed by its placement reference (`workspace_ref`,
//!   `unresolved`) and resolved by the first `adopt` that names it.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::doc::Doc;
use super::model::*;
use super::order_key;
use crate::sidebar_layout::{self, Content};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyMachine {
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

/// One personal workspace row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyWorkspace {
    pub session_id: String,
    pub workspace_key: String,
    /// The public id, when this store knows it (this machine's workspaces).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
}

impl LegacyWorkspace {
    pub fn reference(&self) -> WorkspaceRef {
        match &self.workspace_id {
            Some(id) => WorkspaceRef::new(&self.session_id, id),
            None => {
                let mut reference = WorkspaceRef::new(&self.session_id, &self.workspace_key);
                reference.extra.insert("workspace_ref".into(), self.workspace_key.clone().into());
                reference.extra.insert("unresolved".into(), Value::Bool(true));
                reference
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyGroup {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default)]
    pub collapsed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default)]
    pub pinned: bool,
}

/// One entry of the personal sidebar order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LegacyEntry {
    Workspace { workspace: LegacyWorkspace },
    Group { group: LegacyGroup, members: Vec<LegacyWorkspace> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LegacyInput {
    /// This machine's session (registry id).
    pub local_session: String,
    /// Known machines; this machine first.
    pub machines: Vec<LegacyMachine>,
    pub layout: sidebar_layout::Document,
    /// The personal order, every machine's rows.
    pub entries: Vec<LegacyEntry>,
    /// This machine's workspaces with the old pin flag, in order.
    pub pinned_flags: Vec<WorkspaceRef>,
    /// Display names of workspaces, stored as the label of a moved item.
    #[serde(default)]
    pub labels: Vec<(WorkspaceRef, String)>,
}

/// The new layout ref value `<session>:<workspace>` as a workspace ref.
pub fn parse_layout_workspace(value: &str) -> Option<WorkspaceRef> {
    let (session, workspace) = value.split_once(':')?;
    (!session.is_empty() && !workspace.is_empty()).then(|| WorkspaceRef::new(session, workspace))
}

/// The body of an old layout item ref.
pub fn body_of_layout_ref(reference: &sidebar_layout::ItemRef) -> Body {
    let value = reference.value.clone();
    match reference.kind.as_str() {
        "workspace" => match parse_layout_workspace(&value) {
            Some(reference) => Body::Workspace { reference },
            None => Body::Ref { kind: reference.kind.clone(), value },
        },
        "built_in" => Body::Builtin { id: value },
        "app" => Body::App { id: value },
        "url" => Body::Url { url: value, title: None, icon_url: None },
        "tab" => Body::Tab { reference: value },
        "room" => Body::Room { id: value },
        "saved_group" => Body::SavedGroup { id: value },
        other => Body::Ref { kind: other.into(), value },
    }
}

/// The old layout ref of a body (the inverse of [`body_of_layout_ref`]);
/// None for a group, which the old layout cannot show.
pub fn layout_ref_of_body(body: &Body) -> Option<sidebar_layout::ItemRef> {
    let (kind, value) = match body {
        Body::Workspace { reference } => {
            ("workspace", format!("{}:{}", reference.session_id, reference.workspace_id))
        }
        Body::Group { .. } => return None,
        Body::Builtin { id } => ("built_in", id.clone()),
        Body::App { id } => ("app", id.clone()),
        Body::Url { url, .. } => ("url", url.clone()),
        Body::Tab { reference } => ("tab", reference.clone()),
        Body::Room { id } => ("room", id.clone()),
        Body::SavedGroup { id } => ("saved_group", id.clone()),
        Body::Ref { kind, value } => return Some(sidebar_layout::ItemRef::new(kind, value)),
    };
    Some(sidebar_layout::ItemRef::new(kind, &value))
}

struct Builder {
    sections: Vec<Section>,
    items: Vec<Item>,
    ids: HashSet<String>,
    placed: HashSet<(String, String)>,
    machines: Vec<String>,
}

impl Builder {
    fn is_placed(&self, reference: &WorkspaceRef) -> bool {
        self.placed.contains(&(reference.session_id.clone(), reference.workspace_id.clone()))
    }

    fn mark(&mut self, reference: &WorkspaceRef) {
        self.placed.insert((reference.session_id.clone(), reference.workspace_id.clone()));
    }

    /// Append `item` to its sibling list (keys are given at the end).
    fn push(&mut self, mut item: Item) {
        item.lift_icon_url();
        self.ids.insert(item.id.clone());
        self.items.push(item);
    }

    fn has_item(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    fn machine_section(&mut self, session: &str) -> SectionId {
        let id = machine_section_id(session);
        if !self.sections.iter().any(|section| section.id == id) {
            // A machine seen only in the personal rows: after the last
            // machine section (or in the middle region at its end).
            let mut section = Section::machine(session);
            let last = self
                .sections
                .iter()
                .filter(|s| s.region == Region::Middle)
                .map(|s| s.order.clone())
                .max();
            section.order = order_key::between(last.as_deref(), None);
            self.sections.push(section);
            self.machines.push(session.into());
        }
        id
    }

    fn place_workspace(
        &mut self,
        workspace: &WorkspaceRef,
        section: &str,
        parent: Option<&str>,
        label: Option<&String>,
    ) {
        if self.is_placed(workspace) {
            return;
        }
        self.mark(workspace);
        let mut item = Item::workspace(workspace.clone(), section);
        item.parent = parent.map(str::to_string);
        if let Some(label) = label {
            item.extra.insert("label".into(), label.clone().into());
        }
        self.push(item);
    }

    /// A group item in `section` holding its unplaced members of the group's
    /// machine; members of another machine go loose to their own section.
    fn place_group(
        &mut self,
        group: &LegacyGroup,
        members: &[LegacyWorkspace],
        section: Option<&str>,
        labels: &[(WorkspaceRef, String)],
    ) {
        let refs: Vec<WorkspaceRef> = members
            .iter()
            .map(LegacyWorkspace::reference)
            .filter(|reference| !self.is_placed(reference))
            .collect();
        let machine = refs
            .first()
            .map(|r| r.session_id.clone())
            .unwrap_or_else(|| self.machines.first().cloned().unwrap_or_default());
        let section = match section {
            Some(section) => section.to_string(),
            None => self.machine_section(&machine),
        };
        let id = group_item_id(&group.id);
        if self.has_item(&id) {
            return;
        }
        self.push(Item::new(
            &id,
            &section,
            Body::Group {
                name: group.name.clone(),
                color: group.color.clone(),
                icon: group.icon.clone(),
                collapsed: group.collapsed,
                profile: group.profile.clone(),
            },
        ));
        let label = |reference: &WorkspaceRef| {
            labels.iter().find(|(r, _)| r.same(reference)).map(|(_, label)| label)
        };
        for reference in refs {
            let label = label(&reference).cloned();
            if reference.session_id == machine {
                self.place_workspace(&reference, &section, Some(&id), label.as_ref());
            } else {
                let own = self.machine_section(&reference.session_id);
                self.place_workspace(&reference, &own, None, label.as_ref());
            }
        }
    }
}

/// A document section from an old layout section (no items, no order).
pub fn section_from_layout(section: &sidebar_layout::Section, kind: SectionKind) -> Section {
    let mut new = Section::new(&section.id, kind, section.region.clone());
    new.title = section.title.clone();
    new.shows_title = section.shows_title;
    new.look = section.look.clone();
    new.arrangement = match &section.arrangement.layout {
        ArrangementLayout::Tiles => ArrangementLayout::Grid,
        other => other.clone(),
    };
    new.align = section.arrangement.align.clone();
    new.gap = section.arrangement.gap;
    new.columns = section.arrangement.columns;
    new.max_rows = section.max_rows;
    new.room = section.room.clone();
    new.extra = section.extra.clone();
    if !section.arrangement.extra.is_empty() {
        new.extra.insert("arrangement".into(), Value::Object(section.arrangement.extra.clone()));
    }
    new
}

/// The document kind of an old layout section that holds items (`Items` or
/// a newer content kind): Pinned, built-in (look `built_in`) or custom.
pub fn kind_of_layout_items_section(section: &sidebar_layout::Section) -> SectionKind {
    if section.id == PINNED_SECTION_ID {
        SectionKind::Pinned
    } else if section.look == Look::BuiltIn {
        SectionKind::Builtin
    } else {
        SectionKind::Custom
    }
}

/// The document the old stores describe (revision 0: the first change is 1).
pub fn migrate(input: &LegacyInput) -> Doc {
    let mut builder = Builder {
        sections: Vec::new(),
        items: Vec::new(),
        ids: HashSet::new(),
        placed: HashSet::new(),
        machines: Vec::new(),
    };
    let mut machine_ids: Vec<String> = Vec::new();
    for machine in
        std::iter::once(&input.local_session).chain(input.machines.iter().map(|m| &m.session_id))
    {
        if !machine_ids.contains(machine) {
            machine_ids.push(machine.clone());
        }
    }
    let title_of = |session: &str| {
        input.machines.iter().find(|m| m.session_id == session).and_then(|m| m.title.clone())
    };
    // Sections, in layout order.
    let mut sections: Vec<Section> = Vec::new();
    let mut layout_items: Vec<(SectionId, &sidebar_layout::Item)> = Vec::new();
    for section in &input.layout.sections {
        match &section.content {
            Content::Workspaces => {
                for session in &machine_ids {
                    let mut machine = Section::machine(session);
                    machine.region = section.region.clone();
                    machine.title = title_of(session);
                    machine.room = section.room.clone();
                    machine.look = section.look.clone();
                    machine.align = section.arrangement.align.clone();
                    machine.gap = section.arrangement.gap;
                    machine.max_rows = section.max_rows;
                    sections.push(machine);
                }
            }
            Content::App => {
                let contribution = section.contribution.clone().unwrap_or_default();
                sections.push(section_from_layout(section, SectionKind::App { contribution }));
            }
            Content::Items | Content::Other(_) => {
                let kind = kind_of_layout_items_section(section);
                let mut new = section_from_layout(section, kind);
                new.keeps_closed = new.kind.keeps_closed_by_default();
                if new.kind == SectionKind::Pinned {
                    new.shows_title = false;
                }
                sections.push(new);
                layout_items.extend(section.items.iter().map(|item| (section.id.clone(), item)));
            }
        }
    }
    if !sections.iter().any(|s| s.kind == SectionKind::Pinned) {
        let at = sections
            .iter()
            .position(|s| s.id == "sec_top")
            .map(|i| i + 1)
            .or_else(|| sections.iter().position(|s| s.region == Region::Top))
            .unwrap_or(0);
        sections.insert(at, Section::pinned());
    }
    if !sections.iter().any(|s| s.kind.machine() == Some(input.local_session.as_str())) {
        // A layout with no workspaces section (never stored by the app).
        for session in &machine_ids {
            sections.push(Section::machine(session));
        }
    }
    let keys = order_key::spread(sections.len());
    for (section, key) in sections.iter_mut().zip(keys) {
        section.order = key;
    }
    builder.machines = machine_ids.clone();
    builder.sections = sections;
    // 1. Layout items (tiles and top rows), in section order.
    for (section, item) in layout_items {
        let body = body_of_layout_ref(&item.reference);
        let mut new = match &body {
            Body::Workspace { reference } => {
                if builder.is_placed(reference) {
                    continue;
                }
                builder.mark(reference);
                Item::workspace(reference.clone(), &section)
            }
            _ => Item::new(&item.id, &section, body),
        };
        new.shows_label = item.shows_label;
        new.span = item.span;
        new.extra = item.extra.clone();
        if builder.has_item(&new.id) {
            continue;
        }
        builder.push(new);
    }
    let label = |reference: &WorkspaceRef| {
        input.labels.iter().find(|(r, _)| r.same(reference)).map(|(_, label)| label.clone())
    };
    // 2. Pin flags.
    for reference in &input.pinned_flags {
        builder.place_workspace(reference, PINNED_SECTION_ID, None, label(reference).as_ref());
    }
    // 3. Pinned groups.
    for entry in &input.entries {
        if let LegacyEntry::Group { group, members } = entry
            && group.pinned
        {
            builder.place_group(group, members, Some(PINNED_SECTION_ID), &input.labels);
        }
    }
    // 4. The personal order.
    for entry in &input.entries {
        match entry {
            LegacyEntry::Workspace { workspace } => {
                let reference = workspace.reference();
                let section = builder.machine_section(&reference.session_id);
                builder.place_workspace(&reference, &section, None, None);
            }
            LegacyEntry::Group { group, members } if !group.pinned => {
                builder.place_group(group, members, None, &input.labels);
            }
            LegacyEntry::Group { .. } => {}
        }
    }
    let Builder { sections, mut items, .. } = builder;
    // Insertion order is the order: one spread of keys per sibling list.
    let mut lists: std::collections::HashMap<(String, Option<String>), Vec<usize>> =
        std::collections::HashMap::new();
    for (index, item) in items.iter().enumerate() {
        lists.entry((item.section.clone(), item.parent.clone())).or_default().push(index);
    }
    // The indexes come from enumerating `items`, so every lookup finds its item.
    for indexes in lists.values() {
        for (&index, key) in indexes.iter().zip(order_key::spread(indexes.len())) {
            if let Some(item) = items.get_mut(index) {
                item.order = key;
            }
        }
    }
    let mut doc = Doc::from_parts(0, sections, items);
    // Old stores allow values the document refuses (group names up to 256
    // characters, for one); a document that fails `check` refuses every op.
    super::reduce::repair(&mut doc);
    doc
}
