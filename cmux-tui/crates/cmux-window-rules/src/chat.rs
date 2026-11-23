//! Where an agent chat, a tool opened from it and a column action go.
//!
//! The chat dock is the left dock column with the agent chat role
//! (lawrence-call-1006 D, two columns): a person's new tab from it is a tab
//! in the scrolling strip, a new agent chat joins it, and a chat alone on its
//! screen docks left when the first tool opens. Home's pinned dock (the
//! Chief) takes no new tab or chat: what it opens goes beside it. The app
//! reads its screen's columns (in strip order) and the pane's facts, asks
//! here, and moves the tabs. Column actions (widths, moves, focus, docking,
//! the canvas) are planned here over the column the app found.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub mod agent;

/// A dock column's role.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockRole {
    /// The agent chat column: new terminals and browsers open beside it, never in it.
    AgentChat,
    #[serde(other)]
    Other,
}

/// A column docked to an edge.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Dock {
    pub role: Option<DockRole>,
    /// `pinned-dock-v1`: Home's dock.
    pub pinned: bool,
    /// `pinned-dock-v1`: a pinned column that takes dragged tabs.
    pub allows_tabs: bool,
}

impl Dock {
    fn is_chat(&self) -> bool {
        self.role == Some(DockRole::AgentChat)
    }

    /// Whether this chat dock takes only agent chats: every chat dock but
    /// Home's pinned dock while it takes tabs (`allow_tabs`; Leo 2026-10-21:
    /// "JUST MAKE THE TAB THING SHOW UP ON THE MAIN PANE TOO").
    pub fn takes_only_chats(&self) -> bool {
        self.is_chat() && !(self.pinned && self.allows_tabs)
    }

    /// Whether Split Down of a pane in this column grows it below that pane
    /// (#29848): an unpinned chat dock on a screen that is not `zoomed`.
    pub fn splits_down(&self, zoomed: bool) -> bool {
        !zoomed && self.is_chat() && !self.pinned
    }
}

/// One column of a screen, in strip order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Column {
    /// Its panes in tree order; the first is its top pane.
    pub panes: Vec<String>,
    pub dock: Option<Dock>,
    /// One pane holding one agent chat (the app reads the pane's tabs).
    pub lone_chat: bool,
}

impl Column {
    fn contains(&self, pane: &str) -> bool {
        self.panes.iter().any(|p| p == pane)
    }

    fn chat_dock(&self) -> Option<&Dock> {
        self.dock.as_ref().filter(|dock| dock.is_chat())
    }
}

/// Where a person's new tab from a pane goes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "placement")]
pub enum ColumnPlacement {
    /// A tab in the pane it was opened from.
    Here,
    /// A tab in this pane of the scrolling strip.
    Tab { pane: String },
    /// The chat is alone on its screen: it moves into a new left chat dock
    /// and the new tab stays in its pane.
    DockChat,
    /// Home's pinned dock alone on its screen (`pinned-dock-alone-v1`): the
    /// new tab opens in a new column right of it.
    BesideDock,
}

/// Where a person's new tab from `pane` goes. A `zoomed` screen shows only
/// its zoomed pane, so nothing docks or moves; `recent` orders panes by last
/// focus, newest first. Only the role makes a chat dock.
pub fn column_placement(
    pane: &str,
    columns: &[Column],
    recent: &[String],
    zoomed: bool,
) -> ColumnPlacement {
    let Some(column) = columns.iter().find(|c| c.contains(pane)).filter(|_| !zoomed) else {
        return ColumnPlacement::Here;
    };
    let strip: Vec<&Column> = columns.iter().filter(|c| c.dock.is_none()).collect();
    if let Some(dock) = column.chat_dock() {
        let Some(first) = strip.first() else {
            return if dock.pinned { ColumnPlacement::BesideDock } else { ColumnPlacement::Here };
        };
        let used = recent.iter().find(|id| strip.iter().any(|c| c.contains(id)));
        let Some(target) = used.or(first.panes.first()) else { return ColumnPlacement::Here };
        return ColumnPlacement::Tab { pane: target.clone() };
    }
    let any_chat_dock = columns.iter().any(|c| c.chat_dock().is_some());
    if column.dock.is_none() && strip.len() == 1 && !any_chat_dock && column.lone_chat {
        ColumnPlacement::DockChat
    } else {
        ColumnPlacement::Here
    }
}

/// The chat dock column (not Home's pinned one) holding `pane`, and whether
/// `pane` is its top pane (the chat's).
fn unpinned_chat_dock<'a>(pane: &str, columns: &'a [Column]) -> Option<(&'a Column, bool)> {
    let column = columns.iter().find(|c| c.contains(pane))?;
    let dock = column.chat_dock()?;
    if dock.pinned {
        return None;
    }
    Some((column, column.panes.first().is_some_and(|p| p == pane)))
}

/// Whether a person's New Tab page from `pane` opens in `pane` itself: the
/// chat dock's top pane (Leo 2026-10-30: "IF I'M FOCUSED ON THE MAIN PANE
/// OPEN IT THERE"). A pane Split Down made below the chat is an ordinary pane.
pub fn keeps_new_tab_page(pane: &str, columns: &[Column]) -> bool {
    unpinned_chat_dock(pane, columns).is_some_and(|(_, top)| top)
}

/// Whether `pane` is one Split Down made below the chat in the chat dock (#29848).
pub fn is_below_chat(pane: &str, columns: &[Column]) -> bool {
    unpinned_chat_dock(pane, columns).is_some_and(|(_, top)| !top)
}

/// The strip pane a terminal or browser picked on a New Tab page in the
/// chat dock's top pane opens in (the one used last, else the first); None
/// anywhere else, on a zoomed screen, or with no strip beside the dock.
pub fn page_pick(
    pane: &str,
    columns: &[Column],
    recent: &[String],
    zoomed: bool,
) -> Option<String> {
    if !keeps_new_tab_page(pane, columns) {
        return None;
    }
    match column_placement(pane, columns, recent, zoomed) {
        ColumnPlacement::Tab { pane } => Some(pane),
        _ => None,
    }
}

/// Where a new agent chat opens: the chat dock is the workspace's one chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "placement")]
pub enum NewChatPlacement {
    /// A tab in the pane it was opened from.
    Here,
    /// A tab in the chat dock's pane (or, beside Home's pinned dock, the first scrolling pane).
    Dock { pane: String },
    /// A new left chat dock, made from the chat once it exists.
    NewDock,
    /// A new column right of Home's pinned dock alone on its screen.
    BesideDock,
}

/// Where a new chat from `pane` opens. `lone_chat`: the pane's column is one
/// pane holding one agent chat, the only scrolling column (it docks when the
/// first tool opens, so a second chat joins its pane).
pub fn new_chat_placement(pane: &str, columns: &[Column], lone_chat: bool) -> NewChatPlacement {
    if !columns.iter().any(|c| c.contains(pane)) {
        return NewChatPlacement::Here;
    }
    if let Some(column) = columns.iter().find(|c| c.chat_dock().is_some()) {
        let first = |c: &Column| c.panes.first().cloned();
        if column.chat_dock().is_some_and(|d| !d.pinned) {
            return first(column)
                .map_or(NewChatPlacement::Here, |pane| NewChatPlacement::Dock { pane });
        }
        // `pinned-dock-v1`: Home's dock takes no new chat, even while it takes
        // dragged tabs: where it was asked for, else the first scrolling pane.
        if !column.contains(pane) {
            return NewChatPlacement::Here;
        }
        return match columns.iter().find(|c| c.dock.is_none()) {
            Some(strip) => {
                first(strip).map_or(NewChatPlacement::Here, |pane| NewChatPlacement::Dock { pane })
            }
            None => NewChatPlacement::BesideDock,
        };
    }
    if lone_chat { NewChatPlacement::Here } else { NewChatPlacement::NewDock }
}

/// A tab moving into a pane, as the chat dock reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Moving {
    /// A reorder in its own pane, not a move into it.
    pub same_pane: bool,
    /// An agent chat (a tab group never is).
    pub chat: bool,
}

/// What one pane of a screen is, for every chat placement asked of it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnRead {
    pub placement: ColumnPlacement,
    pub new_chat: NewChatPlacement,
    pub keeps_new_tab_page: bool,
    pub below_chat: bool,
    pub page_pick: Option<String>,
    /// The pane's column is a chat dock (any, Home's included).
    pub chat_dock: bool,
    /// That dock takes only agent chats.
    pub takes_only_chats: bool,
    /// Split Down of the pane grows its chat dock.
    pub splits_down: bool,
    /// The chat dock refuses `moving` (a tool, or a group, moved into it).
    pub refuses_move: bool,
    /// The top pane of the screen's chat dock (not Home's pinned one): the workspace's one chat.
    pub chat_dock_top: Option<String>,
}

/// Every chat placement of `pane` at once.
pub fn read(
    pane: &str,
    columns: &[Column],
    recent: &[String],
    zoomed: bool,
    moving: Option<Moving>,
) -> ColumnRead {
    let placement = column_placement(pane, columns, recent, zoomed);
    let lone = placement == ColumnPlacement::DockChat;
    let dock = columns.iter().find(|c| c.contains(pane)).and_then(|c| c.dock);
    let takes_only_chats = dock.is_some_and(|d| d.takes_only_chats());
    ColumnRead {
        new_chat: new_chat_placement(pane, columns, lone),
        keeps_new_tab_page: keeps_new_tab_page(pane, columns),
        below_chat: is_below_chat(pane, columns),
        page_pick: page_pick(pane, columns, recent, zoomed),
        chat_dock: dock.is_some_and(|d| d.is_chat()),
        takes_only_chats,
        splits_down: dock.is_some_and(|d| d.splits_down(zoomed)),
        refuses_move: moving.is_some_and(|m| !m.same_pane && !m.chat && takes_only_chats),
        chat_dock_top: columns
            .iter()
            .find(|c| c.chat_dock().is_some_and(|d| !d.pinned))
            .and_then(|c| c.panes.first().cloned()),
        placement,
    }
}

/// A person's New Agent Chat (Cmd-I) in a workspace, as the app reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DockedOpen {
    /// A person's key, menu or palette run.
    pub user: bool,
    pub targeted: bool,
    pub has_arguments: bool,
    /// The machine can hold an agent chat.
    pub can_host: bool,
    /// The daemon serves dock roles (`dock-column-role-v1`).
    pub dock_roles: bool,
    pub pane: String,
    /// The pane's [`read`] on its screen; None when no screen shows it.
    pub chat_dock_top: Option<String>,
    /// The read's placement is [`ColumnPlacement::DockChat`] (a lone chat).
    pub docks_chat: bool,
    /// A screen shows the pane.
    pub shown: bool,
    /// A chat from an earlier Cmd-I is still on its way to its dock.
    pub pending_dock: bool,
}

/// What Cmd-I does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "open")]
pub enum DockedOpenDecision {
    /// Not the docked chat's: a script, a target, or a daemon without chat docks.
    NotHandled,
    /// Focus this pane: the workspace's chat dock, or the lone chat itself.
    Focus { pane: String },
    /// Nothing to do: the chat is on its way to its dock.
    Handled,
    /// Open a new chat in the pane, which docks it.
    Open,
}

/// Cmd-I: the workspace's one chat (its unpinned chat dock, else a lone chat)
/// takes focus; Home's pinned dock is not that chat, so a new chat opens
/// beside it (cx-ihyx2, Lawrence 2026-10-14).
pub fn docked_open(facts: &DockedOpen) -> DockedOpenDecision {
    if !(facts.shown
        && facts.user
        && !facts.targeted
        && !facts.has_arguments
        && facts.can_host
        && facts.dock_roles)
    {
        return DockedOpenDecision::NotHandled;
    }
    if let Some(top) = &facts.chat_dock_top {
        return DockedOpenDecision::Focus { pane: top.clone() };
    }
    if facts.docks_chat {
        return DockedOpenDecision::Focus { pane: facts.pane.clone() };
    }
    if facts.pending_dock { DockedOpenDecision::Handled } else { DockedOpenDecision::Open }
}

/// The split decision of a drop on a pane's edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DropSplit {
    /// The chat dock never splits.
    RefusedChatDock,
    Split,
    /// Measure the room first.
    Measure,
}

/// A drop into the chat dock is refused; a drag's preview already measured the room.
pub fn drop_split(room_decided: bool, into_chat_dock: bool) -> DropSplit {
    if into_chat_dock {
        DropSplit::RefusedChatDock
    } else if room_decided {
        DropSplit::Split
    } else {
        DropSplit::Measure
    }
}

/// The pane (index) a drop on a workspace lands in: its first screen's first
/// pane outside the chat dock, else its first pane.
pub fn drop_pane(chat_docks: &[bool]) -> Option<usize> {
    chat_docks.iter().position(|dock| !dock).or((!chat_docks.is_empty()).then_some(0))
}

/// One pane, as an agent chat's destination reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatPane {
    pub id: String,
    pub resource_id: Option<String>,
    /// When the pane last had focus (the daemon's counter).
    pub focused_at: u64,
}

/// One workspace, as an agent chat's destination reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatWorkspace {
    pub id: String,
    pub resource_id: Option<String>,
    /// Its key; a workspace with none is not a destination.
    pub key: Option<String>,
    /// Every screen's panes.
    pub panes: Vec<ChatPane>,
}

/// One window, as an agent chat's destination reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatWindow {
    /// The workspace it shows.
    pub workspace: Option<String>,
    /// Its workspaces, most recent first.
    pub recency: Vec<String>,
    /// The workspace its focus topology is of, and its focused pane.
    pub focus_workspace: Option<String>,
    pub focused_pane: Option<String>,
    /// The pane each workspace last had focused in it.
    pub remembered: HashMap<String, String>,
}

/// A workspace (index into the request's) and a pane of it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatDestination {
    pub workspace: usize,
    pub pane: String,
}

/// The pane focused last of `panes`; the first of equals.
fn latest(panes: &[ChatPane]) -> Option<&ChatPane> {
    panes.iter().fold(None, |best: Option<&ChatPane>, pane| match best {
        Some(best) if best.focused_at >= pane.focused_at => Some(best),
        _ => Some(pane),
    })
}

/// Where a chat a script or agent asks for opens, by client-local focus: the
/// active window first (`windows[0]`), then the others; in each, its shown
/// workspace then its recent ones; there its focused pane (only once the
/// focus topology is of that workspace: the previous workspace's pane never
/// masks it), else the pane it remembers, else the pane focused last. None:
/// no window names a workspace with a key and a pane (ask [`latest_pane`]).
pub fn destination(
    windows: &[ChatWindow],
    workspaces: &[ChatWorkspace],
) -> Option<ChatDestination> {
    for window in windows {
        for id in window.workspace.iter().chain(window.recency.iter()) {
            let Some((index, workspace)) =
                workspaces.iter().enumerate().find(|(_, w)| &w.id == id && w.key.is_some())
            else {
                continue;
            };
            let has = |pane: &String| workspace.panes.iter().any(|p| &p.id == pane);
            let topology = window.workspace.as_ref() == Some(id)
                && window.focus_workspace.as_ref() == Some(id);
            let focused = window.focused_pane.as_ref().filter(|_| topology);
            let preferred =
                focused.filter(|p| has(p)).or(window.remembered.get(id).filter(|p| has(p)));
            if let Some(pane) =
                preferred.cloned().or_else(|| latest(&workspace.panes).map(|p| p.id.clone()))
            {
                return Some(ChatDestination { workspace: index, pane });
            }
        }
    }
    None
}

/// The pane focused last across the workspaces with a key (the first of equals).
pub fn latest_pane(workspaces: &[ChatWorkspace]) -> Option<ChatDestination> {
    let mut best: Option<(usize, &ChatPane)> = None;
    for (index, workspace) in workspaces.iter().enumerate().filter(|(_, w)| w.key.is_some()) {
        for pane in &workspace.panes {
            if best.is_none_or(|(_, b)| pane.focused_at > b.focused_at) {
                best = Some((index, pane));
            }
        }
    }
    best.map(|(workspace, pane)| ChatDestination { workspace, pane: pane.id.clone() })
}

/// What a chat's target names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TargetKind {
    Pane,
    Workspace,
    #[serde(other)]
    Other,
}

/// The pane a chat's target names: a pane by id or resource id, else a
/// workspace (by id, resource id or key) at its pane focused last. The
/// workspaces are every machine's, in order; the first match wins.
pub fn target(kind: TargetKind, id: &str, workspaces: &[ChatWorkspace]) -> Option<ChatDestination> {
    for (index, workspace) in workspaces.iter().enumerate() {
        match kind {
            TargetKind::Pane => {
                let named = |p: &&ChatPane| p.id == id || p.resource_id.as_deref() == Some(id);
                if let Some(pane) = workspace.panes.iter().find(named) {
                    return Some(ChatDestination { workspace: index, pane: pane.id.clone() });
                }
            }
            TargetKind::Workspace => {
                let names = [
                    Some(workspace.id.as_str()),
                    workspace.resource_id.as_deref(),
                    workspace.key.as_deref(),
                ];
                if !names.contains(&Some(id)) {
                    continue;
                }
                return latest(&workspace.panes)
                    .map(|pane| ChatDestination { workspace: index, pane: pane.id.clone() });
            }
            TargetKind::Other => return None,
        }
    }
    None
}

/// The folder a new chat starts in: the caller's, the workspace's agent
/// folder, else the pane's selected tab's (#16620), else its first tab's.
pub fn cwd(
    given: Option<&str>,
    agent_folder: Option<&str>,
    tabs: &[Option<String>],
    selected: i64,
) -> Option<String> {
    if let Some(given) = given.filter(|g| !g.is_empty()) {
        return Some(given.to_owned());
    }
    if let Some(folder) = agent_folder {
        return Some(folder.to_owned());
    }
    usize::try_from(selected).ok().and_then(|i| tabs.get(i)).or(tabs.first()).cloned().flatten()
}

/// The column action ids the app binds, and the ones disabled on a screen's lone column.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnActions {
    /// Planned by [`column_plan`].
    pub planned: Vec<&'static str>,
    /// Disabled with "Add a second column first" on a screen's only column.
    pub lone_column_disabled: Vec<&'static str>,
    /// The canvas arrangement actions.
    pub canvas: Vec<CanvasAction>,
}

/// A canvas arrangement action: its id and the arrangement it runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CanvasAction {
    pub id: &'static str,
    pub arrangement: &'static str,
}

/// Width presets, narrowest first.
const PRESETS: [f64; 4] = [1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0];
const WIDTH_ACTIONS: [(&str, f64); 4] = [
    ("column.widthOneThird", PRESETS[0]),
    ("column.widthHalf", PRESETS[1]),
    ("column.widthTwoThirds", PRESETS[2]),
    ("column.widthFull", PRESETS[3]),
];
const CANVAS: [(&str, &str); 9] = [
    ("canvasTidy", "tidy"),
    ("canvasAlignLeft", "alignLeft"),
    ("canvasAlignRight", "alignRight"),
    ("canvasAlignTop", "alignTop"),
    ("canvasAlignBottom", "alignBottom"),
    ("canvasEqualizeWidths", "equalizeWidths"),
    ("canvasEqualizeHeights", "equalizeHeights"),
    ("canvasDistributeHorizontally", "distributeHorizontally"),
    ("canvasDistributeVertically", "distributeVertically"),
];

pub fn column_actions() -> ColumnActions {
    let mut planned: Vec<&'static str> = WIDTH_ACTIONS.iter().map(|(id, _)| *id).collect();
    planned.extend([
        "column.cycleWidth",
        "column.cycleWidthBack",
        "column.moveLeft",
        "column.moveRight",
        "column.focusLeft",
        "column.focusRight",
        "column.center",
    ]);
    let lone_column_disabled =
        planned.iter().copied().filter(|id| *id != "column.center").collect();
    let canvas = CANVAS.iter().map(|&(id, arrangement)| CanvasAction { id, arrangement }).collect();
    ColumnActions { planned, lone_column_disabled, canvas }
}

/// The preset strictly wider (`forward`) or narrower than `width`, wrapping around.
pub fn next_width(width: f64, forward: bool) -> f64 {
    let epsilon = 0.01;
    if forward {
        PRESETS.into_iter().find(|p| *p > width + epsilon).unwrap_or(PRESETS[0])
    } else {
        PRESETS.into_iter().rev().find(|p| *p < width - epsilon).unwrap_or(PRESETS[3])
    }
}

/// The column a column action runs on, as the app found it.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ActionColumn {
    pub width: f64,
    pub panes: Vec<String>,
    /// The screen's implicit column (a screen that is one split tree): its only column.
    pub implicit: bool,
    pub docked: bool,
}

/// The facts a column action reads.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ColumnFacts {
    pub column: ActionColumn,
    /// The panes of the column on its left and on its right, when there is one.
    pub left: Option<Vec<String>>,
    pub right: Option<Vec<String>>,
    /// The workspace's panes by last focus, newest first.
    pub recent: Vec<String>,
    /// The workspace's focused pane.
    pub focused: Option<String>,
    /// The daemon serves `column-move-v1`.
    pub column_move: bool,
    /// The column's first pane has a daemon handle (a move sends it).
    pub handle: bool,
}

/// Left or right.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Side {
    Left,
    Right,
}

/// Why a column action does nothing; the app words it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "reason")]
pub enum ColumnRefusal {
    AlreadyHasWidth,
    ColumnAtEdge,
    NoColumnInDirection {
        side: Side,
    },
    /// The daemon lacks `column-move-v1` for a column of several panes.
    NeedsColumnMove,
    /// The column's first pane has no daemon handle.
    NoHandle,
}

/// What a column action does.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "plan")]
pub enum ColumnPlan {
    SetWidth {
        width: f64,
    },
    /// `move-column`: the whole column, one daemon commit.
    MoveColumn {
        side: Side,
        pane: String,
    },
    /// `swap-pane` of a one-pane column (a daemon without `column-move-v1`).
    SwapPane {
        side: Side,
        pane: String,
    },
    Focus {
        pane: String,
    },
    Center {
        pane: String,
    },
    /// Refused; `quiet`: a no-op shows no notice (R136).
    Refuse {
        refusal: ColumnRefusal,
        quiet: bool,
    },
    /// Nothing to do (a column with no pane).
    Nothing,
    /// Not a planned column action.
    Unknown,
}

fn quiet(refusal: ColumnRefusal) -> ColumnPlan {
    ColumnPlan::Refuse { refusal, quiet: true }
}

fn set_width(column: &ActionColumn, width: f64) -> ColumnPlan {
    if (column.width - width).abs() > 0.001 {
        ColumnPlan::SetWidth { width }
    } else {
        quiet(ColumnRefusal::AlreadyHasWidth)
    }
}

/// The plan of column action `action` on the column the app found.
pub fn column_plan(action: &str, facts: &ColumnFacts) -> ColumnPlan {
    let column = &facts.column;
    if let Some((_, width)) = WIDTH_ACTIONS.iter().find(|(id, _)| *id == action) {
        return set_width(column, *width);
    }
    let side = |forward: bool| if forward { Side::Right } else { Side::Left };
    let adjacent = |forward: bool| if forward { facts.right.as_ref() } else { facts.left.as_ref() };
    if action == "column.cycleWidth" || action == "column.cycleWidthBack" {
        return set_width(column, next_width(column.width, action == "column.cycleWidth"));
    }
    if !column_actions().planned.contains(&action) {
        return ColumnPlan::Unknown;
    }
    let Some(first) = column.panes.first() else { return ColumnPlan::Nothing };
    match action {
        "column.center" => {
            let focused = facts.focused.as_ref().filter(|p| column.panes.contains(p));
            ColumnPlan::Center { pane: focused.unwrap_or(first).clone() }
        }
        "column.focusLeft" | "column.focusRight" => {
            let forward = action == "column.focusRight";
            // The column's most recently focused tile, else its first.
            let next = adjacent(forward).and_then(|panes| {
                facts.recent.iter().find(|p| panes.contains(p)).or(panes.first()).cloned()
            });
            match next {
                Some(pane) => ColumnPlan::Focus { pane },
                None => quiet(ColumnRefusal::NoColumnInDirection { side: side(forward) }),
            }
        }
        "column.moveLeft" | "column.moveRight" => {
            let forward = action == "column.moveRight";
            if adjacent(forward).is_none() {
                return quiet(ColumnRefusal::ColumnAtEdge);
            }
            let pane = first.clone();
            if !facts.handle {
                ColumnPlan::Refuse { refusal: ColumnRefusal::NoHandle, quiet: false }
            } else if facts.column_move {
                ColumnPlan::MoveColumn { side: side(forward), pane }
            } else if column.panes.len() == 1 {
                ColumnPlan::SwapPane { side: side(forward), pane }
            } else {
                ColumnPlan::Refuse { refusal: ColumnRefusal::NeedsColumnMove, quiet: false }
            }
        }
        _ => ColumnPlan::Unknown,
    }
}

/// Why a column action is disabled up front (never a refusal at run time).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ColumnUnavailable {
    /// "Add a second column first": widths and moves on a screen's only column.
    AddSecondColumn,
    /// Undock on a column that is not docked.
    NotDocked,
}

/// Whether `action` is disabled on `column`; None: available (or no column found).
pub fn column_availability(
    action: &str,
    column: Option<&ActionColumn>,
) -> Option<ColumnUnavailable> {
    let column = column?;
    if action == "column.undock" {
        return (!column.docked).then_some(ColumnUnavailable::NotDocked);
    }
    let disabled = column_actions().lone_column_disabled.contains(&action);
    (disabled && column.implicit).then_some(ColumnUnavailable::AddSecondColumn)
}

/// The facts of a dock change (`set-column-dock`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DockFacts {
    /// The dock asked for is a top or bottom band; false for an undock.
    pub band: bool,
    /// The workspace's daemon serves `dock-columns-v1`.
    pub dock_columns: bool,
    /// It serves `edge-docks-v1`.
    pub edge_docks: bool,
}

/// The daemon capability a dock change lacks (on the wire, its capability name).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum DockNeeds {
    #[serde(rename = "dock-columns-v1")]
    DockColumns,
    #[serde(rename = "edge-docks-v1")]
    EdgeDocks,
    #[serde(rename = "tab-column-respawn-v1")]
    TabColumnRespawn,
}

/// What a dock change needs first that the daemon lacks; None: send it.
pub fn dock_needs(facts: DockFacts) -> Option<DockNeeds> {
    if !facts.dock_columns {
        Some(DockNeeds::DockColumns)
    } else if facts.band && !facts.edge_docks {
        Some(DockNeeds::EdgeDocks)
    } else {
        None
    }
}

/// A screen's only scrolling column docks its focused tab instead: the facts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DockMoveFacts {
    pub pane: String,
    /// The pane's tab count.
    pub pane_tabs: usize,
    /// The column's panes.
    pub column_panes: Vec<String>,
    /// The column's other panes a window shows, in order.
    pub shown_others: Vec<String>,
    /// The pane is shown and has a selected tab to move.
    pub has_tab: bool,
    pub edge_docks: bool,
    pub tab_column_respawn: bool,
}

/// How the focused tab moves into a new docked column.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "move")]
pub enum DockMove {
    Refuse {
        needs: DockNeeds,
    },
    /// The focused pane has no tab to move.
    NoTab,
    /// Move it; `respawn`: a fresh tab of its kind stays behind (the column
    /// keeps a tab to scroll). `anchor` places the new column: a pane's only
    /// tab cannot leave through its own pane, so another pane anchors it.
    Move {
        respawn: bool,
        anchor: String,
    },
}

pub fn dock_move(facts: &DockMoveFacts) -> DockMove {
    if !facts.edge_docks {
        return DockMove::Refuse { needs: DockNeeds::EdgeDocks };
    }
    if !facts.has_tab {
        return DockMove::NoTab;
    }
    let respawn = facts.pane_tabs == 1 && facts.column_panes.len() == 1;
    if respawn && !facts.tab_column_respawn {
        return DockMove::Refuse { needs: DockNeeds::TabColumnRespawn };
    }
    let anchor = if respawn || facts.pane_tabs > 1 {
        facts.pane.clone()
    } else {
        facts
            .shown_others
            .iter()
            .find(|p| **p != facts.pane)
            .cloned()
            .unwrap_or_else(|| facts.pane.clone())
    };
    DockMove::Move { respawn, anchor }
}

#[cfg(test)]
#[path = "chat_tests.rs"]
mod tests;
