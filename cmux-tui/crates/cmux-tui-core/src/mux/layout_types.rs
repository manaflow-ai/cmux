//! Layout request and result types: layout specs for `apply_layout`, zoom and
//! focus directions, applied pane results, the typed layout undo and viewport
//! width errors, and the result and the error of a floating pane request.

use std::fmt;

use cmux_layout_reducer::floating_panes::FloatFrame;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FloatPaneError {
    /// The pane is unknown.
    PaneNotFound { pane: PaneId },
    /// The pane is the only tiled pane of its screen.
    LastTiledPane,
    /// The pane is a member of a stack, or its column is docked or has rows.
    FixedPane,
    /// `mode` is not one of the documented strings, or a frame value is not a
    /// finite number.
    InvalidArgument { field: &'static str, value: String },
    /// `quick-terminal-v1`: no pane of the screen can float, so a new quick
    /// terminal has no place beside one.
    NoPlaceForQuickTerminal,
    /// The screen is unknown.
    ScreenNotFound { screen: ScreenId },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
}

impl FloatPaneError {
    pub const PANE_MISSING_CODE: &'static str = "floating-pane-missing";
    pub const LAST_TILED_CODE: &'static str = "floating-pane-last-tiled";
    pub const FIXED_CODE: &'static str = "floating-pane-fixed";
    pub const INVALID_ARGUMENT_CODE: &'static str = "invalid-argument";
    pub const QUICK_NO_PLACE_CODE: &'static str = "quick-terminal-no-place";
    /// The field name of a bad `mode` of `quick-terminal`.
    pub const QUICK_MODE_FIELD: &'static str = "quick-terminal mode";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::PaneNotFound { .. } => Some(Self::PANE_MISSING_CODE),
            Self::LastTiledPane => Some(Self::LAST_TILED_CODE),
            Self::FixedPane => Some(Self::FIXED_CODE),
            Self::InvalidArgument { .. } => Some(Self::INVALID_ARGUMENT_CODE),
            Self::NoPlaceForQuickTerminal => Some(Self::QUICK_NO_PLACE_CODE),
            Self::ScreenNotFound { .. } | Self::CommitFailed => None,
        }
    }
}

impl fmt::Display for FloatPaneError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PaneNotFound { pane } => write!(formatter, "no pane {pane}"),
            Self::LastTiledPane => {
                formatter.write_str("the last tiled pane of a screen cannot float")
            }
            Self::FixedPane => formatter.write_str(
                "a pane of a stack, of a docked column or of a column with rows cannot float",
            ),
            Self::InvalidArgument { field: "mode", value } => {
                write!(formatter, "bad mode {value:?} (want \"toggle\", \"on\" or \"off\")")
            }
            Self::InvalidArgument { field: Self::QUICK_MODE_FIELD, value } => {
                write!(formatter, "bad mode {value:?} (want \"toggle\", \"show\" or \"hide\")")
            }
            Self::InvalidArgument { field, value } => {
                write!(formatter, "bad {field} {value:?} (want four finite numbers: x, y, w, h)")
            }
            Self::NoPlaceForQuickTerminal => formatter.write_str(
                "no pane of the screen can float, so a quick terminal has no place on it",
            ),
            Self::ScreenNotFound { screen } => write!(formatter, "unknown screen {screen}"),
            Self::CommitFailed => formatter.write_str("could not persist the floating pane"),
        }
    }
}

impl std::error::Error for FloatPaneError {}

/// Result of a `float-pane` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FloatPaneOutcome {
    pub screen: ScreenId,
    /// The pane's frame after the request; `None` when the pane is tiled.
    pub frame: Option<FloatFrame>,
    /// False when the request matched the screen and committed nothing.
    pub changed: bool,
}
