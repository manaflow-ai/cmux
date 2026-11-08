//! Decides which typed characters cmux may draw before the remote echoes them.
//!
//! The engine owns policy, not pixels. It never writes to the terminal grid, so
//! a wrong guess is withdrawn by dropping an overlay glyph rather than by
//! undoing a screen mutation, and the screen stays whatever the remote said.
//!
//! Prediction runs only for a surface the host classified as remote, whose
//! shell runs on another machine. A local shell never sees a predicted glyph,
//! however slowly it echoes, and its keystrokes and output are ignored.
//!
//! Within a remote surface, prediction runs only inside a confirmed echo run:
//! nothing is drawn until the remote echoed two tracked characters in a row,
//! and output the engine did not predict ends the run. A password prompt
//! therefore never shows a speculative glyph: nothing there is echoed, a key
//! typed ahead of the prompt gets at most one echo before the prompt turns echo
//! off, and a masked prompt's `*` never counts.
//!
//! A line editor that moves back over text it echoed and prints the same text
//! again (zsh after the first key, zsh-syntax-highlighting recolouring a word)
//! is rewriting, not mispredicting: the engine remembers what it saw echoed on
//! the row and accepts the rewrite. Output that moves the cursor somewhere
//! unmodelled, or a keystroke whose echo is overdue, takes the overlay down but
//! keeps matching the keystrokes in flight, since they still echo in order; only
//! an echo that contradicts them drops them.
//!
//! Backspace over a glyph the remote has not echoed yet retracts it at once. The
//! remote still receives both keys, so it echoes the character and then erases
//! it; the engine waits for exactly that and withdraws on anything else.
//! Backspace over anything the remote already drew is the remote's to render.
//!
//! A deleted character must not come back. A retracted glyph's echo is still on
//! its way when the user deletes it, so its cell is drawn blank (`Erased`) until
//! the remote's erase lands. A key whose effect is not modelled while glyphs are
//! in flight (Return, an arrow, Backspace over echoed text) leaves those glyphs
//! drawn behind a barrier: they are still exactly what the remote echoes next.
//! Ctrl-U and Ctrl-W ([`TerminalPredictionEngine::typed_line_erase`]) turn the
//! glyphs in flight into blanks instead, because the remote is about to delete
//! them. Any output that is not the expected echo or erase clears everything,
//! blanks included, so a blank never hides real output.

use crate::config::PredictionConfiguration;
use crate::glyph::{PredictedGlyph, Standing};
use crate::input::InputKind;
use crate::scanner::{OutputSignal, TerminalOutputScanner};
use std::time::Duration;

/// Why the engine is or is not drawing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Status {
    /// The setting is off.
    Disabled = 0,
    /// The surface's shell runs on this Mac, or the host has not said otherwise.
    LocalSurface = 1,
    /// No confirmed echo yet, or the last remote output ended the run.
    Listening = 2,
    /// The link is fast enough that there is no lag to hide.
    LinkIsFastEnough = 3,
    /// A full-screen application owns the screen; its echo is unpredictable.
    AlternateScreen = 4,
    /// Too many visible withdrawals recently.
    Suspended = 5,
    Predicting = 6,
}

/// How far through erasing one retracted glyph the remote's echo is. Line
/// editors erase one character as a move left followed by a clear: `BS SP BS`,
/// `BS CSI K`, `BS CSI P`, or `CSI D` in place of `BS`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EraseProgress {
    AwaitingMoveLeft,
    /// On the retracted glyph's cell, one left of where the echo left the cursor.
    MovedLeft,
    /// Printed a space over it, so the cursor is back where it started.
    Blanked,
}

/// Whose echo output inside the untracked window is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum UntrackedOutput {
    /// A keystroke's the engine stopped tracking.
    Older,
    /// The oldest tracked keystroke's.
    Tracked,
    /// Either; nothing tells them apart.
    Ambiguous,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Keystroke {
    /// A printable key: the remote echoes this byte and advances one cell.
    Glyph(u8),
    /// A Backspace that retracted the newest glyph before it.
    Erase(EraseProgress),
    /// A key whose effect is not modelled, typed while glyphs were in flight.
    /// The echoes before it are still predicted; any output once it is next
    /// withdraws everything.
    Barrier,
}

/// One keystroke the remote has not finished echoing, in the order sent. The
/// remote echoes these strictly in order, so the echoed ones are always a
/// prefix of the queue.
#[derive(Clone, Copy, Debug)]
struct Entry {
    keystroke: Keystroke,
    typed_at: Duration,
    /// For a glyph, whether its echo arrived. An erase stays speculative until
    /// it completes, and then leaves the queue with its glyph.
    standing: Standing,
    /// When the echo arrived. The hold is measured from here, not from the
    /// keystroke, so a slow link does not expire its own confirmations. Never
    /// set on a retracted glyph, which has nothing to hold.
    confirmed_at: Option<Duration>,
    /// Whether the user ever saw this glyph. Only these can misfire visibly, so
    /// only these count toward suspension.
    is_displayed: bool,
    /// Withdrawn from the overlay but still expected: the remote echoes it in
    /// order all the same, so matching it keeps later keystrokes placed.
    is_hidden: bool,
    /// A later Backspace took it back. The remote still echoes it, but the
    /// overlay never draws it again.
    is_retracted: bool,
    /// Ctrl-U or Ctrl-W deleted it while it was in flight. Its cell is drawn
    /// blank until the output after its echo, the remote's erase.
    is_masked: bool,
}

impl Entry {
    fn new(keystroke: Keystroke, typed_at: Duration, is_displayed: bool) -> Self {
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

    fn is_glyph(&self) -> bool {
        matches!(self.keystroke, Keystroke::Glyph(_))
    }

    fn is_drawn(&self) -> bool {
        self.is_displayed && !self.is_retracted && !self.is_masked && !self.is_hidden
    }

    /// Whether its cell is drawn blank: deleted by the user, not yet by the remote.
    fn is_blanked(&self) -> bool {
        self.is_glyph()
            && !self.is_hidden
            && (self.is_masked || (self.is_retracted && self.is_displayed))
    }

    /// Whether the overlay covers its cell at all.
    fn is_on_screen(&self) -> bool {
        self.is_drawn() || self.is_blanked()
    }

    /// Cells this keystroke moves the cursor once fully echoed.
    fn cell_advance(&self) -> i32 {
        match self.keystroke {
            Keystroke::Glyph(_) => 1,
            Keystroke::Erase(_) => -1,
            Keystroke::Barrier => 0,
        }
    }

    /// Cells the echo received so far has moved the cursor.
    fn echoed_advance(&self) -> i32 {
        match self.keystroke {
            Keystroke::Glyph(_) => i32::from(self.standing == Standing::Confirmed),
            Keystroke::Erase(EraseProgress::MovedLeft) => -1,
            Keystroke::Erase(_) | Keystroke::Barrier => 0,
        }
    }

    fn is_held_confirmation(&self) -> bool {
        self.is_glyph()
            && self.standing == Standing::Confirmed
            && !self.is_retracted
            && !self.is_masked
    }
}

const MAXIMUM_LINE_MEMORY: usize = 512;

#[derive(Clone, Debug)]
pub struct TerminalPredictionEngine {
    pub configuration: PredictionConfiguration,
    pub is_enabled: bool,
    /// Whether the host established that this surface's shell runs on another
    /// machine. Off by default, so a host that never classifies the surface
    /// gets the local behavior.
    pub is_remote_surface: bool,
    scanner: TerminalOutputScanner,
    entries: Vec<Entry>,
    is_alternate_screen: bool,
    /// Set once a mode switch was seen in output. A switch the engine saw can
    /// be newer than what the terminal's parser applied, so it outranks a seed.
    has_observed_alternate_screen_switch: bool,
    /// Consecutive echoes matched since the run last ended. Drawing starts at
    /// two: one echo is what a tty in cooked mode gives the first key typed
    /// ahead of a password prompt, and one `*` is what a masked prompt echoes.
    echo_streak: u32,
    /// Cells left of the cursor on this row whose content the engine saw
    /// echoed, newest last: how a rewrite is told apart from a redraw.
    line: Vec<u8>,
    /// Cells the cursor moved back over, nearest first. Until the remote
    /// printed them again, drawn offsets are measured from where the cursor
    /// will be once it has.
    rewound: Vec<u8>,
    /// Set when output removed blanks from the overlay. The frame on screen was
    /// built before that output, so the host keeps the overlay where it is
    /// until the next presented frame (or `confirmation_hold`).
    layout_held_since: Option<Duration>,
    smoothed_echo_latency: Option<Duration>,
    recent_mispredictions: Vec<Duration>,
    suspended_until: Option<Duration>,
    /// Until this instant, output may still be the echo of keystrokes the
    /// engine stopped tracking when it last withdrew; matching it against keys
    /// typed since would misalign every later offset, so it only clears.
    untracked_echo_deadline: Option<Duration>,
    /// When the newest keystroke the engine did not track was sent (behind a
    /// barrier, or the one a withdrawal was for). A key sent right after it can
    /// reach the remote in the same read and come back merged with it.
    newest_untracked_keystroke: Option<Duration>,
    /// Printable keys sent untracked, with when: each one's echo may still be
    /// on its way for a settle period. Output matching the next tracked key
    /// is ambiguous while a key with its byte is here.
    untracked_bytes: Vec<(u8, Duration)>,
    /// Until when output may come from a key whose effect is not modelled
    /// (Return, an editing key, a lost read): it can print anything.
    opaque_echo_until: Option<Duration>,
}

impl Default for TerminalPredictionEngine {
    fn default() -> Self {
        Self::new(PredictionConfiguration::default(), false, false)
    }
}

impl TerminalPredictionEngine {
    pub fn new(
        configuration: PredictionConfiguration,
        is_enabled: bool,
        is_remote_surface: bool,
    ) -> Self {
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
            newest_untracked_keystroke: None,
            untracked_bytes: Vec::new(),
            opaque_echo_until: None,
        }
    }

    fn is_active(&self) -> bool {
        self.is_enabled && self.is_remote_surface
    }

    fn is_echo_run_active(&self) -> bool {
        self.echo_streak >= 2
    }

    // Readable state

    /// What the host draws, left to right, with offsets from the live cursor.
    ///
    /// The host anchors on the cursor ghostty reports, and ghostty's parser has
    /// already advanced it past every echo this engine confirmed (the engine
    /// sees output just before the parser). So confirmed glyphs, always the
    /// leading entries, sit at negative offsets, exactly over the cells their
    /// echo landed in. Speculative glyphs start at offset 0. Entries typed
    /// before the run armed are never drawn, but still occupy their cell.
    pub fn glyphs(&self) -> Vec<PredictedGlyph> {
        let rewound = i32::try_from(self.rewound.len()).unwrap_or(i32::MAX);
        let cursor = self.entries.iter().map(Entry::echoed_advance).sum::<i32>() - rewound;
        let mut cell = 0;
        let mut drawn = Vec::new();
        for entry in &self.entries {
            if entry.is_blanked() {
                drawn.push(PredictedGlyph {
                    character: b' ',
                    offset: cell - cursor,
                    standing: Standing::Erased,
                });
            } else if entry.is_drawn()
                && let Keystroke::Glyph(character) = entry.keystroke
            {
                drawn.push(PredictedGlyph {
                    character,
                    offset: cell - cursor,
                    standing: entry.standing,
                });
            }
            cell += entry.cell_advance();
        }
        // A glyph typed after a Backspace lands on the cell the blank masks;
        // the glyph is what the cell will show, so the blank gives way.
        let lettered: Vec<i32> = drawn
            .iter()
            .filter(|glyph| glyph.standing != Standing::Erased)
            .map(|glyph| glyph.offset)
            .collect();
        drawn.retain(|glyph| {
            glyph.standing != Standing::Erased || !lettered.contains(&glyph.offset)
        });
        drawn
    }

    /// Round trip from keystroke to echo, smoothed. `None` until the first echo.
    pub fn observed_echo_latency(&self) -> Option<Duration> {
        self.smoothed_echo_latency
    }

    /// Whether the overlay stays where it is until the next presented frame.
    pub fn holds_layout_until_frame(&self) -> bool {
        self.layout_held_since.is_some()
    }

    /// When the next change to what is drawn falls due, or `None` when nothing
    /// is drawn. A terminal gone quiet renders no frames, so the host sets a
    /// timer for this; otherwise a prediction made just before the link died
    /// would stay drawn until the user typed again.
    pub fn next_expiry(&self) -> Option<Duration> {
        let hold_ends =
            self.layout_held_since.map(|since| since + self.configuration.confirmation_hold);
        if !self.entries.iter().any(Entry::is_on_screen) {
            return hold_ends;
        }
        let lifetime = self.speculative_lifetime();
        let entry_expiry = self
            .entries
            .iter()
            .filter_map(|entry| {
                if entry.standing == Standing::Speculative {
                    return Some(entry.typed_at + lifetime);
                }
                if !entry.is_drawn() {
                    return None;
                }
                entry.confirmed_at.map(|at| at + self.configuration.confirmation_hold)
            })
            .min();
        [entry_expiry, hold_ends].into_iter().flatten().min()
    }

    pub fn status(&self, now: Duration) -> Status {
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
        match self.smoothed_echo_latency {
            None => Status::Listening,
            Some(latency) if latency <= self.configuration.engage_above_echo_latency => {
                Status::LinkIsFastEnough
            }
            Some(_) => Status::Predicting,
        }
    }

    /// Seeds whether a full-screen application already owns the screen (the
    /// host reads the terminal's mode before the first keystroke). Ignored once
    /// a switch was seen in output, which may be newer than the read.
    pub fn seed_alternate_screen(&mut self, is_active: bool) {
        if !self.has_observed_alternate_screen_switch {
            self.is_alternate_screen = is_active;
        }
    }

    // Input

    /// One chunk of encoded input the host is about to send to the remote,
    /// classified by [`InputKind::of`]. Returns whether the drawn overlay changed.
    pub fn sent(&mut self, bytes: &[u8], now: Duration) -> bool {
        match InputKind::of(bytes) {
            InputKind::Printable(byte) => self.typed(Some(byte), now),
            InputKind::Backspace => self.typed_backspace(now),
            InputKind::LineErase => self.typed_line_erase(now),
            InputKind::Nothing => self.typed_nothing(now),
            InputKind::Untracked => self.typed(None, now),
        }
    }

    /// A key that puts `byte` (printable ASCII) on the wire, or `None` for every
    /// other key but Backspace. `None` withdraws: editing keys, Return, chords
    /// and escape sequences all leave the screen somewhere this does not model,
    /// and non-ASCII text can be wide or combining.
    pub fn typed(&mut self, byte: Option<u8>, now: Duration) -> bool {
        if !self.is_active() {
            return false;
        }
        let expired = self.expire(now);
        // Behind a barrier the remote's state is unknown, so nothing typed now
        // can be placed. Its echo arrives after the barrier resolves, which
        // starts the untracked window that covers it.
        if self.has_barrier() {
            self.newest_untracked_keystroke = Some(now);
            match byte.filter(|byte| (0x20..=0x7E).contains(byte)) {
                Some(byte) => self.note_untracked_byte(byte, now),
                None => self.mark_opaque_echo(now),
            }
            return expired;
        }
        let Some(byte) = byte.filter(|byte| (0x20..=0x7E).contains(byte)) else {
            if self.raise_barrier_if_in_flight(now) {
                return expired;
            }
            self.mark_opaque_echo(now);
            return self.withdraw_all(false, now, true) || expired;
        };
        if self.entries.len() >= self.configuration.maximum_speculative_glyphs {
            self.note_untracked_byte(byte, now);
            return self.withdraw_all(false, now, true) || expired;
        }
        let in_untracked_window =
            self.untracked_echo_deadline.is_some_and(|deadline| now < deadline);
        if in_untracked_window
            && self
                .newest_untracked_keystroke
                .is_some_and(|untracked| now.saturating_sub(untracked) < self.coalescing_gap())
        {
            // Readline and zle redraw pending input as one net change, so a key
            // sent right behind an untracked one may come back merged with it,
            // or not at all when it undoes it; it is untracked too.
            self.newest_untracked_keystroke = Some(now);
            self.note_untracked_byte(byte, now);
            self.untracked_echo_deadline = self
                .untracked_echo_deadline
                .map(|deadline| deadline.max(now + self.untracked_echo_settle()));
            return expired;
        }
        // Any other key is tracked, also while older echoes may still be on
        // their way: they arrive first, in order, and are told apart from this
        // key's echo by when they come (`is_tracked_echo`). It is not drawn
        // until the window closes; a key typed in it no longer pushes it out,
        // so steady typing after Return or a Backspace predicts again within
        // a round trip instead of once the user pauses.
        let display = !in_untracked_window && self.status(now) == Status::Predicting;
        self.entries.push(Entry::new(Keystroke::Glyph(byte), now, display));
        display || expired
    }

    /// A key that sent nothing the remote's screen reacts to: the run stays.
    pub fn typed_nothing(&mut self, now: Duration) -> bool {
        if !self.is_active() {
            return false;
        }
        self.expire(now)
    }

    /// A Backspace, whichever byte (DEL or BS) the key sends. Retracts the
    /// newest glyph if it is drawn; otherwise the character to erase is already
    /// on the grid, or was never shown, so this withdraws like any editing key.
    pub fn typed_backspace(&mut self, now: Duration) -> bool {
        if !self.is_active() {
            return false;
        }
        let expired = self.expire(now);
        if self.has_barrier() {
            self.newest_untracked_keystroke = Some(now);
            self.mark_opaque_echo(now);
            return expired;
        }
        // Everything after the newest unretracted glyph is retracted glyphs and
        // their erases, which occupy no cells, so it is the one the remote erases.
        let room = self.entries.len() < self.configuration.maximum_speculative_glyphs;
        let newest = self
            .entries
            .iter_mut()
            .rev()
            .find(|entry| entry.is_glyph() && !entry.is_retracted)
            .filter(|entry| room && entry.is_drawn());
        let Some(newest) = newest else {
            if self.raise_barrier_if_in_flight(now) {
                return expired;
            }
            // Its echo may redraw the rest of the line.
            self.mark_opaque_echo(now);
            return self.withdraw_all(false, now, true) || expired;
        };
        // A glyph whose echo arrived but is still held for its frame is
        // retracted the same way: until the erase, its cell is blank.
        newest.is_retracted = true;
        newest.confirmed_at = None;
        self.entries.push(Entry::new(
            Keystroke::Erase(EraseProgress::AwaitingMoveLeft),
            now,
            false,
        ));
        true
    }

    /// Ctrl-U, Ctrl-W, Option-Backspace: a key that deletes backwards by more
    /// than one character. Glyphs still in flight are drawn blank until the
    /// remote's erase lands instead of flashing back as their echoes arrive.
    pub fn typed_line_erase(&mut self, now: Duration) -> bool {
        if !self.is_active() {
            return false;
        }
        let expired = self.expire(now);
        if self.has_barrier() {
            self.newest_untracked_keystroke = Some(now);
            self.mark_opaque_echo(now);
            return expired;
        }
        let mut changed = false;
        for entry in &mut self.entries {
            if entry.standing == Standing::Speculative
                && entry.is_glyph()
                && !entry.is_retracted
                && !entry.is_masked
            {
                entry.is_masked = true;
                changed = true;
            }
        }
        if self.raise_barrier_if_in_flight(now) {
            return changed || expired;
        }
        self.mark_opaque_echo(now);
        self.withdraw_all(false, now, true) || expired
    }

    /// Input that reached the remote another way (a paste, automation): its
    /// echo moves the cursor by an amount this cannot know.
    pub fn sent_untracked_input(&mut self, now: Duration) -> bool {
        self.typed(None, now)
    }

    // Output

    /// The bytes the remote sent, just before the terminal parses them.
    /// Returns whether the host re-anchors the overlay: any output that moves
    /// the cursor while something is drawn moves every drawn glyph too.
    pub fn observed_output(&mut self, bytes: &[u8], now: Duration) -> bool {
        if !self.is_active() {
            return false;
        }
        let mut changed = self.expire(now);
        let blanks_before = self.blank_count();
        let mut moved_cursor = false;
        let mut rest = bytes;
        while let Some((&byte, after)) = rest.split_first() {
            if self.entries.is_empty() && self.rewound.is_empty() {
                // Nothing in flight: most output lands here (a build log, an
                // agent's stream), and all it can do is end the run or switch
                // screens, so skip past plain text.
                self.skim(rest, now);
                break;
            }
            if let Some(signal) = self.scanner.next(byte) {
                if signal != OutputSignal::Ignorable {
                    moved_cursor = true;
                }
                changed = self.observe(signal, now) || changed;
            }
            rest = after;
        }
        if self.blank_count() < blanks_before && self.layout_held_since.is_none() {
            self.layout_held_since = Some(now);
        }
        changed || (moved_cursor && self.any_on_screen())
    }

    /// Output was lost before reaching the engine: nothing drawn can be placed
    /// any more, and a sequence may have been cut in half.
    pub fn missed_output(&mut self, now: Duration) -> bool {
        if !self.is_active() {
            return false;
        }
        self.scanner = TerminalOutputScanner::new();
        let changed = self.withdraw_all(false, now, false);
        self.mark_opaque_echo(now);
        self.extend_untracked_deadline(now);
        changed
    }

    /// A rendered frame reached the screen. Confirmed glyphs retire here: the
    /// engine sees output before the parser, so retiring at confirmation would
    /// blank the cell for the frames between the echo and its paint.
    pub fn presented_frame(&mut self, now: Duration) -> bool {
        self.expire(now);
        let before = self.entries.len();
        self.entries.retain(|entry| !entry.is_held_confirmation());
        let released = self.layout_held_since.take().is_some();
        self.entries.len() != before || released
    }

    /// Advances time with no other event, withdrawing what aged out.
    pub fn tick(&mut self, now: Duration) -> bool {
        self.expire(now)
    }

    // Internals

    fn blank_count(&self) -> usize {
        self.entries.iter().filter(|entry| entry.is_blanked()).count()
    }

    fn any_on_screen(&self) -> bool {
        self.entries.iter().any(Entry::is_on_screen)
    }

    fn skim(&mut self, bytes: &[u8], now: Duration) {
        let skim = self.scanner.skim(bytes);
        if let Some(entered) = skim.alternate_screen {
            self.is_alternate_screen = entered;
            self.has_observed_alternate_screen_switch = true;
        }
        if !skim.touched_the_screen {
            return;
        }
        self.end_run();
        if self.untracked_echo_deadline.is_some_and(|deadline| now >= deadline) {
            self.close_untracked_window();
        }
    }

    fn observe(&mut self, signal: OutputSignal, now: Duration) -> bool {
        if let Some(deadline) = self.untracked_echo_deadline {
            if now < deadline
                && signal != OutputSignal::Ignorable
                && !matches!(signal, OutputSignal::AlternateScreen(_))
            {
                match self.classify_untracked_output(signal, now) {
                    UntrackedOutput::Older => {
                        // The echo of a keystroke already given up on. The keys
                        // tracked since echo after it, in order, so they stay;
                        // the row it wrote is unknown, so the run starts over.
                        self.end_run();
                        return false;
                    }
                    UntrackedOutput::Ambiguous => {
                        // It could be either; guessing wrong would put every
                        // later glyph one cell off, so everything goes.
                        return self.withdraw_all(false, now, false);
                    }
                    // The first tracked key's echo: everything untracked was
                    // ahead of it in the stream, so it has all arrived.
                    UntrackedOutput::Tracked => self.close_untracked_window(),
                }
            } else if now >= deadline {
                self.close_untracked_window();
            }
        }
        match signal {
            OutputSignal::Ignorable => false,
            OutputSignal::AlternateScreen(entered) => {
                self.is_alternate_screen = entered;
                self.has_observed_alternate_screen_switch = true;
                self.withdraw_all(false, now, false)
            }
            // The remote's answer to Return, an arrow or a paste: the
            // unmodelled key did what it does, not a wrong guess.
            OutputSignal::Disruptive if self.is_awaiting_barrier() => self.resolve_barrier(now),
            // The remote moved the cursor somewhere not predicted (a background
            // job's line, a prompt redraw). The keystrokes in flight still echo
            // in order, so they are hidden rather than dropped. Where an erase
            // was due, that is a shell erasing in a form not modelled here.
            OutputSignal::Disruptive => {
                let counting = !self.is_awaiting_erase();
                self.hide_all(counting, now)
            }
            OutputSignal::Printable(byte) => self.consume_printable(byte, now),
            OutputSignal::CursorLeft
                if !self.is_awaiting_erase() && !self.is_awaiting_barrier() =>
            {
                self.rewind(1, now)
            }
            OutputSignal::CursorLeftBy(count) => {
                if self.is_awaiting_barrier() {
                    return self.resolve_barrier(now);
                }
                if self.is_awaiting_erase() {
                    return self.withdraw_all(false, now, false);
                }
                self.rewind(count, now)
            }
            // Cleared what it moved back over; a rewrite puts it back.
            OutputSignal::ClearAtCursor
                if !self.rewound.is_empty() && !self.is_awaiting_erase() =>
            {
                false
            }
            OutputSignal::CursorLeft | OutputSignal::ClearAtCursor => {
                self.consume_erase(signal, now)
            }
        }
    }

    /// The remote moved the cursor back over text it echoed, most likely to
    /// print it again.
    fn rewind(&mut self, count: usize, now: Duration) -> bool {
        if count > self.line.len() {
            // Further back than anything seen echoed: a redraw.
            return self.withdraw_all(false, now, false);
        }
        let start = self.line.len() - count;
        let moved: Vec<u8> = self.line.drain(start..).collect();
        self.rewound.splice(0..0, moved);
        self.any_on_screen()
    }

    /// The first entry still waiting for its echo, with its index.
    fn first_speculative_entry(&self) -> Option<(usize, Entry)> {
        self.entries
            .iter()
            .copied()
            .enumerate()
            .find(|(_, entry)| entry.standing == Standing::Speculative)
    }

    /// Marks entry `index` echoed; `at` is when, for a glyph held until its frame.
    fn confirm(&mut self, index: usize, at: Option<Duration>) {
        if let Some(entry) = self.entries.get_mut(index) {
            entry.standing = Standing::Confirmed;
            if at.is_some() {
                entry.confirmed_at = at;
            }
        }
    }

    fn consume_printable(&mut self, byte: u8, now: Duration) -> bool {
        if let Some(&rewritten) = self.rewound.first() {
            if rewritten != byte {
                // Not a rewrite of what it moved back over: a redraw.
                return self.withdraw_all(false, now, false);
            }
            self.rewound.remove(0);
            self.remember(byte);
            return self.any_on_screen();
        }
        let Some((index, entry)) = self.first_speculative_entry() else {
            // Output at the cursor nobody typed: it advances the cursor the
            // offsets are measured from, and it ends the echo run.
            return self.withdraw_all(false, now, false);
        };
        if now < entry.typed_at {
            // Output stamped before the keystroke existed was already in flight
            // when it was typed, so it cannot be its echo.
            return self.withdraw_all(false, now, false);
        }
        let expected = match entry.keystroke {
            Keystroke::Barrier => return self.resolve_barrier(now),
            // Mid-erase, the only printable a line editor sends is the space of
            // `BS SP BS`; the erase withdraws on anything else.
            Keystroke::Erase(_) => {
                return self.advance_erase(index, OutputSignal::Printable(byte), now);
            }
            Keystroke::Glyph(expected) => expected,
        };
        if expected != byte {
            return self.withdraw_all(true, now, false);
        }
        self.record_echo_latency(now.saturating_sub(entry.typed_at));
        self.remember(byte);
        if entry.is_masked {
            // Its blank now covers the echo it waited for, and stays until the
            // erase after it. It re-arms nothing: the user deleted it.
            self.confirm(index, None);
            return true;
        }
        // A `*` is what a masked password prompt echoes for any key, so it
        // proves nothing about echo.
        if byte != b'*' {
            self.echo_streak = self.echo_streak.saturating_add(1);
        }
        if entry.is_hidden {
            self.entries.remove(index);
            return false;
        }
        if entry.is_retracted {
            // Its blank covers the echo until the erase arrives. Nothing is
            // held, but the cursor moved, so drawn cells are measured afresh.
            self.confirm(index, None);
            return self.any_on_screen();
        }
        // A glyph the user never saw has nothing to hold on screen for. It still
        // counts toward the cursor for any held glyph before it, so it goes when
        // they do.
        if !entry.is_displayed {
            if self.entries.iter().take(index).any(Entry::is_drawn) {
                self.confirm(index, Some(now));
            } else {
                self.entries.remove(index);
            }
            return false;
        }
        self.confirm(index, Some(now));
        true
    }

    /// A cursor-left or clear from the remote, which only a pending erase
    /// expects. Anywhere else it moved the screen in a way not predicted.
    fn consume_erase(&mut self, signal: OutputSignal, now: Duration) -> bool {
        let Some((index, entry)) = self.first_speculative_entry() else {
            return self.withdraw_all(true, now, false);
        };
        if now < entry.typed_at {
            return self.withdraw_all(false, now, false);
        }
        match entry.keystroke {
            Keystroke::Barrier => self.resolve_barrier(now),
            Keystroke::Erase(_) => self.advance_erase(index, signal, now),
            Keystroke::Glyph(_) => self.withdraw_all(true, now, false),
        }
    }

    /// Whether the next echo expected is (the rest of) an erase.
    fn is_awaiting_erase(&self) -> bool {
        self.first_speculative_entry()
            .is_some_and(|(_, entry)| matches!(entry.keystroke, Keystroke::Erase(_)))
    }

    /// Advances the erase at `index`, the next echo expected. A mismatch
    /// withdraws without counting toward suspension: line editors erase in more
    /// forms than modelled here, and a shell that always uses one of those is
    /// not mispredicting.
    fn advance_erase(&mut self, index: usize, signal: OutputSignal, now: Duration) -> bool {
        let Some(Keystroke::Erase(progress)) = self.entries.get(index).map(|entry| entry.keystroke)
        else {
            return self.withdraw_all(false, now, false);
        };
        let next = match (progress, signal) {
            (EraseProgress::AwaitingMoveLeft, OutputSignal::CursorLeft) => {
                self.line.pop();
                EraseProgress::MovedLeft
            }
            (EraseProgress::MovedLeft, OutputSignal::Printable(0x20)) => EraseProgress::Blanked,
            (EraseProgress::MovedLeft, OutputSignal::ClearAtCursor)
            | (EraseProgress::Blanked, OutputSignal::CursorLeft) => {
                // Erased. Every inner retraction completed before this one, so
                // the entry just before it is the glyph it took back, and the
                // pair occupies no cells; the blank goes with it.
                let Some(glyph) = index.checked_sub(1) else {
                    return self.withdraw_all(false, now, false);
                };
                if !self.entries.get(glyph).is_some_and(|entry| entry.is_retracted) {
                    return self.withdraw_all(false, now, false);
                }
                self.entries.drain(glyph..=index);
                return true;
            }
            _ => return self.withdraw_all(false, now, false),
        };
        if let Some(entry) = self.entries.get_mut(index) {
            entry.keystroke = Keystroke::Erase(next);
        }
        self.any_on_screen()
    }

    fn record_echo_latency(&mut self, sample: Duration) {
        self.smoothed_echo_latency = Some(match self.smoothed_echo_latency {
            None => sample,
            Some(current) => (current * 7 + sample) / 8,
        });
    }

    /// Drops everything. `sending_keystroke`: the withdrawal is for a key sent
    /// now, whose echo is as untracked as those of the entries dropped.
    fn withdraw_all(
        &mut self,
        counting_misprediction: bool,
        now: Duration,
        sending_keystroke: bool,
    ) -> bool {
        let was_visible = self.entries.iter().any(Entry::is_drawn);
        let was_on_screen = self.any_on_screen();
        if counting_misprediction && was_visible {
            self.count_misprediction(now);
        }
        // Keystrokes in flight echo anyway, in a form no longer tracked. Each
        // echo arrives within about a round trip of its key, so output keeps
        // clearing the queue until that passed for the newest of them.
        let newest_untracked = if sending_keystroke {
            Some(now)
        } else {
            self.entries
                .iter()
                .filter(|entry| entry.standing == Standing::Speculative)
                .map(|e| e.typed_at)
                .max()
        };
        for entry in &self.entries {
            if entry.standing != Standing::Speculative {
                continue;
            }
            match entry.keystroke {
                Keystroke::Glyph(byte) => {
                    self.untracked_bytes.push((byte, entry.typed_at));
                }
                // An erase may redraw the rest of the line, and an unmodelled
                // key may print anything.
                Keystroke::Barrier | Keystroke::Erase(_) => {
                    let until = now + self.untracked_echo_settle();
                    self.opaque_echo_until =
                        Some(self.opaque_echo_until.map_or(until, |known| known.max(until)));
                }
            }
        }
        if let Some(newest) = newest_untracked {
            self.newest_untracked_keystroke =
                Some(self.newest_untracked_keystroke.map_or(newest, |known| known.max(newest)));
            let deadline = newest + self.untracked_echo_settle();
            self.untracked_echo_deadline =
                Some(self.untracked_echo_deadline.map_or(deadline, |d| d.max(deadline)));
        }
        self.entries.clear();
        self.end_run();
        was_on_screen
    }

    /// Output nobody predicted: whatever the row holds now is unknown.
    fn end_run(&mut self) {
        self.echo_streak = 0;
        self.line.clear();
        self.rewound.clear();
    }

    fn remember(&mut self, byte: u8) {
        if self.line.len() >= MAXIMUM_LINE_MEMORY {
            let half = self.line.len() / 2;
            self.line.drain(..half);
        }
        self.line.push(byte);
    }

    /// Takes everything off the overlay but keeps matching it: the keystrokes
    /// were sent and still echo, in order. Only a mismatch drops them.
    fn hide_all(&mut self, counting_misprediction: bool, now: Duration) -> bool {
        let was_visible = self.entries.iter().any(Entry::is_drawn);
        let was_on_screen = self.any_on_screen();
        if counting_misprediction && was_visible {
            self.count_misprediction(now);
        }
        self.entries.retain(|entry| !entry.is_held_confirmation());
        for entry in &mut self.entries {
            entry.is_hidden = true;
        }
        self.end_run();
        was_on_screen
    }

    fn count_misprediction(&mut self, now: Duration) {
        self.recent_mispredictions.push(now);
        let window = self.configuration.misprediction_window;
        self.recent_mispredictions.retain(|&at| now.saturating_sub(at) <= window);
        if self.recent_mispredictions.len() >= self.configuration.mispredictions_before_suspending {
            self.suspended_until = Some(now + self.configuration.suspension);
            self.recent_mispredictions.clear();
        }
    }

    fn has_barrier(&self) -> bool {
        self.entries.iter().any(|entry| entry.keystroke == Keystroke::Barrier)
    }

    /// Whether the next output answers a barrier rather than a prediction.
    fn is_awaiting_barrier(&self) -> bool {
        self.first_speculative_entry()
            .is_some_and(|(_, entry)| entry.keystroke == Keystroke::Barrier)
    }

    /// Puts a barrier behind the glyphs in flight, when the user can see any,
    /// so they stay drawn until their own echoes confirm them. Returns whether
    /// it did; without one the caller withdraws.
    fn raise_barrier_if_in_flight(&mut self, now: Duration) -> bool {
        let in_flight = self.entries.iter().any(|entry| {
            (entry.is_drawn() && entry.standing == Standing::Speculative) || entry.is_blanked()
        });
        if !in_flight {
            return false;
        }
        self.entries.push(Entry::new(Keystroke::Barrier, now, false));
        self.echo_streak = 0;
        true
    }

    /// Output arrived for the unmodelled key behind the barrier: its effect is
    /// unknown, so everything goes, and output stays untracked for a settle
    /// period covering the keys typed behind it.
    fn resolve_barrier(&mut self, now: Duration) -> bool {
        let changed = self.withdraw_all(false, now, false);
        self.mark_opaque_echo(now);
        self.extend_untracked_deadline(now);
        changed
    }

    fn extend_untracked_deadline(&mut self, now: Duration) {
        let deadline = now + self.untracked_echo_settle();
        self.untracked_echo_deadline =
            Some(self.untracked_echo_deadline.map_or(deadline, |d| d.max(deadline)));
    }

    /// How long a keystroke may go unechoed before what was drawn for it is
    /// taken down: the configured floor, or three round trips on a slower link.
    fn speculative_lifetime(&self) -> Duration {
        match self.smoothed_echo_latency {
            None => self.configuration.speculative_lifetime,
            Some(latency) => self.configuration.speculative_lifetime.max(latency * 3),
        }
    }

    /// Whose output this is, inside the untracked window. The oldest key
    /// tracked since echoes the character it expects, no sooner than half a
    /// measured round trip after it was sent; an older key's echo comes first
    /// and was sent at least that much earlier. Output that fits both is
    /// ambiguous when an untracked key had the same byte, or one whose effect
    /// is unknown may still be printing.
    fn classify_untracked_output(&self, signal: OutputSignal, now: Duration) -> UntrackedOutput {
        let OutputSignal::Printable(byte) = signal else {
            return UntrackedOutput::Older;
        };
        let Some((_, entry)) = self.first_speculative_entry() else {
            return UntrackedOutput::Older;
        };
        let earliest = entry.typed_at
            + self.smoothed_echo_latency.map_or(Duration::ZERO, |latency| latency / 2);
        if entry.keystroke != Keystroke::Glyph(byte) || now < earliest {
            return UntrackedOutput::Older;
        }
        let opaque = self.opaque_echo_until.is_some_and(|until| now < until);
        let settle = self.untracked_echo_settle();
        let same_byte_in_flight = self
            .untracked_bytes
            .iter()
            .any(|&(untracked, sent_at)| untracked == byte && now < sent_at + settle);
        if opaque || same_byte_in_flight {
            return UntrackedOutput::Ambiguous;
        }
        UntrackedOutput::Tracked
    }

    /// Keeps at most the last 64 untracked keys: each is dropped once its echo
    /// can no longer be on its way.
    fn note_untracked_byte(&mut self, byte: u8, now: Duration) {
        let settle = self.untracked_echo_settle();
        self.untracked_bytes.retain(|&(_, sent_at)| now < sent_at + settle);
        if self.untracked_bytes.len() >= 64 {
            self.untracked_bytes.remove(0);
        }
        self.untracked_bytes.push((byte, now));
    }

    /// A key whose effect is not modelled was sent or answered now.
    fn mark_opaque_echo(&mut self, now: Duration) {
        let until = now + self.untracked_echo_settle();
        self.opaque_echo_until =
            Some(self.opaque_echo_until.map_or(until, |known| known.max(until)));
    }

    fn close_untracked_window(&mut self) {
        self.untracked_echo_deadline = None;
        self.untracked_bytes.clear();
        self.opaque_echo_until = None;
    }

    /// How soon after an untracked key another one may reach the remote in the
    /// same read, so that a line editor answers both as one change.
    fn coalescing_gap(&self) -> Duration {
        let jitter = self.smoothed_echo_latency.map_or(Duration::ZERO, |latency| latency / 8);
        Duration::from_millis(60) + jitter
    }

    /// How long after a withdrawal output may still belong to keystrokes the
    /// engine dropped: twice the round trip, plus jitter.
    fn untracked_echo_settle(&self) -> Duration {
        match self.smoothed_echo_latency {
            None => Duration::from_millis(500),
            Some(latency) => latency * 2 + Duration::from_millis(50),
        }
    }

    fn expire(&mut self, now: Duration) -> bool {
        if self.suspended_until.is_some_and(|until| now >= until) {
            self.suspended_until = None;
        }
        let hold = self.configuration.confirmation_hold;
        let is_stale =
            |entry: &Entry| entry.confirmed_at.is_some_and(|at| now.saturating_sub(at) > hold);
        let mut stale_confirmation = self.entries.iter().any(is_stale);
        if self.layout_held_since.is_some_and(|since| now.saturating_sub(since) > hold) {
            // No frame came to release the layout: re-anchor now.
            self.layout_held_since = None;
            stale_confirmation = true;
        }
        if stale_confirmation {
            // The host stopped reporting frames: drop the hold rather than
            // leave a glyph pinned over a cell the grid already owns.
            self.entries.retain(|entry| !is_stale(entry));
        }
        // Erases and retracted glyphs expire too: an echo that never comes
        // leaves every later offset measured from the wrong cell.
        let lifetime = self.speculative_lifetime();
        let expired: Vec<Entry> = self
            .entries
            .iter()
            .filter(|entry| {
                entry.standing == Standing::Speculative
                    && now.saturating_sub(entry.typed_at) > lifetime
            })
            .copied()
            .collect();
        if expired.is_empty() {
            return stale_confirmation;
        }
        // A key with no visible effect (an arrow at the end of the line) can
        // leave only its barrier unanswered, which guessed nothing.
        if expired.iter().any(|entry| entry.keystroke == Keystroke::Barrier)
            || expired.iter().any(|entry| now.saturating_sub(entry.typed_at) > lifetime * 4)
        {
            // Or long past any stall: the key was swallowed, not delayed.
            return self.withdraw_all(false, now, false) || stale_confirmation;
        }
        // Nothing came back in time. What was drawn goes, but the link may only
        // have stalled: keep matching the echoes in order, so they re-arm the
        // run when they land instead of leaving it dark.
        if !self.any_on_screen() {
            return stale_confirmation;
        }
        self.hide_all(true, now) || stale_confirmation
    }
}
