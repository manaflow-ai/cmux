//! Decides which typed characters cmux may draw before the remote echoes them.
//!
//! The engine owns policy, not pixels. It never writes to the terminal grid,
//! so a wrong guess is withdrawn by dropping an overlay glyph rather than by
//! undoing a screen mutation, and the authoritative screen stays whatever the
//! remote said it was.
//!
//! Prediction runs only for a surface the host has classified as remote,
//! whose shell runs on another machine. A local shell never sees a predicted
//! glyph, however slowly it echoes, and its keystrokes and output are ignored.
//!
//! Within a remote surface, prediction runs only inside a confirmed echo run:
//! the engine will not draw a character until it has seen the remote echo two
//! characters it tracked in a row, and output it did not predict ends the run.
//! A password prompt therefore never displays a speculative glyph: nothing
//! there is echoed, a key typed ahead of the prompt gets at most one echo
//! before the prompt turns echo off, and a masked prompt's `*` never counts.
//!
//! A line editor that moves back over text it echoed and prints the same text
//! again (zsh after the first key, zsh-syntax-highlighting recolouring a word)
//! is rewriting, not mispredicting: the engine remembers what it saw echoed on
//! the row and accepts the rewrite. Output that moves the cursor somewhere
//! unmodelled, or a keystroke whose echo is overdue, takes the overlay down
//! but keeps matching the keystrokes in flight, since they still echo in
//! order; only an echo that contradicts them drops them.
//!
//! Backspace over a glyph the remote has not echoed yet retracts it from the
//! overlay at once. The remote still receives both keystrokes, so it echoes
//! the character and then erases it; the engine waits for exactly that and
//! withdraws on anything else. Backspace over anything the remote already
//! drew is the remote's to render, and withdraws as any other editing key.
//!
//! A deleted character must not come back. A retracted glyph's echo is still
//! on its way when the user deletes it, so its cell is drawn blank (`Erased`)
//! until the remote's erase lands. A key whose effect is not modelled while
//! glyphs are in flight (Return, an arrow, Backspace over echoed text) leaves
//! those glyphs drawn behind a barrier: they are still exactly what the remote
//! echoes next, and dropping them would blank text the user just saw until
//! its echo repaints it. Ctrl-U and Ctrl-W (`typed_line_erase`) turn the
//! glyphs in flight into blanks instead, because the remote is about to delete
//! them. Any output that is not the expected echo or erase clears everything,
//! blanks included, so a blank never hides real output.

mod entry;
mod output;

use crate::config::{PredictionConfiguration, PredictionInstant};
use crate::glyph::{PredictedGlyph, Standing};
use crate::scanner::TerminalOutputScanner;
use entry::{Entry, EraseProgress, Keystroke};
use std::collections::HashSet;
use std::time::Duration;

/// Why the engine is or is not drawing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Status {
    /// The setting is off.
    Disabled,
    /// The surface's shell runs on this Mac, or the host has not said
    /// otherwise. Nothing is tracked or drawn.
    LocalSurface,
    /// No confirmed echo yet, or the last remote output ended the run.
    /// Keystrokes are tracked so an echo can re-arm, but nothing is drawn.
    Listening,
    /// The link is fast enough that there is no lag to hide.
    LinkIsFastEnough,
    /// A full-screen application owns the screen; its echo is unpredictable.
    AlternateScreen,
    /// Too many visible withdrawals recently.
    Suspended,
    Predicting,
}

const MAXIMUM_LINE_MEMORY: usize = 512;

/// See the module docs.
#[derive(Clone, Debug)]
pub struct TerminalPredictionEngine {
    pub configuration: PredictionConfiguration,
    pub is_enabled: bool,
    /// Whether the host established that this surface's shell runs on another
    /// machine. Defaults to `false`, so a host that never classifies the
    /// surface gets the local behavior.
    pub is_remote_surface: bool,

    scanner: TerminalOutputScanner,
    entries: Vec<Entry>,
    is_alternate_screen: bool,
    /// Set once a mode switch has been seen in output. A switch the engine
    /// saw can be newer than what the terminal's parser has applied, so it
    /// outranks a seeded read.
    has_observed_alternate_screen_switch: bool,
    /// Consecutive echoes matched since the run last ended. Drawing starts at
    /// two: a single echo is what a tty in cooked mode gives the first key
    /// typed ahead of a password prompt, just before the prompt turns echo
    /// off, and one `*` is what a masked prompt echoes.
    echo_streak: u32,
    /// Cells left of the cursor on this row whose content the engine saw
    /// echoed, newest last. A line editor that moves back over text it
    /// already echoed and prints it again (zsh recolouring a word, or
    /// redrawing after the first key) is rewriting, not mispredicting; this
    /// is how that is told apart from a redraw.
    line: Vec<u8>,
    /// Cells the cursor moved back over, nearest first. Until the remote has
    /// printed them again, drawn offsets are measured from where the cursor
    /// will be once it has.
    rewound: Vec<u8>,
    /// Set when output removed blanks from the overlay. The frame on screen
    /// was built before that output, so the host keeps the overlay where it
    /// is until the next presented frame instead of re-anchoring it now. A
    /// host that stops reporting frames gets the overlay back after
    /// `confirmation_hold`, as with a held confirmation.
    layout_held_since: Option<PredictionInstant>,
    smoothed_echo_latency: Option<Duration>,
    recent_mispredictions: Vec<PredictionInstant>,
    suspended_until: Option<PredictionInstant>,
    /// Until this instant, output may still be the echo of keystrokes the
    /// engine stopped tracking when it last withdrew. Matching that echo
    /// against keystrokes typed since would misalign every later offset, so
    /// until it passes, output only clears the queue.
    untracked_echo_deadline: Option<PredictionInstant>,
}

impl Default for TerminalPredictionEngine {
    fn default() -> Self {
        Self::new(PredictionConfiguration::DEFAULT, false, false)
    }
}

impl TerminalPredictionEngine {
    pub fn new(configuration: PredictionConfiguration, is_enabled: bool, is_remote_surface: bool) -> Self {
        Self {
            configuration,
            is_enabled,
            is_remote_surface,
            scanner: TerminalOutputScanner::new(),
            entries: Vec::new(),
            is_alternate_screen: false,
            has_observed_alternate_screen_switch: false,
            echo_streak: 0,
            line: Vec::new(),
            rewound: Vec::new(),
            layout_held_since: None,
            smoothed_echo_latency: None,
            recent_mispredictions: Vec::new(),
            suspended_until: None,
            untracked_echo_deadline: None,
        }
    }

    /// Whether keystrokes and output are tracked at all.
    fn is_active(&self) -> bool {
        self.is_enabled && self.is_remote_surface
    }

    fn is_echo_run_active(&self) -> bool {
        self.echo_streak >= 2
    }

    // Readable state

    /// See `layout_held_since`.
    pub fn holds_layout_until_frame(&self) -> bool {
        self.layout_held_since.is_some()
    }

    /// What the host should draw, ordered left to right, with offsets measured
    /// from the live cursor.
    ///
    /// The host anchors on the cursor ghostty reports, and ghostty's parser
    /// has already advanced that cursor past every echo this engine has
    /// confirmed (the tee runs ahead of the parser, and the engine drains
    /// after it). So confirmed glyphs, which are always the leading entries,
    /// sit at negative offsets, exactly over the cells their echo landed in:
    /// drawing them there covers the frames before ghostty repaints without
    /// ever doubling a character one cell to the right. Speculative glyphs
    /// start at offset 0. Entries typed before the run armed are never drawn,
    /// but still occupy their cell, so a later glyph keeps its true offset.
    ///
    /// A retracted glyph and its erase add up to no cells, but while the
    /// remote is between echoing the character and erasing it the live cursor
    /// sits one cell further right, so offsets are measured from how far the
    /// echo so far has actually moved it.
    pub fn glyphs(&self) -> Vec<PredictedGlyph> {
        let mut drawn = Vec::new();
        self.glyphs_into(&mut drawn);
        drawn
    }

    /// `glyphs`, into a buffer the caller reuses (the FFI's snapshot).
    pub fn glyphs_into(&self, drawn: &mut Vec<PredictedGlyph>) {
        drawn.clear();
        let rewound = i32::try_from(self.rewound.len()).unwrap_or(i32::MAX);
        let cursor = self.entries.iter().map(Entry::echoed_advance).sum::<i32>() - rewound;
        let mut cell = 0;
        for entry in &self.entries {
            if entry.is_blanked() {
                drawn.push(PredictedGlyph::new(' ', cell - cursor, Standing::Erased));
            } else if let (true, Keystroke::Glyph(byte)) = (entry.is_drawn(), entry.keystroke) {
                drawn.push(PredictedGlyph::new(char::from(byte), cell - cursor, entry.standing));
            }
            cell += entry.cell_advance();
        }
        // A glyph typed after a Backspace lands on the cell the blank masks;
        // the glyph is what the cell will show, so the blank gives way.
        if drawn.iter().any(|g| g.standing == Standing::Erased) {
            let lettered: HashSet<i32> =
                drawn.iter().filter(|g| g.standing != Standing::Erased).map(|g| g.offset).collect();
            drawn.retain(|g| g.standing != Standing::Erased || !lettered.contains(&g.offset));
        }
    }

    /// Round trip from keystroke to echo, smoothed. `None` until the first echo.
    pub fn observed_echo_latency(&self) -> Option<Duration> {
        self.smoothed_echo_latency
    }

    /// When the next change to what is drawn falls due, or `None` when
    /// nothing is drawn.
    ///
    /// Nothing renders a terminal that has gone quiet, so the host has to set
    /// a timer for this; otherwise a prediction made just before the link died
    /// would stay drawn until the user typed again. Any speculative entry
    /// expiring withdraws everything, so while anything is drawn the undrawn
    /// ones count too: an erase that never arrives expires on its own
    /// keystroke's clock, not on that of a glyph typed after it.
    pub fn next_expiry(&self) -> Option<PredictionInstant> {
        let hold_ends = self.layout_held_since.map(|since| since + self.configuration.confirmation_hold);
        if !self.entries.iter().any(Entry::is_on_screen) {
            return hold_ends;
        }
        let lifetime = self.speculative_lifetime();
        let entry_expiry = self
            .entries
            .iter()
            .filter_map(|entry| {
                if entry.is_speculative() {
                    return Some(entry.typed_at + lifetime);
                }
                let confirmed_at = entry.confirmed_at.filter(|_| entry.is_drawn())?;
                Some(confirmed_at + self.configuration.confirmation_hold)
            })
            .min();
        [entry_expiry, hold_ends].into_iter().flatten().min()
    }

    pub fn status(&self, now: PredictionInstant) -> Status {
        if !self.is_enabled {
            return Status::Disabled;
        }
        if !self.is_remote_surface {
            return Status::LocalSurface;
        }
        if self.is_alternate_screen {
            return Status::AlternateScreen;
        }
        if self.suspended_until.is_some_and(|until| now < until) {
            return Status::Suspended;
        }
        if !self.is_echo_run_active() {
            return Status::Listening;
        }
        let Some(latency) = self.smoothed_echo_latency else { return Status::Listening };
        if latency <= self.configuration.engage_above_echo_latency {
            return Status::LinkIsFastEnough;
        }
        Status::Predicting
    }

    /// Seeds whether a full-screen application already owns the screen.
    ///
    /// The engine otherwise learns this only from the mode switches it sees in
    /// output, so a surface that was already in the alternate screen when
    /// prediction started (the setting turned on, or the surface registered,
    /// with vim or htop open) would predict inside it. The host reads the
    /// terminal's current mode and passes it here before the first keystroke.
    /// Ignored once a mode switch has been seen in output, because output is
    /// teed ahead of the terminal's parser and may be newer than the read.
    pub fn seed_alternate_screen(&mut self, is_active: bool) {
        if !self.has_observed_alternate_screen_switch {
            self.is_alternate_screen = is_active;
        }
    }

    // Input

    /// Record what the user typed. `text` is the literal bytes cmux is about
    /// to send to the PTY. Returns whether the drawn overlay changed.
    pub fn typed(&mut self, text: impl AsRef<[u8]>, now: PredictionInstant) -> bool {
        match text.as_ref() {
            // DEL is what ghostty sends for Backspace by default; BS when configured.
            [0x7F | 0x08] => self.typed_backspace(now),
            &[byte @ 0x20..=0x7E] => self.typed_printable_ascii(Some(byte), now),
            _ => self.typed_printable_ascii(None, now),
        }
    }

    /// The byte-level entry point the host uses.
    ///
    /// `byte` is the printable ASCII byte this key sends, or `None` for every
    /// other key but Backspace, which goes to `typed_backspace`. `None`
    /// withdraws: editing keys, Return, chords, and anything the key encoder
    /// turned into an escape sequence all leave the screen somewhere this
    /// does not model, and non-ASCII text can be wide or combining, so its
    /// cell count is not one.
    pub fn typed_printable_ascii(&mut self, byte: Option<u8>, now: PredictionInstant) -> bool {
        if !self.is_active() {
            return false;
        }
        let expired = self.expire(now);
        // Behind a barrier the remote's state is unknown, so nothing typed now
        // can be placed. Its echo arrives after the barrier resolves, which
        // starts the untracked window that covers it.
        if self.has_barrier() {
            return expired;
        }

        let Some(byte) = byte.filter(|b| (0x20..=0x7E).contains(b)) else {
            if self.raise_barrier_if_in_flight(now) {
                return expired;
            }
            return self.withdraw_all(false, now, true) || expired;
        };
        if self.entries.len() >= self.configuration.maximum_speculative_glyphs {
            return self.withdraw_all(false, now, true) || expired;
        }
        if let Some(deadline) = self.untracked_echo_deadline.filter(|&d| now < d) {
            // Readline and zle redraw pending input as one net change, so this
            // key's echo may arrive merged with the untracked ones, or not at
            // all when it undoes one of them. Matching it would re-arm a run
            // cells away from the remote, so it is untracked too.
            self.untracked_echo_deadline = Some(deadline.max(now + self.untracked_echo_settle()));
            return expired;
        }

        let display = self.status(now) == Status::Predicting;
        self.entries.push(Entry::new(Keystroke::Glyph(byte), now, display));
        display || expired
    }

    /// Record a key that a local binding consumed without sending anything to
    /// the PTY. This advances expiry bookkeeping while leaving the prediction
    /// run intact, because the remote terminal state did not change.
    pub fn typed_nothing(&mut self, now: PredictionInstant) -> bool {
        if !self.is_active() {
            return false;
        }
        self.expire(now)
    }

    /// Record a Backspace, whichever byte (DEL or BS) the key sends.
    ///
    /// Retracts the newest glyph if it is drawn: not yet echoed, or echoed but
    /// not yet painted. The remote's echo of it, if still due, and of its
    /// erase is then expected before anything else. With no such glyph, the
    /// character to erase is already on the grid, or was never shown, so this
    /// withdraws like any other editing key. Returns whether the drawn overlay
    /// changed.
    pub fn typed_backspace(&mut self, now: PredictionInstant) -> bool {
        if !self.is_active() {
            return false;
        }
        let expired = self.expire(now);
        if self.has_barrier() {
            return expired;
        }

        // Everything after the newest unretracted glyph is retracted glyphs
        // and their erases, which occupy no cells, so it is the one the
        // remote will erase.
        let index = self.entries.iter().rposition(|e| e.is_glyph() && !e.is_retracted);
        let Some(index) = index.filter(|&i| {
            self.entries[i].is_drawn() && self.entries.len() < self.configuration.maximum_speculative_glyphs
        }) else {
            // Backspace over text the remote already drew is the remote's to
            // render. Retracted glyphs still waiting for their erase keep
            // their blanks until it lands.
            if self.raise_barrier_if_in_flight(now) {
                return expired;
            }
            return self.withdraw_all(false, now, true) || expired;
        };

        // A glyph whose echo already arrived but is still held for the frame
        // that paints it is retracted the same way: the remote erases it
        // next, and until then its cell is blank rather than flashing the
        // character between this frame and the erase.
        self.entries[index].is_retracted = true;
        self.entries[index].confirmed_at = None;
        self.entries.push(Entry::new(Keystroke::Erase(EraseProgress::AwaitingMoveLeft), now, false));
        true
    }

    /// Record a key that deletes backwards by more than one character:
    /// Ctrl-U, Ctrl-W, Option-Backspace. The remote erases the glyphs still in
    /// flight along with text it already drew, so their cells are drawn blank
    /// until its erase lands instead of flashing back as their echoes arrive.
    /// Returns whether the drawn overlay changed.
    pub fn typed_line_erase(&mut self, now: PredictionInstant) -> bool {
        if !self.is_active() {
            return false;
        }
        let expired = self.expire(now);
        // Behind a barrier the line was already submitted or changed in a way
        // not modelled; this key acts on whatever the remote shows now.
        if self.has_barrier() {
            return expired;
        }
        let mut changed = false;
        for entry in &mut self.entries {
            if entry.is_speculative() && entry.is_glyph() && !entry.is_retracted && !entry.is_masked {
                entry.is_masked = true;
                changed = true;
            }
        }
        if self.raise_barrier_if_in_flight(now) {
            return changed || expired;
        }
        self.withdraw_all(false, now, true) || expired
    }

    /// Record input that reached the remote without passing through `typed`:
    /// a paste, dropped text, or text and keys sent by automation or a paired
    /// device. Its echo moves the cursor by an amount this cannot know, so
    /// everything drawn is withdrawn and later keystrokes stay undrawn until a
    /// fresh echo re-arms the run. Returns whether the drawn overlay changed.
    pub fn sent_untracked_input(&mut self, now: PredictionInstant) -> bool {
        self.typed_printable_ascii(None, now)
    }

    /// Report that a rendered frame reached the screen. Confirmed glyphs
    /// retire here: the tee fires before the VT parser, so retiring at
    /// confirmation would blank the cell for the frames between the echo and
    /// its paint.
    pub fn presented_frame(&mut self, now: PredictionInstant) -> bool {
        self.expire(now);
        let before = self.entries.len();
        self.entries.retain(|e| !e.is_held_confirmation());
        let released = self.holds_layout_until_frame();
        self.layout_held_since = None;
        self.entries.len() != before || released
    }

    /// Advance time with no other event, withdrawing anything that has aged out.
    pub fn tick(&mut self, now: PredictionInstant) -> bool {
        self.expire(now)
    }
}
