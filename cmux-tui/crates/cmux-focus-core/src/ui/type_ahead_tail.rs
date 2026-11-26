//! The keys that follow a page's queued type-ahead text and are not text
//! (Swift `TypeAheadTail`): Return first, then every key typed after it. They
//! wait, in typing order, until the text landed in the page, and run then as
//! typed. Before, Return ended the queue: the text typed into a page whose
//! field was not ready was dropped and Return acted on an empty field ("I
//! type in something and press Enter and if it's too early nothing happens",
//! Lawrence 2026-11-10).
//!
//! A key is the app's id for the held event; the app keeps the event.

use serde::{Deserialize, Serialize};

/// Escape's key code: it cancels what waits.
pub const ESCAPE: u16 = 53;
/// Return's and keypad Enter's key codes: they start the tail.
pub const RETURN: u16 = 36;
pub const KEYPAD_ENTER: u16 = 76;

/// The held keys. A value the app keeps and sends back.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TypeAheadTail {
    /// The surface the keys wait for; None when none wait.
    surface: Option<String>,
    keys: Vec<u64>,
    /// The text the keys follow was taken for the page (it is on its way, or landed).
    text_taken: bool,
}

impl TypeAheadTail {
    /// The surface the keys wait for.
    pub fn surface(&self) -> Option<&str> {
        self.surface.as_deref()
    }

    /// Whether keys wait behind `surface`'s text.
    pub fn holds(&self, surface: &str) -> bool {
        self.surface.as_deref() == Some(surface) && !self.keys.is_empty()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// How many keys wait behind `surface`'s text.
    pub fn count(&self, surface: &str) -> usize {
        if self.surface.as_deref() == Some(surface) { self.keys.len() } else { 0 }
    }

    /// Whether a key typed now waits here. Return or keypad Enter starts the
    /// tail when it follows queued text (`behind_text`); every later key joins
    /// it, except Escape (it cancels what waits). A chord never waits: it
    /// ends the queue.
    pub fn takes(&self, key_code: u16, chord: bool, surface: &str, behind_text: bool) -> bool {
        if chord {
            return false;
        }
        if self.holds(surface) {
            return key_code != ESCAPE;
        }
        behind_text && (key_code == RETURN || key_code == KEYPAD_ENTER)
    }

    /// Holds `key` behind `surface`'s text. `delivering`: that text was
    /// already taken for the page. Keys held for another surface are dropped
    /// first: its page is no longer the one typed into.
    pub fn hold(&mut self, key: u64, surface: &str, delivering: bool) {
        if self.surface.as_deref() != Some(surface) {
            self.drop_all();
        }
        self.surface = Some(surface.to_owned());
        self.keys.push(key);
        if delivering {
            self.text_taken = true;
        }
    }

    /// `surface`'s queued text was taken for the page: the held keys follow it.
    pub fn text_was_taken(&mut self, surface: &str) {
        if self.surface.as_deref() == Some(surface) && !self.keys.is_empty() {
            self.text_taken = true;
        }
    }

    /// Nothing more is on its way to `surface`: the held keys, once, in
    /// typing order. Empty when their text never reached the page (it expired
    /// in the queue): a key alone would act on an empty field, so they are
    /// dropped with it.
    pub fn settle(&mut self, surface: &str) -> Vec<u64> {
        if self.surface.as_deref() != Some(surface) {
            return Vec::new();
        }
        let run = if self.text_taken { std::mem::take(&mut self.keys) } else { Vec::new() };
        self.drop_all();
        run
    }

    /// The text failed to land, a chord ended the queue, or focus left the
    /// page: the keys go.
    pub fn drop_all(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RET: u64 = 1;
    const P: u64 = 2;

    #[test]
    fn return_waits_behind_queued_text_and_runs_after_it_landed() {
        let mut tail = TypeAheadTail::default();
        tail.hold(RET, "page-1", false);
        assert!(tail.holds("page-1"));
        tail.text_was_taken("page-1");
        assert_eq!(tail.settle("page-1"), vec![RET]);
        assert!(tail.settle("page-1").is_empty(), "the keys run once");
    }

    #[test]
    fn keys_typed_after_return_keep_their_order() {
        let mut tail = TypeAheadTail::default();
        tail.hold(RET, "page-1", true);
        tail.hold(P, "page-1", true);
        tail.hold(3, "page-1", true);
        assert_eq!(tail.count("page-1"), 3);
        assert_eq!(tail.settle("page-1"), vec![RET, P, 3]);
    }

    #[test]
    fn return_behind_text_that_never_landed_is_dropped() {
        let mut tail = TypeAheadTail::default();
        tail.hold(RET, "page-1", false);
        assert!(tail.settle("page-1").is_empty());
        assert!(tail.is_empty());
    }

    #[test]
    fn keys_for_another_page_are_dropped() {
        let mut tail = TypeAheadTail::default();
        tail.hold(RET, "page-1", true);
        tail.hold(4, "page-2", true);
        assert!(!tail.holds("page-1"));
        assert!(tail.settle("page-1").is_empty());
        assert_eq!(tail.settle("page-2"), vec![4]);
    }

    #[test]
    fn only_plain_return_starts_the_tail() {
        let mut tail = TypeAheadTail::default();
        assert!(tail.takes(RETURN, false, "page-1", true));
        assert!(tail.takes(KEYPAD_ENTER, false, "page-1", true));
        assert!(!tail.takes(RETURN, false, "page-1", false), "no text waits: Return goes on");
        assert!(!tail.takes(RETURN, true, "page-1", true));
        assert!(!tail.takes(0, false, "page-1", true), "text is queued, not held");
        tail.hold(RET, "page-1", false);
        assert!(tail.takes(0, false, "page-1", true));
        assert!(!tail.takes(ESCAPE, false, "page-1", true), "Escape cancels what waits");
        assert!(!tail.takes(0, true, "page-1", true));
        assert!(!tail.takes(0, false, "page-2", false));
    }
}
