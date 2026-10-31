//! The flat rows one window draws: the document reconciled with the live
//! workspace set, the window's filter (room, machines), the text filter and
//! the collapsed groups and sections.
//!
//! - A live workspace with no item shows at the end of its machine
//!   section (a machine section with no stored section is drawn after the
//!   last machine section). Its row key is its item id to be
//!   ([`workspace_item_id`]), so a client can adopt and move it in one
//!   `sidebar.apply`.
//! - A closed workspace (placed, not live) draws dimmed in a section that
//!   keeps closed items (Pinned, custom) and is hidden in the others.
//! - An archived item (and everything under an archived group) draws
//!   dimmed with `archived`; it lists after its unarchived siblings, and
//!   the live workspaces with no item yet show above a section's archived
//!   tail (plans/cmux-next/archiving-DESIGN.md).
//! - A machine section shows its header only when more than one machine
//!   section shows (one machine is the main list, no header, as today).
//! - A text filter shows the items whose title matches, a group whose name
//!   matches with all its children, and a group with a matching child; it
//!   ignores collapse, and a section shows its header only when a row of
//!   it shows.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::doc::Doc;
use super::model::*;

/// A live workspace of one machine, with the title the filter matches.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveWorkspace {
    pub session_id: String,
    pub workspace_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

/// Which sections one window shows.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct WindowFilter {
    /// The window's room: sections of another room are hidden.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    /// The machines the window shows; absent shows every machine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sessions: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ViewRequest {
    #[serde(default)]
    pub live: Vec<LiveWorkspace>,
    #[serde(default)]
    pub window: WindowFilter,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<String>,
    /// The collapsed group and section ids of this window. Absent: each
    /// group's stored `collapsed`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub key: String,
    /// `section` for a header, else the body kind (`workspace`, `group`, ...).
    pub kind: String,
    pub section: SectionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ItemId>,
    pub depth: u8,
    /// The document item; absent for a header and an unplaced workspace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<ItemId>,
    pub dimmed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "ref")]
    pub reference: Option<WorkspaceRef>,
    /// A group or section header drawn collapsed.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub collapsed: bool,
    /// An archived item, or one under an archived group: drawn dimmed.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub archived: bool,
}

struct Context<'a> {
    live: HashMap<(&'a str, &'a str), &'a LiveWorkspace>,
    needle: Option<String>,
    collapsed: Option<HashSet<&'a str>>,
}

impl Context<'_> {
    fn is_live(&self, reference: &WorkspaceRef) -> bool {
        self.live.contains_key(&(reference.session_id.as_str(), reference.workspace_id.as_str()))
    }

    fn title_of(&self, item: &Item) -> String {
        match &item.body {
            Body::Workspace { reference } => self
                .live
                .get(&(reference.session_id.as_str(), reference.workspace_id.as_str()))
                .and_then(|live| live.title.clone())
                .or_else(|| item.label().map(str::to_string))
                .unwrap_or_default(),
            Body::Group { name, .. } => name.clone(),
            Body::Url { url, title, .. } => {
                format!("{} {url}", title.clone().unwrap_or_default())
            }
            Body::Builtin { id }
            | Body::App { id }
            | Body::Room { id }
            | Body::SavedGroup { id } => item.label().map_or_else(|| id.clone(), str::to_string),
            Body::Tab { reference } => item.label().unwrap_or(reference).to_string(),
            Body::Ref { value, .. } => item.label().unwrap_or(value).to_string(),
        }
    }

    fn matches(&self, text: &str) -> bool {
        self.needle.as_ref().is_none_or(|needle| text.to_lowercase().contains(needle))
    }

    fn is_collapsed(&self, id: &str, stored: bool) -> bool {
        if self.needle.is_some() {
            return false;
        }
        match &self.collapsed {
            Some(set) => set.contains(id),
            None => stored,
        }
    }
}

fn item_row(item: &Item, depth: u8, dimmed: bool, collapsed: bool, archived: bool) -> Row {
    Row {
        key: item.id.clone(),
        kind: item.body.kind_name().into(),
        section: item.section.clone(),
        parent: item.parent.clone(),
        depth,
        item: Some(item.id.clone()),
        dimmed,
        reference: item.body.workspace().cloned(),
        collapsed,
        archived: archived || item.archived(),
    }
}

/// The rows of a group and its subtree at `depth`: the group's row, then
/// (unless it is collapsed) its children, a subgroup with its own rows.
/// With a text filter, a group whose name matches shows its whole subtree
/// (`shown`), and a group with a matching row anywhere under it shows as the
/// path to that row; otherwise the group shows nothing.
fn group_rows(
    doc: &Doc,
    context: &Context<'_>,
    section: &Section,
    group: &Item,
    depth: u8,
    shown: bool,
    archived: bool,
) -> Vec<Row> {
    let Body::Group { collapsed, .. } = &group.body else { return Vec::new() };
    let archived = archived || group.archived();
    let name_matches = shown || context.matches(&context.title_of(group));
    let mut inner = Vec::new();
    // A valid document has at most MAX_GROUP_DEPTH levels; the bound keeps a
    // corrupt one finite.
    if usize::from(depth) < MAX_GROUP_DEPTH {
        for child in doc.list(&section.id, Some(group.id.as_str())) {
            if child.body.is_group() {
                inner.extend(group_rows(
                    doc,
                    context,
                    section,
                    child,
                    depth + 1,
                    name_matches,
                    archived,
                ));
                continue;
            }
            let live = child.body.workspace().is_none_or(|r| context.is_live(r));
            if !live && !section.keeps_closed {
                continue;
            }
            if name_matches || context.matches(&context.title_of(child)) {
                inner.push(item_row(child, depth + 1, !live, false, archived));
            }
        }
    }
    if !name_matches && inner.is_empty() {
        return Vec::new();
    }
    let folded = context.is_collapsed(&group.id, *collapsed);
    let mut rows = vec![item_row(group, depth, false, folded, archived)];
    if !folded {
        rows.extend(inner);
    }
    rows
}

/// The rows of `doc` for one window.
pub fn view(doc: &Doc, request: &ViewRequest) -> Vec<Row> {
    let context = Context {
        live: request
            .live
            .iter()
            .map(|live| ((live.session_id.as_str(), live.workspace_id.as_str()), live))
            .collect(),
        needle: request
            .filter
            .as_ref()
            .map(|text| text.trim().to_lowercase())
            .filter(|text| !text.is_empty()),
        collapsed: request.collapsed.as_ref().map(|ids| ids.iter().map(String::as_str).collect()),
    };
    let shown_session = |session: &str| {
        request
            .window
            .sessions
            .as_ref()
            .is_none_or(|sessions| sessions.iter().any(|s| s == session))
    };
    // Unplaced live workspaces, by machine, in live order.
    let mut unplaced: Vec<(String, Vec<&LiveWorkspace>)> = Vec::new();
    for live in &request.live {
        let reference = WorkspaceRef::new(&live.session_id, &live.workspace_id);
        if doc.workspace_item(&reference).is_some() {
            continue;
        }
        match unplaced.iter_mut().find(|(session, _)| *session == live.session_id) {
            Some((_, list)) => list.push(live),
            None => unplaced.push((live.session_id.clone(), vec![live])),
        }
    }
    // The sections this window shows, with a stand-in for each machine
    // that has unplaced workspaces and no section.
    let mut sections: Vec<Section> = doc
        .sections()
        .iter()
        .filter(|section| {
            section.room.as_ref().is_none_or(|room| request.window.room.as_ref() == Some(room))
        })
        .filter(|section| section.kind.machine().is_none_or(&shown_session))
        .cloned()
        .collect();
    for (session, _) in &unplaced {
        if doc.machine_section(session).is_some() || !shown_session(session) {
            continue;
        }
        let at = sections
            .iter()
            .rposition(|section| section.kind.machine().is_some())
            .map_or(sections.len(), |i| i + 1);
        sections.insert(at, Section::machine(session));
    }
    let machine_count = sections.iter().filter(|s| s.kind.machine().is_some()).count();
    let mut rows = Vec::new();
    for section in &sections {
        let mut body: Vec<Row> = Vec::new();
        let section_collapsed = context.is_collapsed(&section.id, false);
        for item in doc.list(&section.id, None) {
            match &item.body {
                Body::Workspace { reference } => {
                    let live = context.is_live(reference);
                    if (live || section.keeps_closed) && context.matches(&context.title_of(item)) {
                        body.push(item_row(item, 0, !live, false, false));
                    }
                }
                Body::Group { .. } => {
                    body.extend(group_rows(doc, &context, section, item, 0, false, false));
                }
                _ => {
                    if context.matches(&context.title_of(item)) {
                        body.push(item_row(item, 0, false, false, false));
                    }
                }
            }
        }
        if let Some(session) = section.kind.machine()
            && let Some((_, list)) = unplaced.iter().find(|(s, _)| s == session)
        {
            // Above the archived tail, where adopting them puts them.
            let mut at = body.len();
            for (index, row) in body.iter().enumerate().rev() {
                if row.depth == 0 {
                    if !row.archived {
                        break;
                    }
                    at = index;
                }
            }
            for live in list {
                if !context.matches(live.title.as_deref().unwrap_or_default()) {
                    continue;
                }
                let reference = WorkspaceRef::new(&live.session_id, &live.workspace_id);
                body.insert(
                    at,
                    Row {
                        key: workspace_item_id(&reference),
                        kind: "workspace".into(),
                        section: section.id.clone(),
                        parent: None,
                        depth: 0,
                        item: None,
                        dimmed: false,
                        reference: Some(reference),
                        collapsed: false,
                        archived: false,
                    },
                );
                at += 1;
            }
        }
        let header = section.shows_title
            && (section.kind.machine().is_none() || machine_count > 1)
            && (context.needle.is_none() || !body.is_empty());
        if header {
            rows.push(Row {
                key: section.id.clone(),
                kind: "section".into(),
                section: section.id.clone(),
                parent: None,
                depth: 0,
                item: None,
                dimmed: false,
                reference: None,
                collapsed: section_collapsed,
                archived: false,
            });
        }
        if !(header && section_collapsed) {
            rows.extend(body);
        }
    }
    rows
}
