//! One keystroke the remote has not finished echoing.

use crate::config::PredictionInstant;
use crate::glyph::Standing;

/// How far through erasing one retracted glyph the remote's echo is.
///
/// Line editors erase one character as a move left followed by a clear:
/// `BS SP BS`, `BS CSI K`, `BS CSI P`, or `CSI D` in place of `BS`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum EraseProgress {
    AwaitingMoveLeft,
    /// On the retracted glyph's cell, one left of where the echo left the
    /// cursor.
    MovedLeft,
    /// Printed a space over it, so the cursor is back where it started.
    Blanked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Keystroke {
    /// A printable key: the remote echoes `byte` and advances one cell.
    Glyph(u8),
    /// A Backspace that retracted the newest glyph before it.
    Erase(EraseProgress),
    /// A key whose effect is not modelled, typed while glyphs were in
    /// flight. The echoes before it are still predicted; any output once it
    /// is next withdraws everything.
    Barrier,
}

/// One keystroke the remote has not finished echoing, in the order sent.
///
/// The remote echoes these strictly in order, so the ones it has echoed are
/// always a prefix of the queue.
#[derive(Clone, Debug)]
pub(super) struct Entry {
    pub keystroke: Keystroke,
    pub typed_at: PredictionInstant,
    /// For a glyph, whether its echo arrived. An erase stays speculative
    /// until it completes, and then leaves the queue with its glyph.
    pub standing: Standing,
    /// When the echo arrived. The hold is measured from here, not from the
    /// keystroke, so a slow link does not expire its own confirmations.
    /// Never set on a retracted glyph, which has nothing to hold.
    pub confirmed_at: Option<PredictionInstant>,
    /// Whether the user ever saw this glyph. Only these can misfire visibly,
    /// so only these count toward suspension.
    pub is_displayed: bool,
    /// Withdrawn from the overlay but still expected: the remote echoes it in
    /// order all the same, so matching it keeps later keystrokes placed
    /// instead of leaving the rest of the line untracked.
    pub is_hidden: bool,
    /// A later Backspace took it back. The remote still echoes it, but the
    /// overlay never draws it again.
    pub is_retracted: bool,
    /// Ctrl-U or Ctrl-W deleted it while it was in flight. Its cell is drawn
    /// blank until the output after its echo, the remote's erase.
    pub is_masked: bool,
}

impl Entry {
    pub fn new(keystroke: Keystroke, typed_at: PredictionInstant, is_displayed: bool) -> Self {
        Self {
            keystroke,
            typed_at,
            standing: Standing::Speculative,
            confirmed_at: None,
            is_displayed,
            is_hidden: false,
            is_retracted: false,
            is_masked: false,
        }
    }

    pub fn is_glyph(&self) -> bool {
        matches!(self.keystroke, Keystroke::Glyph(_))
    }

    pub fn is_erase(&self) -> bool {
        matches!(self.keystroke, Keystroke::Erase(_))
    }

    pub fn is_speculative(&self) -> bool {
        self.standing == Standing::Speculative
    }

    pub fn is_drawn(&self) -> bool {
        self.is_displayed && !self.is_retracted && !self.is_masked && !self.is_hidden
    }

    /// Whether its cell is drawn blank: deleted by the user, not yet by the
    /// remote.
    pub fn is_blanked(&self) -> bool {
        if !self.is_glyph() || self.is_hidden {
            return false;
        }
        self.is_masked || (self.is_retracted && self.is_displayed)
    }

    /// Whether the overlay covers its cell at all.
    pub fn is_on_screen(&self) -> bool {
        self.is_drawn() || self.is_blanked()
    }

    /// Cells this keystroke moves the cursor once fully echoed.
    pub fn cell_advance(&self) -> i32 {
        match self.keystroke {
            Keystroke::Glyph(_) => 1,
            Keystroke::Erase(_) => -1,
            Keystroke::Barrier => 0,
        }
    }

    /// Cells the echo received so far has moved the cursor.
    pub fn echoed_advance(&self) -> i32 {
        match self.keystroke {
            Keystroke::Glyph(_) => i32::from(self.standing == Standing::Confirmed),
            Keystroke::Erase(EraseProgress::MovedLeft) => -1,
            Keystroke::Erase(_) | Keystroke::Barrier => 0,
        }
    }

    pub fn is_held_confirmation(&self) -> bool {
        self.is_glyph() && self.standing == Standing::Confirmed && !self.is_retracted && !self.is_masked
    }
}
