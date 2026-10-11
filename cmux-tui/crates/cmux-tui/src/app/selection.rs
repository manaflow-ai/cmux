//! Terminal text selection state: the selection range and mode, click
//! sequence tracking for word and line selection, the semantic selection
//! cache, and status message selection.

use std::time::{Duration, Instant};

use cmux_tui_core::{Rect, SurfaceId};
use crossterm::event::KeyModifiers;
use ghostty_vt::{Screen, SelectionPoint, SelectionRange, TrackedScreenPoint};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// A text selection in one surface. Rows are absolute scrollback rows:
/// viewport row + scrollbar offset at capture time, so the selection
/// remains stable while the viewport scrolls.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selection {
    pub surface: SurfaceId,
    pub anchor: (u16, u64),
    pub head: (u16, u64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum SelectionMode {
    #[default]
    Cell,
    Word,
    Line,
}

/// State shared by the press and drag halves of one terminal selection
/// gesture. Crossterm reports individual presses, so the TUI owns the small
/// amount of timing and distance state needed to recognize repeats.
pub(super) struct SelectionClickSequence {
    pub(super) surface: SurfaceId,
    pub(super) screen: Option<Screen>,
    pub(super) position: (u16, u16),
    pub(super) modifiers: KeyModifiers,
    pub(super) time: Instant,
    pub(super) count: u8,
    pub(super) mode: SelectionMode,
    pub(super) anchor: (u16, u64),
    pub(super) dragged: bool,
    pub(super) tracked_anchor: Option<TrackedScreenPoint>,
    /// A failed semantic press keeps `tracked_anchor` alive for a same-press
    /// cell drag, but it must not keep the repeat count alive for the next
    /// press.
    pub(super) repeatable: bool,
}

/// The most recent semantic drag result. Pointer reports often repeat the
/// same terminal cell while the mouse moves between cell boundaries. Keep
/// one bounded result and tie it to the terminal content generation so live
/// output or scrolling always forces a fresh Ghostty lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct SemanticSelectionCache {
    pub(super) surface: SurfaceId,
    pub(super) mode: SelectionMode,
    pub(super) anchor: SelectionPoint,
    pub(super) current: SelectionPoint,
    pub(super) content_generation: u64,
    pub(super) range: Option<SelectionRange>,
}

pub(super) const SELECTION_REPEAT_INTERVAL: Duration = Duration::from_millis(500);
pub(super) const SELECTION_REPEAT_DISTANCE_SQUARED: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct VisibleInputState {
    pub(super) pty_surface: Option<SurfaceId>,
    pub(super) selection: Option<Selection>,
    pub(super) scroll_offset: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct StatusMessageSelection {
    pub(super) text: String,
    pub(super) anchor: u16,
    pub(super) head: u16,
}

impl StatusMessageSelection {
    pub(super) fn range(&self) -> (u16, u16) {
        if self.anchor <= self.head { (self.anchor, self.head) } else { (self.head, self.anchor) }
    }

    pub(super) fn contains(&self, text: &str, cell: u16) -> bool {
        self.text == text && {
            let (start, end) = self.range();
            cell >= start && cell <= end
        }
    }

    pub(super) fn selected_text(&self) -> String {
        let (start, end) = self.range();
        let mut cell = 0usize;
        self.text
            .graphemes(true)
            .filter(|grapheme| {
                let width = grapheme.width();
                let grapheme_start = cell;
                let grapheme_end = cell.saturating_add(width);
                cell = grapheme_end;
                width > 0 && grapheme_start <= usize::from(end) && grapheme_end > usize::from(start)
            })
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RenderedStatusMessage {
    pub(super) rect: Rect,
    pub(super) text: String,
}

impl Selection {
    /// Normalized (start, end) in row-major order, inclusive.
    pub fn range(&self) -> ((u16, u64), (u16, u64)) {
        let a = (self.anchor.1, self.anchor.0);
        let h = (self.head.1, self.head.0);
        if a <= h { (self.anchor, self.head) } else { (self.head, self.anchor) }
    }

    /// Whether a viewport cell is inside the (linear) selection at the
    /// current scrollbar offset.
    pub fn contains_viewport(&self, x: u16, y: u16, offset: u64) -> bool {
        let y = offset + y as u64;
        let ((sx, sy), (ex, ey)) = self.range();
        if y < sy || y > ey {
            return false;
        }
        if sy == ey {
            return x >= sx && x <= ex;
        }
        if y == sy {
            return x >= sx;
        }
        if y == ey {
            return x <= ex;
        }
        true
    }
}
