//! What a doc or a name is, and the scopes the search window offers.

use serde::{Deserialize, Serialize};

/// What a hit is, and so where it jumps.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Terminal lines that left the screen: `target` is the terminal,
    /// `position` the absolute line of the doc's first line.
    Scrollback,
    /// A full-screen TUI frame (alt screen): `target` is the terminal,
    /// `position` the frame time.
    Screen,
    /// A finished shell command (OSC 133): `target` is the terminal.
    Command,
    /// An agent chat message (ACP, acpmux, harness stores): `target` is the
    /// session, `position` the turn.
    Chat,
    /// A Chief message or memory entry: `target` is the Chief.
    Chief,
    /// A file: its path as a name, its text as content.
    File,
    /// A browser page (history or open tab).
    Page,
    /// A workspace name.
    Workspace,
    /// A tab name.
    Tab,
    /// A pane name.
    Pane,
}

impl Kind {
    /// Every kind, in a fixed order.
    pub const ALL: [Self; 10] = [
        Self::Scrollback,
        Self::Screen,
        Self::Command,
        Self::Chat,
        Self::Chief,
        Self::File,
        Self::Page,
        Self::Workspace,
        Self::Tab,
        Self::Pane,
    ];

    /// The wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Scrollback => "scrollback",
            Self::Screen => "screen",
            Self::Command => "command",
            Self::Chat => "chat",
            Self::Chief => "chief",
            Self::File => "file",
            Self::Page => "page",
            Self::Workspace => "workspace",
            Self::Tab => "tab",
            Self::Pane => "pane",
        }
    }

    /// The kind with wire name `value`.
    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == value)
    }

    /// A one-byte code for the on-disk format and block kind masks.
    pub(crate) fn code(self) -> u8 {
        Self::ALL.iter().position(|kind| *kind == self).unwrap_or(0) as u8
    }

    pub(crate) fn from_code(code: u8) -> Option<Self> {
        Self::ALL.get(usize::from(code)).copied()
    }

    /// How much a content hit of this kind weighs against others at the
    /// same match quality (design section 7.3).
    pub(crate) fn weight(self) -> f64 {
        match self {
            Self::Chief => 1.2,
            Self::Chat => 1.15,
            Self::Command => 1.1,
            Self::Scrollback | Self::File => 1.0,
            Self::Page => 0.95,
            Self::Screen => 0.9,
            Self::Workspace | Self::Tab | Self::Pane => 1.1,
        }
    }
}

/// A group of kinds the search window can be scoped to (a scope chip).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Scope {
    /// Agent chats (Cmd+Shift+A opens with this and [`Scope::Chief`]).
    Chat,
    /// Chief chats and memory.
    Chief,
    /// Terminal scrollback, full-screen frames and commands.
    Terminal,
    /// Files in open workspaces' folders.
    File,
    /// Workspaces, tabs and panes.
    Workspace,
    /// Browser pages.
    Page,
}

impl Scope {
    /// Every scope.
    pub const ALL: [Self; 6] =
        [Self::Chat, Self::Chief, Self::Terminal, Self::File, Self::Workspace, Self::Page];

    /// The scope Cmd+Shift+A opens the window with.
    pub const AGENTS: [Self; 2] = [Self::Chat, Self::Chief];

    /// The wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Chief => "chief",
            Self::Terminal => "terminal",
            Self::File => "file",
            Self::Workspace => "workspace",
            Self::Page => "page",
        }
    }

    /// The scope with wire name `value` (`scrollback` is accepted for
    /// [`Scope::Terminal`]).
    pub fn parse(value: &str) -> Option<Self> {
        if value == "scrollback" {
            return Some(Self::Terminal);
        }
        Self::ALL.into_iter().find(|scope| scope.as_str() == value)
    }

    /// The kinds this scope covers.
    pub fn kinds(self) -> &'static [Kind] {
        match self {
            Self::Chat => &[Kind::Chat],
            Self::Chief => &[Kind::Chief],
            Self::Terminal => &[Kind::Scrollback, Kind::Screen, Kind::Command],
            Self::File => &[Kind::File],
            Self::Workspace => &[Kind::Workspace, Kind::Tab, Kind::Pane],
            Self::Page => &[Kind::Page],
        }
    }

    /// The kinds of every scope in `scopes`; empty when `scopes` is empty
    /// (every kind).
    pub fn kinds_of(scopes: &[Self]) -> Vec<Kind> {
        let mut kinds: Vec<Kind> = Vec::new();
        for scope in scopes {
            for kind in scope.kinds() {
                if !kinds.contains(kind) {
                    kinds.push(*kind);
                }
            }
        }
        kinds
    }
}
