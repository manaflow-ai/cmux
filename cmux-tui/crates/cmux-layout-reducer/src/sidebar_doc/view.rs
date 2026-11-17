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
    /// The live set is the one the last request to this view sent (the
    /// mirror keeps it), so a change sends no live list; `live` is ignored.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub live_same: bool,
    /// The caller holds nothing of the last answer: send all of it
    /// (`sidebar_doc::view_splice`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub fresh: bool,
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

thread_local! {
    static ROWS_BUILT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Rows built on this thread since the last call (it resets the count): the
/// work count the scale tests hold to the rows a change touches.
pub fn take_rows_built() -> usize {
    ROWS_BUILT.with(|built| built.replace(0))
}

fn count_row() {
    ROWS_BUILT.with(|built| built.set(built.get() + 1));
}

/// The live workspaces of one view, indexed by `(session, workspace id)`
/// with their place in live order.
#[derive(Debug, Clone, Default)]
pub struct LiveIndex {
    list: Vec<LiveWorkspace>,
    at: HashMap<String, HashMap<String, usize>>,
}

impl LiveIndex {
    pub fn new(list: Vec<LiveWorkspace>) -> Self {
        let mut at: HashMap<String, HashMap<String, usize>> = HashMap::new();
        for (index, live) in list.iter().enumerate() {
            at.entry(live.session_id.clone())
                .or_default()
                .entry(live.workspace_id.clone())
                .or_insert(index);
        }
        LiveIndex { list, at }
    }

    pub fn list(&self) -> &[LiveWorkspace] {
        &self.list
    }

    /// The place of `(session, workspace)` in live order (its first entry).
    pub fn position(&self, session: &str, workspace: &str) -> Option<usize> {
        self.at.get(session).and_then(|ids| ids.get(workspace)).copied()
    }

    fn get(&self, reference: &WorkspaceRef) -> Option<&LiveWorkspace> {
        self.position(&reference.session_id, &reference.workspace_id).map(|at| &self.list[at])
    }
}

/// The live set a view reads: borrowed from the request for one full view
/// (no copy), or the kept index of an incremental one.
pub(super) enum Live<'a> {
    Borrowed(HashMap<(&'a str, &'a str), &'a LiveWorkspace>),
    Kept(&'a LiveIndex),
}

impl<'a> Live<'a> {
    pub(super) fn borrowed(list: &'a [LiveWorkspace]) -> Self {
        Live::Borrowed(
            list.iter()
                .map(|live| ((live.session_id.as_str(), live.workspace_id.as_str()), live))
                .collect(),
        )
    }

    fn get(&self, reference: &WorkspaceRef) -> Option<&'a LiveWorkspace> {
        match self {
            Live::Borrowed(map) => {
                map.get(&(reference.session_id.as_str(), reference.workspace_id.as_str())).copied()
            }
            Live::Kept(index) => index.get(reference),
        }
    }
}

/// What every row of one view reads besides the document: the live set, the
/// text filter and the collapsed ids.
pub(super) struct Context<'a> {
    live: Live<'a>,
    pub(super) needle: Option<String>,
    collapsed: Option<HashSet<&'a str>>,
}

impl<'a> Context<'a> {
    pub(super) fn new(live: Live<'a>, request: &'a ViewRequest) -> Self {
        Context {
            live,
            needle: request
                .filter
                .as_ref()
                .map(|text| text.trim().to_lowercase())
                .filter(|text| !text.is_empty()),
            collapsed: request
                .collapsed
                .as_ref()
                .map(|ids| ids.iter().map(String::as_str).collect()),
        }
    }

    pub(super) fn is_live(&self, reference: &WorkspaceRef) -> bool {
        self.live.get(reference).is_some()
    }

    fn title_of(&self, item: &Item) -> String {
        match &item.body {
            Body::Workspace { reference } => self
                .live
                .get(reference)
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

    pub(super) fn matches(&self, text: &str) -> bool {
        self.needle.as_ref().is_none_or(|needle| text.to_lowercase().contains(needle))
    }

    /// Whether `item` passes the text filter. With no filter (every view
    /// but a search) it builds no title: that was a string per row per view.
    fn shows(&self, item: &Item) -> bool {
        self.needle.is_none() || self.matches(&self.title_of(item))
    }

    pub(super) fn is_collapsed(&self, id: &str, stored: bool) -> bool {
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
    count_row();
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
    let name_matches = shown || context.shows(group);
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
            if name_matches || context.shows(child) {
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

/// The rows of one top-level item of `section` (a group with its subtree):
/// a block, which depends only on that item's tree, the section and the
/// context, so a change rebuilds only the blocks it touches.
pub(super) fn block_rows(
    doc: &Doc,
    context: &Context<'_>,
    section: &Section,
    item: &Item,
) -> Vec<Row> {
    let mut out = Vec::new();
    push_block(doc, context, section, item, &mut out);
    out
}

/// [`block_rows`] appended to `out`.
fn push_block(
    doc: &Doc,
    context: &Context<'_>,
    section: &Section,
    item: &Item,
    out: &mut Vec<Row>,
) {
    match &item.body {
        Body::Workspace { reference } => {
            let live = context.is_live(reference);
            if (live || section.keeps_closed) && context.shows(item) {
                out.push(item_row(item, 0, !live, false, false));
            }
        }
        Body::Group { .. } => out.extend(group_rows(doc, context, section, item, 0, false, false)),
        _ => {
            if context.shows(item) {
                out.push(item_row(item, 0, false, false, false));
            }
        }
    }
}

/// The row of a live workspace the document does not place yet, in
/// `section` (its machine's).
pub(super) fn unplaced_row(section: &Section, live: &LiveWorkspace) -> Row {
    count_row();
    let reference = WorkspaceRef::new(&live.session_id, &live.workspace_id);
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
    }
}

/// A section's header row, when it shows one: a titled section, a machine
/// section only when more than one shows, and with a text filter only when
/// a row of it shows.
pub(super) fn header_row(
    section: &Section,
    context: &Context<'_>,
    machine_count: usize,
    body_empty: bool,
) -> Option<Row> {
    let header = section.shows_title
        && (section.kind.machine().is_none() || machine_count > 1)
        && (context.needle.is_none() || !body_empty);
    header.then(|| {
        count_row();
        Row {
            key: section.id.clone(),
            kind: "section".into(),
            section: section.id.clone(),
            parent: None,
            depth: 0,
            item: None,
            dimmed: false,
            reference: None,
            collapsed: context.is_collapsed(&section.id, false),
            archived: false,
        }
    })
}

/// Unplaced live workspaces, by machine, in live order.
pub(super) fn unplaced_by_session<'a>(
    doc: &Doc,
    live: &'a [LiveWorkspace],
) -> Vec<(String, Vec<&'a LiveWorkspace>)> {
    let mut unplaced: Vec<(String, Vec<&LiveWorkspace>)> = Vec::new();
    for live in live {
        let reference = WorkspaceRef::new(&live.session_id, &live.workspace_id);
        if doc.workspace_item(&reference).is_some() {
            continue;
        }
        match unplaced.iter_mut().find(|(session, _)| *session == live.session_id) {
            Some((_, list)) => list.push(live),
            None => unplaced.push((live.session_id.clone(), vec![live])),
        }
    }
    unplaced
}

/// The sections `window` shows, with a stand-in for each machine in
/// `unplaced_sessions` that has no section.
pub(super) fn shown_sections<'s>(
    doc: &Doc,
    window: &WindowFilter,
    unplaced_sessions: impl Iterator<Item = &'s str>,
) -> Vec<Section> {
    let shown_session = |session: &str| {
        window.sessions.as_ref().is_none_or(|sessions| sessions.iter().any(|s| s == session))
    };
    let mut sections: Vec<Section> = doc
        .sections()
        .iter()
        .filter(|section| {
            section.room.as_ref().is_none_or(|room| window.room.as_ref() == Some(room))
        })
        .filter(|section| section.kind.machine().is_none_or(shown_session))
        .cloned()
        .collect();
    for session in unplaced_sessions {
        if doc.machine_section(session).is_some() || !shown_session(session) {
            continue;
        }
        let at = sections
            .iter()
            .rposition(|section| section.kind.machine().is_some())
            .map_or(sections.len(), |i| i + 1);
        sections.insert(at, Section::machine(session));
    }
    sections
}

/// Where a section's unplaced rows go among its blocks: above the trailing
/// run of blocks whose top row is archived (where adopting them puts them).
/// `heads` yields each block's top row (`None` for a block with no rows).
pub(super) fn unplaced_at<'r>(heads: impl DoubleEndedIterator<Item = Option<&'r Row>>) -> usize {
    let heads: Vec<Option<&Row>> = heads.collect();
    let mut at = heads.len();
    for (index, head) in heads.iter().enumerate().rev() {
        let Some(head) = head else { continue };
        if !head.archived {
            break;
        }
        at = index;
    }
    at
}

/// The rows of `doc` for one window.
pub fn view(doc: &Doc, request: &ViewRequest) -> Vec<Row> {
    let context = Context::new(Live::borrowed(&request.live), request);
    let unplaced = unplaced_by_session(doc, &request.live);
    let sections =
        shown_sections(doc, &request.window, unplaced.iter().map(|(session, _)| session.as_str()));
    let machine_count = sections.iter().filter(|s| s.kind.machine().is_some()).count();
    let mut rows = Vec::new();
    for section in &sections {
        let mut body: Vec<Row> = Vec::new();
        for item in doc.list(&section.id, None) {
            push_block(doc, &context, section, item, &mut body);
        }
        if let Some(session) = section.kind.machine()
            && let Some((_, list)) = unplaced.iter().find(|(s, _)| s == session)
        {
            // Above the archived tail (each block's top row is its depth-0 row).
            let at = unplaced_at(body.iter().map(|row| (row.depth == 0).then_some(row)));
            let extra: Vec<Row> = list
                .iter()
                .filter(|live| context.matches(live.title.as_deref().unwrap_or_default()))
                .map(|live| unplaced_row(section, live))
                .collect();
            body.splice(at..at, extra);
        }
        let header = header_row(section, &context, machine_count, body.is_empty());
        let folded = header.as_ref().is_some_and(|header| header.collapsed);
        rows.extend(header);
        if !folded {
            rows.append(&mut body);
        }
    }
    rows
}
