//! A sidebar row's own rules, moved from the app's CmuxNextSidebar
//! `SidebarGroupDragPlan`, `SidebarLayoutMetrics` and `WorkspaceRowContent`
//! with the same inputs and outputs:
//!
//! - [`group_drag`]: a dragged group's whole drag as pure geometry. The
//!   base's top-level blocks, the slot a card's centre takes (a step function
//!   of the centre alone), the slot's top and where the drawn list opens the
//!   gap, and the lifted card's cut height ([`card_height`]).
//! - [`metrics`]: a row's height from its lines, status block and subagents,
//!   and the density's row step.
//! - [`row_content`]: which facts a workspace row draws, in which order, for
//!   a compact or an expanded row. The app keeps the words it formats (ages,
//!   dates, localized text) and passes them in; the rule picks among them.
//!
//! Pure, no I/O. The app asks over `cmux_layout_reducer_json` op
//! `sidebar_row_rules` ([`respond`]), one rule per call tagged by `rule`.

use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// Separates second-line items (`WorkspaceRowContent.separator`).
pub const SEPARATOR: &str = " · ";
/// The rows past the cap fade under a bottom edge this tall (`SidebarGroupDragPlan.fade`).
pub const FADE: f64 = 16.0;

// MARK: Group drag

/// A row's identity as the group drag reads it (`SidebarRowKey`'s case).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RowKind {
    Section,
    Workspace,
    Item,
    Group,
    DoneFold,
    ShowMore,
    #[serde(other)]
    Other,
}

/// One laid-out row of the base (`SidebarRow`): what the blocks read.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Row {
    pub kind: RowKind,
    /// A group header's own group id (`.group(id)`), the opened block's group.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub y: f64,
    pub height: f64,
    /// The group the row belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default)]
    pub depth: i64,
    #[serde(default)]
    pub sibling_index: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_index: Option<i64>,
    /// A group's one row standing for its header (`SidebarRow.standsForGroup`).
    #[serde(default)]
    pub stands_for_group: bool,
}

impl Row {
    fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// The header a group's one row stands for (`SidebarRow.standingHeader`), as the blocks read it.
    fn standing_header(&self) -> Option<Row> {
        if !self.stands_for_group {
            return None;
        }
        let group = self.group.clone()?;
        let mut header = self.clone();
        header.kind = RowKind::Group;
        header.id = Some(group);
        header.sibling_index = self.parent_index.unwrap_or(self.sibling_index);
        header.parent_index = None;
        header.depth = self.depth - 1;
        header.stands_for_group = false;
        Some(header)
    }
}

/// One top-level block of the base (`SidebarGroupDragPlan.Block`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Block {
    /// The block's y range, `[top, bottom]`, in base coordinates.
    pub range: [f64; 2],
    /// The index in the request's rows of the block's first row. A group's one
    /// row (`stands_for_group`) heads its block as its standing header.
    pub head: usize,
    /// The node index right after the block: past a group's subgroups.
    pub next_index: i64,
}

/// The top-level blocks of `rows`, top to bottom (`SidebarGroupDragPlan.blocks(of:)`).
pub fn blocks(rows: &[Row]) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut open_group: Option<String> = None;
    for (index, source) in rows.iter().enumerate() {
        if source.height <= 0.0 {
            continue;
        }
        let row = source.standing_header().unwrap_or_else(|| source.clone());
        let in_open_group = open_group.is_some() && (row.group == open_group || row.depth > 0);
        let joins = matches!(
            row.kind,
            RowKind::Workspace
                | RowKind::Item
                | RowKind::Group
                | RowKind::DoneFold
                | RowKind::ShowMore
        ) && in_open_group;
        if joins && let Some(last) = blocks.last_mut() {
            last.range = [last.range[0], last.range[1].max(row.max_y())];
            if row.kind == RowKind::Group {
                last.next_index = last.next_index.max(row.sibling_index + 1);
            }
            continue;
        }
        blocks.push(Block {
            range: [row.y, row.max_y()],
            head: index,
            next_index: row.sibling_index + 1,
        });
        open_group = if row.kind == RowKind::Group { row.id.clone() } else { None };
    }
    blocks
}

/// The number of blocks whose midpoint is above `y` (the midpoints rise top to bottom).
fn raw_slot(y: f64, blocks: &[Block]) -> usize {
    let (mut low, mut high) = (0usize, blocks.len());
    while low < high {
        let mid = (low + high) / 2;
        let range = blocks[mid].range;
        if (range[0] + range[1]) / 2.0 < y {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    low
}

/// A plan (`SidebarGroupDragPlan.init`): the base's blocks and the card.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub blocks: Vec<Block>,
    pub card: f64,
    pub trail: f64,
    pub lead: f64,
    pub group_top: f64,
    pub origin: usize,
    pub allowed: Vec<bool>,
}

impl Plan {
    /// A plan over `blocks` for a card `card` tall whose top was at `group_top`. `allowed` has
    /// one entry per slot (0 through `blocks.len()`); nil accepts every slot, a wrong length none.
    /// The origin always accepts.
    pub fn new(
        blocks: Vec<Block>,
        group_top: f64,
        card: f64,
        lead: f64,
        trail: f64,
        allowed: Option<Vec<bool>>,
    ) -> Plan {
        let origin = raw_slot(group_top, &blocks);
        let slots = blocks.len() + 1;
        let mut accepts = allowed.unwrap_or_else(|| vec![true; slots]);
        if accepts.len() != slots {
            accepts = vec![false; slots];
        }
        accepts[origin] = true;
        Plan { blocks, card, trail, lead, group_top, origin, allowed: accepts }
    }

    /// How far the open gap pushes the blocks at and below the slot.
    pub fn gap(&self) -> f64 {
        self.card + self.trail
    }

    /// The slot a card whose centre is at `centre` takes; a refused slot gives the nearest
    /// accepted one (the upper on a tie).
    pub fn slot(&self, centre: f64) -> usize {
        let raw = raw_slot(centre - self.card / 2.0, &self.blocks);
        if self.allowed[raw] {
            return raw;
        }
        for distance in 1..=self.blocks.len().max(1) {
            if raw >= distance && self.allowed[raw - distance] {
                return raw - distance;
            }
            if raw + distance <= self.blocks.len() && self.allowed[raw + distance] {
                return raw + distance;
            }
        }
        self.origin
    }

    /// The top of the card standing in `slot`.
    pub fn top(&self, slot: usize) -> f64 {
        if let Some(block) = self.blocks.get(slot) {
            return block.range[0];
        }
        self.blocks.last().map_or(self.group_top, |last| last.range[1] + self.lead)
    }
}

/// The lifted card's height (`SidebarGroupDragPlan.cardHeight`): the whole block with at most
/// `max_rows` rows under its header, else cut at the bottom of the `max_rows`-th one.
pub fn card_height(rows: &[[f64; 2]], top: f64, full: f64, max_rows: usize) -> f64 {
    let shown: Vec<&[f64; 2]> = rows.iter().filter(|r| r[1] > r[0]).collect();
    if shown.len() <= max_rows + 1 {
        return full;
    }
    full.min(shown[max_rows][1] - top)
}

/// A dragged row standing in the gap: its y from the card's top and its height.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Carried {
    pub y: f64,
    pub height: f64,
}

fn default_max_rows() -> usize {
    3
}

/// `group_drag`'s request: the base rows and the card, the centres to slot and the slots to place.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GroupDragRequest {
    /// Every row of the base (the list laid out without the dragged group), zero-height ones too.
    pub rows: Vec<Row>,
    pub group_top: f64,
    pub card: f64,
    pub lead: f64,
    pub trail: f64,
    #[serde(default)]
    pub allowed: Option<Vec<bool>>,
    #[serde(default)]
    pub carried: Vec<Carried>,
    /// Card centres to slot.
    #[serde(default)]
    pub centres: Vec<f64>,
    /// Slots to place the card in (`layout(_:slot:)`).
    #[serde(default)]
    pub place: Vec<usize>,
}

/// Where the drawn list opens the gap for one slot (`SidebarGroupDragPlan.layout(_:slot:)`): the
/// carried rows go in at `insert_at` with these ys, every row from there (and a pinned or earlier
/// chats line at or below `top - 0.5`) moves down by `gap`, and the gap is marked at `top`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    pub slot: usize,
    pub top: f64,
    pub insert_at: usize,
    pub carried_y: Vec<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GroupDragReply {
    pub blocks: Vec<Block>,
    pub origin: usize,
    pub allowed: Vec<bool>,
    pub gap: f64,
    pub slots: Vec<usize>,
    pub placements: Vec<Placement>,
}

/// The group drag's answer for one request.
pub fn group_drag(request: &GroupDragRequest) -> GroupDragReply {
    let plan = Plan::new(
        blocks(&request.rows),
        request.group_top,
        request.card,
        request.lead,
        request.trail,
        request.allowed.clone(),
    );
    let slots = request.centres.iter().map(|&c| plan.slot(c)).collect();
    let placements = request
        .place
        .iter()
        .filter(|&&slot| slot <= plan.blocks.len())
        .map(|&slot| {
            let top = plan.top(slot);
            let carried_y = request
                .carried
                .iter()
                .map(|row| top + row.y.min((plan.card - row.height).max(0.0)))
                .collect();
            let insert_at = request
                .rows
                .iter()
                .position(|row| row.y >= top - 0.5)
                .unwrap_or(request.rows.len());
            Placement { slot, top, insert_at, carried_y }
        })
        .collect();
    GroupDragReply {
        gap: plan.gap(),
        origin: plan.origin,
        allowed: plan.allowed.clone(),
        blocks: plan.blocks,
        slots,
        placements,
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CardHeightRequest {
    pub rows: Vec<[f64; 2]>,
    pub top: f64,
    pub full: f64,
    #[serde(default = "default_max_rows")]
    pub max_rows: usize,
}

// MARK: Metrics

fn status_line_height() -> f64 {
    14.0
}
fn progress_bar_height() -> f64 {
    8.0
}
fn status_bottom_padding() -> f64 {
    4.0
}
fn subagent_line_height() -> f64 {
    24.0
}
fn subagent_stack_height() -> f64 {
    18.0
}

/// The row metrics a height reads (`SidebarLayoutMetrics`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Metrics {
    pub row_height: f64,
    pub row_height_with_subtitle: f64,
    #[serde(default)]
    pub two_line_rows: bool,
    #[serde(default = "status_line_height")]
    pub status_line_height: f64,
    #[serde(default = "progress_bar_height")]
    pub progress_bar_height: f64,
    #[serde(default = "status_bottom_padding")]
    pub status_bottom_padding: f64,
    #[serde(default = "subagent_line_height")]
    pub subagent_line_height: f64,
    #[serde(default = "subagent_stack_height")]
    pub subagent_stack_height: f64,
}

impl Metrics {
    /// One line, or two in Expanded: a group header's and a usual row's height.
    pub fn row_step(&self) -> f64 {
        if self.two_line_rows { self.row_height_with_subtitle } else { self.row_height }
    }

    /// The metrics a layout uses: Expanded's two-line rows, not with workspaces as tabs.
    pub fn resolved(&self, expanded: bool, workspaces_as_tabs: bool) -> Metrics {
        let mut m = *self;
        if expanded && !workspaces_as_tabs {
            m.two_line_rows = true;
        }
        m
    }

    /// The subagents under a chat row: a line each, or the one stacked line; 0 without any.
    pub fn subagents_height(&self, content: &RowShape) -> f64 {
        match &content.subagents {
            None => 0.0,
            Some(strip) if strip.stack => self.subagent_stack_height,
            Some(strip) => strip.line_count as f64 * self.subagent_line_height,
        }
    }

    /// The status block under the title lines; 0 without one.
    pub fn status_height(&self, content: &RowShape) -> f64 {
        match content.status_lines {
            None => 0.0,
            Some(lines) => {
                lines as f64 * self.status_line_height
                    + if content.has_progress { self.progress_bar_height } else { 0.0 }
                    + self.status_bottom_padding
            }
        }
    }

    /// A row's height (`SidebarLayoutMetrics.height(for:)`): its lines, never shorter than the
    /// row step, then its status block and subagents.
    pub fn height(&self, content: &RowShape) -> f64 {
        let lines = i64::from(content.has_detail) + i64::from(content.has_meta);
        self.row_step()
            .max(self.row_height + lines as f64 * (self.row_height_with_subtitle - self.row_height))
            + self.status_height(content)
            + self.subagents_height(content)
    }
}

/// A chat row's subagents as a height reads them (`SidebarSubagentStrip`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Strip {
    /// The stacked line (`mode == .stack`), else a line per row.
    #[serde(default)]
    pub stack: bool,
    /// `lineCount` in rows mode.
    #[serde(default)]
    pub line_count: i64,
}

/// What a row's height reads of its content (`WorkspaceRowContent`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowShape {
    #[serde(default)]
    pub has_detail: bool,
    #[serde(default)]
    pub has_meta: bool,
    /// The status block's line count; nil without a block.
    #[serde(default)]
    pub status_lines: Option<i64>,
    #[serde(default)]
    pub has_progress: bool,
    #[serde(default)]
    pub subagents: Option<Strip>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MetricsRequest {
    pub metrics: Metrics,
    #[serde(default)]
    pub expanded: bool,
    #[serde(default)]
    pub workspaces_as_tabs: bool,
    #[serde(default)]
    pub rows: Vec<RowShape>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MetricsReply {
    pub two_line_rows: bool,
    pub row_step: f64,
    pub heights: Vec<f64>,
    pub status_heights: Vec<f64>,
    pub subagents_heights: Vec<f64>,
}

/// Row heights under resolved metrics.
pub fn metrics(request: &MetricsRequest) -> MetricsReply {
    let m = request.metrics.resolved(request.expanded, request.workspaces_as_tabs);
    MetricsReply {
        two_line_rows: m.two_line_rows,
        row_step: m.row_step(),
        heights: request.rows.iter().map(|r| m.height(r)).collect(),
        status_heights: request.rows.iter().map(|r| m.status_height(r)).collect(),
        subagents_heights: request.rows.iter().map(|r| m.subagents_height(r)).collect(),
    }
}

// MARK: Row content

/// A row element (`WorkspaceRowElement`, its Swift raw values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Element {
    Icon,
    Directory,
    Branch,
    Process,
    AgentStatus,
    Ports,
    LastActivity,
    Notification,
    TabCount,
    PullRequest,
    Progress,
    Working,
    Log,
    #[serde(other)]
    Other,
}

/// The status glyph's state (`StatusIndicatorState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Activity {
    Idle,
    Waiting,
    Error,
    Success,
    Busy,
    Paused,
    Working,
}

/// The Priority view's chip (`SidebarPriorityEntry.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Chip {
    NeedsYou,
    Failed,
    Lost,
    CiFailing,
    Done,
    Working,
    Idle,
}

/// The status glyph a row draws (`WorkspaceRowContent.activity`).
pub fn activity(state: Activity, working: bool, progress: bool) -> Activity {
    match state {
        Activity::Idle | Activity::Waiting | Activity::Error | Activity::Success => state,
        Activity::Busy | Activity::Paused => {
            if working || progress {
                state
            } else {
                Activity::Idle
            }
        }
        Activity::Working => {
            if working {
                state
            } else {
                Activity::Idle
            }
        }
    }
}

/// The chip a row may carry: only what asks for the person (`WorkspaceRowContent.rowChip`).
pub fn row_chip(state: Option<Chip>) -> Option<Chip> {
    match state {
        Some(Chip::NeedsYou | Chip::Failed | Chip::Lost | Chip::CiFailing) => state,
        _ => None,
    }
}

fn non_empty(text: Option<&str>) -> Option<&str> {
    text.filter(|t| !t.is_empty())
}

/// Swift's `CharacterSet.newlines`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Swift's `CharacterSet.whitespaces`: spaces and tabs, not newlines.
fn is_space(c: char) -> bool {
    c.is_whitespace() && !is_newline(c)
}

/// Drops an agent-session row's synthetic `local · <title>` line (`nonRedundantDetail`).
pub fn non_redundant_detail(detail: Option<&str>, title: &str) -> Option<String> {
    let detail = non_empty(detail)?;
    let parts: Vec<&str> = detail.split(SEPARATOR).map(str::trim).collect();
    if parts.len() == 2
        && parts[0].to_lowercase() == "local"
        && parts[1].to_lowercase() == title.trim().to_lowercase()
    {
        return None;
    }
    Some(detail.to_owned())
}

/// The description's first non-empty line, trimmed (`descriptionLine`).
pub fn description_line(description: Option<&str>) -> Option<String> {
    description?
        .split(is_newline)
        .map(|line| line.trim_matches(is_space))
        .find(|line| !line.is_empty())
        .map(str::to_owned)
}

fn folded(text: &str) -> String {
    text.nfd().filter(|&c| !is_combining_mark(c)).collect::<String>().to_lowercase()
}

/// Two titles name the same thing: equal once trimmed, ignoring case and diacritics; an empty
/// title names nothing (`WorkspaceRowContent.sameTitle`).
pub fn same_title(a: &str, b: &str) -> bool {
    let (a, b) = (a.trim(), b.trim());
    !a.is_empty() && folded(a) == folded(b)
}

/// The status block a workspace reported (`SidebarWorkspaceStatus`): its entries' display texts.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Reported {
    #[serde(default)]
    pub entries: Vec<String>,
    #[serde(default)]
    pub log: Option<String>,
    #[serde(default)]
    pub progress_label: Option<String>,
}

/// A workspace's progress as a row reads it (`SidebarProgress`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Progress {
    #[serde(default)]
    pub has_value: bool,
    #[serde(default)]
    pub is_error: bool,
}

/// The facts of one workspace a row picks from (`SidebarWorkspace`). The app formats the words
/// it localizes: `last_activity` (a time today, else a short date) and `age` (the short age).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Workspace {
    pub title: String,
    pub directory: Option<String>,
    pub branch: Option<String>,
    pub process: Option<String>,
    pub status: Option<String>,
    pub ports: Option<String>,
    pub notification_text: Option<String>,
    pub pull_request: Option<String>,
    pub stage: Option<String>,
    pub last_message: Option<String>,
    pub description: Option<String>,
    /// `activityText(rowAge)`; nil without an age.
    pub last_activity: Option<String>,
    /// Whether the workspace has an age (`rowAge`).
    pub has_age: bool,
    pub agent_working: bool,
    pub activity: Option<Activity>,
    pub reported: Option<Reported>,
    pub progress: Option<Progress>,
    pub placeholder: bool,
}

/// The elements a compact row shows (`WorkspaceRowElements` resolved for the row's kind).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Elements {
    pub shown: Vec<Element>,
    /// The second line's elements, in order.
    pub second_line: Vec<Element>,
}

impl Elements {
    fn shows(&self, element: Element) -> bool {
        self.shown.contains(&element)
    }
}

/// Which parts of the reported block a row draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusPick {
    pub entries: bool,
    pub log: bool,
    pub progress_label: bool,
}

fn status_pick(reported: Option<&Reported>, set: &Elements) -> Option<StatusPick> {
    let reported = reported?;
    let pick = StatusPick {
        entries: set.shows(Element::AgentStatus) && !reported.entries.is_empty(),
        log: set.shows(Element::Log) && reported.log.is_some(),
        progress_label: set.shows(Element::Progress) && reported.progress_label.is_some(),
    };
    (pick.entries || pick.log || pick.progress_label).then_some(pick)
}

fn bar(ws: &Workspace) -> bool {
    ws.progress.is_some_and(|p| p.has_value || p.is_error || ws.placeholder)
}

fn text_of(element: Element, ws: &Workspace) -> Option<String> {
    let text = match element {
        Element::Directory => non_empty(ws.directory.as_deref()),
        Element::Branch => non_empty(ws.branch.as_deref()),
        Element::Process => non_empty(ws.process.as_deref()),
        Element::AgentStatus => {
            if ws.reported.as_ref().is_some_and(|r| !r.entries.is_empty()) {
                None
            } else {
                non_empty(ws.status.as_deref())
            }
        }
        Element::Ports => non_empty(ws.ports.as_deref()),
        Element::LastActivity => ws.last_activity.as_deref(),
        Element::Notification => non_empty(ws.notification_text.as_deref()),
        _ => None,
    };
    text.map(str::to_owned)
}

/// What a row draws (`WorkspaceRowContent`'s choices): the app builds its row from it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Content {
    pub icon: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub tab_count: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge: Option<String>,
    pub activity: Activity,
    pub progress: bool,
    pub shows_working: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<StatusPick>,
    /// The reported entry or status line moved onto the name's line.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trailing_status: Option<String>,
    /// Draw the age: a compact row's dim time, or an expanded row's time on the title's line.
    pub age: bool,
    pub expanded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meta: Option<String>,
}

/// A compact row (`WorkspaceRowContent.init(_:preferences:)` without a custom layout).
pub fn compact(ws: &Workspace, set: &Elements) -> Content {
    let second_line: Vec<(Element, String)> =
        set.second_line.iter().filter_map(|&e| text_of(e, ws).map(|t| (e, t))).collect();
    let mut items: Vec<String> = second_line.iter().map(|(_, t)| t.clone()).collect();
    let mut status = status_pick(ws.reported.as_ref(), set);
    let others = second_line.iter().filter(|(e, _)| *e != Element::AgentStatus).count();
    let mut trailing = None;
    if others == 0 {
        let line =
            second_line.iter().find(|(e, _)| *e == Element::AgentStatus).map(|(_, t)| t.clone());
        if let (Some(line), None) = (&line, status) {
            trailing = Some(line.clone());
            items.clear();
        } else if let (Some(pick), Some(reported)) = (status, ws.reported.as_ref())
            && pick.entries
            && reported.entries.len() == 1
            && !pick.log
            && !pick.progress_label
        {
            trailing = Some(reported.entries[0].clone());
            status = None;
        }
    }
    let working = ws.agent_working && set.shows(Element::Working);
    let joined = (!items.is_empty()).then(|| items.join(SEPARATOR));
    Content {
        icon: set.shows(Element::Icon),
        detail: non_redundant_detail(joined.as_deref(), &ws.title),
        tab_count: set.shows(Element::TabCount),
        badge: if set.shows(Element::PullRequest) {
            non_empty(ws.pull_request.as_deref()).map(str::to_owned)
        } else {
            None
        },
        activity: activity(
            ws.activity.unwrap_or(Activity::Idle),
            working,
            set.shows(Element::Progress),
        ),
        progress: set.shows(Element::Progress) && bar(ws),
        shows_working: working,
        status,
        trailing_status: trailing,
        age: !set.second_line.contains(&Element::LastActivity) && ws.has_age,
        expanded: false,
        meta: None,
    }
}

/// An expanded row (`WorkspaceRowContent.init(expanded:)`).
pub fn expanded(
    ws: &Workspace,
    machine: Option<&str>,
    shows_notification: bool,
    shows_pull_request: bool,
) -> Content {
    let place: Vec<&str> =
        [ws.directory.as_deref(), ws.branch.as_deref()].into_iter().filter_map(non_empty).collect();
    let meta: Vec<&str> = [
        non_empty(machine),
        non_empty(ws.stage.as_deref()),
        if shows_pull_request { non_empty(ws.pull_request.as_deref()) } else { None },
    ]
    .into_iter()
    .flatten()
    .collect();
    let detail = (if shows_notification {
        non_empty(ws.notification_text.as_deref()).map(str::to_owned)
    } else {
        None
    })
    .or_else(|| description_line(ws.description.as_deref()))
    .or_else(|| non_empty(ws.last_message.as_deref()).map(str::to_owned))
    .or_else(|| non_empty(ws.status.as_deref()).map(str::to_owned))
    .or_else(|| (!place.is_empty()).then(|| place.join(SEPARATOR)));
    Content {
        icon: true,
        detail: non_redundant_detail(detail.as_deref(), &ws.title),
        tab_count: false,
        badge: None,
        activity: activity(ws.activity.unwrap_or(Activity::Idle), ws.agent_working, true),
        progress: bar(ws),
        shows_working: ws.agent_working,
        status: None,
        trailing_status: None,
        age: ws.has_age,
        expanded: true,
        meta: (!meta.is_empty()).then(|| meta.join(SEPARATOR)),
    }
}

fn yes() -> bool {
    true
}

/// `row_content`'s request: one workspace's row, compact (`elements`) or expanded.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowContentRequest {
    pub workspace: Workspace,
    #[serde(default)]
    pub expanded: bool,
    #[serde(default)]
    pub elements: Elements,
    #[serde(default)]
    pub machine: Option<String>,
    #[serde(default = "yes")]
    pub shows_notification: bool,
    #[serde(default = "yes")]
    pub shows_pull_request: bool,
}

/// A row's content for one request.
pub fn row_content(request: &RowContentRequest) -> Content {
    if request.expanded {
        expanded(
            &request.workspace,
            request.machine.as_deref(),
            request.shows_notification,
            request.shows_pull_request,
        )
    } else {
        compact(&request.workspace, &request.elements)
    }
}

// MARK: Wire

/// One `sidebar_row_rules` call, tagged by `rule`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "rule", rename_all = "snake_case")]
pub enum Request {
    GroupDrag(GroupDragRequest),
    CardHeight(CardHeightRequest),
    Metrics(MetricsRequest),
    RowContent(Box<RowContentRequest>),
    RowChip {
        #[serde(default)]
        state: Option<Chip>,
    },
    SameTitle {
        a: String,
        b: String,
    },
}

/// The answer to one [`Request`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reply {
    GroupDrag(GroupDragReply),
    CardHeight { height: f64 },
    Metrics(MetricsReply),
    RowContent(Box<Content>),
    RowChip { chip: Option<Chip> },
    SameTitle { same: bool },
}

/// The op's answer.
pub fn respond(request: &Request) -> Reply {
    match request {
        Request::GroupDrag(r) => Reply::GroupDrag(group_drag(r)),
        Request::CardHeight(r) => {
            Reply::CardHeight { height: card_height(&r.rows, r.top, r.full, r.max_rows) }
        }
        Request::Metrics(r) => Reply::Metrics(metrics(r)),
        Request::RowContent(r) => Reply::RowContent(Box::new(row_content(r))),
        Request::RowChip { state } => Reply::RowChip { chip: row_chip(*state) },
        Request::SameTitle { a, b } => Reply::SameTitle { same: same_title(a, b) },
    }
}

#[cfg(test)]
#[path = "sidebar_row_rules_tests.rs"]
mod tests;
