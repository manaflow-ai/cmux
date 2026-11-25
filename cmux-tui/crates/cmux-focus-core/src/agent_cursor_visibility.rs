//! Where an agent cursor for a target tab (a browser tab) draws: on its
//! page, as a pulsing indicator at an anchor in its window, or nowhere
//! (plans/cmux-next/agent-cursor.md section 3; decisions CURSOR-HIDDEN,
//! CURSOR-SHOW, CURSOR-SCREENS, 2026-10-04). The macOS app builds a
//! [`Snapshot`] from its live models when an agent input event arrives (or
//! a tracked target's layout changes) and asks [`resolve`] over the app FFI
//! (the typed call `cmux_agent_cursor_visibility`; the JSON operation
//! `agent_cursor_visibility` still answers, and its FFI test replays the vectors).
//!
//! Rects are points in one window's content view, flipped (origin top-left,
//! y down). They follow `CGRect`'s rules: a negative size is standardized,
//! and every output rect is standardized. A non-finite number (a converted
//! `CGRect.null` has infinite x and y) travels as the string "inf", "-inf"
//! or "nan" both ways, as JSON has no such numbers. Shared vectors:
//! schemas/agent-cursor-visibility/vectors.json.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;

/// Thickness of an edge anchor (column edge, window edge), in points.
pub const EDGE_THICKNESS: f64 = 4.0;

/// Non-finite numbers on the wire: "inf", "-inf" and "nan" (the Swift
/// side's JSONEncoder and JSONDecoder `convertToString` / `convertFromString`
/// strategies with these names); finite numbers stay numbers.
mod non_finite {
    use serde::{Deserialize, Deserializer, Serializer};

    #[derive(Deserialize)]
    #[serde(untagged)]
    pub(super) enum Wire {
        Number(f64),
        Text(String),
    }

    impl Wire {
        fn value<E: serde::de::Error>(self) -> Result<f64, E> {
            match self {
                Wire::Number(value) => Ok(value),
                Wire::Text(text) => match text.as_str() {
                    "inf" => Ok(f64::INFINITY),
                    "-inf" => Ok(f64::NEG_INFINITY),
                    "nan" => Ok(f64::NAN),
                    _ => Err(E::custom(format!("not a number: {text}"))),
                },
            }
        }
    }

    pub fn serialize<S: Serializer>(value: &f64, serializer: S) -> Result<S::Ok, S::Error> {
        let value = *value;
        if value.is_finite() {
            serializer.serialize_f64(value)
        } else if value.is_nan() {
            serializer.serialize_str("nan")
        } else if value > 0.0 {
            serializer.serialize_str("inf")
        } else {
            serializer.serialize_str("-inf")
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<f64, D::Error> {
        Wire::deserialize(deserializer)?.value()
    }

    pub mod option {
        use super::Wire;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            value: &Option<f64>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(value) => super::serialize(value, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<f64>, D::Error> {
            Option::<Wire>::deserialize(deserializer)?.map(Wire::value::<D::Error>).transpose()
        }
    }
}

/// A rect in one window's content-view coordinates, flipped.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[repr(C)]
pub struct Rect {
    #[serde(with = "non_finite")]
    pub x: f64,
    #[serde(with = "non_finite")]
    pub y: f64,
    #[serde(with = "non_finite")]
    pub w: f64,
    #[serde(with = "non_finite")]
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
    #[serde(with = "non_finite")]
    pub zoom: f64,
    /// Points per CSS px of the page at zoom 1 (an emulation's scale); none is 1.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "non_finite::option")]
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
        #[serde(with = "non_finite")]
        zoom: f64,
        #[serde(default = "one", with = "non_finite")]
        scale: f64,
    },
    /// The target is in `window` but not shown: an indicator in the session
    /// color pulses at `rect`. Never over a pane that is not the target.
    Hidden { window: String, anchor: Anchor, rect: Rect },
    /// Nothing draws.
    NotDrawn { reason: NotDrawnReason },
}

/// Where the cursor for `target` draws in `snapshot`.
pub fn resolve<'a>(target: &'a str, snapshot: &'a Snapshot) -> Visibility {
    let outcome = resolve_view::<Owned<'a>>(target, &Owned(snapshot));
    // The rules name only windows they read, so every index is in range.
    let window_id = |window: usize| snapshot.windows.get(window).map(|w| w.id.clone());
    let not_in_any_window = Visibility::NotDrawn { reason: NotDrawnReason::NotInAnyWindow };
    match outcome {
        Outcome::Visible { window, viewport, clip, zoom, scale } => match window_id(window) {
            Some(window) => Visibility::Visible { window, viewport, clip, zoom, scale },
            None => not_in_any_window,
        },
        Outcome::Hidden { window, anchor, rect } => match window_id(window) {
            Some(window) => Visibility::Hidden { window, anchor, rect },
            None => not_in_any_window,
        },
        Outcome::NotDrawn { reason } => Visibility::NotDrawn { reason },
    }
}

/// [`Visibility`] with the window as its index in the snapshot's windows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Outcome {
    Visible { window: usize, viewport: Rect, clip: Rect, zoom: f64, scale: f64 },
    Hidden { window: usize, anchor: Anchor, rect: Rect },
    NotDrawn { reason: NotDrawnReason },
}

/// One window's scalar facts, as the rules read them.
#[derive(Clone, Copy, Debug)]
pub struct WindowFacts<I> {
    pub minimized: bool,
    pub on_active_space: bool,
    pub overlay: Rect,
    pub shown_workspace: Option<I>,
    pub sidebar_hidden: bool,
}

/// One pane's facts, as the rules read them.
#[derive(Clone, Copy, Debug)]
pub struct PaneFacts<I> {
    pub frame: Option<Rect>,
    pub clip: Option<Rect>,
    pub selected_tab: Option<I>,
    pub strip: Option<Rect>,
    pub page: Option<Page>,
}

/// A snapshot as the rules read it. Ids are compared only for identity, so
/// [`Snapshot`]'s strings and the app FFI's numbered ids (`u32`) read the
/// same; the typed call borrows the caller's arrays and allocates nothing.
pub trait SnapshotView {
    type Id: PartialEq + Copy;
    /// The target tab's workspace and pane; none when no tab has the target id.
    fn tab(&self) -> Option<(Self::Id, Self::Id)>;
    /// Windows, front to back.
    fn window_count(&self) -> usize;
    /// None for an index past [`Self::window_count`].
    fn window(&self, window: usize) -> Option<WindowFacts<Self::Id>>;
    /// Whether `window` lists `workspace` in its sidebar.
    fn lists(&self, window: usize, workspace: Self::Id) -> bool;
    /// The sidebar row anchor of `workspace` in `window`.
    fn sidebar_row(&self, window: usize, workspace: Self::Id) -> Option<Rect>;
    /// The first pane of `window` with id `pane`: a handle for [`Self::chip`] and its facts.
    fn pane(&self, window: usize, pane: Self::Id) -> Option<(usize, PaneFacts<Self::Id>)>;
    /// The chip anchor of `tab` in the pane `pane` (a handle from [`Self::pane`]).
    fn chip(&self, window: usize, pane: usize, tab: Self::Id) -> Option<Rect>;
}

/// [`Snapshot`] as a [`SnapshotView`] with string ids.
struct Owned<'s>(&'s Snapshot);

impl<'s> SnapshotView for Owned<'s> {
    type Id = &'s str;

    fn tab(&self) -> Option<(&'s str, &'s str)> {
        let snapshot: &'s Snapshot = self.0;
        snapshot.tab.as_ref().map(|tab| (tab.workspace.as_str(), tab.pane.as_str()))
    }

    fn window_count(&self) -> usize {
        self.0.windows.len()
    }

    fn window(&self, window: usize) -> Option<WindowFacts<&'s str>> {
        let snapshot: &'s Snapshot = self.0;
        let window = snapshot.windows.get(window)?;
        Some(WindowFacts {
            minimized: window.minimized,
            on_active_space: window.on_active_space,
            overlay: window.overlay,
            shown_workspace: window.shown_workspace.as_deref(),
            sidebar_hidden: window.sidebar_hidden,
        })
    }

    fn lists(&self, window: usize, workspace: &'s str) -> bool {
        self.0.windows.get(window).is_some_and(|window| {
            window.listed_workspaces.iter().any(|listed| listed.as_str() == workspace)
        })
    }

    fn sidebar_row(&self, window: usize, workspace: &'s str) -> Option<Rect> {
        self.0.windows.get(window)?.sidebar_rows.get(workspace).copied()
    }

    fn pane(&self, window: usize, pane: &'s str) -> Option<(usize, PaneFacts<&'s str>)> {
        let snapshot: &'s Snapshot = self.0;
        let panes = &snapshot.windows.get(window)?.panes;
        let (index, found) =
            panes.iter().enumerate().find(|(_, candidate)| candidate.id == pane)?;
        Some((
            index,
            PaneFacts {
                frame: found.frame,
                clip: found.clip,
                selected_tab: found.selected_tab.as_deref(),
                strip: found.strip,
                page: found.page,
            },
        ))
    }

    fn chip(&self, window: usize, pane: usize, tab: &'s str) -> Option<Rect> {
        self.0.windows.get(window)?.panes.get(pane)?.chips.get(tab).copied()
    }
}

/// Where the cursor for `target` draws in `view`: the rules, once for every
/// representation.
pub fn resolve_view<V: SnapshotView>(target: V::Id, view: &V) -> Outcome {
    let Some((workspace, pane_id)) = view.tab() else {
        return Outcome::NotDrawn { reason: NotDrawnReason::TabClosed };
    };
    // The front-most window that shows the workspace, else one that lists it.
    let count = view.window_count();
    let shows_workspace =
        |w: usize| view.window(w).is_some_and(|f| f.shown_workspace == Some(workspace));
    let found = (0..count)
        .find(|&w| shows_workspace(w))
        .or_else(|| (0..count).find(|&w| view.lists(w, workspace)));
    let Some((window, facts)) = found.and_then(|w| Some((w, view.window(w)?))) else {
        return Outcome::NotDrawn { reason: NotDrawnReason::NotInAnyWindow };
    };
    // CURSOR-SCREENS: another display draws; minimized or another Space does not.
    if facts.minimized {
        return Outcome::NotDrawn { reason: NotDrawnReason::Minimized };
    }
    if !facts.on_active_space {
        return Outcome::NotDrawn { reason: NotDrawnReason::OtherSpace };
    }
    if facts.shown_workspace != Some(workspace) {
        return workspace_anchor(view, window, &facts, workspace);
    }
    let pane = view.pane(window, pane_id);
    let Some((pane, found, frame, clip)) =
        pane.and_then(|(handle, found)| Some((handle, found, found.frame?, found.clip?)))
    else {
        // The pane is not on the active screen of the workspace.
        return hidden(window, Anchor::WindowEdge, window_edge(&facts.overlay));
    };
    if !shows(&frame, &clip) {
        return column_edge(&frame, &clip, window);
    }
    let page = match (found.selected_tab, found.page) {
        (Some(selected), Some(page)) if selected == target => page,
        // A background tab (or a selected page not laid out yet): its chip.
        _ => return chip_anchor(view, window, pane, &found, target, &clip),
    };
    let viewport = page.viewport;
    if !shows(&viewport, &clip) {
        return column_edge(&viewport, &clip, window);
    }
    Outcome::Visible {
        window,
        viewport: viewport.standardized(),
        clip: overlap(&viewport, &clip),
        zoom: page.zoom,
        scale: page.scale.unwrap_or(1.0),
    }
}

fn hidden(window: usize, anchor: Anchor, rect: Rect) -> Outcome {
    Outcome::Hidden { window, anchor, rect: rect.standardized() }
}

/// The part of `rect` in `clip`; only called after [`shows`] said they meet.
fn overlap(rect: &Rect, clip: &Rect) -> Rect {
    rect.intersection(clip).unwrap_or_else(|| clip.standardized())
}

/// Another workspace of the window: its sidebar row, else the window edge.
fn workspace_anchor<V: SnapshotView>(
    view: &V,
    window: usize,
    facts: &WindowFacts<V::Id>,
    workspace: V::Id,
) -> Outcome {
    match view.sidebar_row(window, workspace) {
        Some(row) if !facts.sidebar_hidden => hidden(window, Anchor::WorkspaceRow, row),
        _ => hidden(window, Anchor::WindowEdge, window_edge(&facts.overlay)),
    }
}

fn chip_anchor<V: SnapshotView>(
    view: &V,
    window: usize,
    pane: usize,
    found: &PaneFacts<V::Id>,
    target: V::Id,
    clip: &Rect,
) -> Outcome {
    if let Some(chip) = view.chip(window, pane, target).filter(|chip| shows(chip, clip)) {
        return hidden(window, Anchor::TabChip, overlap(&chip, clip));
    }
    if let Some(strip) = found.strip.filter(|strip| shows(strip, clip)) {
        return hidden(window, Anchor::TabStrip, overlap(&strip, clip));
    }
    let frame = found.frame.unwrap_or(*clip);
    hidden(window, Anchor::TabStrip, overlap(&frame, clip))
}

/// The strip edge on the side `rect` left `clip` through.
fn column_edge(rect: &Rect, clip: &Rect, window: usize) -> Outcome {
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
