//! `SidebarLayout.make` (CmuxNextSidebar/Logic/SidebarLayout.swift and its `+Recents`, `+Status`, `+GroupRows`,
//! `+SoleMember`, `+OneRowPerWorkspace`, `+ArchiveSection`, `+Folder` extensions, with `SidebarChatHistoryPlacement`):
//! the sidebar's sections flattened into rows with frames, and the drop gap. Step A of a two-step port: Swift stays
//! the caller until the FFI re-pin, so the row content the Swift side owns (a workspace row's height from its
//! `WorkspaceRowContent`, its agent state, its Group by Status section) comes in on each workspace, and a workspace
//! row answers only the session tree's depth, chevron and roll-up the layout puts on it.
//!
//! The Done fold and the session tree helpers below mirror `sidebar_list_rules` (cmux#57677) privately until that
//! module is on this base; dedupe them once it is.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};

// MARK: - Wire

/// `SectionID`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SectionId {
    Pinned,
    Machine(String),
    Custom(String),
}

/// `SidebarMachine.Kind`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineKind {
    #[default]
    Local,
    Cloud,
    Ssh,
    Server,
}

/// `SidebarSection.Kind`: what the layout reads of it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SectionKind {
    Pinned,
    Machine {
        id: String,
        #[serde(default)]
        kind: MachineKind,
    },
    Custom(String),
}

/// `SidebarSection`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    pub kind: SectionKind,
    #[serde(default)]
    pub is_collapsed: bool,
    #[serde(default)]
    pub is_host_group: bool,
    #[serde(default)]
    pub draws_as_group: bool,
    #[serde(default)]
    pub nodes: Vec<Node>,
}

impl Section {
    pub fn id(&self) -> SectionId {
        match &self.kind {
            SectionKind::Pinned => SectionId::Pinned,
            SectionKind::Machine { id, .. } => SectionId::Machine(id.clone()),
            SectionKind::Custom(id) => SectionId::Custom(id.clone()),
        }
    }

    pub(crate) fn machine(&self) -> Option<MachineKind> {
        match &self.kind {
            SectionKind::Machine { kind, .. } => Some(*kind),
            _ => None,
        }
    }

    pub(crate) fn doc_id(&self) -> Option<&str> {
        match &self.kind {
            SectionKind::Custom(id) => Some(id),
            _ => None,
        }
    }

    /// `SidebarRowIndex.keepsHeaderInOneList`: a remote group a person made.
    fn keeps_header_in_one_list(&self) -> bool {
        self.is_host_group && !self.draws_as_group
    }
}

/// `SidebarNode`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Node {
    Workspace(Workspace),
    Group(Group),
    Item(Item),
}

impl Node {
    fn workspaces(&self) -> &[Workspace] {
        match self {
            Node::Workspace(ws) => std::slice::from_ref(ws),
            Node::Group(g) => &g.workspaces,
            Node::Item(_) => &[],
        }
    }
}

/// `SidebarStatusSection`, in its order.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatusSection {
    NeedsYou,
    Done,
    Failed,
    CiFailing,
    Working,
    #[default]
    Idle,
}

impl StatusSection {
    const ALL: [StatusSection; 6] = [
        StatusSection::NeedsYou,
        StatusSection::Done,
        StatusSection::Failed,
        StatusSection::CiFailing,
        StatusSection::Working,
        StatusSection::Idle,
    ];

    fn collapses(self) -> bool {
        self != StatusSection::NeedsYou
    }
}

/// `SidebarAgentState`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    #[default]
    Idle,
    FinishedUnread,
    Running,
    Failed,
    Blocked,
}

/// `SidebarTreeFold`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TreeFold {
    Expanded,
    Collapsed,
}

/// `SidebarTreeRollUp`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RollUp {
    pub blocked: usize,
    pub failed: usize,
    pub running: usize,
    pub unread: usize,
    pub total: usize,
}

impl RollUp {
    fn of(states: impl Iterator<Item = AgentState>) -> RollUp {
        let mut r = RollUp::default();
        for state in states {
            r.total = r.total.saturating_add(1);
            match state {
                AgentState::Blocked => r.blocked = r.blocked.saturating_add(1),
                AgentState::Failed => r.failed = r.failed.saturating_add(1),
                AgentState::Running => r.running = r.running.saturating_add(1),
                AgentState::FinishedUnread => r.unread = r.unread.saturating_add(1),
                AgentState::Idle => {}
            }
        }
        r
    }

    fn is_empty(&self) -> bool {
        self.total == 0
            && self.blocked == 0
            && self.failed == 0
            && self.running == 0
            && self.unread == 0
    }
}

/// `SidebarWorkspace`, as the layout reads it, with what the Swift side computes for its row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// `taskStatus == .done`.
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub archived: bool,
    /// `agentChip == .needsYou`.
    #[serde(default)]
    pub needs_you: bool,
    #[serde(default)]
    pub last_activity: Option<f64>,
    #[serde(default)]
    pub folder: Option<String>,
    /// `SidebarGrouping.section(ws)` (the held row's too).
    #[serde(default)]
    pub status_section: StatusSection,
    /// `SidebarAgentState.of(ws, lane:)` under the session tree's states.
    #[serde(default)]
    pub agent_state: AgentState,
    /// `metrics.height(for: options.rowContent(ws, machine: label))`, the metrics resolved for the options.
    pub height: f64,
    /// The chevron `rowContent` gives a parent of subagents.
    #[serde(default)]
    pub tree_fold: Option<TreeFold>,
    /// `machineID`: the computer the workspace runs on (`SidebarEdits.canPlace`).
    #[serde(default)]
    pub machine_id: Option<String>,
}

/// `SidebarListItem`: a link, tab or app row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    #[serde(default)]
    pub archived: bool,
}

/// `SidebarGroupItem`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupItem {
    pub item: Item,
    #[serde(default)]
    pub after: Option<String>,
}

/// `SidebarGroup`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub is_collapsed: bool,
    #[serde(default)]
    pub workspaces: Vec<Workspace>,
    #[serde(default)]
    pub items: Vec<GroupItem>,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub depth: usize,
    #[serde(default)]
    pub is_archived: bool,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Member<'a> {
    Workspace(&'a Workspace),
    Item(&'a Item),
}

impl Group {
    /// `members`: the workspaces, each item after the workspace it follows (first when none; last when that
    /// workspace is not here).
    pub(crate) fn members(&self) -> Vec<Member<'_>> {
        if self.items.is_empty() {
            return self.workspaces.iter().map(Member::Workspace).collect();
        }
        let present: HashSet<&str> = self.workspaces.iter().map(|w| w.id.as_str()).collect();
        let mut after: HashMap<&str, Vec<&Item>> = HashMap::new();
        let (mut first, mut last) = (Vec::new(), Vec::new());
        for entry in &self.items {
            match entry.after.as_deref() {
                Some(anchor) if present.contains(anchor) => {
                    after.entry(anchor).or_default().push(&entry.item);
                }
                Some(_) => last.push(&entry.item),
                None => first.push(&entry.item),
            }
        }
        let mut members: Vec<Member<'_>> = first.into_iter().map(Member::Item).collect();
        for ws in &self.workspaces {
            members.push(Member::Workspace(ws));
            if let Some(items) = after.get(ws.id.as_str()) {
                members.extend(items.iter().copied().map(Member::Item));
            }
        }
        members.extend(last.into_iter().map(Member::Item));
        members
    }
}

/// `SidebarLayoutMetrics` (the base; `make` resolves it for the options).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub top_padding: f64,
    pub bottom_padding: f64,
    pub section_header_height: f64,
    pub section_spacing: f64,
    pub row_height: f64,
    pub row_height_with_subtitle: f64,
    pub row_spacing: f64,
    pub empty_section_height: f64,
    #[serde(default)]
    pub two_line_rows: bool,
}

impl Metrics {
    pub(crate) fn resolved(mut self, o: &Options) -> Metrics {
        if o.expanded && !o.workspaces_as_tabs {
            self.two_line_rows = true;
        }
        self
    }

    fn row_step(&self) -> f64 {
        if self.two_line_rows { self.row_height_with_subtitle } else { self.row_height }
    }

    fn group_header_height(&self) -> f64 {
        self.row_step()
    }

    /// `height(for: WorkspaceRowContent())`: an item, fold or Show more row.
    pub(crate) fn empty_content_height(&self) -> f64 {
        self.row_step().max(self.row_height)
    }
}

/// `DropPosition`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Gap {
    pub section: SectionId,
    #[serde(default)]
    pub group: Option<String>,
    pub index: isize,
}

/// `SidebarGroupBy`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupBy {
    #[default]
    None,
    Folder,
    Recents,
}

/// `SidebarGrouping`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Grouping {
    #[serde(default)]
    pub by: GroupBy,
    #[serde(default)]
    pub by_status: bool,
    #[serde(default)]
    pub collapsed: HashSet<StatusSection>,
}

impl Grouping {
    fn groups_by_folder(&self) -> bool {
        self.by == GroupBy::Folder && !self.by_status
    }

    fn groups_by_recents(&self) -> bool {
        self.by == GroupBy::Recents && !self.by_status
    }

    /// `isGrouped`: by Status, Folder or Recents.
    pub(crate) fn is_grouped(&self) -> bool {
        self.by != GroupBy::None || self.by_status
    }
}

/// `SidebarSessionTreeState`, as the layout reads it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTree {
    #[serde(default)]
    pub parents: BTreeMap<String, String>,
    #[serde(default)]
    pub collapsed: HashSet<String>,
    #[serde(default)]
    pub opened: HashSet<String>,
    #[serde(default)]
    pub folds_deep: bool,
    #[serde(default)]
    pub hides_started: bool,
    #[serde(default)]
    pub keeps: HashSet<String>,
}

impl SessionTree {
    fn is_folded(&self, id: &str, depth: usize) -> bool {
        self.collapsed.contains(id) || (self.folds_deep && depth > 0 && !self.opened.contains(id))
    }

    /// `hiddenStarted`: the agent-started rows `hidesStarted` leaves out, as indices into `ids`.
    fn hidden_started(
        &self,
        ids: &[Option<&str>],
        state: &dyn Fn(usize) -> AgentState,
    ) -> HashSet<usize> {
        if !self.hides_started || self.parents.is_empty() {
            return HashSet::new();
        }
        let mut kept: HashSet<&str> = HashSet::new();
        for (index, id) in ids.iter().enumerate() {
            let Some(id) = *id else { continue };
            if !self.parents.contains_key(id)
                || !(self.keeps.contains(id) || state(index) == AgentState::Blocked)
            {
                continue;
            }
            let mut current = Some(id);
            while let Some(next) = current {
                if !self.parents.contains_key(next) || !kept.insert(next) {
                    break;
                }
                current = self.parents.get(next).map(String::as_str);
            }
        }
        ids.iter()
            .enumerate()
            .filter_map(|(i, id)| {
                id.filter(|id| self.parents.contains_key(*id) && !kept.contains(id)).map(|_| i)
            })
            .collect()
    }
}

/// `SidebarChatHistoryState`, as its heights read it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatHistory {
    #[serde(default)]
    pub pinned: usize,
    #[serde(default)]
    pub has_earlier: bool,
    #[serde(default)]
    pub earlier_folded: bool,
    #[serde(default)]
    pub earlier: usize,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub shows_loading: bool,
}

impl ChatHistory {
    fn pinned_height(&self, m: &Metrics) -> f64 {
        if self.pinned == 0 {
            0.0
        } else {
            m.section_header_height + self.pinned as f64 * (m.row_height + m.row_spacing)
        }
    }

    fn earlier_height(&self, m: &Metrics) -> f64 {
        if !self.has_earlier {
            return 0.0;
        }
        if self.earlier_folded {
            return m.section_header_height;
        }
        let extra = usize::from(self.has_more || self.shows_loading);
        m.section_header_height
            + self.earlier.saturating_add(extra) as f64 * (m.row_height + m.row_spacing)
    }
}

/// `SidebarDoneFoldID.Kind`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FoldKind {
    #[default]
    Done,
    Settled,
    Automatic,
    Archived,
    Projects,
}

/// `SidebarDoneFoldID`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FoldId {
    pub section: SectionId,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub kind: FoldKind,
    #[serde(default)]
    pub folder: Option<String>,
}

impl FoldId {
    fn list(section: &SectionId, group: Option<&str>) -> FoldId {
        FoldId {
            section: section.clone(),
            group: group.map(str::to_owned),
            kind: FoldKind::Done,
            folder: None,
        }
    }

    fn projects() -> FoldId {
        FoldId { section: SectionId::Pinned, group: None, kind: FoldKind::Projects, folder: None }
    }

    fn of(&self, kind: FoldKind) -> FoldId {
        FoldId { kind, ..self.clone() }
    }
}

fn yes() -> bool {
    true
}

/// `SidebarLayoutOptions`, as `make` reads them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Options {
    #[serde(default)]
    pub excluded_workspaces: HashSet<String>,
    #[serde(default)]
    pub excluded_group: Option<String>,
    #[serde(default)]
    pub excluded_item: Option<String>,
    #[serde(default)]
    pub block_heights: HashMap<String, f64>,
    #[serde(default)]
    pub collapsed_doc_sections: HashSet<String>,
    #[serde(default)]
    pub empty_doc_sections: HashSet<String>,
    #[serde(default)]
    pub filter_matches: Option<HashSet<String>>,
    #[serde(default)]
    pub show_empty_pinned: bool,
    #[serde(default)]
    pub gap: Option<Gap>,
    #[serde(default)]
    pub gap_height: f64,
    #[serde(default)]
    pub shows_sole_machine_header: bool,
    #[serde(default)]
    pub flattens_machines: bool,
    #[serde(default)]
    pub active_workspace_id: Option<String>,
    #[serde(default)]
    pub revealed_workspaces: HashMap<String, HashSet<String>>,
    #[serde(default)]
    pub expanded: bool,
    #[serde(default)]
    pub workspaces_as_tabs: bool,
    #[serde(default)]
    pub hides_workspaces: bool,
    #[serde(default)]
    pub grouping: Grouping,
    #[serde(default)]
    pub session_tree: Option<SessionTree>,
    #[serde(default)]
    pub chat_history: Option<ChatHistory>,
    #[serde(default)]
    pub folds_done: bool,
    #[serde(default)]
    pub settled: HashSet<String>,
    #[serde(default)]
    pub automatic: HashSet<String>,
    #[serde(default = "yes")]
    pub folds_archived: bool,
    #[serde(default = "yes")]
    pub archive_section: bool,
    #[serde(default)]
    pub open_done_folds: HashSet<FoldId>,
    #[serde(default)]
    pub row_limit: usize,
    #[serde(default)]
    pub open_show_more: HashSet<FoldId>,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            excluded_workspaces: HashSet::new(),
            excluded_group: None,
            excluded_item: None,
            block_heights: HashMap::new(),
            collapsed_doc_sections: HashSet::new(),
            empty_doc_sections: HashSet::new(),
            filter_matches: None,
            show_empty_pinned: false,
            gap: None,
            gap_height: 0.0,
            shows_sole_machine_header: false,
            flattens_machines: false,
            active_workspace_id: None,
            revealed_workspaces: HashMap::new(),
            expanded: false,
            workspaces_as_tabs: false,
            hides_workspaces: false,
            grouping: Grouping::default(),
            session_tree: None,
            chat_history: None,
            folds_done: false,
            settled: HashSet::new(),
            automatic: HashSet::new(),
            folds_archived: true,
            archive_section: true,
            open_done_folds: HashSet::new(),
            row_limit: 0,
            open_show_more: HashSet::new(),
        }
    }
}

impl Options {
    /// `visible`: not dragged out, and a match while filtering.
    pub(crate) fn visible(&self, ws: &Workspace) -> bool {
        !self.excluded_workspaces.contains(&ws.id)
            && self.filter_matches.as_ref().is_none_or(|f| f.contains(&ws.id))
    }

    fn is_active(&self, id: &str) -> bool {
        self.active_workspace_id.as_deref() == Some(id)
    }

    /// `shown(inCollapsed:)`: the revealed rows of a collapsed group, and the active one.
    pub(crate) fn shown_in_collapsed(&self, group: &str, id: &str) -> bool {
        self.revealed_workspaces.get(group).is_some_and(|s| s.contains(id)) || self.is_active(id)
    }

    fn folds_started(&self) -> bool {
        self.filter_matches.is_none() && self.session_tree.as_ref().is_none_or(|t| t.hides_started)
    }

    pub(crate) fn settles(&self, ws: &Workspace) -> bool {
        !self.settled.is_empty()
            && self.settled.contains(&ws.id)
            && !self.is_active(&ws.id)
            && self.folds_started()
    }

    pub(crate) fn automates(&self, ws: &Workspace) -> bool {
        !self.automatic.is_empty()
            && self.automatic.contains(&ws.id)
            && !self.is_active(&ws.id)
            && self.folds_started()
    }
}

/// A list's header row: Projects or Recents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ListHeader {
    Projects,
    Recents,
}

/// `SidebarRowKey`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Key {
    Section(SectionId),
    Group(String),
    Workspace(String),
    EmptySection(SectionId),
    EmptyGroup(String),
    Folder(SectionId, String),
    Status(StatusSection),
    Item(String),
    Block(String),
    DoneFold(FoldId),
    ShowMore(FoldId),
    ListHeader(ListHeader),
}

/// What the layout puts on a row's `WorkspaceRowContent`: the session tree's depth, chevron and roll-up.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Content {
    pub tree_depth: usize,
    pub tree_fold: Option<TreeFold>,
    pub roll_up: Option<RollUp>,
}

impl Content {
    pub(crate) fn base(ws: &Workspace) -> Content {
        Content { tree_depth: 0, tree_fold: ws.tree_fold, roll_up: None }
    }
}

/// `SidebarRow`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub key: Key,
    pub y: f64,
    pub height: f64,
    pub section: SectionId,
    pub group: Option<String>,
    pub sibling_index: usize,
    pub parent_index: Option<usize>,
    pub is_last_in_group: bool,
    pub is_collapsed: bool,
    pub child_count: usize,
    pub group_color: Option<String>,
    pub titles_projects: bool,
    pub depth: usize,
    pub stands_for_group: bool,
    pub content: Option<Content>,
}

impl Row {
    pub(crate) fn new(key: Key, y: f64, height: f64, section: SectionId) -> Row {
        Row {
            key,
            y,
            height,
            section,
            group: None,
            sibling_index: 0,
            parent_index: None,
            is_last_in_group: false,
            is_collapsed: false,
            child_count: 0,
            group_color: None,
            titles_projects: false,
            depth: 0,
            stands_for_group: false,
            content: None,
        }
    }
}

/// `SidebarLayout`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub rows: Vec<Row>,
    pub total_height: f64,
    pub gap_y: Option<f64>,
    pub gap_height: f64,
    pub gap_shift: f64,
    pub row_spacing: f64,
    pub pinned_chats_y: Option<f64>,
    pub earlier_chats_y: Option<f64>,
}

impl Layout {
    fn empty() -> Layout {
        Layout {
            rows: Vec::new(),
            total_height: 0.0,
            gap_y: None,
            gap_height: 0.0,
            gap_shift: 0.0,
            row_spacing: 0.0,
            pinned_chats_y: None,
            earlier_chats_y: None,
        }
    }
}

/// `make`'s inputs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MakeRequest {
    pub sections: Vec<Section>,
    pub metrics: Metrics,
    #[serde(default)]
    pub options: Options,
}

/// One rule of the op.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Request {
    Make(Box<MakeRequest>),
}

/// The answer to one [`Request`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reply {
    Make(Box<Layout>),
}

/// The op's answer.
pub fn respond(request: &Request) -> Reply {
    match request {
        Request::Make(r) => Reply::Make(Box::new(make(&r.sections, &r.metrics, &r.options))),
    }
}

// MARK: - Done fold and session tree (mirrors `sidebar_list_rules`, cmux#57677)

type Entry = (isize, usize);

const DONE_FOLD: isize = -1;
const SHOW_MORE: isize = -2;
const ARCHIVED_FOLD: isize = -3;
const SETTLED_FOLD: isize = -4;
const AUTOMATIC_FOLD: isize = -5;
/// `gapAtEnd`: the gap opens after the last drawn row.
const GAP_AT_END: isize = isize::MIN;

fn runs(drawn: &[Entry]) -> Vec<Vec<Entry>> {
    let mut runs: Vec<Vec<Entry>> = Vec::new();
    for &entry in drawn {
        match runs.last_mut() {
            Some(run) if entry.1 > 0 => run.push(entry),
            _ => runs.push(vec![entry]),
        }
    }
    runs
}

/// `foldingDone`: the drawn order with the Done, settled, automatic and archived runs folded at the end and the
/// row limit's Show more.
fn folding_done<'a>(
    drawn: &[Entry],
    workspace: &dyn Fn(isize) -> Option<&'a Workspace>,
    id: &FoldId,
    limits: &dyn Fn(isize) -> bool,
    o: &Options,
) -> Vec<Entry> {
    if o.filter_matches.is_some() {
        return drawn.to_vec();
    }
    let (mut shown, mut done, mut settled, mut automatic, mut archived) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for run in runs(drawn) {
        let holds_active = run.iter().any(|e| workspace(e.0).is_some_and(|w| o.is_active(&w.id)));
        let ws = run.first().and_then(|e| workspace(e.0));
        match ws {
            Some(ws) if o.folds_archived && ws.archived && !holds_active => archived.push(run),
            Some(ws) if o.folds_done && ws.done && !holds_active => done.push(run),
            Some(ws) if o.settles(ws) && !holds_active => settled.push(run),
            Some(ws) if o.automates(ws) && !holds_active => automatic.push(run),
            _ => shown.push(run),
        }
    }
    let mut listed = limiting(&shown, workspace, limits, id, o);
    for (runs, index, kind) in [
        (automatic, AUTOMATIC_FOLD, FoldKind::Automatic),
        (settled, SETTLED_FOLD, FoldKind::Settled),
        (done, DONE_FOLD, FoldKind::Done),
        (archived, ARCHIVED_FOLD, FoldKind::Archived),
    ] {
        if runs.is_empty() {
            continue;
        }
        let folded: Vec<Entry> = runs.into_iter().flatten().collect();
        listed.push((index, folded.len()));
        if o.open_done_folds.contains(&id.of(kind)) {
            listed.extend(folded);
        }
    }
    listed
}

fn limiting<'a>(
    shown: &[Vec<Entry>],
    workspace: &dyn Fn(isize) -> Option<&'a Workspace>,
    limits: &dyn Fn(isize) -> bool,
    id: &FoldId,
    o: &Options,
) -> Vec<Entry> {
    let all: Vec<Entry> = shown.iter().flatten().copied().collect();
    let limited = shown.iter().filter(|run| run.first().is_some_and(|e| limits(e.0))).count();
    if o.row_limit == 0 || limited <= o.row_limit.saturating_add(1) {
        return all;
    }
    if o.open_show_more.contains(id) {
        let mut all = all;
        all.push((SHOW_MORE, 0));
        return all;
    }
    let (mut kept, mut hidden, mut n) = (Vec::new(), 0usize, 0usize);
    for run in shown {
        if !run.first().is_some_and(|e| limits(e.0)) {
            kept.extend_from_slice(run);
            continue;
        }
        let stays =
            run.iter().any(|e| workspace(e.0).is_some_and(|w| o.is_active(&w.id) || w.needs_you));
        if n < o.row_limit || stays {
            kept.extend_from_slice(run);
        } else {
            hidden = hidden.saturating_add(run.len());
        }
        n = n.saturating_add(1);
    }
    if hidden == 0 {
        return all;
    }
    kept.push((SHOW_MORE, hidden));
    kept
}

/// `gapEntry`: where the drop gap opens in a drawn order that folds or nests rows, or nil to open it by index.
fn gap_entry(
    drawn: &[Entry],
    gap: Option<&Gap>,
    section: &SectionId,
    group: Option<&str>,
    count: usize,
) -> Option<isize> {
    let gap = gap?;
    if gap.section != *section || gap.group.as_deref() != group || gap.index > count as isize {
        return None;
    }
    if !drawn.iter().any(|e| e.0 < 0 || e.1 > 0) {
        return None;
    }
    Some(
        drawn
            .iter()
            .find(|e| e.0 < 0 || (e.1 == 0 && e.0 >= gap.index))
            .map_or(GAP_AT_END, |e| e.0),
    )
}

/// `pathToMatch`: the groups above a group that holds a match.
fn path_to_match(section: &Section, o: &Options) -> HashSet<String> {
    let mut parents: HashMap<&str, Option<&str>> = HashMap::new();
    for node in &section.nodes {
        if let Node::Group(g) = node {
            parents.entry(g.id.as_str()).or_insert(g.parent.as_deref());
        }
    }
    let mut path = HashSet::new();
    for node in &section.nodes {
        let Node::Group(g) = node else { continue };
        if !g.workspaces.iter().any(|w| o.visible(w)) {
            continue;
        }
        let mut parent = g.parent.as_deref();
        while let Some(id) = parent {
            if !path.insert(id.to_owned()) {
                break;
            }
            parent = parents.get(id).copied().flatten();
        }
    }
    path
}

fn tree_children(
    ids: &[Option<&str>],
    parents: &BTreeMap<String, String>,
) -> HashMap<String, Vec<usize>> {
    let present: HashSet<&str> = ids.iter().flatten().copied().collect();
    let mut rooted: HashMap<String, bool> = HashMap::new();
    let mut reaches_root = |id: &str| -> bool {
        let mut path: Vec<String> = Vec::new();
        let mut on_path: HashSet<String> = HashSet::new();
        let mut next = Some(id.to_owned());
        let mut answer = true;
        while let Some(current) = next {
            if let Some(&known) = rooted.get(&current) {
                answer = known;
                break;
            }
            if !on_path.insert(current.clone()) {
                answer = false;
                break;
            }
            next = parents.get(&current).filter(|p| present.contains(p.as_str())).cloned();
            path.push(current);
        }
        for node in path {
            rooted.insert(node, answer);
        }
        answer
    };
    let mut children: HashMap<String, Vec<usize>> = HashMap::new();
    for (index, id) in ids.iter().enumerate() {
        let Some(id) = *id else { continue };
        let Some(parent) = parents.get(id) else { continue };
        if !present.contains(parent.as_str()) || !reaches_root(id) {
            continue;
        }
        children.entry(parent.clone()).or_default().push(index);
    }
    children
}

fn tree_descendants(
    id: &str,
    ids: &[Option<&str>],
    children: &HashMap<String, Vec<usize>>,
) -> Vec<usize> {
    let mut found = Vec::new();
    let mut stack = children.get(id).cloned().unwrap_or_default();
    while let Some(index) = stack.pop() {
        found.push(index);
        if let Some(child) = ids.get(index).copied().flatten()
            && let Some(kids) = children.get(child)
        {
            stack.extend_from_slice(kids);
        }
    }
    found
}

/// `treeOrder`: each root, then its children depth first, a folded parent's children left out.
fn tree_order(
    ids: &[Option<&str>],
    parents: Option<&BTreeMap<String, String>>,
    folded: &dyn Fn(&str, usize) -> bool,
    known: Option<&HashMap<String, Vec<usize>>>,
    skipped: &HashSet<usize>,
) -> Vec<(usize, usize)> {
    let Some(parents) = parents.filter(|p| !p.is_empty()) else {
        return (0..ids.len()).map(|i| (i, 0)).collect();
    };
    let computed;
    let children = match known {
        Some(c) => c,
        None => {
            computed = tree_children(ids, parents);
            &computed
        }
    };
    let mut nested: HashSet<usize> = children.values().flatten().copied().collect();
    nested.extend(skipped.iter().copied());
    let mut order = Vec::with_capacity(ids.len());
    for root in (0..ids.len()).filter(|i| !nested.contains(i)) {
        let mut stack = vec![(root, 0usize)];
        while let Some((index, depth)) = stack.pop() {
            order.push((index, depth));
            let Some(id) = ids.get(index).copied().flatten() else { continue };
            if folded(id, depth) {
                continue;
            }
            if let Some(kids) = children.get(id) {
                stack.extend(kids.iter().rev().map(|&k| (k, depth.saturating_add(1))));
            }
        }
    }
    order
}

#[derive(Debug, Clone, Default)]
struct TreeRow {
    index: usize,
    depth: usize,
    fold: Option<TreeFold>,
    roll_up: Option<RollUp>,
}

/// `treeRows`: the session tree's drawn order with each parent's chevron and folded roll-up.
fn tree_rows<'a>(
    ids: &[Option<&str>],
    workspace: &dyn Fn(usize) -> Option<&'a Workspace>,
    live: Option<&SessionTree>,
    filtering: bool,
) -> Vec<TreeRow> {
    let state = |i: usize| workspace(i).map_or(AgentState::Idle, |w| w.agent_state);
    let skipped = match live {
        Some(t) if !filtering => t.hidden_started(ids, &state),
        _ => HashSet::new(),
    };
    let tree = live.map(|shown| {
        let mut tree = shown.clone();
        if filtering || shown.hides_started {
            tree.collapsed.clear();
            tree.folds_deep = false;
        }
        tree
    });
    let mut children = tree.as_ref().map(|t| tree_children(ids, &t.parents)).unwrap_or_default();
    if !skipped.is_empty() {
        children = children
            .into_iter()
            .filter_map(|(k, kids)| {
                let shown: Vec<usize> = kids.into_iter().filter(|i| !skipped.contains(i)).collect();
                (!shown.is_empty()).then_some((k, shown))
            })
            .collect();
    }
    let folded = |id: &str, depth: usize| tree.as_ref().is_some_and(|t| t.is_folded(id, depth));
    tree_order(ids, tree.as_ref().map(|t| &t.parents), &folded, Some(&children), &skipped)
        .into_iter()
        .map(|(index, depth)| {
            let Some(t) = tree.as_ref().filter(|t| !t.hides_started) else {
                return TreeRow { index, depth, fold: None, roll_up: None };
            };
            let (fold, roll_up) = match ids.get(index).copied().flatten() {
                Some(id) if children.get(id).is_some_and(|k| !k.is_empty()) => {
                    if t.is_folded(id, depth) {
                        let r =
                            RollUp::of(tree_descendants(id, ids, &children).into_iter().map(state));
                        (Some(TreeFold::Collapsed), (!r.is_empty()).then_some(r))
                    } else {
                        (Some(TreeFold::Expanded), None)
                    }
                }
                _ => (None, None),
            };
            TreeRow { index, depth, fold, roll_up }
        })
        .collect()
}

/// `folderBuckets`: a section's loose rows by folder, first-seen order, "no folder" last.
fn folder_buckets(nodes: &[&Node]) -> (Vec<String>, HashMap<String, Vec<usize>>) {
    let mut folders: Vec<String> = Vec::new();
    let mut members: HashMap<String, Vec<usize>> = HashMap::new();
    for (index, node) in nodes.iter().enumerate() {
        let Node::Workspace(ws) = node else { continue };
        let folder = ws.folder.clone().unwrap_or_default();
        if !members.contains_key(&folder) {
            folders.push(folder.clone());
        }
        members.entry(folder).or_default().push(index);
    }
    if let Some(none) = folders.iter().position(String::is_empty)
        && none.saturating_add(1) != folders.len()
    {
        let f = folders.remove(none);
        folders.push(f);
    }
    (folders, members)
}

// MARK: - One row per workspace, archived rows (`+OneRowPerWorkspace`, `+ArchiveSection`)

/// `listingEachWorkspaceOnce`: each workspace id listed once, by the first section that lists it.
fn listing_each_workspace_once(sections: &[Section]) -> Vec<Section> {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut repeated: HashSet<&str> = HashSet::new();
    for section in sections {
        for ws in section.nodes.iter().flat_map(Node::workspaces) {
            if !seen.insert(&ws.id) {
                repeated.insert(&ws.id);
            }
        }
    }
    if repeated.is_empty() {
        return sections.to_vec();
    }
    let mut owner: HashMap<&str, SectionId> = HashMap::new();
    for section in sections {
        for ws in section.nodes.iter().flat_map(Node::workspaces) {
            if repeated.contains(ws.id.as_str()) && !owner.contains_key(ws.id.as_str()) {
                owner.insert(&ws.id, section.id());
            }
        }
    }
    sections
        .iter()
        .map(|section| {
            let id = section.id();
            let mut kept: HashSet<String> = HashSet::new();
            let mut keeps = |ws: &Workspace| match owner.get(ws.id.as_str()) {
                None => true,
                Some(stays) => *stays == id && kept.insert(ws.id.clone()),
            };
            let nodes = section
                .nodes
                .iter()
                .filter_map(|node| match node {
                    Node::Workspace(ws) => keeps(ws).then(|| node.clone()),
                    Node::Group(group) => {
                        let mut g = group.clone();
                        let (mut workspaces, mut items) = (Vec::new(), Vec::new());
                        for member in group.members() {
                            match member {
                                Member::Workspace(ws) => {
                                    if keeps(ws) {
                                        workspaces.push(ws.clone());
                                    }
                                }
                                Member::Item(item) => items.push(GroupItem {
                                    item: item.clone(),
                                    after: workspaces.last().map(|w: &Workspace| w.id.clone()),
                                }),
                            }
                        }
                        (g.workspaces, g.items) = (workspaces, items);
                        Some(Node::Group(g))
                    }
                    Node::Item(_) => Some(node.clone()),
                })
                .collect();
            Section { nodes, ..section.clone_without_nodes() }
        })
        .collect()
}

impl Section {
    fn clone_without_nodes(&self) -> Section {
        Section {
            kind: self.kind.clone(),
            is_collapsed: self.is_collapsed,
            is_host_group: self.is_host_group,
            draws_as_group: self.draws_as_group,
            nodes: Vec::new(),
        }
    }
}

/// `SidebarDocStore.pinnedSection`.
pub(crate) const DOC_PINNED_SECTION: &str = "sec_pinned";

/// `withoutArchived`: the sections without their archived rows and groups; `active` keeps its place.
fn without_archived(sections: Vec<Section>, active: Option<&str>) -> Vec<Section> {
    sections
        .into_iter()
        .map(|section| {
            if section.id() == SectionId::Pinned || section.doc_id() == Some(DOC_PINNED_SECTION) {
                return section;
            }
            let (mut holds_active, mut holds_live, mut holds_rows) =
                (HashSet::<String>::new(), HashSet::<String>::new(), HashSet::<String>::new());
            for node in section.nodes.iter().rev() {
                let Node::Group(g) = node else { continue };
                let id = &g.id;
                if let Some(active) = active
                    && g.workspaces.iter().any(|w| w.id == active)
                {
                    holds_active.insert(id.clone());
                }
                if !g.workspaces.is_empty() || !g.items.is_empty() {
                    holds_rows.insert(id.clone());
                }
                if g.workspaces.iter().any(|w| !w.archived)
                    || g.items.iter().any(|i| !i.item.archived)
                {
                    holds_live.insert(id.clone());
                }
                if g.is_archived {
                    holds_live.remove(id);
                }
                let Some(parent) = &g.parent else { continue };
                if holds_active.contains(id) {
                    holds_active.insert(parent.clone());
                }
                if holds_rows.contains(id) {
                    holds_rows.insert(parent.clone());
                }
                if holds_live.contains(id) {
                    holds_live.insert(parent.clone());
                }
            }
            let mut kept: HashSet<String> = HashSet::new();
            let mut live = section.clone_without_nodes();
            for node in section.nodes {
                match node {
                    Node::Workspace(ws) => {
                        if !ws.archived || Some(ws.id.as_str()) == active {
                            live.nodes.push(Node::Workspace(ws));
                        }
                    }
                    Node::Item(item) => {
                        if !item.archived {
                            live.nodes.push(Node::Item(item));
                        }
                    }
                    Node::Group(mut g) => {
                        let parent_kept = g.parent.as_ref().is_none_or(|p| kept.contains(p));
                        let stays = holds_active.contains(&g.id)
                            || (parent_kept
                                && !g.is_archived
                                && (holds_live.contains(&g.id) || !holds_rows.contains(&g.id)));
                        if !stays {
                            continue;
                        }
                        kept.insert(g.id.clone());
                        g.workspaces.retain(|w| !w.archived || Some(w.id.as_str()) == active);
                        g.items.retain(|i| !i.item.archived);
                        live.nodes.push(Node::Group(g));
                    }
                }
            }
            live
        })
        .collect()
}

// MARK: - Projects and Recents (`+Recents`)

const PROJECT_LIMIT: usize = 5;

struct RecentsSplit {
    sections: Vec<Section>,
    recents: Vec<(Workspace, SectionId, usize)>,
    project_count: usize,
    hidden_projects: usize,
    projects_opened: bool,
}

fn draws_recents(o: &Options) -> bool {
    o.grouping.groups_by_recents() && o.filter_matches.is_none() && o.session_tree.is_none()
}

fn splitting_recents(sections: &[Section], o: &Options) -> RecentsSplit {
    let mut top_groups: Vec<&str> = Vec::new();
    let mut holds_active: HashSet<String> = HashSet::new();
    for section in sections.iter().filter(|s| s.machine().is_some()) {
        let mut parents: HashMap<&str, &str> = HashMap::new();
        for node in &section.nodes {
            let Node::Group(g) = node else { continue };
            match &g.parent {
                Some(p) => {
                    parents.insert(&g.id, p);
                }
                None => top_groups.push(&g.id),
            }
            if !g.workspaces.iter().any(|w| o.is_active(&w.id) || w.needs_you) {
                continue;
            }
            let mut top: &str = &g.id;
            for _ in 0..64 {
                let Some(parent) = parents.get(top) else { break };
                top = parent;
            }
            holds_active.insert(top.to_owned());
        }
    }
    let opened = o.open_show_more.contains(&FoldId::projects());
    let folds = top_groups.len() > PROJECT_LIMIT + 1;
    let listed: HashSet<String> = if folds && !opened {
        top_groups.iter().take(PROJECT_LIMIT).map(|s| (*s).to_owned()).chain(holds_active).collect()
    } else {
        top_groups.iter().map(|s| (*s).to_owned()).collect()
    };
    let mut split = RecentsSplit {
        sections: Vec::new(),
        recents: Vec::new(),
        project_count: top_groups.len(),
        hidden_projects: top_groups.len().saturating_sub(listed.len()),
        projects_opened: folds && opened,
    };
    let mut recents: Vec<(Workspace, SectionId, usize)> = Vec::new();
    for section in sections {
        if section.machine().is_none() {
            split.sections.push(section.clone());
            continue;
        }
        let mut kept = section.clone_without_nodes();
        let mut dropped: HashSet<&str> = HashSet::new();
        for (index, node) in section.nodes.iter().enumerate() {
            match node {
                Node::Workspace(ws) => {
                    if o.visible(ws) {
                        recents.push((ws.clone(), section.id(), index));
                    }
                }
                Node::Group(g) => {
                    let hidden = match &g.parent {
                        Some(p) => dropped.contains(p.as_str()),
                        None => !listed.contains(&g.id),
                    };
                    if hidden {
                        dropped.insert(&g.id);
                    } else {
                        kept.nodes.push(node.clone());
                    }
                }
                Node::Item(_) => kept.nodes.push(node.clone()),
            }
        }
        split.sections.push(kept);
    }
    // Newest activity first, rows without one last, ties in list order (a stable sort).
    recents.sort_by(|a, b| match (a.0.last_activity, b.0.last_activity) {
        (Some(x), Some(y)) if x != y => y.partial_cmp(&x).unwrap_or(std::cmp::Ordering::Equal),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        _ => std::cmp::Ordering::Equal,
    });
    split.recents = recents;
    split
}

// MARK: - make

/// `SidebarChatHistoryPlacement`.
struct Chats {
    pinned_height: f64,
    earlier_height: f64,
    spacing: f64,
    pinned_y: Option<f64>,
    earlier_y: Option<f64>,
}

impl Chats {
    fn new(history: Option<&ChatHistory>, m: &Metrics) -> Chats {
        Chats {
            pinned_height: history.map_or(0.0, |h| h.pinned_height(m)),
            earlier_height: history.map_or(0.0, |h| h.earlier_height(m)),
            spacing: m.section_spacing,
            pinned_y: None,
            earlier_y: None,
        }
    }

    fn place_pinned(&mut self, y: &mut f64) {
        if self.pinned_y.is_some() || self.pinned_height <= 0.0 {
            return;
        }
        self.pinned_y = Some(*y);
        *y += self.pinned_height;
    }

    fn place_earlier(&mut self, y: &mut f64) {
        self.place_pinned(y);
        if self.earlier_y.is_some() || self.earlier_height <= 0.0 {
            return;
        }
        *y += self.spacing;
        self.earlier_y = Some(*y);
        *y += self.earlier_height;
    }
}

/// The rows `make` builds, where the next one goes, and the drop gap.
pub(crate) struct Builder<'o> {
    o: &'o Options,
    m: Metrics,
    gap_height: f64,
    rows: Vec<Row>,
    y: f64,
    gap_y: Option<f64>,
}

impl<'o> Builder<'o> {
    /// A builder that lays rows out from `y` with no drop gap (a splice's container, `SidebarDragLook`).
    pub(crate) fn at(o: &'o Options, m: Metrics, y: f64) -> Builder<'o> {
        Builder { o, m, gap_height: 0.0, rows: Vec::new(), y, gap_y: None }
    }

    /// The rows laid out and the y after them.
    pub(crate) fn finish(self) -> (Vec<Row>, f64) {
        (self.rows, self.y)
    }

    /// `openGap`: the drop gap, when it opens at `section`, `group`, `index` and has not opened yet.
    fn open_gap(&mut self, section: &SectionId, group: Option<&str>, index: isize) {
        let Some(gap) = &self.o.gap else { return };
        if self.gap_y.is_some()
            || gap.section != *section
            || gap.group.as_deref() != group
            || gap.index != index
        {
            return;
        }
        self.gap_y = Some(self.y);
        self.y += self.gap_height + self.m.row_spacing;
    }

    fn push(&mut self, row: Row) {
        self.y += row.height + self.m.row_spacing;
        self.rows.push(row);
    }

    /// `appendFold`: a Done, settled, automatic or archived fold's row, or a Show more row.
    fn append_fold(
        &mut self,
        entry: isize,
        list: &FoldId,
        count: usize,
        parent: Option<usize>,
        color: Option<&str>,
        last: bool,
    ) {
        let more = entry == SHOW_MORE;
        let id = list.of(match entry {
            ARCHIVED_FOLD => FoldKind::Archived,
            SETTLED_FOLD => FoldKind::Settled,
            AUTOMATIC_FOLD => FoldKind::Automatic,
            _ => FoldKind::Done,
        });
        let open = if more {
            self.o.open_show_more.contains(&id)
        } else {
            self.o.open_done_folds.contains(&id)
        };
        let mut row = Row::new(
            Key::ShowMore(id.clone()),
            self.y,
            self.m.empty_content_height(),
            id.section.clone(),
        );
        if !more {
            row.key = Key::DoneFold(id.clone());
        }
        row.group = id.group;
        row.parent_index = parent;
        row.is_last_in_group = last;
        row.is_collapsed = !open;
        row.child_count = count;
        row.group_color = color.map(str::to_owned);
        row.content = Some(Content::default());
        self.push(row);
    }

    fn workspace_row(
        &self,
        ws: &Workspace,
        section: &SectionId,
        sibling: usize,
        content: Content,
    ) -> Row {
        let mut row = Row::new(Key::Workspace(ws.id.clone()), self.y, ws.height, section.clone());
        row.sibling_index = sibling;
        row.content = Some(content);
        row
    }

    /// `appendGroup`: a group's header (or the one row it draws as), its members and its folds.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn append_group(
        &mut self,
        group: &Group,
        children: &[&Workspace],
        index: usize,
        section: &SectionId,
        has_subgroups: bool,
        filtering: bool,
    ) {
        let o = self.o;
        let shown: HashSet<&str> = children.iter().map(|w| w.id.as_str()).collect();
        let members: Vec<Member<'_>> = group
            .members()
            .into_iter()
            .filter(|m| match m {
                Member::Workspace(ws) => shown.contains(ws.id.as_str()),
                Member::Item(item) => {
                    !filtering && o.excluded_item.as_deref() != Some(item.id.as_str())
                }
            })
            .collect();
        let group_collapsed = group.is_collapsed && !filtering;
        let gid = Some(group.id.as_str());
        if let Some(sole) = sole_member(group, &members, has_subgroups, o)
            && let Some(depth) =
                live_depth(sole, &members, group, group_collapsed, &FoldId::list(section, gid), o)
        {
            let mut row = self.workspace_row(
                sole,
                section,
                0,
                Content { tree_depth: depth, ..Content::base(sole) },
            );
            row.group = Some(group.id.clone());
            row.parent_index = Some(index);
            row.is_last_in_group = true;
            row.group_color = group.color.clone();
            row.depth = group.depth.saturating_add(1);
            row.stands_for_group = true;
            self.push(row);
            self.open_gap(section, gid, 0);
            self.open_gap(section, gid, 1);
            return;
        }
        let mut header = Row::new(
            Key::Group(group.id.clone()),
            self.y,
            self.m.group_header_height(),
            section.clone(),
        );
        header.group = Some(group.id.clone());
        header.sibling_index = index;
        header.is_collapsed = group_collapsed;
        header.child_count = members.len();
        header.group_color = group.color.clone();
        header.depth = group.depth;
        self.push(header);
        let member_rows_start = self.rows.len();
        self.append_members(group, &members, children, index, section, filtering, group_collapsed);
        for row in self.rows.iter_mut().skip(member_rows_start) {
            row.depth = group.depth.saturating_add(1);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn append_members(
        &mut self,
        group: &Group,
        members: &[Member<'_>],
        children: &[&Workspace],
        index: usize,
        section: &SectionId,
        filtering: bool,
        collapsed: bool,
    ) {
        let o = self.o;
        let gid = Some(group.id.as_str());
        let member_row = |mut row: Row, sibling: usize, last: bool| {
            row.group = Some(group.id.clone());
            row.sibling_index = sibling;
            row.parent_index = Some(index);
            row.is_last_in_group = last;
            row.group_color = group.color.clone();
            row
        };
        if collapsed {
            let kept: Vec<(usize, &Workspace)> = members
                .iter()
                .enumerate()
                .filter_map(|(i, m)| match m {
                    Member::Workspace(ws) if o.shown_in_collapsed(&group.id, &ws.id) => {
                        children.iter().find(|c| c.id == ws.id).map(|c| (i, *c))
                    }
                    _ => None,
                })
                .collect();
            for (n, (child_index, ws)) in kept.iter().enumerate() {
                let row = self.workspace_row(ws, section, *child_index, Content::base(ws));
                let row = member_row(row, *child_index, n.saturating_add(1) == kept.len());
                self.push(row);
            }
            return;
        }
        let fold = FoldId::list(section, gid);
        let member_ws = |i: usize| match members.get(i) {
            Some(Member::Workspace(ws)) => Some(*ws),
            _ => None,
        };
        let ids: Vec<Option<&str>> = members
            .iter()
            .map(|m| match m {
                Member::Workspace(ws) => Some(ws.id.as_str()),
                Member::Item(_) => None,
            })
            .collect();
        let member_tree = tree_rows(&ids, &member_ws, o.session_tree.as_ref(), filtering);
        let mut member_tree_row: HashMap<usize, &TreeRow> = HashMap::new();
        for row in member_tree.iter().filter(|r| r.fold.is_some()) {
            member_tree_row.entry(row.index).or_insert(row);
        }
        let entries: Vec<Entry> = member_tree.iter().map(|r| (r.index as isize, r.depth)).collect();
        let by_entry = |i: isize| usize::try_from(i).ok().and_then(member_ws);
        let drawn = folding_done(&entries, &by_entry, &fold, &|_| true, o);
        let folded_gap = gap_entry(&drawn, o.gap.as_ref(), section, gid, members.len());
        for (position, &(child_index, depth)) in drawn.iter().enumerate() {
            let last = position.saturating_add(1) == drawn.len();
            if Some(child_index) == folded_gap
                && let Some(gap) = &o.gap
            {
                self.open_gap(section, gid, gap.index);
            }
            let Ok(child) = usize::try_from(child_index) else {
                self.append_fold(
                    child_index,
                    &fold,
                    depth,
                    Some(index),
                    group.color.as_deref(),
                    last,
                );
                continue;
            };
            if folded_gap.is_none() {
                self.open_gap(section, gid, child_index);
            }
            let row = match members.get(child) {
                Some(Member::Workspace(ws)) => {
                    let tree = member_tree_row.get(&child);
                    let content = Content {
                        tree_depth: depth,
                        tree_fold: tree.and_then(|t| t.fold),
                        roll_up: tree.and_then(|t| t.roll_up),
                    };
                    self.workspace_row(ws, section, child, content)
                }
                Some(Member::Item(item)) => {
                    let mut row = Row::new(
                        Key::Item(item.id.clone()),
                        self.y,
                        self.m.empty_content_height(),
                        section.clone(),
                    );
                    row.content = Some(Content::default());
                    row
                }
                None => continue,
            };
            let row = member_row(row, child, last);
            self.push(row);
        }
        if folded_gap == Some(GAP_AT_END)
            && let Some(gap) = &o.gap
        {
            self.open_gap(section, gid, gap.index);
        }
        self.open_gap(section, gid, members.len() as isize);
    }

    /// One node of a section at its model index (`make`'s `emit`).
    fn emit(
        &mut self,
        section: &SectionId,
        index: usize,
        entry: &NodeEntry<'_>,
        tree: Option<&TreeRow>,
        opens_gap: bool,
        ctx: &EmitContext,
    ) {
        if opens_gap {
            self.open_gap(section, None, index as isize);
        }
        match entry.0 {
            Node::Workspace(ws) => {
                let base = Content::base(ws);
                let content = match tree {
                    Some(t) => Content {
                        tree_depth: t.depth,
                        tree_fold: t.fold.or(base.tree_fold),
                        roll_up: t.roll_up,
                    },
                    None => Content { tree_depth: 0, tree_fold: base.tree_fold, roll_up: None },
                };
                let row = self.workspace_row(ws, section, index, content);
                self.push(row);
            }
            Node::Item(item) => {
                let mut row = Row::new(
                    Key::Item(item.id.clone()),
                    self.y,
                    self.m.empty_content_height(),
                    section.clone(),
                );
                row.sibling_index = index;
                row.content = Some(Content::default());
                self.push(row);
            }
            Node::Group(group) => {
                let has_subgroups = ctx.subgroup_parents.contains(group.id.as_str());
                self.append_group(group, &entry.1, index, section, has_subgroups, ctx.filtering);
            }
        }
    }
}

type NodeEntry<'a> = (&'a Node, Vec<&'a Workspace>);

struct EmitContext<'a> {
    subgroup_parents: HashSet<&'a str>,
    filtering: bool,
}

/// `soleMember`: the workspace a group draws as its one row, or nil when it keeps its header.
pub(crate) fn sole_member<'a>(
    group: &Group,
    members: &[Member<'a>],
    has_subgroups: bool,
    o: &Options,
) -> Option<&'a Workspace> {
    if members.len() != 1 || held(group, o) != 1 || has_subgroups {
        return None;
    }
    let Some(&Member::Workspace(ws)) = members.first() else { return None };
    names(group, &ws.title).then_some(ws)
}

/// `held`: the members a group holds, a dragged one excepted (a filter's hidden ones count).
fn held(group: &Group, o: &Options) -> usize {
    let workspaces =
        group.workspaces.iter().filter(|w| !o.excluded_workspaces.contains(&w.id)).count();
    let items = group
        .items
        .iter()
        .filter(|i| o.excluded_item.as_deref() != Some(i.item.id.as_str()))
        .count();
    workspaces.saturating_add(items)
}

/// `names`: `title` is the group's name, both trimmed, the name not empty.
fn names(group: &Group, title: &str) -> bool {
    let name = group.name.trim();
    !name.is_empty() && title.trim() == name
}

/// `liveDepth`: the depth the sole member draws at, or nil when it would not draw as a live row of its own.
fn live_depth(
    ws: &Workspace,
    members: &[Member<'_>],
    group: &Group,
    collapsed: bool,
    fold: &FoldId,
    o: &Options,
) -> Option<usize> {
    if collapsed {
        return o.shown_in_collapsed(&group.id, &ws.id).then_some(0);
    }
    let ids: Vec<Option<&str>> = members
        .iter()
        .map(|m| match m {
            Member::Workspace(w) => Some(w.id.as_str()),
            Member::Item(_) => None,
        })
        .collect();
    let order: Vec<Entry> = tree_order(
        &ids,
        o.session_tree.as_ref().map(|t| &t.parents),
        &|_, _| false,
        None,
        &HashSet::new(),
    )
    .into_iter()
    .map(|(i, d)| (i as isize, d))
    .collect();
    let drawn = folding_done(&order, &|_| Some(ws), fold, &|_| true, o);
    match drawn.as_slice() {
        [(0, depth)] => Some(*depth),
        _ => None,
    }
}

/// `statusRows`: Group by Status, every computer's rows under their state's header.
fn status_rows(
    sections: &[Section],
    spacing: f64,
    chats: &mut Chats,
    b: &mut Builder<'_>,
) -> Vec<Row> {
    let o = b.o;
    let machines: Vec<&Section> = sections.iter().filter(|s| s.machine().is_some()).collect();
    let Some(first) = machines.first() else { return Vec::new() };
    let first_id = first.id();
    b.y += spacing;
    chats.place_pinned(&mut b.y);
    let mut members: HashMap<StatusSection, Vec<(&Workspace, SectionId, usize)>> = HashMap::new();
    for section in &machines {
        let id = section.id();
        for (index, node) in section.nodes.iter().enumerate() {
            for ws in node.workspaces().iter().filter(|w| o.visible(w)) {
                members.entry(ws.status_section).or_default().push((ws, id.clone(), index));
            }
        }
    }
    let start = b.rows.len();
    for status in StatusSection::ALL {
        let Some(listed) = members.get(&status) else { continue };
        let collapsed = status.collapses() && o.grouping.collapsed.contains(&status);
        let mut header =
            Row::new(Key::Status(status), b.y, b.m.group_header_height(), first_id.clone());
        header.is_collapsed = collapsed;
        header.child_count = listed.len();
        b.push(header);
        if collapsed {
            continue;
        }
        for (ws, section, index) in listed {
            let row = b.workspace_row(ws, section, *index, Content::base(ws));
            b.push(row);
        }
    }
    b.rows.split_off(start)
}

/// `appendRecents`: Projects' Show more row, then the Recents header and its rows.
fn append_recents(split: &RecentsSplit, first_row: bool, b: &mut Builder<'_>) {
    if split.hidden_projects > 0 || split.projects_opened {
        let mut row = Row::new(
            Key::ShowMore(FoldId::projects()),
            b.y,
            b.m.empty_content_height(),
            SectionId::Pinned,
        );
        row.is_collapsed = !split.projects_opened;
        row.child_count = split.hidden_projects;
        row.content = Some(Content::default());
        b.push(row);
    }
    let Some(first) = split.recents.first() else { return };
    if !first_row {
        b.y += b.m.section_spacing;
    }
    let mut header = Row::new(
        Key::ListHeader(ListHeader::Recents),
        b.y,
        b.m.group_header_height(),
        first.1.clone(),
    );
    header.child_count = split.recents.len();
    b.push(header);
    for (ws, section, index) in &split.recents {
        let row = b.workspace_row(ws, section, *index, Content::base(ws));
        b.push(row);
    }
}

/// `SidebarLayout.make`.
pub fn make(sections: &[Section], base: &Metrics, o: &Options) -> Layout {
    let m = base.resolved(o);
    let gap_height = o.gap_height.max(0.0);
    if o.hides_workspaces {
        return Layout::empty();
    }
    let once = listing_each_workspace_once(sections);
    let live = if o.archive_section && o.filter_matches.is_none() {
        without_archived(once, o.active_workspace_id.as_deref())
    } else {
        once
    };
    let recents = draws_recents(o).then(|| splitting_recents(&live, o));
    let sections: &[Section] = recents.as_ref().map_or(&live, |r| &r.sections);
    let mut b = Builder { o, m, gap_height, rows: Vec::new(), y: m.top_padding, gap_y: None };
    let filtering = o.filter_matches.is_some();
    let machine_count = sections.iter().filter(|s| s.machine().is_some()).count();
    let lists_any_machine_row =
        sections.iter().any(|s| s.machine().is_some() && !s.nodes.is_empty());
    let mut previous_was_machine = false;
    let mut after_block: Option<f64> = None;
    let mut shown_empty_machine = false;
    let mut chats = Chats::new(if filtering { None } else { o.chat_history.as_ref() }, &m);
    let last_machine = sections.iter().rposition(|s| s.machine().is_some());
    let (mut first_section, mut status_shown, mut status_listed) = (true, false, false);
    let (mut projects_headed, mut recents_placed) = (false, false);
    let mut place_recents = |b: &mut Builder<'_>, first_section: &mut bool| {
        let Some(recents) = &recents else { return };
        if recents_placed {
            return;
        }
        recents_placed = true;
        let before = b.rows.len();
        let first_row = b.rows.is_empty();
        append_recents(recents, first_row, b);
        if b.rows.len() != before {
            *first_section = false;
        }
    };
    for (section_index, section) in sections.iter().enumerate() {
        let sid = section.id();
        let machine = section.machine();
        if last_machine.is_some_and(|last| section_index > last) {
            place_recents(&mut b, &mut first_section);
            let before = b.y;
            chats.place_earlier(&mut b.y);
            if b.y != before {
                first_section = false;
            }
        }
        if o.grouping.by_status && !filtering && machine.is_some() {
            if !status_shown {
                status_shown = true;
                let (start, pinned_chats_y) = (b.y, chats.pinned_y);
                let spacing =
                    if first_section { 0.0 } else { after_block.unwrap_or(m.section_spacing) };
                let status = status_rows(sections, spacing, &mut chats, &mut b);
                status_listed = !status.is_empty() || chats.pinned_y != pinned_chats_y;
                if status_listed {
                    b.rows.extend(status);
                } else {
                    b.y = start;
                }
            }
            if status_listed {
                (first_section, previous_was_machine, after_block) = (false, false, None);
            }
            continue;
        }
        let mut nodes: Vec<NodeEntry<'_>> = Vec::new();
        let mut hidden_groups: HashSet<&str> = HashSet::new();
        let subgroup_parents: HashSet<&str> = section
            .nodes
            .iter()
            .filter_map(|n| match n {
                Node::Group(g) => g.parent.as_deref(),
                _ => None,
            })
            .collect();
        let path = if filtering { path_to_match(section, o) } else { HashSet::new() };
        for node in &section.nodes {
            match node {
                Node::Workspace(ws) => {
                    if o.visible(ws) {
                        nodes.push((node, vec![ws]));
                    }
                }
                Node::Group(g) => {
                    if g.parent.as_deref().is_some_and(|p| hidden_groups.contains(p))
                        || o.excluded_group.as_deref() == Some(g.id.as_str())
                    {
                        hidden_groups.insert(&g.id);
                        continue;
                    }
                    let children: Vec<&Workspace> =
                        g.workspaces.iter().filter(|w| o.visible(w)).collect();
                    if filtering && children.is_empty() && !path.contains(&g.id) {
                        hidden_groups.insert(&g.id);
                        continue;
                    }
                    if g.is_collapsed && !filtering {
                        hidden_groups.insert(&g.id);
                    }
                    nodes.push((node, children));
                }
                Node::Item(item) => {
                    if !filtering && o.excluded_item.as_deref() != Some(item.id.as_str()) {
                        nodes.push((node, Vec::new()));
                    }
                }
            }
        }
        let is_pinned = sid == SectionId::Pinned;
        let gap_here = o.gap.as_ref().is_some_and(|g| g.section == sid);
        if nodes.is_empty() && filtering {
            continue;
        }
        if is_pinned && nodes.is_empty() && !o.show_empty_pinned && !gap_here {
            continue;
        }
        let doc_id = section.doc_id();
        let is_doc = doc_id.is_some();
        let block_height = doc_id.and_then(|d| o.block_heights.get(d).copied()).unwrap_or(0.0);
        if doc_id.is_some_and(|d| o.collapsed_doc_sections.contains(d)) {
            nodes.clear();
        }
        let empty_drop_zone =
            doc_id.is_some_and(|d| o.empty_doc_sections.contains(d)) && !filtering;
        if is_doc && nodes.is_empty() && block_height == 0.0 && !gap_here && !empty_drop_zone {
            continue;
        }
        let flat = o.flattens_machines && machine.is_some() && !section.keeps_header_in_one_list();
        if recents.is_some() && machine.is_some() && nodes.is_empty() && !gap_here {
            continue;
        }
        if flat && nodes.is_empty() && !gap_here && (lists_any_machine_row || shown_empty_machine) {
            continue;
        }
        if flat && nodes.is_empty() {
            shown_empty_machine = true;
        }
        if o.flattens_machines
            && machine == Some(MachineKind::Cloud)
            && !section.is_host_group
            && nodes.is_empty()
            && !gap_here
        {
            continue;
        }
        if first_section && block_height > 0.0 {
            b.y -= m.top_padding;
        }
        if !first_section && (!flat || !previous_was_machine) && block_height == 0.0 {
            b.y += after_block.unwrap_or(m.section_spacing);
        }
        first_section = false;
        if let Some(r) = &recents
            && !projects_headed
            && machine.is_some()
            && !nodes.is_empty()
            && r.project_count > 0
        {
            projects_headed = true;
            let mut header = Row::new(
                Key::ListHeader(ListHeader::Projects),
                b.y,
                m.group_header_height(),
                sid.clone(),
            );
            header.child_count = r.project_count;
            b.push(header);
        }
        if machine.is_some() {
            chats.place_pinned(&mut b.y);
        }
        let rows_under_block = block_height > 0.0 && (!nodes.is_empty() || empty_drop_zone);
        let ends_in_zone = is_doc && nodes.is_empty() && (block_height == 0.0 || rows_under_block);
        after_block = if ends_in_zone {
            Some(0.0)
        } else if block_height > 0.0 && nodes.is_empty() {
            Some(m.row_spacing)
        } else {
            None
        };
        previous_was_machine = machine.is_some() && flat;
        if let Some(doc) = doc_id
            && block_height > 0.0
        {
            b.rows.push(Row::new(Key::Block(doc.to_owned()), b.y, block_height, sid.clone()));
            b.y += block_height + if rows_under_block { m.row_spacing } else { 0.0 };
        }
        let shows_header = !is_doc
            && (machine.is_none()
                || section.keeps_header_in_one_list()
                || (!flat && (machine_count > 1 || o.shows_sole_machine_header)));
        let collapsed = shows_header && section.is_collapsed && !filtering;
        if shows_header {
            let mut header =
                Row::new(Key::Section(sid.clone()), b.y, m.section_header_height, sid.clone());
            header.is_collapsed = collapsed;
            header.child_count = nodes.len();
            header.titles_projects =
                machine.is_some_and(|k| k != MachineKind::Cloud) && machine_count == 1;
            b.push(header);
        }
        if collapsed {
            continue;
        }
        if nodes.is_empty() {
            if gap_here {
                b.open_gap(&sid, None, 0);
            } else if block_height == 0.0 || empty_drop_zone {
                b.push(Row::new(
                    Key::EmptySection(sid.clone()),
                    b.y,
                    m.empty_section_height,
                    sid.clone(),
                ));
            }
            continue;
        }
        let ctx = EmitContext { subgroup_parents, filtering };
        let node_ws = |i: usize| match nodes.get(i).map(|n| n.0) {
            Some(Node::Workspace(ws)) => Some(ws),
            _ => None,
        };
        let by_folder =
            o.grouping.groups_by_folder() && machine.is_some() && machine_count == 1 && !filtering;
        if !by_folder {
            let fold = FoldId::list(&sid, None);
            let ids: Vec<Option<&str>> = nodes
                .iter()
                .map(|n| match n.0 {
                    Node::Workspace(ws) => Some(ws.id.as_str()),
                    _ => None,
                })
                .collect();
            let tree = tree_rows(&ids, &node_ws, o.session_tree.as_ref(), filtering);
            let mut tree_row: HashMap<usize, &TreeRow> = HashMap::new();
            for row in &tree {
                tree_row.entry(row.index).or_insert(row);
            }
            let entries: Vec<Entry> = tree.iter().map(|r| (r.index as isize, r.depth)).collect();
            let by_entry = |i: isize| usize::try_from(i).ok().and_then(node_ws);
            let limits = |i: isize| usize::try_from(i).ok().and_then(node_ws).is_some();
            let drawn = folding_done(&entries, &by_entry, &fold, &limits, o);
            let folded_gap = gap_entry(&drawn, o.gap.as_ref(), &sid, None, nodes.len());
            for &(index, depth) in &drawn {
                if Some(index) == folded_gap
                    && let Some(gap) = &o.gap
                {
                    b.open_gap(&sid, None, gap.index);
                }
                match usize::try_from(index) {
                    Ok(i) => {
                        let fallback = TreeRow { index: i, depth, fold: None, roll_up: None };
                        let tree = tree_row.get(&i).copied().unwrap_or(&fallback);
                        if let Some(entry) = nodes.get(i) {
                            b.emit(&sid, i, entry, Some(tree), folded_gap.is_none(), &ctx);
                        }
                    }
                    Err(_) => b.append_fold(index, &fold, depth, None, None, false),
                }
            }
            if folded_gap == Some(GAP_AT_END)
                && let Some(gap) = &o.gap
            {
                b.open_gap(&sid, None, gap.index);
            }
            b.open_gap(&sid, None, nodes.len() as isize);
            continue;
        }
        for (index, entry) in nodes.iter().enumerate() {
            if !matches!(entry.0, Node::Workspace(_)) {
                b.emit(&sid, index, entry, None, true, &ctx);
            }
        }
        let plain: Vec<&Node> = nodes.iter().map(|n| n.0).collect();
        let (folders, members) = folder_buckets(&plain);
        for folder in folders {
            let indices = members.get(&folder).cloned().unwrap_or_default();
            let mut header = Row::new(
                Key::Folder(sid.clone(), folder.clone()),
                b.y,
                m.group_header_height(),
                sid.clone(),
            );
            header.child_count = indices.len();
            b.push(header);
            if o.settled.is_empty() && o.automatic.is_empty() {
                for index in indices {
                    if let Some(entry) = nodes.get(index) {
                        b.emit(&sid, index, entry, None, true, &ctx);
                    }
                }
                continue;
            }
            let mut settling = o.clone();
            (settling.folds_done, settling.folds_archived, settling.row_limit) = (false, false, 0);
            let fold = FoldId {
                kind: FoldKind::Settled,
                folder: Some(folder),
                ..FoldId::list(&sid, None)
            };
            let entries: Vec<Entry> = indices.iter().map(|&i| (i as isize, 0)).collect();
            let by_entry = |i: isize| usize::try_from(i).ok().and_then(node_ws);
            let drawn = folding_done(&entries, &by_entry, &fold, &|_| true, &settling);
            for (index, depth) in drawn {
                match usize::try_from(index) {
                    Ok(i) => {
                        if let Some(entry) = nodes.get(i) {
                            b.emit(&sid, i, entry, None, true, &ctx);
                        }
                    }
                    Err(_) => b.append_fold(index, &fold, depth, None, None, false),
                }
            }
        }
        b.open_gap(&sid, None, nodes.len() as isize);
    }
    place_recents(&mut b, &mut first_section);
    chats.place_earlier(&mut b.y);
    b.y += m.bottom_padding;
    let (gap_height, gap_shift) =
        if b.gap_y.is_none() { (0.0, 0.0) } else { (gap_height, gap_height + m.row_spacing) };
    Layout {
        rows: b.rows,
        total_height: b.y,
        gap_y: b.gap_y,
        gap_height,
        gap_shift,
        row_spacing: m.row_spacing,
        pinned_chats_y: chats.pinned_y,
        earlier_chats_y: chats.earlier_y,
    }
}

#[cfg(test)]
#[path = "sidebar_layout_engine_tests.rs"]
mod tests;
