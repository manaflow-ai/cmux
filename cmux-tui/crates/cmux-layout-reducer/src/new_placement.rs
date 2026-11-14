//! New ▸ Kind ▸ Placement (`new_placement`): where "open kind K at placement P" puts the new
//! item, and how it is made. The pane's New menu, its ••• menu, the palette and the CLI open a
//! Terminal, a Browser, an Agent Chat or a New Tab Page at the ten places Fork To forks to:
//! beside the pane (right, left, above, below), in a new strip column on either side or a new
//! row below, or in a new tab, workspace or window.
//!
//! A placement is one layout op ([`Op`]), whatever opens there (the fork's placements are the
//! same ten). How the item is made ([`Make`]) depends on its kind: a kind whose own create already
//! makes it in that place in one daemon commit (Cmd-D's split terminal, New Column's terminal, a
//! split's New Tab Page or agent chat in its split, a tab in the pane) is made there; any other is
//! made unselected in the pane, kept out of its strip, and moved there in one daemon move, the way
//! a link's tab or a fork reaches a new split, column, row, workspace or window. Every new pane
//! goes through the app's one split transition either way. Pure: the same request always plans
//! the same.

use serde::{Deserialize, Serialize};

/// What opens: the four kinds the New menu offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Terminal,
    Browser,
    AgentChat,
    NewTabPage,
}

impl Kind {
    pub const ALL: [Kind; 4] = [Kind::Terminal, Kind::Browser, Kind::AgentChat, Kind::NewTabPage];
}

/// Where it opens. The names are the app's fork destinations (`AgentForkDestination`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Placement {
    Right,
    Left,
    Up,
    Down,
    ColumnRight,
    ColumnLeft,
    Row,
    Tab,
    Workspace,
    Window,
}

impl Placement {
    pub const ALL: [Placement; 10] = [
        Placement::Right,
        Placement::Left,
        Placement::Up,
        Placement::Down,
        Placement::ColumnRight,
        Placement::ColumnLeft,
        Placement::Row,
        Placement::Tab,
        Placement::Workspace,
        Placement::Window,
    ];
}

/// The side of the pane a split puts the new pane on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    Right,
    Left,
    Top,
    Bottom,
}

/// The layout op a placement asks of the daemon.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    /// A new split of the pane on `edge`.
    Split { edge: Edge },
    /// A new strip column right after the pane's column, or right before it when `left`.
    Column { left: bool },
    /// A new row below the pane's row, in its column (needs rows and `rows-v1`).
    Row,
    /// A new tab in the pane.
    Tab,
    /// A new workspace, placed as Cmd-N places one.
    Workspace,
    /// A new window showing a new workspace.
    Window,
}

/// How the new item is made.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Make {
    /// In its place, by the kind's own create for that op, in one daemon commit.
    InPlace,
    /// Unselected in the pane and out of its strip, then moved to the op's place in one daemon move.
    MadeThenMoved,
}

/// One question: open `kind` at `placement` from a pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub kind: Kind,
    pub placement: Placement,
    /// The pane's daemon makes a conversation tab (an agent chat) straight in a new split
    /// (`conversation-tab-split-v1`).
    #[serde(default)]
    pub tab_split: bool,
}

/// The answer: the op, and how the item gets there.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    #[serde(flatten)]
    pub op: Op,
    pub make: Make,
}

/// The layout op of `placement` (the fork's mapping, `TerminalForkPlacement`).
pub fn op(placement: Placement) -> Op {
    match placement {
        Placement::Right => Op::Split { edge: Edge::Right },
        Placement::Left => Op::Split { edge: Edge::Left },
        Placement::Up => Op::Split { edge: Edge::Top },
        Placement::Down => Op::Split { edge: Edge::Bottom },
        Placement::ColumnRight => Op::Column { left: false },
        Placement::ColumnLeft => Op::Column { left: true },
        Placement::Row => Op::Row,
        Placement::Tab => Op::Tab,
        Placement::Workspace => Op::Workspace,
        Placement::Window => Op::Window,
    }
}

/// Whether `kind`'s own create makes it at `op` in one daemon commit.
fn made_in_place(kind: Kind, op: Op, tab_split: bool) -> bool {
    match (kind, op) {
        // Every kind has its own new tab.
        (_, Op::Tab) => true,
        // A workspace or window gets the tab moved into it (Move Tab to New Workspace / Window).
        (_, Op::Workspace | Op::Window) => false,
        // Cmd-D's split on every side (left and up swap after the split), New Column Right / Left, New Row.
        (Kind::Terminal, Op::Split { .. } | Op::Column { .. } | Op::Row) => true,
        // Split Browser Right / Down: the page made in its split where the daemon can.
        (Kind::Browser, Op::Split { edge: Edge::Right | Edge::Bottom }) => true,
        // A split's New Tab Page on every side (left and up swap back; an older daemon moves it itself).
        (Kind::NewTabPage, Op::Split { .. }) => true,
        // A chat made in its split (`conversation-tab-split-v1`), right or below only.
        (Kind::AgentChat, Op::Split { edge: Edge::Right | Edge::Bottom }) => tab_split,
        _ => false,
    }
}

/// The plan for `request`.
pub fn plan(request: &Request) -> Plan {
    let op = op(request.placement);
    let make = if made_in_place(request.kind, op, request.tab_split) {
        Make::InPlace
    } else {
        Make::MadeThenMoved
    };
    Plan { op, make }
}

#[cfg(test)]
mod tests;
