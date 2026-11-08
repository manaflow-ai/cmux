//! What remote output does to the keystrokes in flight, and the bookkeeping
//! (withdrawal, hiding, suspension, expiry) behind it.

use super::entry::{Entry, EraseProgress, Keystroke};
use super::{MAXIMUM_LINE_MEMORY, TerminalPredictionEngine};
use crate::config::PredictionInstant;
use crate::glyph::Standing;
use crate::scanner::{TerminalOutputScanner, TerminalOutputSignal};
use std::time::Duration;

impl TerminalPredictionEngine {
    /// Feed the bytes the remote sent, from the PTY output tee. Returns
    /// whether the host has to re-anchor the overlay.
    ///
    /// That is not only when the drawn set changed. Every offset is measured
    /// from the live cursor, so any output that moves it while something is
    /// drawn moves every drawn glyph too, even an echo nobody saw typed. The
    /// host may also have re-anchored on a frame ghostty rendered after
    /// parsing this output but before this drain, measuring the old offsets
    /// from the new cursor; only a redraw now puts them back.
    pub fn observed_output(&mut self, bytes: &[u8], now: PredictionInstant) -> bool {
        if !self.is_active() {
            return false;
        }
        let mut changed = self.expire(now);
        let blanks_before = self.blank_count();
        let mut moved_cursor = false;
        let mut index = 0;
        while index < bytes.len() {
            if self.entries.is_empty() && self.rewound.is_empty() {
                // Nothing in flight: most output lands here (a build log, an
                // agent's stream), and all it can do is end the run or switch
                // screens, so skip past plain text instead of classifying it
                // byte by byte.
                self.skim(&bytes[index..], now);
                break;
            }
            if let Some(signal) = self.scanner.next(bytes[index]) {
                if signal != TerminalOutputSignal::Ignorable {
                    moved_cursor = true;
                }
                changed = self.observe(signal, now) || changed;
            }
            index += 1;
        }
        if self.blank_count() < blanks_before && self.layout_held_since.is_none() {
            self.layout_held_since = Some(now);
        }
        changed || (moved_cursor && self.any_on_screen())
    }

    /// Report that output was lost before reaching the engine (the host's
    /// buffer overflowed). Nothing drawn can be placed any more, and a
    /// sequence may have been cut in half, so everything starts over.
    pub fn missed_output(&mut self, now: PredictionInstant) -> bool {
        if !self.is_active() {
            return false;
        }
        self.scanner = TerminalOutputScanner::new();
        let changed = self.withdraw_all(false, now, false);
        self.extend_untracked_deadline(now + self.untracked_echo_settle());
        changed
    }

    fn blank_count(&self) -> usize {
        self.entries.iter().filter(|e| e.is_blanked()).count()
    }

    pub(super) fn any_on_screen(&self) -> bool {
        self.entries.iter().any(Entry::is_on_screen)
    }

    fn extend_untracked_deadline(&mut self, deadline: PredictionInstant) {
        self.untracked_echo_deadline = Some(self.untracked_echo_deadline.map_or(deadline, |d| d.max(deadline)));
    }

    fn skim(&mut self, bytes: &[u8], now: PredictionInstant) {
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
            self.untracked_echo_deadline = None;
        }
    }

    fn observe(&mut self, signal: TerminalOutputSignal, now: PredictionInstant) -> bool {
        use TerminalOutputSignal as S;
        if let Some(deadline) = self.untracked_echo_deadline {
            if now < deadline && signal != S::Ignorable && !matches!(signal, S::AlternateScreen(_)) {
                // Possibly the echo of a keystroke already given up on. Drop
                // what was typed since as well: its echo is behind output
                // this cannot account for.
                return self.withdraw_all(false, now, false);
            }
            if now >= deadline {
                self.untracked_echo_deadline = None;
            }
        }
        match signal {
            S::Ignorable => false,

            S::AlternateScreen(entered) => {
                self.is_alternate_screen = entered;
                self.has_observed_alternate_screen_switch = true;
                self.withdraw_all(false, now, false)
            }

            // The remote's answer to Return, an arrow or a paste: the
            // unmodelled key did what it does, not a wrong guess.
            S::Disruptive if self.is_awaiting_barrier() => self.resolve_barrier(now),

            // The remote moved the cursor somewhere we did not predict (a
            // background job's line, a prompt redraw). The keystrokes in
            // flight still echo in order, wherever the cursor now is, so they
            // are hidden rather than dropped and keep being matched. Where an
            // erase was due, that is a shell erasing in a form not modelled
            // here, not a wrong guess.
            S::Disruptive => {
                let counting = !self.is_awaiting_erase();
                self.hide_all(counting, now)
            }

            S::Printable(byte) => self.consume_printable(byte, now),

            S::CursorLeft if !self.is_awaiting_erase() && !self.is_awaiting_barrier() => self.rewind(1, now),

            S::CursorLeftBy(count) => {
                if self.is_awaiting_barrier() {
                    return self.resolve_barrier(now);
                }
                if self.is_awaiting_erase() {
                    return self.withdraw_all(false, now, false);
                }
                self.rewind(count, now)
            }

            // Cleared what it moved back over; a rewrite puts it back.
            S::ClearAtCursor if !self.rewound.is_empty() && !self.is_awaiting_erase() => false,

            S::CursorLeft | S::ClearAtCursor => self.consume_erase(signal, now),
        }
    }

    /// The remote moved the cursor back over text it echoed, most likely to
    /// print it again.
    fn rewind(&mut self, count: usize, now: PredictionInstant) -> bool {
        if count > self.line.len() {
            // Further back than anything seen echoed: a redraw.
            return self.withdraw_all(false, now, false);
        }
        let start = self.line.len() - count;
        let moved: Vec<u8> = self.line.drain(start..).collect();
        self.rewound.splice(0..0, moved);
        self.any_on_screen()
    }

    fn consume_printable(&mut self, byte: u8, now: PredictionInstant) -> bool {
        if let Some(&rewritten) = self.rewound.first() {
            if rewritten != byte {
                // Not a rewrite of what it moved back over: a redraw.
                return self.withdraw_all(false, now, false);
            }
            self.rewound.remove(0);
            self.remember(byte);
            return self.any_on_screen();
        }
        let Some(index) = self.entries.iter().position(Entry::is_speculative) else {
            // Output at the cursor that we did not type. It advances the
            // cursor our offsets are measured from, and it ends the echo run.
            return self.withdraw_all(false, now, false);
        };
        if now < self.entries[index].typed_at {
            // Output stamped before the keystroke existed was already in
            // flight when it was typed (arrivals drain later on the main
            // thread), so it cannot be the echo of it.
            return self.withdraw_all(false, now, false);
        }
        let expected = match self.entries[index].keystroke {
            Keystroke::Barrier => return self.resolve_barrier(now),
            // Mid-erase, the only printable a line editor sends is the space
            // of `BS SP BS`; the erase withdraws on anything else.
            Keystroke::Erase(_) => return self.advance_erase(index, TerminalOutputSignal::Printable(byte), now),
            Keystroke::Glyph(expected) => expected,
        };
        if expected != byte {
            return self.withdraw_all(true, now, false);
        }

        let sample = now - self.entries[index].typed_at;
        self.record_echo_latency(sample);
        self.remember(byte);
        let entry = &mut self.entries[index];
        if entry.is_masked {
            // Its blank now covers the echo it was waiting for, and stays
            // until the erase after it. It re-arms nothing: the user deleted it.
            entry.standing = Standing::Confirmed;
            return true;
        }
        // A `*` is what a masked password prompt echoes for any key, so it
        // proves nothing about echo.
        if byte != b'*' {
            self.echo_streak += 1;
        }
        let entry = &mut self.entries[index];
        if entry.is_hidden {
            self.entries.remove(index);
            return false;
        }
        if entry.is_retracted {
            // Its blank covers the echo until the erase arrives. Nothing is
            // held, but the cursor moved, so drawn cells are measured afresh.
            entry.standing = Standing::Confirmed;
            return self.any_on_screen();
        }
        // A glyph the user never saw has nothing to hold on screen for; the
        // real character is already on its way into the grid. It still counts
        // toward the cursor for any held glyph before it, so it goes when
        // they do.
        let is_displayed = entry.is_displayed;
        if !is_displayed && !self.entries[..index].iter().any(Entry::is_drawn) {
            self.entries.remove(index);
            return false;
        }
        let entry = &mut self.entries[index];
        entry.standing = Standing::Confirmed;
        entry.confirmed_at = Some(now);
        is_displayed
    }

    /// A cursor-left or clear from the remote, which only a pending erase
    /// expects. Anywhere else it moved the screen in a way we did not predict.
    fn consume_erase(&mut self, signal: TerminalOutputSignal, now: PredictionInstant) -> bool {
        let Some(index) = self.entries.iter().position(Entry::is_speculative) else {
            return self.withdraw_all(true, now, false);
        };
        if now < self.entries[index].typed_at {
            // Already in flight when the key was typed, as in
            // `consume_printable`: not its echo, and not a wrong guess.
            return self.withdraw_all(false, now, false);
        }
        match self.entries[index].keystroke {
            Keystroke::Barrier => self.resolve_barrier(now),
            Keystroke::Erase(_) => self.advance_erase(index, signal, now),
            Keystroke::Glyph(_) => self.withdraw_all(true, now, false),
        }
    }

    /// Whether the next echo expected is (the rest of) an erase.
    pub(super) fn is_awaiting_erase(&self) -> bool {
        self.entries.iter().find(|e| e.is_speculative()).is_some_and(Entry::is_erase)
    }

    /// Advances the erase at `index`, the next echo expected.
    ///
    /// A mismatch withdraws without counting toward suspension. Line editors
    /// erase in more forms than the ones modelled here (a full repaint after a
    /// carriage return, zsh redrawing an autosuggestion), and a shell that
    /// always uses one of those is not mispredicting; counting it would
    /// suspend prediction after a few corrections.
    fn advance_erase(&mut self, index: usize, signal: TerminalOutputSignal, now: PredictionInstant) -> bool {
        use TerminalOutputSignal as S;
        let Keystroke::Erase(progress) = self.entries[index].keystroke else {
            return self.withdraw_all(false, now, false);
        };
        match (progress, signal) {
            (EraseProgress::AwaitingMoveLeft, S::CursorLeft) => {
                self.entries[index].keystroke = Keystroke::Erase(EraseProgress::MovedLeft);
                self.line.pop();
            }
            (EraseProgress::MovedLeft, S::Printable(0x20)) => {
                self.entries[index].keystroke = Keystroke::Erase(EraseProgress::Blanked);
            }
            (EraseProgress::MovedLeft, S::ClearAtCursor) | (EraseProgress::Blanked, S::CursorLeft) => {
                // Erased. Every inner retraction completed before this one, so
                // the entry just before it is the glyph it took back, and the
                // pair together occupies no cells.
                if index == 0 || !self.entries[index - 1].is_retracted {
                    return self.withdraw_all(false, now, false);
                }
                self.entries.drain(index - 1..=index);
                // The blank that covered the erased cell goes with the pair.
                return true;
            }
            _ => return self.withdraw_all(false, now, false),
        }
        self.any_on_screen()
    }

    fn record_echo_latency(&mut self, sample: Duration) {
        self.smoothed_echo_latency = Some(match self.smoothed_echo_latency {
            None => sample,
            Some(current) => (current * 7 + sample) / 8,
        });
    }

    /// Takes everything off the overlay and stops tracking it.
    ///
    /// `sending_keystroke`: the withdrawal is for a key being sent now, whose
    /// echo is as untracked as those of the entries dropped.
    pub(super) fn withdraw_all(
        &mut self,
        counting_misprediction: bool,
        now: PredictionInstant,
        sending_keystroke: bool,
    ) -> bool {
        let was_visible = self.entries.iter().any(Entry::is_drawn);
        let was_on_screen = self.any_on_screen();
        if counting_misprediction && was_visible {
            self.count_misprediction(now);
        }
        // Keystrokes still in flight echo anyway, in a form this no longer
        // tracks. Each echo arrives within about a round trip of its key, so
        // output keeps clearing the queue until that has passed for the
        // newest of them.
        let newest_untracked = if sending_keystroke {
            Some(now)
        } else {
            self.entries.iter().filter(|e| e.is_speculative()).map(|e| e.typed_at).max()
        };
        if let Some(newest) = newest_untracked {
            self.extend_untracked_deadline(newest + self.untracked_echo_settle());
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
    fn hide_all(&mut self, counting_misprediction: bool, now: PredictionInstant) -> bool {
        let was_visible = self.entries.iter().any(Entry::is_drawn);
        let was_on_screen = self.any_on_screen();
        if counting_misprediction && was_visible {
            self.count_misprediction(now);
        }
        self.entries.retain(|e| !e.is_held_confirmation());
        for entry in &mut self.entries {
            entry.is_hidden = true;
        }
        self.end_run();
        was_on_screen
    }

    fn count_misprediction(&mut self, now: PredictionInstant) {
        self.recent_mispredictions.push(now);
        let window = self.configuration.misprediction_window;
        self.recent_mispredictions.retain(|&at| now.saturating_sub(at) <= window);
        if self.recent_mispredictions.len() >= self.configuration.mispredictions_before_suspending {
            self.suspended_until = Some(now + self.configuration.suspension);
            self.recent_mispredictions.clear();
        }
    }

    pub(super) fn has_barrier(&self) -> bool {
        self.entries.iter().any(|e| e.keystroke == Keystroke::Barrier)
    }

    /// Whether the next output answers a barrier rather than a prediction.
    fn is_awaiting_barrier(&self) -> bool {
        self.entries.iter().find(|e| e.is_speculative()).is_some_and(|e| e.keystroke == Keystroke::Barrier)
    }

    /// Puts a barrier behind the glyphs in flight, when there are any the user
    /// can see, so they stay drawn until their own echoes confirm them.
    /// Returns whether it did; without one the caller withdraws as before.
    pub(super) fn raise_barrier_if_in_flight(&mut self, now: PredictionInstant) -> bool {
        let in_flight = self.entries.iter().any(|e| (e.is_drawn() && e.is_speculative()) || e.is_blanked());
        if !in_flight {
            return false;
        }
        self.entries.push(Entry::new(Keystroke::Barrier, now, false));
        self.echo_streak = 0;
        true
    }

    /// Output arrived for the unmodelled key behind the barrier: its effect is
    /// unknown, so everything goes, and output stays untracked for a settle
    /// period covering the keys typed behind the barrier.
    fn resolve_barrier(&mut self, now: PredictionInstant) -> bool {
        let changed = self.withdraw_all(false, now, false);
        self.extend_untracked_deadline(now + self.untracked_echo_settle());
        changed
    }

    /// How long a keystroke may go unechoed before what was drawn for it is
    /// taken down: the configured floor, or three round trips on a link slower
    /// than that allows for.
    pub(super) fn speculative_lifetime(&self) -> Duration {
        let floor = self.configuration.speculative_lifetime;
        self.smoothed_echo_latency.map_or(floor, |latency| floor.max(latency * 3))
    }

    /// How long after a withdrawal output may still belong to keystrokes the
    /// engine dropped. Twice the round trip absorbs jitter and a remote that
    /// reads in bursts; with no measurement yet, nothing is drawn anyway, so a
    /// generous default only delays arming.
    pub(super) fn untracked_echo_settle(&self) -> Duration {
        self.smoothed_echo_latency
            .map_or(Duration::from_millis(500), |latency| latency * 2 + Duration::from_millis(50))
    }

    pub(super) fn expire(&mut self, now: PredictionInstant) -> bool {
        if self.suspended_until.is_some_and(|until| now >= until) {
            self.suspended_until = None;
        }

        let hold = self.configuration.confirmation_hold;
        let is_stale = |entry: &Entry| entry.confirmed_at.is_some_and(|at| now.saturating_sub(at) > hold);
        let mut stale_confirmation = self.entries.iter().any(is_stale);
        if self.layout_held_since.is_some_and(|since| now.saturating_sub(since) > hold) {
            // No frame came to release the layout: re-anchor now.
            self.layout_held_since = None;
            stale_confirmation = true;
        }
        if stale_confirmation {
            // The host stopped reporting frames. Drop the hold rather than
            // leave a glyph pinned over a cell the grid already owns.
            self.entries.retain(|entry| !is_stale(entry));
        }

        // Erases and retracted glyphs expire too: an echo that never comes
        // leaves every later offset measured from the wrong cell.
        let lifetime = self.speculative_lifetime();
        let mut any_expired = false;
        let mut barrier_expired = false;
        let mut long_expired = false;
        for entry in self.entries.iter().filter(|e| e.is_speculative()) {
            let age = now.saturating_sub(entry.typed_at);
            if age > lifetime {
                any_expired = true;
                barrier_expired |= entry.keystroke == Keystroke::Barrier;
                long_expired |= age > lifetime * 4;
            }
        }
        if !any_expired {
            return stale_confirmation;
        }
        // A key with no visible effect (an arrow at the end of the line) can
        // leave only its barrier unanswered, which guessed nothing.
        if barrier_expired {
            return self.withdraw_all(false, now, false) || stale_confirmation;
        }
        if long_expired {
            // Long past any stall: the key was swallowed, not delayed.
            return self.withdraw_all(false, now, false) || stale_confirmation;
        }
        // Nothing came back in time. Whatever was drawn goes, but the link may
        // only have stalled: keep matching the echoes in order, so they re-arm
        // the run when they land instead of leaving it dark.
        if !self.any_on_screen() {
            return stale_confirmation;
        }
        self.hide_all(true, now) || stale_confirmation
    }
}
