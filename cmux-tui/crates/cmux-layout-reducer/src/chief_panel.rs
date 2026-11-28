//! The Home Chief panel and the layout style's resolved metrics, moved from the app's Swift
//! (`Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Model/ChiefPanel.swift`, `ChiefPanelFrame.swift`
//! and the pure parts of `LayoutStyle.swift`).
//!
//! - [`ChiefPanel`]: whether the panel shows, where (floating or docked at an edge) and the frame it
//!   takes from the window's content (`split`). Pure value: the window controller owns one per window.
//! - [`ChiefPanelFrame`]: the floating panel's frame as fractions of the content, so it keeps its
//!   place when the window resizes.
//! - [`StyleInput`] / [`resolve_style`]: the layout style's metrics after the floating-panes, lines
//!   and drop-edge overrides apply, and the minimum pane size they give.
//!
//! `schemas/dock-model/vectors.json` has the answers the Swift types gave (ops `dock_model_chief`,
//! `dock_model_frame_rect`, `dock_model_frame_fitting`, `dock_model_style`); `chief_panel_tests.rs`
//! mirrors their tests.

use crate::dock_model::{DEFAULT_EXTENT_PERMILLE, DockEdge, clamp_extent};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// A rectangle in points, y running down (CoreGraphics `CGRect` in a flipped view).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A size in points (CoreGraphics `CGSize`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// The edge `Rect::divided` slices from (CoreGraphics `CGRectEdge`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RectEdge {
    MinX,
    MaxX,
    MinY,
    MaxY,
}

impl Rect {
    /// `CGRect.divided(atDistance:from:)`: the slice `amount` deep from `edge` (clamped into the
    /// rect) and the remainder.
    pub fn divided(self, amount: f64, edge: RectEdge) -> (Rect, Rect) {
        let Rect { x, y, width: w, height: h } = self;
        match edge {
            RectEdge::MinX | RectEdge::MaxX => {
                let a = amount.max(0.0).min(w);
                if edge == RectEdge::MinX {
                    (
                        Rect { x, y, width: a, height: h },
                        Rect { x: x + a, y, width: w - a, height: h },
                    )
                } else {
                    (
                        Rect { x: x + w - a, y, width: a, height: h },
                        Rect { x, y, width: w - a, height: h },
                    )
                }
            }
            RectEdge::MinY | RectEdge::MaxY => {
                let a = amount.max(0.0).min(h);
                if edge == RectEdge::MinY {
                    (
                        Rect { x, y, width: w, height: a },
                        Rect { x, y: y + a, width: w, height: h - a },
                    )
                } else {
                    (
                        Rect { x, y: y + h - a, width: w, height: a },
                        Rect { x, y, width: w, height: h - a },
                    )
                }
            }
        }
    }
}

/// The floating Chief panel's frame as fractions of the content (Swift `ChiefPanelFrame`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChiefPanelFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Default for ChiefPanelFrame {
    fn default() -> Self {
        Self::INITIAL
    }
}

impl ChiefPanelFrame {
    /// Where the panel opens the first time: the right part of the window, inset from its edges.
    pub const INITIAL: ChiefPanelFrame =
        ChiefPanelFrame { x: 0.6, y: 0.04, width: 0.37, height: 0.92 };

    /// The smallest the floating panel gets, in points.
    pub const MINIMUM_SIZE: Size = Size { width: 280.0, height: 220.0 };

    /// The frame in points inside content of `size`, at least `minimum` (never more than the
    /// content) and inside it, rounded to whole points. Zero for an empty content.
    pub fn rect(&self, size: Size, minimum: Size) -> Rect {
        if !(size.width > 0.0 && size.height > 0.0) {
            return Rect::default();
        }
        let width = size.width.min(minimum.width.max(self.width * size.width));
        let height = size.height.min(minimum.height.max(self.height * size.height));
        let left = (self.x * size.width).max(0.0).min(size.width - width);
        let top = (self.y * size.height).max(0.0).min(size.height - height);
        Rect { x: left.round(), y: top.round(), width: width.round(), height: height.round() }
    }

    /// The frame for `rect` in content of `size`, clamped the way [`ChiefPanelFrame::rect`] clamps;
    /// [`ChiefPanelFrame::INITIAL`] for an empty content.
    pub fn fitting(rect: Rect, size: Size, minimum: Size) -> ChiefPanelFrame {
        if !(size.width > 0.0 && size.height > 0.0) {
            return Self::INITIAL;
        }
        let width = size.width.min(minimum.width.max(rect.width));
        let height = size.height.min(minimum.height.max(rect.height));
        let left = rect.x.max(0.0).min(size.width - width);
        let top = rect.y.max(0.0).min(size.height - height);
        ChiefPanelFrame {
            x: left / size.width,
            y: top / size.height,
            width: width / size.width,
            height: height / size.height,
        }
    }
}

/// The Home Chief panel of one window (Swift `ChiefPanel`). `docked_edge` nil is the floating
/// placement.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChiefPanel {
    #[serde(default)]
    pub docked_edge: Option<DockEdge>,
    #[serde(default)]
    is_open: bool,
    #[serde(default)]
    pub floating_frame: ChiefPanelFrame,
    #[serde(default = "default_extent")]
    dock_extent_permille: i64,
}

fn default_extent() -> i64 {
    DEFAULT_EXTENT_PERMILLE
}

impl Default for ChiefPanel {
    fn default() -> Self {
        ChiefPanel::new(None, false, ChiefPanelFrame::INITIAL, DEFAULT_EXTENT_PERMILLE)
    }
}

/// The panel's rect and the stage's rect [`ChiefPanel::split`] gives.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChiefSplit {
    pub panel: Rect,
    pub stage: Rect,
}

impl ChiefPanel {
    /// A panel; the extent is clamped into the dock extent range.
    pub fn new(
        docked_edge: Option<DockEdge>,
        is_open: bool,
        floating_frame: ChiefPanelFrame,
        dock_extent_permille: i64,
    ) -> Self {
        ChiefPanel {
            docked_edge,
            is_open,
            floating_frame,
            dock_extent_permille: clamp_extent(dock_extent_permille),
        }
    }

    pub fn is_open(&self) -> bool {
        self.is_open
    }

    pub fn dock_extent_permille(&self) -> i64 {
        self.dock_extent_permille
    }

    /// Sets the docked extent, clamped (Swift `didSet`).
    pub fn set_dock_extent_permille(&mut self, permille: i64) {
        self.dock_extent_permille = clamp_extent(permille);
    }

    /// Whether the panel draws over a stage showing `stage`: open, and never over Home itself.
    pub fn is_shown(&self, stage: Option<&str>, home: Option<&str>) -> bool {
        let Some(stage) = stage.filter(|_| self.is_open) else { return false };
        Some(stage) != home
    }

    pub fn open(&mut self) {
        self.is_open = true;
    }

    /// Opens the panel floating.
    pub fn open_floating(&mut self) {
        self.docked_edge = None;
        self.is_open = true;
    }

    pub fn hide(&mut self) {
        self.is_open = false;
    }

    /// Docks the panel at `edge` and opens it.
    pub fn dock(&mut self, edge: DockEdge) {
        self.docked_edge = Some(edge);
        self.is_open = true;
    }

    /// Floats a docked panel; false when it already floats.
    pub fn undock(&mut self) -> bool {
        if self.docked_edge.is_none() {
            return false;
        }
        self.docked_edge = None;
        true
    }

    /// The panel's rect and the stage's rect inside `bounds`: floating, the panel draws over the
    /// whole stage; docked, it takes its extent from its edge (y runs down: top is minY).
    pub fn split(&self, bounds: Rect) -> ChiefSplit {
        let Some(edge) = self.docked_edge else {
            let rect = self.floating_frame.rect(
                Size { width: bounds.width, height: bounds.height },
                ChiefPanelFrame::MINIMUM_SIZE,
            );
            let panel = Rect { x: rect.x + bounds.x, y: rect.y + bounds.y, ..rect };
            return ChiefSplit { panel, stage: bounds };
        };
        let share = self.dock_extent_permille as f64 / 1000.0;
        let (panel, stage) = match edge {
            DockEdge::Left | DockEdge::Right => bounds.divided(
                (bounds.width * share).round(),
                if edge == DockEdge::Left { RectEdge::MinX } else { RectEdge::MaxX },
            ),
            DockEdge::Top | DockEdge::Bottom => bounds.divided(
                (bounds.height * share).round(),
                if edge == DockEdge::Top { RectEdge::MinY } else { RectEdge::MaxY },
            ),
        };
        ChiefSplit { panel, stage }
    }

    /// Runs one [`ChiefAction`] and returns its answer as JSON (the `dock_model_chief` op).
    pub fn apply(&mut self, action: &ChiefAction) -> Value {
        match action {
            ChiefAction::Open => self.open(),
            ChiefAction::OpenFloating => self.open_floating(),
            ChiefAction::Hide => self.hide(),
            ChiefAction::Dock { edge } => self.dock(*edge),
            ChiefAction::Undock => return json!(self.undock()),
            ChiefAction::SetPlacement { edge } => self.docked_edge = *edge,
            ChiefAction::SetExtent { permille } => self.set_dock_extent_permille(*permille),
            ChiefAction::SetFloatingFrame { frame } => self.floating_frame = *frame,
            ChiefAction::IsShown { stage, home } => {
                return json!(self.is_shown(stage.as_deref(), home.as_deref()));
            }
            ChiefAction::DockedEdge => return json!(self.docked_edge),
            ChiefAction::Split { bounds } => return json!(self.split(*bounds)),
        }
        Value::Null
    }
}

/// One call on a [`ChiefPanel`], as the `dock_model_chief` op names it (`{"action": "dock", ...}`).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum ChiefAction {
    Open,
    OpenFloating,
    Hide,
    Dock {
        edge: DockEdge,
    },
    Undock,
    SetPlacement {
        #[serde(default)]
        edge: Option<DockEdge>,
    },
    SetExtent {
        permille: i64,
    },
    SetFloatingFrame {
        frame: ChiefPanelFrame,
    },
    IsShown {
        #[serde(default)]
        stage: Option<String>,
        #[serde(default)]
        home: Option<String>,
    },
    DockedEdge,
    Split {
        bounds: Rect,
    },
}

// MARK: LayoutStyle (pure parts)

/// The style values and overrides [`resolve_style`] reads (Swift `LayoutStyle` with the settings
/// `applyingDesignMetrics` and the pane-size overrides read).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleInput {
    /// Panes float as cards: no dividers.
    pub floating_panes: bool,
    pub divider_thickness: f64,
    /// The design draws lines; off, no focus ring and no attention border.
    pub draws_lines: bool,
    pub floating_panes_hide_focus_ring: bool,
    pub focus_ring_enabled: bool,
    pub attention_width: f64,
    /// `[lower, upper]` of the drop-edge band.
    pub drop_edge_range: (f64, f64),
    pub minimum_pane_content_size: Size,
    pub pane_padding: f64,
    pub pane_chrome_height: f64,
    #[serde(default)]
    pub drop_edge_minimum: Option<f64>,
    /// Zero means no upper bound.
    #[serde(default)]
    pub drop_edge_maximum: Option<f64>,
    #[serde(default)]
    pub minimum_content_width: Option<f64>,
    #[serde(default)]
    pub minimum_content_height: Option<f64>,
}

/// The resolved style metrics.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedStyle {
    pub divider_thickness: f64,
    pub focus_ring_enabled: bool,
    pub attention_width: f64,
    pub drop_edge_range: (f64, f64),
    pub minimum_pane_content_size: Size,
    /// The content minimum plus the pane's padding and chrome.
    pub minimum_pane_size: Size,
}

/// The style's metrics after its overrides apply.
pub fn resolve_style(input: &StyleInput) -> ResolvedStyle {
    let divider_thickness = if input.floating_panes { 0.0 } else { input.divider_thickness };
    let (mut focus_ring_enabled, mut attention_width) =
        (input.focus_ring_enabled, input.attention_width);
    if !input.draws_lines {
        focus_ring_enabled = false;
        attention_width = 0.0;
    }
    if input.floating_panes_hide_focus_ring {
        focus_ring_enabled = false;
    }
    let mut drop_edge_range = input.drop_edge_range;
    if input.drop_edge_minimum.is_some() || input.drop_edge_maximum.is_some() {
        let lower = input.drop_edge_minimum.unwrap_or(drop_edge_range.0);
        let upper = match input.drop_edge_maximum {
            Some(maximum) if maximum > 0.0 => maximum,
            Some(_) => f64::MAX,
            None => drop_edge_range.1,
        };
        drop_edge_range = (lower, lower.max(upper));
    }
    let minimum_pane_content_size = Size {
        width: input.minimum_content_width.unwrap_or(input.minimum_pane_content_size.width),
        height: input.minimum_content_height.unwrap_or(input.minimum_pane_content_size.height),
    };
    let pad = input.pane_padding;
    ResolvedStyle {
        divider_thickness,
        focus_ring_enabled,
        attention_width,
        drop_edge_range,
        minimum_pane_content_size,
        minimum_pane_size: Size {
            width: minimum_pane_content_size.width + pad * 2.0,
            height: input.pane_chrome_height + minimum_pane_content_size.height + pad * 2.0,
        },
    }
}

#[cfg(test)]
#[path = "chief_panel_tests.rs"]
mod tests;
