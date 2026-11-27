//! Layout request and result types: layout specs for `apply_layout`, zoom and
//! focus directions, applied pane results, and the typed layout undo and
//! viewport width errors.

use std::fmt;

use crate::{PaneId, ScreenId, SplitDir, SurfaceId};

#[derive(Debug, Clone)]
pub struct LayoutLeafSpec {
    pub cwd: Option<String>,
    pub command: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub enum LayoutSpec {
    Leaf(LayoutLeafSpec),
    Split { dir: SplitDir, ratio: f32, a: Box<LayoutSpec>, b: Box<LayoutSpec> },
    Stack { pane_count: usize, expanded_index: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoomMode {
    Toggle,
    On,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    pub(super) fn delta(self) -> (i32, i32) {
        match self {
            Direction::Left => (-1, 0),
            Direction::Right => (1, 0),
            Direction::Up => (0, -1),
            Direction::Down => (0, 1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppliedPane {
    pub pane: PaneId,
    pub surface: SurfaceId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedLayout {
    pub screen: ScreenId,
    pub panes: Vec<AppliedPane>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZoomState {
    pub pane: PaneId,
    pub zoomed: bool,
    pub zoomed_pane: Option<PaneId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutUndoResult {
    Undone { screen: ScreenId, revision: u64 },
    ConfirmationRequired { screen: ScreenId, revision: u64, closes_panes: Vec<PaneId> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutUndoError {
    Unavailable,
    Stale(String),
}

impl LayoutUndoError {
    pub const UNAVAILABLE_CODE: &'static str = "layout-undo-unavailable";
    pub const STALE_CODE: &'static str = "layout-undo-stale";

    pub fn code(&self) -> &'static str {
        match self {
            Self::Unavailable => Self::UNAVAILABLE_CODE,
            Self::Stale(_) => Self::STALE_CODE,
        }
    }
}

impl fmt::Display for LayoutUndoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable => formatter.write_str("no layout change to undo"),
            Self::Stale(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for LayoutUndoError {}

#[derive(Debug, Clone, PartialEq)]
pub enum ViewportWidthError {
    OutOfRange { width: f32 },
    PaneNotResizable { pane: PaneId },
}

impl ViewportWidthError {
    pub const OUT_OF_RANGE_CODE: &'static str = "viewport-width-out-of-range";
    pub const COLUMN_MISSING_CODE: &'static str = "viewport-column-not-found";

    pub fn code(&self) -> &'static str {
        match self {
            Self::OutOfRange { .. } => Self::OUT_OF_RANGE_CODE,
            Self::PaneNotResizable { .. } => Self::COLUMN_MISSING_CODE,
        }
    }
}

impl fmt::Display for ViewportWidthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OutOfRange { .. } => {
                formatter.write_str("viewport pane width must be between 0.1 and 1.0")
            }
            Self::PaneNotResizable { pane } => {
                write!(formatter, "pane {pane} has no resizable viewport column")
            }
        }
    }
}

impl std::error::Error for ViewportWidthError {}
