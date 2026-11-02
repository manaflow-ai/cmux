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

impl Rect {
    pub fn min_x(&self) -> f64 {
        self.x.min(self.x + self.w)
    }

    pub fn max_x(&self) -> f64 {
        self.x.max(self.x + self.w)
    }

    pub fn min_y(&self) -> f64 {
        self.y.min(self.y + self.h)
    }

    pub fn max_y(&self) -> f64 {
        self.y.max(self.y + self.h)
    }

    pub fn width(&self) -> f64 {
        self.w.abs()
    }

    pub fn height(&self) -> f64 {
        self.h.abs()
    }

    /// The same rect with a non-negative size.
    pub fn standardized(&self) -> Rect {
        Rect { x: self.min_x(), y: self.min_y(), w: self.width(), h: self.height() }
    }

    /// `CGRect.intersection`: none when the rects do not meet (`CGRect.null`).
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let (min_x, max_x) = (self.min_x().max(other.min_x()), self.max_x().min(other.max_x()));
        let (min_y, max_y) = (self.min_y().max(other.min_y()), self.max_y().min(other.max_y()));
        if max_x < min_x || max_y < min_y {
            return None;
        }
        Some(Rect { x: min_x, y: min_y, w: max_x - min_x, h: max_y - min_y })
    }
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
pub fn resolve(target: &str, snapshot: &Snapshot) -> Visibility {
    let Some(tab) = &snapshot.tab else {
        return Visibility::NotDrawn { reason: NotDrawnReason::TabClosed };
    };
    // The front-most window that shows the workspace, else one that lists it.
    let shows_workspace =
        |w: &&Window| w.shown_workspace.as_deref() == Some(tab.workspace.as_str());
    let Some(window) =
        snapshot.windows.iter().find(shows_workspace).or_else(|| {
            snapshot.windows.iter().find(|w| w.listed_workspaces.contains(&tab.workspace))
        })
    else {
        return Visibility::NotDrawn { reason: NotDrawnReason::NotInAnyWindow };
    };
    // CURSOR-SCREENS: another display draws; minimized or another Space does not.
    if window.minimized {
        return Visibility::NotDrawn { reason: NotDrawnReason::Minimized };
    }
    if !window.on_active_space {
        return Visibility::NotDrawn { reason: NotDrawnReason::OtherSpace };
    }
    if window.shown_workspace.as_deref() != Some(tab.workspace.as_str()) {
        return workspace_anchor(&tab.workspace, window);
    }
    let pane = window.panes.iter().find(|p| p.id == tab.pane);
    let Some((pane, frame, clip)) = pane.and_then(|p| Some((p, p.frame?, p.clip?))) else {
        // The pane is not on the active screen of the workspace.
        return hidden(&window.id, Anchor::WindowEdge, window_edge(&window.overlay));
    };
    if !shows(&frame, &clip) {
        return column_edge(&frame, &clip, &window.id);
    }
    let page = match (&pane.selected_tab, &pane.page) {
        (Some(selected), Some(page)) if selected == target => page,
        // A background tab (or a selected page not laid out yet): its chip.
        _ => return chip_anchor(target, pane, &clip, &window.id),
    };
    let viewport = page.viewport;
    if !shows(&viewport, &clip) {
        return column_edge(&viewport, &clip, &window.id);
    }
    Visibility::Visible {
        window: window.id.clone(),
        viewport: viewport.standardized(),
        clip: overlap(&viewport, &clip),
        zoom: page.zoom,
        scale: page.scale.unwrap_or(1.0),
    }
}

fn hidden(window: &str, anchor: Anchor, rect: Rect) -> Visibility {
    Visibility::Hidden { window: window.to_owned(), anchor, rect: rect.standardized() }
}

/// The part of `rect` in `clip`; only called after [`shows`] said they meet.
fn overlap(rect: &Rect, clip: &Rect) -> Rect {
    rect.intersection(clip).unwrap_or_else(|| clip.standardized())
}

/// Another workspace of the window: its sidebar row, else the window edge.
fn workspace_anchor(workspace: &str, window: &Window) -> Visibility {
    match window.sidebar_rows.get(workspace) {
        Some(row) if !window.sidebar_hidden => hidden(&window.id, Anchor::WorkspaceRow, *row),
        _ => hidden(&window.id, Anchor::WindowEdge, window_edge(&window.overlay)),
    }
}

fn chip_anchor(target: &str, pane: &Pane, clip: &Rect, window: &str) -> Visibility {
    if let Some(chip) = pane.chips.get(target).filter(|chip| shows(chip, clip)) {
        return hidden(window, Anchor::TabChip, overlap(chip, clip));
    }
    if let Some(strip) = pane.strip.filter(|strip| shows(strip, clip)) {
        return hidden(window, Anchor::TabStrip, overlap(&strip, clip));
    }
    let frame = pane.frame.unwrap_or(*clip);
    hidden(window, Anchor::TabStrip, overlap(&frame, clip))
}

/// The strip edge on the side `rect` left `clip` through.
fn column_edge(rect: &Rect, clip: &Rect, window: &str) -> Visibility {
    let t = EDGE_THICKNESS;
    let side = if rect.max_x() <= clip.min_x() + 0.5 {
        Edge::Leading
    } else if rect.min_x() >= clip.max_x() - 0.5 {
        Edge::Trailing
    } else if rect.max_y() <= clip.min_y() + 0.5 {
        Edge::Top
    } else {
        Edge::Bottom
    };
    let anchor = match side {
        Edge::Leading | Edge::Trailing => {
            let (min_y, max_y) = span(rect.min_y(), rect.max_y(), clip.min_y(), clip.max_y());
            let x = if side == Edge::Leading { clip.min_x() } else { clip.max_x() - t };
            Rect { x, y: min_y, w: t, h: max_y - min_y }
        }
        Edge::Top | Edge::Bottom => {
            let (min_x, max_x) = span(rect.min_x(), rect.max_x(), clip.min_x(), clip.max_x());
            let y = if side == Edge::Top { clip.min_y() } else { clip.max_y() - t };
            Rect { x: min_x, y, w: max_x - min_x, h: t }
        }
    };
    hidden(window, Anchor::ColumnEdge(side), anchor)
}

/// The overlapping range of two intervals, or the second interval when they
/// do not overlap.
fn span(a0: f64, a1: f64, b0: f64, b1: f64) -> (f64, f64) {
    let (lo, hi) = (a0.max(b0), a1.min(b1));
    if hi > lo { (lo, hi) } else { (b0, b1) }
}

fn window_edge(overlay: &Rect) -> Rect {
    Rect { x: overlay.min_x(), y: overlay.min_y(), w: EDGE_THICKNESS, h: overlay.height() }
}

/// At least half a point of `rect` lies in `clip` on both axes.
fn shows(rect: &Rect, clip: &Rect) -> bool {
    rect.intersection(clip).is_some_and(|o| o.w > 0.5 && o.h > 0.5)
}
