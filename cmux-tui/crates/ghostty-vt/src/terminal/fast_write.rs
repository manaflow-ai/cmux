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
    pub(super) fn prepare_write<'a>(&mut self, data: &'a [u8]) -> (Cow<'a, [u8]>, bool) {
        let neutral = if self.c1_normalizer.utf8_remaining == 0 && self.trackers_idle() {
            byte_scan::neutral_run_end(data, 0, !self.prompt_semantic.waits_for_line_end())
        } else {
            0
        };
        if neutral > 0 {
            self.vt_boundary.clear_pending();
        }
        let (head, rest) = data.split_at(neutral);
        let rest = self.c1_normalizer.normalize(rest);
        let rest = self.empty_kitty_probe_filter.write(rest);
        let mouse_modes_may_have_changed = self.feed_trackers(&rest);
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
mod tests {
    use super::super::{Callbacks, Terminal};

    /// Pieces every pre-parse step reacts to, plus the neutral bytes the
    /// fused scan skips: SGR and other inert CSIs, modes, OSC 133 marks,
    /// color and palette OSCs, empty and real Kitty APCs, 8-bit C1 forms,
    /// complete, split and invalid UTF-8, line ends and lone controls.
    const PIECES: &[&[u8]] = &[
        b"cargo build",
        b" ",
        b"ok",
        b"\r\n",
        b"\n",
        b"\x0b",
        b"\x0c",
        b"\t",
        b"\x07",
        b"\x1b[31m",
        b"\x1b[38;5;200m",
        b"\x1b[0m",
        b"\x1b[2J",
        b"\x1b[H",
        b"\x1b[3;4H",
        b"\x1b[?1000h",
        b"\x1b[?1000l",
        b"\x1b[?1006h",
        b"\x1b[?1006l",
        b"\x1b[?2004h",
        b"\x1b[s",
        b"\x1b[u",
        b"\x1b[2 q",
        b"\x1b[c",
        b"\x1b[>4;1m",
        b"\x1b[?1049h",
        b"\x1b[?1049l",
        b"\x1b]133;A\x07",
        b"\x1b]133;B\x1b\\",
        b"\x1b]133;C\x07",
        b"\x1b]133;D;0\x07",
        b"\x1b]133;P;k=i\x07",
        b"\x1b]0;title\x07",
        b"\x1b]10;#ff0000\x07",
        b"\x1b]11;rgb:00/00/ff\x1b\\",
        b"\x1b]4;1;rgb:00/ff/00\x1b\\",
        b"\x1b]104\x07",
        b"\x1b]110\x07",
        b"\x1b]112\x07",
        b"\x1b]12;#00ff00\x07",
        b"\x1b]7;file://h/tmp\x07",
        b"\x1b_G\x1b\\",
        b"\x1b_Ga=q,i=1;AAAA\x1b\\",
        b"\x9fG\x9c",
        b"\x9d0;x\x9c",
        b"\x90q\x9c",
        b"\x9b",
        b"\x1bP+q544e\x1b\\",
        "é".as_bytes(),
        "日本語".as_bytes(),
        "🙂".as_bytes(),
        b"\xe6",
        b"\x80",
        b"\xed\xa0\x80",
        b"\xc0\xaf",
        b"\xf4\x90\x80\x80",
        b"\x1b",
        b"\x18",
        b"\x1a",
        b"\x1b[",
        b"\x1b]",
    ];

    fn stream(seed: u64, pieces: usize) -> Vec<u8> {
        let mut state = seed;
        let mut out = Vec::new();
        for _ in 0..pieces {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let index = usize::try_from(state >> 33).unwrap_or(0) % PIECES.len();
            out.extend_from_slice(PIECES[index]);
        }
        out
    }

    fn state(term: &Terminal) -> impl PartialEq + std::fmt::Debug {
        (
            term.vt_stream_is_ground(),
            term.vt_replay_resumes_stream(),
            term.mouse_mode_bits,
            term.color_overrides(),
            term.c1_normalizer.utf8_remaining,
        )
    }

    /// The fused pre-parse scan accepts the same bytes, leaves the same
    /// tracker state and builds the same replay as the byte-at-a-time
    /// reference, for streams cut into frames at every kind of boundary.
    #[test]
    fn the_fused_pre_parse_scan_matches_the_byte_at_a_time_reference() {
        for seed in 0..300u64 {
            let bytes = stream(seed, 400);
            let mut fast = Terminal::new(30, 6, 4096, Callbacks::default()).unwrap();
            let mut reference = Terminal::new(30, 6, 4096, Callbacks::default()).unwrap();
            let mut cut_state = seed ^ 0x9e37_79b9;
            let mut at = 0;
            while at < bytes.len() {
                cut_state =
                    cut_state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let len = 1 + usize::try_from(cut_state >> 33).unwrap_or(0) % 97;
                let frame = &bytes[at..(at + len).min(bytes.len())];
                let accepted = fast.vt_write_with_normalized(frame).into_owned();
                let expected = reference.vt_write_with_normalized_reference(frame).into_owned();
                assert_eq!(accepted, expected, "seed {seed} at {at}");
                assert_eq!(state(&fast), state(&reference), "seed {seed} at {at}");
                at += frame.len();
            }
            assert_eq!(
                fast.vt_replay_bytes().ok(),
                reference.vt_replay_bytes().ok(),
                "seed {seed}"
            );
        }
    }
}
