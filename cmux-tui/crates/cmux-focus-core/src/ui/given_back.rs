//! Keys the daemon gave back from a terminal creation that did not take them
//! (Swift `GivenBackInput`, `terminal-input-unclaimed`). They are held until a
//! terminal of the window they were typed in can take them, never a terminal
//! of another window (Lawrence 2026-10-23: "i type in one window of cmux, but
//! the text appears in another window"). Keys of no known window are dropped.
//! Keys held longer than the limit are dropped, never typed.
//!
//! Keys of a creation the person closed are dropped too, whether already held
//! or given back later: the close moves the focus to a neighbour terminal,
//! which must not get them.

use serde::{Deserialize, Serialize};

/// How long given-back keys wait by default (3 s).
pub const DEFAULT_LIMIT_NS: i64 = 3_000_000_000;
/// How many closed creating terminals are remembered.
pub const CLOSED_LIMIT: usize = 32;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Piece {
    /// The creating terminal the piece came from (None: not named).
    terminal: Option<String>,
    bytes: Vec<u8>,
}

/// The app's holder of given-back keys. A value the app keeps and sends back.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GivenBackInput {
    held: Vec<Piece>,
    /// The creating terminals the person closed, oldest first.
    closed: Vec<String>,
    /// The window the held keys were typed in.
    window: Option<String>,
    since_ns: Option<i64>,
    pub limit_ns: i64,
}

impl Default for GivenBackInput {
    fn default() -> Self {
        Self::new(DEFAULT_LIMIT_NS)
    }
}

impl GivenBackInput {
    pub fn new(limit_ns: i64) -> Self {
        Self { held: Vec::new(), closed: Vec::new(), window: None, since_ns: None, limit_ns }
    }

    /// Whether no keys are held.
    pub fn is_empty(&self) -> bool {
        self.held.is_empty()
    }

    /// Adds `more`, typed in `window` (from creating terminal `terminal`),
    /// then returns everything held for the window's focused terminal when
    /// there is one (`has_target`) and the held keys were typed in `window`.
    pub fn deliver(
        &mut self,
        more: &[u8],
        terminal: Option<&str>,
        window: Option<&str>,
        has_target: bool,
        now_ns: i64,
    ) -> Option<Vec<u8>> {
        if self.since_ns.is_some_and(|since| now_ns.saturating_sub(since) > self.limit_ns) {
            self.drop_held();
        }
        let closed = terminal.is_some_and(|terminal| self.closed.iter().any(|c| c == terminal));
        if let Some(window) = window.filter(|_| !more.is_empty() && !closed) {
            if self.window.as_deref() != Some(window) {
                self.drop_held();
            }
            if self.held.is_empty() {
                self.since_ns = Some(now_ns);
            }
            self.window = Some(window.to_owned());
            self.held.push(Piece { terminal: terminal.map(str::to_owned), bytes: more.to_vec() });
        }
        let window = window?;
        if self.held.is_empty() || self.window.as_deref() != Some(window) || !has_target {
            return None;
        }
        let bytes = self.held.iter().flat_map(|piece| piece.bytes.iter().copied()).collect();
        self.drop_held();
        Some(bytes)
    }

    /// The person closed the pane of creating terminal `terminal` before it
    /// started: its held keys are dropped now, and later ones when they come.
    pub fn creation_closed(&mut self, terminal: &str) {
        self.held.retain(|piece| piece.terminal.as_deref() != Some(terminal));
        if self.held.is_empty() {
            self.drop_held();
        }
        self.closed.retain(|closed| closed != terminal);
        self.closed.push(terminal.to_owned());
        if self.closed.len() > CLOSED_LIMIT {
            let extra = self.closed.len() - CLOSED_LIMIT;
            self.closed.drain(..extra);
        }
    }

    fn drop_held(&mut self) {
        self.held.clear();
        self.window = None;
        self.since_ns = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LONG: i64 = 60_000_000_000;

    #[test]
    fn keys_reach_only_a_terminal_of_the_window_they_were_typed_in() {
        let mut input = GivenBackInput::new(LONG);
        assert_eq!(input.deliver(b"ls\r", None, Some("A"), false, 0), None);
        assert_eq!(
            input.deliver(b"", None, Some("B"), true, 1),
            None,
            "keys typed in window A reached window B"
        );
        assert_eq!(input.deliver(b"", None, Some("A"), true, 2).as_deref(), Some(&b"ls\r"[..]));
        assert_eq!(
            input.deliver(b"rm", None, None, true, 3),
            None,
            "keys of no known window were typed"
        );
        assert!(input.is_empty());
    }

    #[test]
    fn keys_of_a_closed_starting_pane_reach_no_other_terminal() {
        let mut input = GivenBackInput::new(LONG);
        assert_eq!(input.deliver(b"rm -r build\r", Some("starting"), Some("A"), false, 0), None);
        input.creation_closed("starting");
        assert_eq!(input.deliver(b"", None, Some("A"), true, 1), None);
        assert_eq!(input.deliver(b"y\r", Some("starting"), Some("A"), true, 2), None);
        assert_eq!(input.deliver(b"", None, Some("A"), true, 3), None);
    }

    #[test]
    fn keys_of_other_creations_still_go_to_their_window() {
        let mut input = GivenBackInput::new(LONG);
        let _ = input.deliver(b"a", Some("failed"), Some("A"), false, 0);
        let _ = input.deliver(b"b", Some("starting"), Some("A"), false, 1);
        let _ = input.deliver(b"c", None, Some("A"), false, 2);
        input.creation_closed("starting");
        assert_eq!(input.deliver(b"", None, Some("A"), true, 3).as_deref(), Some(&b"ac"[..]));
    }

    #[test]
    fn keys_held_past_the_limit_are_dropped() {
        let mut input = GivenBackInput::default();
        let _ = input.deliver(b"x", None, Some("A"), false, 0);
        assert_eq!(
            input.deliver(b"", None, Some("A"), true, DEFAULT_LIMIT_NS).as_deref(),
            Some(&b"x"[..]),
            "at the limit"
        );
        let _ = input.deliver(b"y", None, Some("A"), false, 10);
        assert_eq!(
            input.deliver(b"", None, Some("A"), true, 10 + DEFAULT_LIMIT_NS + 1),
            None,
            "past the limit"
        );
    }

    #[test]
    fn keys_from_another_window_replace_the_held_ones() {
        let mut input = GivenBackInput::new(LONG);
        let _ = input.deliver(b"a", None, Some("A"), false, 0);
        let _ = input.deliver(b"b", None, Some("B"), false, 1);
        assert_eq!(input.deliver(b"", None, Some("A"), true, 2), None);
        assert_eq!(input.deliver(b"", None, Some("B"), true, 3).as_deref(), Some(&b"b"[..]));
    }

    #[test]
    fn the_closed_list_keeps_the_last_ones() {
        let mut input = GivenBackInput::new(LONG);
        for n in 0..40 {
            input.creation_closed(&format!("t{n}"));
        }
        assert_eq!(input.deliver(b"x", Some("t0"), Some("A"), true, 0).as_deref(), Some(&b"x"[..]));
        assert_eq!(input.deliver(b"x", Some("t39"), Some("A"), true, 1), None);
    }
}
