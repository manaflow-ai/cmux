//! The tracker pass of [`Terminal::vt_write_with_normalized`] and its
//! byte-at-a-time reference, kept apart from `terminal.rs`.

use std::borrow::Cow;

use super::{Terminal, byte_scan, sys};

impl Terminal {
    /// Everything [`Self::vt_write_with_normalized`] does to `data` before
    /// the parse: C1 normalization, the empty Kitty probe filter and the
    /// tracker pass. Returns the bytes to parse and whether mouse modes may
    /// have changed.
    ///
    /// One scan covers the frame's leading neutral run (see
    /// `byte_scan::neutral_run_end`) for all three steps. With no code point
    /// in progress and every tracker idle, that run is ASCII, complete valid
    /// UTF-8 and inert CSIs: the normalizer copies it unchanged and ends it
    /// with no code point in progress, no empty probe (`ESC _ G ESC \`) can
    /// start in it, and the trackers only clear the boundary tracker's
    /// pending bytes. The three steps then run on the rest alone, as before.
    ///
    /// A frame that starts inside a sequence the previous frame cut off (a
    /// CSI's parameters, a code point's continuation bytes) first finishes
    /// it in [`Self::finish_cut_sequence`], then takes the same leading-run
    /// scan from there.
    pub(super) fn prepare_write<'a>(&mut self, data: &'a [u8]) -> (Cow<'a, [u8]>, bool) {
        let (start, mut mouse_modes_may_have_changed) = self.finish_cut_sequence(data);
        let neutral = if self.c1_normalizer.utf8_remaining == 0 && self.trackers_idle() {
            byte_scan::neutral_run_end(data, start, !self.prompt_semantic.waits_for_line_end())
        } else {
            start
        };
        if neutral > start {
            self.vt_boundary.clear_pending();
        }
        let (head, rest) = data.split_at(neutral);
        let rest = self.c1_normalizer.normalize(rest);
        let rest = self.empty_kitty_probe_filter.write(rest);
        mouse_modes_may_have_changed |= self.feed_trackers(&rest);
        let normalized = match rest {
            Cow::Borrowed(_) => Cow::Borrowed(data),
            Cow::Owned(rest) => {
                let mut joined = Vec::with_capacity(head.len() + rest.len());
                joined.extend_from_slice(head);
                joined.extend_from_slice(&rest);
                Cow::Owned(joined)
            }
        };
        (normalized, mouse_modes_may_have_changed)
    }

    /// Steps the normalizer and every tracker one byte at a time from the
    /// start of `data` until both are idle again, and returns how many bytes
    /// it stepped and whether mouse modes may have changed. Stops early, and
    /// leaves the rest to the full steps, at an ESC, at a byte the
    /// normalizer would replace, or after [`Self::CUT_SEQUENCE_LIMIT`] bytes.
    ///
    /// The stepped bytes hold no ESC and none the normalizer replaces, so
    /// the normalizer and the empty probe filter pass them unchanged, no
    /// empty probe overlaps them, and stepping them here equals running all
    /// three steps on them as their own frame. Returns 0 at once when
    /// nothing is in progress.
    fn finish_cut_sequence(&mut self, data: &[u8]) -> (usize, bool) {
        let mut mouse_modes_may_have_changed = false;
        let mut at = 0;
        let limit = data.len().min(Self::CUT_SEQUENCE_LIMIT);
        while at < limit && !(self.c1_normalizer.utf8_remaining == 0 && self.trackers_idle()) {
            let byte = data[at];
            if byte == 0x1b || !self.c1_normalizer.step_if_unchanged(byte) {
                break;
            }
            self.kitty_inflight.step(byte);
            self.vt_boundary.step(byte);
            self.prompt_semantic.step(byte);
            self.cursor_override.step(byte);
            self.palette_override.step(byte);
            self.color_overrides.step(byte);
            mouse_modes_may_have_changed |= self.mouse_mode_change_detector.step(byte);
            at += 1;
        }
        (at, mouse_modes_may_have_changed)
    }

    /// The longest cut sequence [`Self::finish_cut_sequence`] steps: a cut
    /// CSI's parameters or a code point's continuation bytes are a few
    /// bytes, while a cut string (OSC, DCS, APC) can run long and is left
    /// to the full steps.
    const CUT_SEQUENCE_LIMIT: usize = 64;

    /// Feeds the accepted bytes to every tracker in one pass. The trackers
    /// never read one another, so stepping them byte by byte together equals
    /// running them one after another. While all of them are idle, a neutral
    /// run (see `byte_scan::neutral_run_end`) is skipped: it leaves every one
    /// idle and only clears the boundary tracker's pending bytes.
    pub(super) fn feed_trackers(&mut self, data: &[u8]) -> bool {
        let mut mouse_modes_may_have_changed = false;
        let mut at = 0;
        while at < data.len() {
            if self.trackers_idle() {
                let line_ends_neutral = !self.prompt_semantic.waits_for_line_end();
                let end = byte_scan::neutral_run_end(data, at, line_ends_neutral);
                if end > at {
                    self.vt_boundary.clear_pending();
                    at = end;
                    continue;
                }
            }
            let byte = data[at];
            self.kitty_inflight.step(byte);
            self.vt_boundary.step(byte);
            self.prompt_semantic.step(byte);
            self.cursor_override.step(byte);
            self.palette_override.step(byte);
            self.color_overrides.step(byte);
            mouse_modes_may_have_changed |= self.mouse_mode_change_detector.step(byte);
            at += 1;
        }
        mouse_modes_may_have_changed
    }

    fn trackers_idle(&self) -> bool {
        self.kitty_inflight.is_ground()
            && self.vt_boundary.is_safe()
            && self.prompt_semantic.is_ground()
            && self.cursor_override.is_ground()
            && self.palette_override.is_ground()
            && self.color_overrides.is_idle()
            && self.mouse_mode_change_detector.is_idle()
    }

    /// The original byte-at-a-time form of [`Self::vt_write_with_normalized`],
    /// kept so a check can feed the same bytes through both and require
    /// identical results. Not for production use.
    #[doc(hidden)]
    pub fn vt_write_with_normalized_reference<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        if data.is_empty() {
            return Cow::Borrowed(data);
        }
        self.ensure_history_anchor();
        let previous_history_rows = self.scrollback_rows();
        let history_anchor_missing = previous_history_rows > 0 && self.history_anchor.is_null();
        let normalized = self.c1_normalizer.normalize_reference(data);
        let normalized = self.empty_kitty_probe_filter.write_reference(normalized);
        self.kitty_inflight.write_reference(&normalized);
        self.vt_boundary.feed_reference(&normalized);
        self.prompt_semantic.feed_reference(&normalized);
        self.cursor_override.write_reference(&normalized);
        self.palette_override.write_reference(&normalized);
        self.color_overrides.write_reference(&normalized);
        let mouse_modes_may_have_changed =
            self.mouse_mode_change_detector.write_reference(&normalized);
        self.history_markers_before_write();
        unsafe { sys::ghostty_terminal_vt_write(self.raw, normalized.as_ptr(), normalized.len()) };
        self.history_markers_after_write();
        let history_rows = self.scrollback_rows();
        let history_anchor_evicted = !self.history_anchor.is_null()
            && !unsafe { sys::ghostty_tracked_grid_ref_has_value(self.history_anchor) };
        if previous_history_rows != history_rows || history_anchor_missing || history_anchor_evicted
        {
            self.bump_history_epoch();
        }
        if history_rows == 0 || history_anchor_evicted {
            self.reset_history_anchor();
        } else if self.history_anchor.is_null() {
            self.ensure_history_anchor();
        }
        if mouse_modes_may_have_changed {
            self.refresh_mouse_mode_revision();
        }
        normalized
    }
}

#[cfg(test)]
#[path = "fast_write_tests.rs"]
mod tests;
