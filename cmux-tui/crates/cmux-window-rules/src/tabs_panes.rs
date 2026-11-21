//! The pane rules: what a split does (its direction's edge, axis and daemon
//! direction, its folder, and the tool-split outcome), Auto Layout's split
//! direction, the tab bar refusals, and the terminal verbs' tables. Only the
//! decisions: Cmd-D's optimistic execution and the key focus moves stay in
//! the app.

use serde::{Deserialize, Serialize};

use super::Edge;

/// A split direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

/// The pane edge a split toward `direction` opens on.
pub fn edge(direction: Direction) -> Edge {
    match direction {
        Direction::Left => Edge::Left,
        Direction::Right => Edge::Right,
        Direction::Up => Edge::Top,
        Direction::Down => Edge::Bottom,
    }
}

/// The folder facts of a new pane, each as the app read it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SplitFolders {
    /// The `cwd` argument.
    pub explicit: Option<String>,
    /// The home folder when Ghostty's `split-inherit-working-directory` is false.
    pub uninherited: Option<String>,
    /// The folder of the tab it splits: a terminal's, or an agent chat's exact folder.
    pub inherited: Option<String>,
    /// The selected tab's last known folder.
    pub selected: Option<String>,
    /// The pane's first tab's folder.
    pub first: Option<String>,
}

/// What the app's one tool-split rule (`toolSplit`) said.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToolSplit {
    /// A real split of the pane.
    #[default]
    Split,
    /// Refused; the app names its reason.
    Refused,
    /// From the docked chat: a tab in the strip.
    Tab,
    /// The pinned dock: a column on its right.
    BesideDock,
}

/// The facts of one split.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SplitFacts {
    pub direction: Option<Direction>,
    pub folders: SplitFolders,
    pub tool: ToolSplit,
    /// A person's split of a browser tab, the New Tab page or a chat that did
    /// not ask for a terminal: it opens the New Tab page (cx-jfo7).
    pub page: bool,
    /// The pane has a controller (it is shown).
    pub shown: bool,
}

/// What a split does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitDo {
    /// The New Tab page in a new split of the pane, toward `edge`.
    PageSplit,
    /// The tool split's refusal.
    Refuse,
    /// The New Tab page as a tab in the strip.
    StripPage,
    /// A terminal tab in the strip, in `tabCwd`.
    StripTerminal,
    /// The New Tab page right of the pinned dock.
    DockPage,
    /// A new column right of the pinned dock, in `cwd`.
    DockColumn,
    /// The daemon's split.
    Split,
}

/// The plan of one split.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitPlan {
    #[serde(rename = "do")]
    pub action: SplitDo,
    pub edge: Edge,
    /// Left and right split horizontally.
    pub horizontal: bool,
    /// The daemon splits only right or down: left and up split that way, then
    /// swap the original into the new slot.
    pub daemon_direction: Direction,
    pub swap_towards: Option<Direction>,
    /// The split's action id (a refused split's title).
    pub split_action: &'static str,
    /// The new pane's folder.
    pub cwd: Option<String>,
    /// A strip terminal's folder (None: the daemon's resolver).
    pub tab_cwd: Option<String>,
}

/// The action id of a split toward `direction`.
pub fn split_action(direction: Direction) -> &'static str {
    match direction {
        Direction::Left => "splitLeft",
        Direction::Right => "splitRight",
        Direction::Up => "splitUp",
        Direction::Down => "splitDown",
    }
}

/// The plan of a split: the explicit folder, else home when Ghostty does not
/// inherit, else the split tab's folder, else the selected or first tab's.
pub fn split(facts: &SplitFacts) -> SplitPlan {
    let direction = facts.direction.unwrap_or(Direction::Right);
    let folders = &facts.folders;
    let inherited = folders
        .explicit
        .clone()
        .or_else(|| folders.uninherited.clone())
        .or_else(|| folders.inherited.clone());
    let cwd =
        inherited.clone().or_else(|| folders.selected.clone()).or_else(|| folders.first.clone());
    let action = match facts.tool {
        ToolSplit::Split if facts.page && facts.shown => SplitDo::PageSplit,
        ToolSplit::Split => SplitDo::Split,
        ToolSplit::Refused => SplitDo::Refuse,
        ToolSplit::Tab if facts.page => SplitDo::StripPage,
        ToolSplit::Tab => SplitDo::StripTerminal,
        ToolSplit::BesideDock if facts.page => SplitDo::DockPage,
        ToolSplit::BesideDock => SplitDo::DockColumn,
    };
    let horizontal = matches!(direction, Direction::Left | Direction::Right);
    SplitPlan {
        action,
        edge: if action == SplitDo::DockPage { Edge::Right } else { edge(direction) },
        horizontal,
        daemon_direction: if horizontal { Direction::Right } else { Direction::Down },
        swap_towards: match direction {
            Direction::Left => Some(Direction::Right),
            Direction::Up => Some(Direction::Down),
            _ => None,
        },
        split_action: split_action(direction),
        cwd,
        tab_cwd: inherited,
    }
}

/// The facts of an Auto Layout split's pane.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AutoFacts {
    pub width: f64,
    pub height: f64,
    /// A split toward the right has room.
    pub room_right: bool,
    /// A split downward has room.
    pub room_down: bool,
}

/// Auto Layout's direction for a new pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoDirection {
    /// The longer side (right on a tie).
    pub preferred: Direction,
    /// The preferred side when it has room, else the other axis when only it
    /// has; None when neither has.
    pub fitting: Option<Direction>,
}

pub fn auto_direction(facts: AutoFacts) -> AutoDirection {
    let preferred = if facts.width >= facts.height { Direction::Right } else { Direction::Down };
    let other = if preferred == Direction::Right { Direction::Down } else { Direction::Right };
    let room = |direction| match direction {
        Direction::Right => facts.room_right,
        _ => facts.room_down,
    };
    AutoDirection { preferred, fitting: [preferred, other].into_iter().find(|d| room(*d)) }
}

/// The facts of a pane's tab bar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TabBarFacts {
    /// An app workspace's pane: it never shows a tab bar.
    pub app_pane: bool,
    /// A pinned dock's pane (the Home Chief pane): it takes no new tab.
    pub pinned_dock: bool,
    /// That dock holds only its pinned tab: no tab bar.
    pub pinned_dock_hides_tab_bar: bool,
}

/// Why a pane's tab bar cannot change, or it takes no new tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TabBarRefusal {
    AppPaneHasNoTabBar,
    ChiefPaneHasNoTabBar,
}

/// The refusals of Hide/Show Tab Bar and New Horizontal Tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabBar {
    pub toggle: Option<TabBarRefusal>,
    pub new_tab: Option<TabBarRefusal>,
}

pub fn tab_bar(facts: TabBarFacts) -> TabBar {
    let toggle = if facts.app_pane {
        Some(TabBarRefusal::AppPaneHasNoTabBar)
    } else if facts.pinned_dock_hides_tab_bar {
        Some(TabBarRefusal::ChiefPaneHasNoTabBar)
    } else {
        None
    };
    let new_tab =
        if facts.pinned_dock { Some(TabBarRefusal::ChiefPaneHasNoTabBar) } else { toggle };
    TabBar { toggle, new_tab }
}

/// The terminal actions that run one Ghostty binding action on the live surface.
pub const TERMINAL_BINDINGS: [(&str, &str); 9] = [
    ("resetTerminal", "reset"),
    ("terminal.increaseFontSize", "increase_font_size:1"),
    ("terminal.decreaseFontSize", "decrease_font_size:1"),
    ("terminal.resetFontSize", "reset_font_size"),
    ("terminal.scrollPageUp", "scroll_page_up"),
    ("terminal.scrollPageDown", "scroll_page_down"),
    ("terminal.scrollToTop", "scroll_to_top"),
    ("terminal.scrollToBottom", "scroll_to_bottom"),
    ("terminal.scrollToSelection", "scroll_to_selection"),
];

/// The daemon refusals of a Cmd-K clear the crash telemetry names.
const CLEAR_FAILURES: [&str; 8] = [
    "active terminal input extends into retained history",
    "safe clear-history boundary",
    "does not support clear-history",
    "terminal host has exited",
    "terminal process has exited",
    "did not acknowledge ClearHistory",
    "not connected",
    "timed out",
];

/// A Cmd-K clear's refusal without user content (no paths or screen text):
/// the known reason it contains, else `other`.
pub fn clear_failure_kind(message: &str) -> &'static str {
    CLEAR_FAILURES.into_iter().find(|known| message.contains(known)).unwrap_or("other")
}

/// `path` as one single-quoted shell word.
pub fn shell_quoted(path: &str) -> String {
    format!("'{}'", path.replace('\'', "'\\''"))
}
