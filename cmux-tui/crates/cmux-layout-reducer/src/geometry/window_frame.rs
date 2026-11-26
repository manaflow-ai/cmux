//! A window's docked workspaces and its stage (Swift `WindowFrameGeometry`,
//! plans/cmux-next/docked-workspace-DESIGN.md G1 to G3, W6 to W8) and where a window moved out of
//! another opens (`MovedWindowPlacement`).

use super::dock_strip::{DockMode, FrameOrientation};
use super::{DockEdge, Rect, swift_max, swift_min};
use serde::{Deserialize, Serialize};

/// `WindowFrameGeometry.minimumSide`: the smallest side dock, unless half the frame is smaller.
pub const MINIMUM_SIDE: f64 = 160.;
/// `WindowFrameGeometry.minimumBand`: the smallest band (top or bottom dock).
pub const MINIMUM_BAND: f64 = 120.;

/// `WindowDocks.Dock`: the fields placing reads.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowDock {
    pub workspace: String,
    pub edge: DockEdge,
    pub mode: DockMode,
    pub extent_permille: i64,
    #[serde(default)]
    pub hidden: bool,
}

/// `WindowFrameGeometry.PlacedDock`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlacedDock {
    pub workspace: String,
    pub edge: DockEdge,
    pub frame: Rect,
    pub floating: bool,
}

/// `WindowFrameGeometry.Placement`: the stage and the docks, back to front (docked, then floating).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WindowPlacement {
    pub stage: Rect,
    pub docks: Vec<PlacedDock>,
}

/// `CGRect.integral`: the smallest whole-point rect around `rect`.
fn integral(rect: Rect) -> Rect {
    let (x, y) = (rect.min_x().floor(), rect.min_y().floor());
    Rect::new(x, y, rect.max_x().ceil() - x, rect.max_y().ceil() - y)
}

/// `WindowFrameGeometry.place(_:in:)`: places `docks` (in `WindowDocks.all` order) in `rect`, y-down:
/// the corner owners by `orientation` first, along the whole frame, then the others between their
/// docked inner edges. Floating docks never cut the stage; hidden ones are not placed.
pub fn place(
    docks: &[WindowDock],
    orientation: FrameOrientation,
    gap: f64,
    rect: Rect,
) -> WindowPlacement {
    let visible: Vec<&WindowDock> = docks.iter().filter(|dock| !dock.hidden).collect();
    if visible.is_empty() {
        return WindowPlacement { stage: rect, docks: Vec::new() };
    }
    let sides: Vec<&WindowDock> = visible.iter().copied().filter(|d| !d.edge.is_band()).collect();
    let bands: Vec<&WindowDock> = visible.iter().copied().filter(|d| d.edge.is_band()).collect();
    let mut stage = rect;
    let mut placed: Vec<PlacedDock> = Vec::new();

    let extent = |dock: &WindowDock| {
        let band = dock.edge.is_band();
        let length = if band { rect.height() } else { rect.width() };
        let both = if band { bands.len() } else { sides.len() } > 1;
        let share = match (band, both) {
            (true, true) => 1.0 / 3.,
            (true, false) | (false, false) => 0.5,
            (false, true) => 0.4,
        };
        let maximum = (length * share).floor();
        let minimum = swift_min(if band { MINIMUM_BAND } else { MINIMUM_SIDE }, maximum);
        swift_min(
            swift_max((length * dock.extent_permille as f64 / 1000.).floor(), minimum),
            maximum,
        )
    };

    let put = |dock: &WindowDock, stage: Rect, placed: &mut Vec<PlacedDock>| {
        let size = extent(dock);
        let frame = match dock.edge {
            DockEdge::Left => Rect::new(rect.min_x(), stage.min_y(), size, stage.height()),
            DockEdge::Right => Rect::new(rect.max_x() - size, stage.min_y(), size, stage.height()),
            DockEdge::Top => Rect::new(stage.min_x(), rect.min_y(), stage.width(), size),
            DockEdge::Bottom => Rect::new(stage.min_x(), rect.max_y() - size, stage.width(), size),
        };
        placed.push(PlacedDock {
            workspace: dock.workspace.clone(),
            edge: dock.edge,
            frame: integral(frame),
            floating: dock.mode == DockMode::Overlay,
        });
    };

    let cut = |dock: &WindowDock, stage: &mut Rect, placed: &[PlacedDock]| {
        if dock.mode != DockMode::Docked {
            return;
        }
        let Some(frame) = placed.iter().find(|p| p.workspace == dock.workspace).map(|p| p.frame)
        else {
            return;
        };
        match dock.edge {
            DockEdge::Left => {
                *stage = Rect::new(
                    frame.max_x() + gap,
                    stage.min_y(),
                    stage.max_x() - frame.max_x() - gap,
                    stage.height(),
                );
            }
            DockEdge::Right => stage.w = frame.min_x() - gap - stage.min_x(),
            DockEdge::Top => {
                *stage = Rect::new(
                    stage.min_x(),
                    frame.max_y() + gap,
                    stage.width(),
                    stage.max_y() - frame.max_y() - gap,
                );
            }
            DockEdge::Bottom => stage.h = frame.min_y() - gap - stage.min_y(),
        }
    };

    let (owners, others) = match orientation {
        FrameOrientation::RowMajor => (&bands, &sides),
        FrameOrientation::ColumnMajor => (&sides, &bands),
    };
    for group in [owners, others] {
        for dock in group.iter() {
            put(dock, stage, &mut placed);
        }
        for dock in group.iter() {
            cut(dock, &mut stage, &placed);
        }
    }
    let (front, back): (Vec<PlacedDock>, Vec<PlacedDock>) =
        placed.into_iter().partition(|dock| dock.floating);
    let mut ordered = back;
    ordered.extend(front);
    WindowPlacement {
        stage: Rect::new(
            stage.min_x(),
            stage.min_y(),
            swift_max(0., stage.width()),
            swift_max(0., stage.height()),
        ),
        docks: ordered,
    }
}

impl WindowPlacement {
    /// `Placement.frame(of:)`.
    pub fn frame_of(&self, workspace: &str) -> Option<Rect> {
        self.docks.iter().find(|dock| dock.workspace == workspace).map(|dock| dock.frame)
    }

    /// `Placement.workspace(at:)`: the docked workspace on top at `point`; `None` for the stage.
    pub fn workspace_at(&self, point: super::Point) -> Option<&str> {
        self.docks
            .iter()
            .rev()
            .find(|dock| dock.frame.contains(point))
            .map(|d| d.workspace.as_str())
    }
}

/// `MovedWindowPlacement.cascadeStep`.
pub const CASCADE_STEP: f64 = 28.;
/// `MovedWindowPlacement.gap`'s default.
pub const MOVED_WINDOW_GAP: f64 = 12.;

/// `MovedWindowPlacement.frame(beside:on:)`: beside `source` on its right when `screen` has room, else
/// on its left, else cascaded one step; always on the screen when any of those fit. AppKit frames
/// (y grows up).
pub fn moved_window_frame(source: Rect, screen: Rect, gap: f64) -> Rect {
    let right = source.offset_by(source.width() + gap, 0.);
    if screen.contains_rect(&right) {
        return right;
    }
    let left = source.offset_by(-(source.width() + gap), 0.);
    if screen.contains_rect(&left) {
        return left;
    }
    let step = CASCADE_STEP;
    for (dx, dy) in [(step, -step), (-step, step), (step, step), (-step, -step)] {
        let cascaded = source.offset_by(dx, dy);
        if screen.contains_rect(&cascaded) {
            return cascaded;
        }
    }
    source.offset_by(step, -step)
}

/// `MovedWindowPlacement.frame(beside:on:avoiding:)`: like [`moved_window_frame`], stepping down and
/// right (or jumping to the screen's top-left when free) until no `occupied` window shares its
/// top-left corner.
pub fn moved_window_frame_avoiding(
    source: Rect,
    screen: Rect,
    occupied: &[Rect],
    gap: f64,
) -> Rect {
    let taken = |frame: &Rect| {
        occupied.iter().any(|o| {
            (o.min_x() - frame.min_x()).abs() < 1. && (o.max_y() - frame.max_y()).abs() < 1.
        })
    };
    let mut candidate = moved_window_frame(source, screen, gap);
    let step = CASCADE_STEP;
    for _ in 0..occupied.len() {
        if !taken(&candidate) {
            break;
        }
        let stepped = candidate.offset_by(step, -step);
        let mut wrapped = stepped;
        wrapped.x = screen.min_x() + step;
        wrapped.y = screen.max_y() - stepped.height() - step;
        candidate =
            if screen.contains_rect(&stepped) || taken(&wrapped) { stepped } else { wrapped };
    }
    candidate
}
