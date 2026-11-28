//! The placement handlers' tables (the app's `Handlers/` placement files):
//! how New ▸ Kind ▸ Placement reaches its place (the kind's own create, or
//! made in the pane and moved), the beside-the-chat steps, where a chat
//! column's respawn and a new chat open, the dock actions' edges and modes,
//! and the action each New Tab kind runs. The app reads its panes, tabs and
//! the daemon's capabilities, sends the facts, and runs the answer (the
//! daemon commands, the waits and the focus stay Swift's).

use serde::{Deserialize, Serialize};

/// The layout op the reducer's `new_placement` plans for a place.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", tag = "op")]
pub enum PlaceOp {
    /// A new split on `edge` (`right`, `left`, `top`, `bottom`).
    Split { edge: String },
    /// A new column, on the left when `left`.
    Column {
        #[serde(default)]
        left: bool,
    },
    /// A new row below.
    Row,
    /// A new tab in the pane.
    Tab,
    /// A new workspace.
    Workspace,
    /// A new window.
    Window,
}

/// What must be checked before a New ▸ Kind ▸ Placement row is offered.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NewAtGate {
    /// Rows on and the daemon's `rows-v1` (New Row's reason).
    Row,
    /// The daemon's `column-left-v1` (New Column Left's reason): Cmd-D's
    /// terminal column on the left; the moves place one there without it.
    ColumnLeft,
}

/// The place a kind's submenu row (`new.<kind>`) opens at: Fork To's default.
pub const SUBMENU_PLACE: &str = "right";

/// The check New ▸ `kind` ▸ `place` needs before it is offered, if any.
pub fn new_at_gate(kind: &str, place: &str) -> Option<NewAtGate> {
    match (kind, place) {
        (_, "row") => Some(NewAtGate::Row),
        ("terminal", "columnLeft") => Some(NewAtGate::ColumnLeft),
        _ => None,
    }
}

/// A kind's own create at a place, in one daemon commit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "create")]
pub enum Create {
    /// Cmd-D's split toward `direction`, a terminal even beside a page or a chat.
    TerminalSplit { direction: &'static str },
    /// Run the registry action `action` on the pane.
    Action { action: &'static str },
    /// A new terminal tab in this pane, from its selected tab.
    TerminalTab,
    /// A New Tab Page in a split `edge` (`right` or `bottom`), swapped back
    /// when it was asked for on the left or above.
    PageSplit { edge: &'static str, swaps_back: bool },
    /// A New Tab Page tab in this pane.
    PageTab,
    /// A new chat tab in this pane.
    ChatTab,
    /// A new chat in its own split toward `direction` (`right` or `down`).
    ChatSplit { direction: &'static str },
}

/// The kind made unselected in the pane, then moved to its place.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Made {
    Terminal,
    Browser,
    AgentChat,
    NewTabPage,
}

/// How a made tab reaches its place once the store lists it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "move")]
pub enum PlaceStep {
    /// Move the tab into a new split on `edge`.
    Split { edge: String },
    /// The daemon places it as a fork is: a column (on the left when
    /// `left` is true), or a row below when `left` is absent.
    Fork { left: Option<bool> },
    /// Run the registry action `action` on the tab.
    Action { action: &'static str },
    /// A new tab is already in its place.
    Finished,
}

/// The facts of one New ▸ Kind ▸ Placement run.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewAtFacts {
    pub kind: String,
    #[serde(flatten)]
    pub op: PlaceOp,
    /// The plan makes the kind there by its own create.
    #[serde(default)]
    pub made_in_place: bool,
    /// The invocation's origin (`user`, `cli`, `mcp`, `script`, `remote`).
    #[serde(default)]
    pub origin: String,
    /// The pane's daemon makes browser tabs (`frontend-browser-tabs-v1`).
    #[serde(default)]
    pub frontend_browser_tabs: bool,
}

/// What a New ▸ Kind ▸ Placement run does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "route")]
pub enum NewAt {
    /// Refused: the pane's daemon makes no browser tab a move can take, so a
    /// browser opens only in a new tab here (`frontend-browser-tabs-v1`).
    NeedsFrontendBrowserTabs,
    /// Run `create` when set; when it is unset or does nothing, make
    /// `made` here (marked agent-driven before its first load when
    /// `agent_driven`) and move it by `place`.
    Open { create: Option<Create>, made: Option<Made>, agent_driven: bool, place: PlaceStep },
}

/// How New ▸ `kind` reaches the plan's place for a run from `origin`. A
/// browser the CLI, MCP or a script opens is an agent's: no saved password
/// fills in it, and only its own create at a new tab (openBrowser) marks it,
/// so at any other place it is made here, marked, then moved.
pub fn new_at(facts: &NewAtFacts) -> NewAt {
    let tab = facts.op == PlaceOp::Tab;
    if facts.kind == "browser" && !tab && !facts.frontend_browser_tabs {
        return NewAt::NeedsFrontendBrowserTabs;
    }
    let agent_driven =
        facts.kind == "browser" && matches!(facts.origin.as_str(), "cli" | "mcp" | "script");
    let own_create = facts.made_in_place && (tab || !agent_driven);
    NewAt::Open {
        create: if own_create { in_place(&facts.kind, &facts.op) } else { None },
        made: made(&facts.kind),
        agent_driven,
        place: place_step(&facts.op),
    }
}

/// The kind's own create at `op`; none when the kind has none there.
pub fn in_place(kind: &str, op: &PlaceOp) -> Option<Create> {
    Some(match (kind, op) {
        ("terminal", PlaceOp::Split { edge }) => {
            Create::TerminalSplit { direction: direction(edge) }
        }
        ("terminal", PlaceOp::Column { left }) => {
            Create::Action { action: if *left { "newColumnLeft" } else { "newColumn" } }
        }
        ("terminal", PlaceOp::Row) => Create::Action { action: "newRow" },
        ("terminal", PlaceOp::Tab) => Create::TerminalTab,
        ("browser", PlaceOp::Split { edge }) if edge == "right" => {
            Create::Action { action: "splitBrowserRight" }
        }
        ("browser", PlaceOp::Split { edge }) if edge == "bottom" => {
            Create::Action { action: "splitBrowserDown" }
        }
        ("browser", PlaceOp::Tab) => Create::Action { action: "openBrowser" },
        ("newTabPage", PlaceOp::Split { edge }) => {
            let across = edge == "left" || edge == "right";
            Create::PageSplit {
                edge: if across { "right" } else { "bottom" },
                swaps_back: edge == "left" || edge == "top",
            }
        }
        ("newTabPage", PlaceOp::Tab) => Create::PageTab,
        ("agentChat", PlaceOp::Tab) => Create::ChatTab,
        ("agentChat", PlaceOp::Split { edge }) if edge == "right" => {
            Create::ChatSplit { direction: "right" }
        }
        ("agentChat", PlaceOp::Split { edge }) if edge == "bottom" => {
            Create::ChatSplit { direction: "down" }
        }
        _ => return None,
    })
}

/// The kind New ▸ `kind` makes in the pane before a move; none for a kind it does not know.
pub fn made(kind: &str) -> Option<Made> {
    match kind {
        "terminal" => Some(Made::Terminal),
        "browser" => Some(Made::Browser),
        "agentChat" => Some(Made::AgentChat),
        "newTabPage" => Some(Made::NewTabPage),
        _ => None,
    }
}

/// How a made tab reaches `op`'s place.
pub fn place_step(op: &PlaceOp) -> PlaceStep {
    match op {
        PlaceOp::Split { edge } => PlaceStep::Split { edge: edge.clone() },
        PlaceOp::Column { left } => PlaceStep::Fork { left: Some(*left) },
        PlaceOp::Row => PlaceStep::Fork { left: None },
        PlaceOp::Workspace => PlaceStep::Action { action: "palette.moveTabToNewWorkspace" },
        PlaceOp::Window => PlaceStep::Action { action: "tab.moveToNewWindow" },
        PlaceOp::Tab => PlaceStep::Finished,
    }
}

/// The pane direction a split edge opens toward.
pub fn direction(edge: &str) -> &'static str {
    match edge {
        "left" => "left",
        "top" => "up",
        "bottom" => "down",
        _ => "right",
    }
}

/// The facts of an open that may go beside the chat a pane shows.
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BesideFacts {
    /// The invocation already opens beside its caller.
    pub beside_caller: bool,
    /// The pane's selected tab is a chat.
    pub selected_is_chat: bool,
    /// The pane keeps a New Tab page as its chat column's (`keepsNewTabPage`).
    pub keeps_new_tab_page: bool,
    /// The run may change the view.
    pub allows_view_change: bool,
}

/// The invocation flags an open beside the chat sets.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BesideFlags {
    pub beside_caller: bool,
    pub new_column_beside: bool,
    pub beside_takes_focus: bool,
}

/// Whether the pane shows a chat: its selected tab is one, or it keeps a New Tab page.
pub fn shows_chat(facts: &BesideFacts) -> bool {
    facts.selected_is_chat || facts.keeps_new_tab_page
}

/// The flags of an open from a pane that shows a chat: it opens beside the
/// caller in a new column, taking focus when the run may change the view.
/// None when the invocation keeps its own.
pub fn beside_chat(facts: &BesideFacts) -> Option<BesideFlags> {
    (!facts.beside_caller && shows_chat(facts)).then_some(BesideFlags {
        beside_caller: true,
        new_column_beside: true,
        beside_takes_focus: facts.allows_view_change,
    })
}

/// Where the tab and the chat are once a beside-the-chat tab is listed.
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BesideStepFacts {
    /// The caller's chat: in the anchor pane (true), elsewhere (false), or
    /// none or not found (absent).
    pub chat_in_anchor: Option<bool>,
    /// The new tab: in the anchor pane (true), moved out (false), or not found (absent).
    pub tab_in_anchor: Option<bool>,
    /// The caller is a lone chat column with a workspace.
    pub lone: bool,
}

/// The step a beside-the-chat open takes once its tab is listed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BesideStep {
    /// The chat already docked and the tab stayed in the anchor: select it there.
    ChatDocked,
    /// The lone chat is still in the anchor: dock it, leaving the tab.
    DockChat,
    /// The tab already left the anchor: reveal it where it went.
    Moved,
    /// Move the tab into the right column (`RightColumnPlacement.decide`).
    RightColumn,
}

/// The step a beside-the-chat open takes.
pub fn beside_step(facts: &BesideStepFacts) -> BesideStep {
    match (facts.chat_in_anchor, facts.tab_in_anchor) {
        (Some(false), Some(true)) => BesideStep::ChatDocked,
        (Some(true), _) if facts.lone => BesideStep::DockChat,
        (_, Some(false)) => BesideStep::Moved,
        _ => BesideStep::RightColumn,
    }
}

/// The focus facts after a beside-the-chat move.
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BesideFocusFacts {
    /// The person moved focus since the open was asked for.
    pub person_acted: bool,
    /// The focused pane is the tab's destination.
    pub focused_is_destination: bool,
    /// The chat pane had focus when the open was asked for.
    pub chat_had_focus: bool,
    /// The focused pane is the anchor.
    pub focused_is_anchor: bool,
}

/// What a beside-the-chat move does with selection and focus.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BesideFocus {
    /// Select the new tab in its destination (keeping focus): not when the
    /// person since focused that very pane.
    pub select: bool,
    /// Focus follows the chat into its dock: it had focus (or its anchor
    /// does) and the person did not move it.
    pub follow_chat: bool,
}

/// What a beside-the-chat move does with selection and focus.
pub fn beside_focus(facts: &BesideFocusFacts) -> BesideFocus {
    BesideFocus {
        select: !(facts.person_acted && facts.focused_is_destination),
        follow_chat: (facts.chat_had_focus || facts.focused_is_anchor) && !facts.person_acted,
    }
}

/// One tab of a column's only pane, for the lone-chat read.
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ColumnTab {
    /// The tab has an agent session.
    pub agent_session: bool,
    /// The tab is a New Tab page.
    pub new_tab_page: bool,
}

/// Whether a tab is a chat: an agent session that is not a New Tab page.
pub fn is_chat(tab: &ColumnTab) -> bool {
    tab.agent_session && !tab.new_tab_page
}

/// Whether a column of `panes` panes whose first pane holds `tabs` is a lone
/// chat: one pane with one tab (New Tab pages left out when
/// `ignoring_pages`), a chat.
pub fn lone_chat(panes: usize, tabs: &[ColumnTab], ignoring_pages: bool) -> bool {
    let mut kept = tabs.iter().filter(|tab| !ignoring_pages || !tab.new_tab_page);
    match (panes, kept.next(), kept.next()) {
        (1, Some(tab), None) => is_chat(tab),
        _ => false,
    }
}

/// A chat column's placement (`chat_column`'s answer, as the app names it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatSide {
    Here,
    Tab,
    DockChat,
    BesideDock,
}

/// The facts of a split's route from a chat column.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRouteFacts {
    pub placement: ChatSide,
    /// The split has a tab to leave behind.
    #[serde(default)]
    pub respawn: bool,
    /// The daemon serves `tab-column-respawn-v1`.
    #[serde(default)]
    pub tab_column_respawn: bool,
    /// The pane has a first tab (the chat to dock).
    #[serde(default)]
    pub has_tab: bool,
}

/// Where a split from a chat column goes: a lone chat docks only with a tab
/// left behind on a daemon that respawns one, else the split stays here.
pub fn chat_route(facts: &ChatRouteFacts) -> ChatSide {
    match facts.placement {
        ChatSide::DockChat if !(facts.respawn && facts.tab_column_respawn && facts.has_tab) => {
            ChatSide::Here
        }
        side => side,
    }
}

/// The tab a split beside a chat dock leaves behind.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Respawn {
    Terminal,
    Browser {
        url: String,
        /// The url is a New Tab page's address (either engine's).
        #[serde(default)]
        new_tab_address: bool,
    },
}

/// What opens beside a chat dock.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BesideDockOpen {
    /// A new terminal column after the pane, with the respawn's options.
    NewColumn,
    /// The web page opens on Home (`workspace.open_url`).
    OpenOnHome,
    /// A browser tab of the url, engine and profile.
    BrowserTab,
    /// A New Tab Page split right.
    NewTabPage,
}

/// What opens beside a chat dock for the tab a split would leave behind.
pub fn beside_dock_open(respawn: Option<&Respawn>) -> BesideDockOpen {
    match respawn {
        Some(Respawn::Terminal) => BesideDockOpen::NewColumn,
        Some(Respawn::Browser { url, .. }) if is_web_page(url) => BesideDockOpen::OpenOnHome,
        Some(Respawn::Browser { new_tab_address: false, .. }) => BesideDockOpen::BrowserTab,
        Some(Respawn::Browser { .. }) | None => BesideDockOpen::NewTabPage,
    }
}

/// Whether `url` is an http or https address.
pub fn is_web_page(url: &str) -> bool {
    if url.chars().any(char::is_whitespace) {
        return false;
    }
    url.split_once(':')
        .is_some_and(|(scheme, _)| matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https"))
}

/// Where a new chat opens (`chat_column`'s `newChat`, as the app names it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewChatSide {
    Here,
    Dock,
    BesideDock,
    NewDock,
}

/// The facts of a new chat's opening.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewChatFacts {
    /// The open follows the chat column's placement (else it opens here as asked).
    #[serde(default)]
    pub placed: bool,
    pub placement: NewChatSide,
    #[serde(default)]
    pub select: bool,
    /// The daemon serves `conversation-tab-split-v1`.
    #[serde(default)]
    pub conversation_tab_split: bool,
}

/// How a new chat opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NewChatOpening {
    /// Open in the chat dock's pane (when shown) instead of this one.
    pub in_dock: bool,
    /// Focus the dock first.
    pub focus_dock: bool,
    pub select: bool,
    /// Kept out of the strip until it moves.
    pub hidden: bool,
    /// Open in its own split to the right.
    pub split_right: bool,
    /// Dock the chat in a new column once it is made.
    pub docks: bool,
}

/// How a new chat opens: in the dock (focusing it when selected), in a split
/// right beside a dock on a daemon that splits conversations, or made hidden
/// and unselected, then docked in a new column.
pub fn new_chat_opening(facts: &NewChatFacts) -> NewChatOpening {
    let mut opening = NewChatOpening {
        in_dock: false,
        focus_dock: false,
        select: facts.select,
        hidden: false,
        split_right: false,
        docks: false,
    };
    if !facts.placed {
        return opening;
    }
    match facts.placement {
        NewChatSide::Here => {}
        NewChatSide::Dock => (opening.in_dock, opening.focus_dock) = (true, facts.select),
        NewChatSide::BesideDock => opening.split_right = facts.conversation_tab_split,
        NewChatSide::NewDock => {
            (opening.hidden, opening.select, opening.docks) = (true, false, true);
        }
    }
    opening
}

/// Where the main pane's agent tab opens for a chat column's side.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentTabTarget {
    /// In the strip pane the side names, with no outbound hold.
    Strip,
    /// In this pane, held outbound until its chat docks.
    Docking,
}

/// Where the main pane's agent tab opens; none where it does not handle the side.
pub fn agent_tab_target(side: ChatSide) -> Option<AgentTabTarget> {
    match side {
        ChatSide::Tab => Some(AgentTabTarget::Strip),
        ChatSide::DockChat => Some(AgentTabTarget::Docking),
        ChatSide::Here | ChatSide::BesideDock => None,
    }
}

/// The pane focused once the main pane's chat docked.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DockedFocus {
    /// The pane the tab stayed in.
    Pane,
    /// The chat's new dock.
    Dock,
}

/// The pane focused once the main pane's chat docked: the pane when asked,
/// else the dock when the chat had focus and its dock is found.
pub fn docked_focus(focus: bool, chat_had_focus: bool, dock_found: bool) -> Option<DockedFocus> {
    if focus {
        Some(DockedFocus::Pane)
    } else if chat_had_focus && dock_found {
        Some(DockedFocus::Dock)
    } else {
        None
    }
}

/// A dock column edge.
pub const DOCK_EDGES: [&str; 4] = ["left", "right", "top", "bottom"];

fn dock_edge(edge: Option<&str>) -> Option<&'static str> {
    DOCK_EDGES.into_iter().find(|known| Some(*known) == edge)
}

fn dock_mode(mode: Option<&str>) -> Option<&'static str> {
    ["docked", "overlay"].into_iter().find(|known| Some(*known) == mode)
}

/// The dock settings' defaults.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DockSettings {
    /// cmux.json `layout.dockColumnEdge` when set to an edge; none for the
    /// default `nearest`, which leaves the choice to `DockDefaults`.
    pub configured_edge: Option<&'static str>,
    /// The configured edge, else right: for paths with no column to measure.
    pub default_edge: &'static str,
    /// cmux.json `layout.dockColumnMode`: overlay when set so, else docked.
    pub default_mode: &'static str,
}

/// The dock settings' defaults from cmux.json's `layout.dockColumnEdge` and `layout.dockColumnMode`.
pub fn dock_settings(edge: Option<&str>, mode: Option<&str>) -> DockSettings {
    let configured_edge = dock_edge(edge);
    DockSettings {
        configured_edge,
        default_edge: configured_edge.unwrap_or("right"),
        default_mode: if mode == Some("overlay") { "overlay" } else { "docked" },
    }
}

/// The edge and mode a dock action asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DockAsk {
    /// None: the edge the column is nearer to (`DockDefaults`).
    pub edge: Option<&'static str>,
    /// None: the daemon's (a tab moved to a new docked column).
    pub mode: Option<&'static str>,
}

/// The edge and mode `action` asks for, from its `edge` and `mode`
/// arguments and the settings; none for an action that is not a dock's.
pub fn dock_ask(
    action: &str,
    edge: Option<&str>,
    mode: Option<&str>,
    settings: &DockSettings,
) -> Option<DockAsk> {
    let default_mode = Some(settings.default_mode);
    let (edge, mode) = match action {
        "column.dock" => (dock_edge(edge), dock_mode(mode).or(default_mode)),
        "column.dockLeft" => (Some("left"), default_mode),
        "column.dockRight" => (Some("right"), default_mode),
        "column.dockTop" => (Some("top"), default_mode),
        "column.dockBottom" => (Some("bottom"), default_mode),
        "column.float" => (None, Some("overlay")),
        "tab.moveToNewDockColumn" => {
            (Some(dock_edge(edge).unwrap_or(settings.default_edge)), dock_mode(mode))
        }
        _ => return None,
    };
    Some(DockAsk { edge, mode })
}

/// The layout model's refusal of a column dock change.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockRefusal {
    UnknownColumn,
    LastScrollingColumn,
    Unchanged,
}

/// How a refused dock change fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "failure", content = "reason")]
pub enum DockFailure {
    /// The target is invalid, for the reason the app words.
    InvalidTarget(DockReason),
    /// There is nothing to change, for the reason the app words.
    NoTarget(DockReason),
}

/// The reason a dock change failed (the app's `RefusalStrings`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DockReason {
    NoColumnShown,
    LastScrollingColumn,
    ColumnNotDocked,
    ColumnAlreadyDocked,
}

/// How a refused dock change fails; `undocking` when it asked for no dock.
pub fn dock_failure(refusal: DockRefusal, undocking: bool) -> DockFailure {
    match refusal {
        DockRefusal::UnknownColumn => DockFailure::InvalidTarget(DockReason::NoColumnShown),
        DockRefusal::LastScrollingColumn => {
            DockFailure::InvalidTarget(DockReason::LastScrollingColumn)
        }
        DockRefusal::Unchanged if undocking => DockFailure::NoTarget(DockReason::ColumnNotDocked),
        DockRefusal::Unchanged => DockFailure::NoTarget(DockReason::ColumnAlreadyDocked),
    }
}

/// The action that opens a New Tab kind on its own, whose title New <Kind> Tab takes in a tab's menu.
pub fn new_tab_action(kind: &str) -> Option<&'static str> {
    match kind {
        "terminal" => Some("newSurface"),
        "browser" => Some("openBrowser"),
        "agent" => Some("palette.newAgentChat"),
        "page" => Some("newTab.page"),
        _ => None,
    }
}

/// The `selectedKind` a new tab's facts name for its neighbor's tab kind:
/// a terminal is `pty`, a browser `browser`, any other `other`.
pub fn selected_kind(kind: Option<&str>) -> Option<&'static str> {
    kind.map(|kind| match kind {
        "pty" => "pty",
        "browser" => "browser",
        _ => "other",
    })
}

/// Whether a split of the focused pane follows `newPanePlacement`: only a
/// person's run that names no pane does.
pub fn pane_route_follows_setting(origin: &str, names_pane: bool) -> bool {
    origin == "user" && !names_pane
}

#[cfg(test)]
#[path = "handlers_placement_tests.rs"]
mod tests;
