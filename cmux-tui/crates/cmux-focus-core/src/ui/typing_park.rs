//! Text for a page that its pane no longer shows (Swift `TypingPark`). A
//! person types into a new tab whose page cannot take keys yet, then presses
//! the New Tab key again: the key router's type-ahead queue keeps the text of
//! one page, and a key with Command or Control ends it. The text waits here,
//! by its page, and is typed into that page when the page's field is ready.
//!
//! The rules:
//! - A text waits for one page (an id the app gives each page object). A page
//!   that is gone takes its text with it (the app names gone pages at each
//!   prune: it keeps the page objects weakly).
//! - A text that waited [`TypingPark::limit_ns`] or longer from the key that
//!   parked it is dropped.
//! - Two texts for one page are typed in the order of their keys: the second
//!   waits until the first landed.
//! - The keys from a Return on that waited behind a text are not parked; they
//!   are counted.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How long a text waits for its page by default (2 s).
pub const DEFAULT_LIMIT_NS: i64 = 2_000_000_000;

/// What became of the parked texts since the park was made.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Counts {
    /// Texts that came into the park.
    pub parked: i64,
    /// Texts that were typed into their page.
    pub typed: i64,
    /// Texts that waited the limit or longer.
    pub dropped_old: i64,
    /// Texts whose page was gone.
    pub dropped_page_gone: i64,
    /// Texts that the field of their page refused.
    pub dropped_refused: i64,
    /// Keys from a Return on that waited behind a text at its park.
    pub dropped_returns: i64,
}

impl Counts {
    /// The counts by their names in `debug.focus`.
    pub fn named(&self) -> BTreeMap<&'static str, i64> {
        BTreeMap::from([
            ("parked", self.parked),
            ("typed", self.typed),
            ("dropped_old", self.dropped_old),
            ("dropped_page_gone", self.dropped_page_gone),
            ("dropped_refused", self.dropped_refused),
            ("dropped_returns", self.dropped_returns),
        ])
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    page: u64,
    text: String,
    /// The time of the key that parked the text.
    since_ns: i64,
    /// The text was taken for its page and did not land yet.
    on_its_way: bool,
}

/// The park. A value: the app keeps it and sends it back with each call.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TypingPark {
    entries: Vec<Entry>,
    counts: Counts,
    /// How long a text waits for its page, from the key that parked it.
    pub limit_ns: i64,
}

impl Default for TypingPark {
    fn default() -> Self {
        Self::new(DEFAULT_LIMIT_NS)
    }
}

impl TypingPark {
    pub fn new(limit_ns: i64) -> Self {
        Self { entries: Vec::new(), counts: Counts::default(), limit_ns }
    }

    pub fn counts(&self) -> Counts {
        self.counts
    }

    /// Whether the park has no text: none waits and none is on its way.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Whether a text waits for `page` or is on its way into it. It reads no
    /// clock: a text that waited the limit counts until [`Self::prune`].
    pub fn holds(&self, page: u64) -> bool {
        self.entries.iter().any(|entry| entry.page == page)
    }

    /// Whether a text that was taken for `page` is on its way into it.
    pub fn is_on_its_way(&self, page: u64) -> bool {
        self.entries.iter().any(|entry| entry.on_its_way && entry.page == page)
    }

    /// Parks `text` for `page` at `now_ns`, the time of the key that ended the
    /// queue; `returns` keys from a Return on waited behind it and are dropped.
    pub fn park(&mut self, text: &str, page: u64, returns: i64, now_ns: i64, gone: &[u64]) {
        self.prune(now_ns, gone);
        self.entries.push(Entry {
            page,
            text: text.to_owned(),
            since_ns: now_ns,
            on_its_way: false,
        });
        self.counts.parked += 1;
        self.counts.dropped_returns += returns;
    }

    /// The oldest text that waits for `page`, once: it is on its way then,
    /// until [`Self::landed`]. None when none waits, when one for the page is
    /// on its way, or when it waited the limit (it is dropped then).
    pub fn take(&mut self, page: u64, now_ns: i64, gone: &[u64]) -> Option<String> {
        self.prune(now_ns, gone);
        let index = self.entries.iter().position(|entry| entry.page == page)?;
        if self.entries[index].on_its_way {
            return None;
        }
        self.entries[index].on_its_way = true;
        Some(self.entries[index].text.clone())
    }

    /// The text taken for `page` landed in its field (`typed`), or the field
    /// refused it.
    pub fn landed(&mut self, page: u64, typed: bool) {
        let Some(index) =
            self.entries.iter().position(|entry| entry.on_its_way && entry.page == page)
        else {
            return;
        };
        self.entries.remove(index);
        if typed {
            self.counts.typed += 1;
        } else {
            self.counts.dropped_refused += 1;
        }
    }

    /// Drops each text whose page is in `gone`, and each waiting text that
    /// waited the limit or longer at `now_ns`, with its count.
    pub fn prune(&mut self, now_ns: i64, gone: &[u64]) {
        let (mut gone_count, mut old) = (0, 0);
        let limit = self.limit_ns;
        self.entries.retain(|entry| {
            if gone.contains(&entry.page) {
                gone_count += 1;
                return false;
            }
            if entry.on_its_way || now_ns.saturating_sub(entry.since_ns) < limit {
                return true;
            }
            old += 1;
            false
        });
        self.counts.dropped_page_gone += gone_count;
        self.counts.dropped_old += old;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: i64 = 1_000_000;
    const START: i64 = 1_000 * MS;

    #[test]
    fn a_parked_text_is_taken_one_time_and_only_for_its_page() {
        let mut park = TypingPark::default();
        let (page, other) = (1, 2);
        park.park("x", page, 0, START, &[]);
        assert!(park.holds(page));
        assert!(!park.holds(other));
        assert_eq!(park.take(other, START + 10 * MS, &[]), None);
        assert_eq!(park.take(page, START + 300 * MS, &[]).as_deref(), Some("x"));
        assert!(park.is_on_its_way(page));
        assert_eq!(park.take(page, START + 310 * MS, &[]), None, "the text was taken 2 times");
        assert!(park.holds(page));
        park.landed(page, true);
        assert!(!park.holds(page));
        assert!(!park.is_on_its_way(page));
        assert_eq!(park.counts(), Counts { parked: 1, typed: 1, ..Counts::default() });
    }

    #[test]
    fn a_text_that_waited_the_limit_is_dropped_and_counted() {
        let mut park = TypingPark::default();
        assert_eq!(park.limit_ns, 2_000 * MS);
        let (early, late) = (1, 2);
        park.park("a", early, 0, START, &[]);
        park.park("b", late, 0, START, &[]);
        assert_eq!(park.take(early, START + 1_999 * MS, &[]).as_deref(), Some("a"));
        assert_eq!(
            park.take(late, START + 2_000 * MS, &[]),
            None,
            "a text at the limit was typed late"
        );
        assert!(!park.holds(late));
        assert_eq!(park.counts().dropped_old, 1);
        assert_eq!(park.counts().typed, 0);
        park.prune(START + 10_000 * MS, &[]);
        assert!(park.is_on_its_way(early), "the limit took back a text on its way");
        park.landed(early, true);
        assert_eq!(park.counts().typed, 1);
        assert_eq!(park.counts().dropped_old, 1);
    }

    #[test]
    fn a_text_whose_page_is_gone_is_dropped_and_counted() {
        let mut park = TypingPark::default();
        park.park("x", 7, 0, START, &[]);
        park.prune(START + 10 * MS, &[7]);
        assert_eq!(park.counts().dropped_page_gone, 1);
        assert_eq!(park.counts().dropped_old, 0);
        assert_eq!(park.counts().parked, 1);
        assert!(park.is_empty());
    }

    #[test]
    fn a_text_that_the_field_refused_is_counted_and_not_typed() {
        let mut park = TypingPark::default();
        park.park("x", 1, 0, START, &[]);
        assert_eq!(park.take(1, START + 10 * MS, &[]).as_deref(), Some("x"));
        park.landed(1, false);
        assert_eq!(park.counts().dropped_refused, 1);
        assert_eq!(park.counts().typed, 0);
        assert!(!park.holds(1));
    }

    #[test]
    fn two_texts_for_one_page_are_taken_in_the_order_of_their_keys() {
        let mut park = TypingPark::default();
        park.park("a", 1, 0, START, &[]);
        park.park("b", 1, 0, START + 100 * MS, &[]);
        assert_eq!(park.take(1, START + 200 * MS, &[]).as_deref(), Some("a"));
        assert_eq!(park.take(1, START + 210 * MS, &[]), None, "the second text passed the first");
        park.landed(1, true);
        assert!(park.holds(1));
        assert_eq!(park.take(1, START + 220 * MS, &[]).as_deref(), Some("b"));
        park.landed(1, true);
        assert_eq!(park.counts().parked, 2);
        assert_eq!(park.counts().typed, 2);
        assert!(!park.holds(1));
    }

    #[test]
    fn the_keys_from_a_return_on_are_counted_at_the_park() {
        let mut park = TypingPark::default();
        park.park("hello", 1, 2, START, &[]);
        assert_eq!(park.take(1, START + 10 * MS, &[]).as_deref(), Some("hello"));
        park.landed(1, true);
        assert_eq!(park.counts().dropped_returns, 2);
        let want = BTreeMap::from([
            ("parked", 1),
            ("typed", 1),
            ("dropped_old", 0),
            ("dropped_page_gone", 0),
            ("dropped_refused", 0),
            ("dropped_returns", 2),
        ]);
        assert_eq!(park.counts().named(), want);
    }

    #[test]
    fn a_park_round_trips_over_the_wire() {
        let mut park = TypingPark::default();
        park.park("x", 1, 1, START, &[]);
        let _ = park.take(1, START, &[]);
        let back: TypingPark =
            serde_json::from_value(serde_json::to_value(&park).unwrap()).unwrap();
        assert_eq!(back, park);
    }
}
