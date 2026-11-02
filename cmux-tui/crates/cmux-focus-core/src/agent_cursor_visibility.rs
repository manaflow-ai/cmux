//! Where an agent cursor for a target tab (a browser tab) draws: on its
//! page, as a pulsing indicator at an anchor in its window, or nowhere
//! (plans/cmux-next/agent-cursor.md section 3; decisions CURSOR-HIDDEN,
//! CURSOR-SHOW, CURSOR-SCREENS, 2026-10-04). The macOS app builds a
//! [`Snapshot`] from its live models when an agent input event arrives (or
//! a tracked target's layout changes) and asks [`resolve`] over the app FFI
//! (`cmux_layout_reducer_json` operation `agent_cursor_visibility`).
//!
//! Rects are points in one window's content view, flipped (origin top-left,
//! y down). They follow `CGRect`'s rules: a negative size is standardized,
//! and every output rect is standardized. Shared vectors:
//! schemas/agent-cursor-visibility/vectors.json.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;

/// Thickness of an edge anchor (column edge, window edge), in points.
pub const EDGE_THICKNESS: f64 = 4.0;

/// A rect in one window's content-view coordinates, flipped.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// The facts about one target tab and the windows that could show it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    /// Where the target tab lives; none when no tab has the target id.
    #[serde(default)]
    pub tab: Option<TabLocation>,
    /// Every window, front to back.
    pub windows: Vec<Window>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TabLocation {
    pub workspace: String,
    pub pane: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub id: String,
    /// The display the window is on (informational: a window on another
    /// display still draws).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen: Option<String>,
    pub minimized: bool,
    pub on_active_space: bool,
    /// The window content view's bounds (the cursor host's space).
    pub overlay: Rect,
    /// The workspace the window shows; none while it shows none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shown_workspace: Option<String>,
    /// Workspaces the window lists in its sidebar (shown and parked).
    pub listed_workspaces: Vec<String>,
    pub sidebar_hidden: bool,
    /// Sidebar row anchors by workspace id. A workspace in a collapsed group
    /// anchors at the group row; an unlisted one is absent.
    pub sidebar_rows: HashMap<String, Rect>,
    /// Panes of the shown workspace that the layout measured.
    pub panes: Vec<Pane>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pane {
    pub id: String,
    /// The pane's displayed frame; off the viewport for a column scrolled
    /// out. None when the pane is not on the active screen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<Rect>,
    /// Where the pane may show: the strip area not under docked columns
    /// (strip panes) or the screen (docked panes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clip: Option<Rect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_tab: Option<String>,
    /// The pane's tab strip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strip: Option<Rect>,
    /// Tab chip anchors by tab id, clamped into the strip's tab area.
    pub chips: HashMap<String, Rect>,
    /// The selected tab's page viewport, when it is a laid-out page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page: Option<Page>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Page {
    /// The page's own viewport: the page area minus docked DevTools.
    pub viewport: Rect,
    /// The tab's page zoom.
    pub zoom: f64,
    /// Points per CSS px of the page at zoom 1 (an emulation's scale); none is 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
}

/// The side of the strip a scrolled-out target left through.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Edge {
    Leading,
    Trailing,
    Top,
    Bottom,
}

/// Where the hidden-target indicator sits. On the wire a string: `tabChip`,
/// `tabStrip`, `columnEdge.<leading|trailing|top|bottom>`, `workspaceRow`,
/// `windowEdge`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Anchor {
    /// A background tab: its chip in the pane's strip.
    TabChip,
    /// A background tab with no laid-out chip (a collapsed tab group): the strip.
    TabStrip,
    /// The target's column (or row) is scrolled out of view: the strip edge
    /// on that side.
    ColumnEdge(Edge),
    /// Another workspace of the same window: its sidebar row.
    WorkspaceRow,
    /// No better anchor (sidebar hidden, workspace not listed in the
    /// sidebar, pane not on the active screen): the leading window edge.
    WindowEdge,
}

impl Anchor {
    pub fn as_str(self) -> &'static str {
        match self {
            Anchor::TabChip => "tabChip",
            Anchor::TabStrip => "tabStrip",
            Anchor::ColumnEdge(Edge::Leading) => "columnEdge.leading",
            Anchor::ColumnEdge(Edge::Trailing) => "columnEdge.trailing",
            Anchor::ColumnEdge(Edge::Top) => "columnEdge.top",
            Anchor::ColumnEdge(Edge::Bottom) => "columnEdge.bottom",
            Anchor::WorkspaceRow => "workspaceRow",
            Anchor::WindowEdge => "windowEdge",
        }
    }

    pub fn parse(text: &str) -> Option<Anchor> {
        Some(match text {
            "tabChip" => Anchor::TabChip,
            "tabStrip" => Anchor::TabStrip,
            "columnEdge.leading" => Anchor::ColumnEdge(Edge::Leading),
            "columnEdge.trailing" => Anchor::ColumnEdge(Edge::Trailing),
            "columnEdge.top" => Anchor::ColumnEdge(Edge::Top),
            "columnEdge.bottom" => Anchor::ColumnEdge(Edge::Bottom),
            "workspaceRow" => Anchor::WorkspaceRow,
            "windowEdge" => Anchor::WindowEdge,
            _ => return None,
        })
    }
}

impl Serialize for Anchor {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Anchor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Anchor::parse(&text)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown agent cursor anchor {text}")))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NotDrawnReason {
    /// No tab has the target id.
    TabClosed,
    /// No window shows or lists the tab's workspace.
    NotInAnyWindow,
    Minimized,
    /// The window is on another Space.
    OtherSpace,
}

fn one() -> f64 {
    1.0
}

/// Where the cursor draws. Rects are in the content-view coordinates of
/// `window`, flipped.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Visibility {
    /// The target's page is on screen. `viewport` is the page viewport the
    /// event coordinates map into; `clip` is its part not scrolled out or
    /// under a docked column (equal to `viewport` when fully shown).
    /// `scale` is the page's points per CSS px at zoom 1.
    Visible {
        window: String,
        viewport: Rect,
        clip: Rect,
        zoom: f64,
        #[serde(default = "one")]
        scale: f64,
    },
    /// The target is in `window` but not shown: an indicator in the session
    /// color pulses at `rect`. Never over a pane that is not the target.
    Hidden { window: String, anchor: Anchor, rect: Rect },
    /// Nothing draws.
    NotDrawn { reason: NotDrawnReason },
}

/// Where the cursor for `target` draws in `snapshot`.
pub fn resolve(_target: &str, _snapshot: &Snapshot) -> Visibility {
    Visibility::NotDrawn { reason: NotDrawnReason::TabClosed }
}
