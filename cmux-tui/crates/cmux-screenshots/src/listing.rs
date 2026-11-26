//! The files a grid shows, newest first, keyed by path (Swift `ScreenshotListing`).
//!
//! Order: newer modification date first, then name (case-insensitive, numeric), then path. A path
//! is listed at most once. `replace` re-sorts (O(n log n)); `upsert` and `remove` find their place
//! by binary search, so a live folder of thousands of files takes a new screenshot without a sort.

use crate::rule::MediaKind;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// One file in the grid (Swift `FileGridItem`).
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    /// The file's path: the item's identity.
    pub path: String,
    /// The file's name (the path's last component).
    pub name: String,
    /// Picture, movie or other.
    pub kind: MediaKind,
    /// Size in bytes.
    pub size: i64,
    /// Last modification time, seconds (any epoch, the same for every item).
    pub modified: f64,
    /// The id of the source the item was listed from.
    pub source: String,
}

impl Item {
    /// An item whose name is the last component of `path`.
    pub fn new(
        path: impl Into<String>,
        kind: MediaKind,
        size: i64,
        modified: f64,
        source: impl Into<String>,
    ) -> Self {
        let path = path.into();
        let name = path.trim_end_matches('/').rsplit('/').next().unwrap_or_default().to_owned();
        Self { path, name, kind, size, modified, source: source.into() }
    }
}

/// Compares names as Foundation's `compare(_:options: [.caseInsensitive, .numeric])` does: runs of
/// digits by their value, everything else case-insensitively.
pub fn compare_names(lhs: &str, rhs: &str) -> Ordering {
    let mut a = lhs.chars().peekable();
    let mut b = rhs.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let da = digits(&mut a);
                let db = digits(&mut b);
                let order = da.len().cmp(&db.len()).then_with(|| da.cmp(&db));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                a.next();
                b.next();
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
            }
        }
    }
}

/// A run of ASCII digits without its leading zeros.
fn digits(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut run = String::new();
    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
        chars.next();
        if !(run.is_empty() && c == '0') {
            run.push(c);
        }
    }
    run
}

/// Case and diacritic folding for the search box: `É` and `e` match.
pub fn fold(text: &str) -> String {
    text.nfd().filter(|c| !is_combining_mark(*c)).flat_map(char::to_lowercase).collect()
}

/// The grid's order: `lhs` shows before `rhs`.
pub fn precedes(lhs: &Item, rhs: &Item) -> bool {
    order(lhs, rhs) == Ordering::Less
}

/// The grid's order as an [`Ordering`] (Less: `lhs` shows first).
pub fn order(lhs: &Item, rhs: &Item) -> Ordering {
    if lhs.modified != rhs.modified {
        return if lhs.modified > rhs.modified { Ordering::Less } else { Ordering::Greater };
    }
    compare_names(&lhs.name, &rhs.name).then_with(|| lhs.path.cmp(&rhs.path))
}

/// The sorted listing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Listing {
    items: Vec<Item>,
    by_path: HashMap<String, Item>,
}

impl Listing {
    /// A listing of these items (sorted here; a later duplicate path wins).
    pub fn new(items: impl IntoIterator<Item = Item>) -> Self {
        let mut listing = Self::default();
        for item in items {
            listing.by_path.insert(item.path.clone(), item);
        }
        listing.resort();
        listing
    }

    fn resort(&mut self) {
        self.items = self.by_path.values().cloned().collect();
        self.items.sort_by(order);
    }

    /// Every item, newest first.
    pub fn items(&self) -> &[Item] {
        &self.items
    }

    /// The number of items.
    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Whether nothing is listed.
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// The item at `path`, if listed.
    pub fn item(&self, path: &str) -> Option<&Item> {
        self.by_path.get(path)
    }

    /// Swaps every item of `source` for `items` (a fresh scan of that folder).
    pub fn replace(&mut self, source: &str, items: impl IntoIterator<Item = Item>) {
        self.by_path.retain(|_, item| item.source != source);
        for item in items {
            self.by_path.insert(item.path.clone(), item);
        }
        self.resort();
    }

    /// Drops every item of `source`.
    pub fn remove_source(&mut self, source: &str) {
        self.replace(source, []);
    }

    /// Adds the item, or moves it to its new place when its path is listed.
    pub fn upsert(&mut self, item: Item) {
        if let Some(old) = self.by_path.get(&item.path) {
            if *old == item {
                return;
            }
            if let Some(index) = self.index_of(old) {
                self.items.remove(index);
            }
        }
        let at = self.insertion_index(&item);
        self.by_path.insert(item.path.clone(), item.clone());
        self.items.insert(at, item);
    }

    /// Removes the item at `path`.
    pub fn remove(&mut self, path: &str) {
        let Some(old) = self.by_path.remove(path) else { return };
        if let Some(index) = self.index_of(&old) {
            self.items.remove(index);
        }
    }

    /// The positions (in [`Self::items`]) of the items whose name contains `query` (case- and
    /// diacritic-insensitive) and whose source is in `sources` (None: every source).
    pub fn filtered_indices(&self, query: &str, sources: Option<&HashSet<String>>) -> Vec<usize> {
        let needle = fold(query.trim());
        self.items
            .iter()
            .enumerate()
            .filter(|(_, item)| sources.is_none_or(|s| s.contains(&item.source)))
            .filter(|(_, item)| needle.is_empty() || fold(&item.name).contains(&needle))
            .map(|(index, _)| index)
            .collect()
    }

    /// The items [`Self::filtered_indices`] keeps, newest first.
    pub fn filtered(&self, query: &str, sources: Option<&HashSet<String>>) -> Vec<&Item> {
        self.filtered_indices(query, sources).into_iter().map(|i| &self.items[i]).collect()
    }

    /// The number of items of each source.
    pub fn counts_by_source(&self) -> HashMap<String, usize> {
        let mut counts = HashMap::new();
        for item in &self.items {
            *counts.entry(item.source.clone()).or_insert(0) += 1;
        }
        counts
    }

    /// The position of the item at `path`, if listed.
    pub fn position(&self, path: &str) -> Option<usize> {
        self.by_path.get(path).and_then(|item| self.index_of(item))
    }

    fn insertion_index(&self, item: &Item) -> usize {
        self.items.partition_point(|probe| precedes(probe, item))
    }

    fn index_of(&self, item: &Item) -> Option<usize> {
        let index = self.insertion_index(item);
        (self.items.get(index)?.path == item.path).then_some(index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn item(name: &str, at: f64) -> Item {
        item_in(name, at, "a", 1)
    }

    fn item_in(name: &str, at: f64, source: &str, size: i64) -> Item {
        Item::new(format!("/shots/{source}/{name}"), MediaKind::Image, size, at, source)
    }

    fn names(items: &[Item]) -> Vec<&str> {
        items.iter().map(|i| i.name.as_str()).collect()
    }

    #[test]
    fn lists_newest_first_then_by_numeric_name() {
        let listing = Listing::new([
            item("Shot 10.png", 5.0),
            item("Shot 2.png", 5.0),
            item("old.png", 1.0),
            item("new.mov", 9.0),
        ]);
        assert_eq!(names(listing.items()), ["new.mov", "Shot 2.png", "Shot 10.png", "old.png"]);
    }

    #[test]
    fn upsert_places_a_new_screenshot_first_and_moves_a_rewritten_file() {
        let mut listing = Listing::new([item("a.png", 1.0), item("b.png", 2.0)]);
        listing.upsert(item("c.png", 3.0));
        assert_eq!(names(listing.items()), ["c.png", "b.png", "a.png"]);
        listing.upsert(item_in("a.png", 4.0, "a", 9));
        assert_eq!(names(listing.items()), ["a.png", "c.png", "b.png"]);
        assert_eq!(listing.len(), 3);
        assert_eq!(listing.item("/shots/a/a.png").map(|i| i.size), Some(9));
        assert_eq!(listing.position("/shots/a/c.png"), Some(1));
    }

    #[test]
    fn remove_drops_only_that_path() {
        let mut listing = Listing::new([item("a.png", 1.0), item("b.png", 2.0)]);
        listing.remove("/shots/a/a.png");
        listing.remove("/shots/a/missing.png");
        assert_eq!(names(listing.items()), ["b.png"]);
    }

    #[test]
    fn replace_swaps_one_source_and_keeps_the_others() {
        let mut listing =
            Listing::new([item_in("a.png", 1.0, "a", 1), item_in("b.png", 2.0, "b", 1)]);
        listing.replace("a", [item_in("c.png", 3.0, "a", 1)]);
        assert_eq!(names(listing.items()), ["c.png", "b.png"]);
        listing.remove_source("b");
        assert_eq!(names(listing.items()), ["c.png"]);
        assert_eq!(listing.counts_by_source(), HashMap::from([("a".to_owned(), 1)]));
    }

    #[test]
    fn filters_by_name_and_source() {
        let listing = Listing::new([
            item_in("Screenshot one.png", 3.0, "a", 1),
            item_in("Recording.mov", 2.0, "b", 1),
            item_in("screenshot two.png", 1.0, "b", 1),
        ]);
        let picked = |q: &str, s: Option<&[&str]>| -> Vec<String> {
            let set = s.map(|s| s.iter().map(|x| (*x).to_owned()).collect::<HashSet<_>>());
            listing.filtered(q, set.as_ref()).into_iter().map(|i| i.name.clone()).collect()
        };
        assert_eq!(picked("SCREENSHOT", None), ["Screenshot one.png", "screenshot two.png"]);
        assert_eq!(picked("", Some(&["b"])), ["Recording.mov", "screenshot two.png"]);
        assert!(picked("two", Some(&["a"])).is_empty());
        assert_eq!(picked("  ", None).len(), 3);
    }

    #[test]
    fn filter_ignores_diacritics() {
        let listing = Listing::new([item("Café.png", 1.0), item("Cafe\u{301} 2.png", 2.0)]);
        assert_eq!(listing.filtered("CAFE", None).len(), 2);
        assert_eq!(listing.filtered("café", None).len(), 2);
    }

    #[test]
    fn numeric_names_compare_by_value() {
        assert_eq!(compare_names("Shot 2", "Shot 10"), Ordering::Less);
        assert_eq!(compare_names("shot", "SHOT"), Ordering::Equal);
        assert_eq!(compare_names("a", "B"), Ordering::Less);
        assert_eq!(compare_names("x007", "x7"), Ordering::Equal);
        assert_eq!(compare_names("x", "x1"), Ordering::Less);
    }

    /// A deterministic random source (SplitMix64), as the Swift property test uses.
    struct SplitMix(u64);

    impl SplitMix {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut v = self.0;
            v = (v ^ (v >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            v = (v ^ (v >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            v ^ (v >> 31)
        }

        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    /// Any sequence of upserts and removes leaves the list a full sort of the survivors gives.
    #[test]
    fn incremental_updates_match_a_full_sort() {
        for seed in [1, 7, 42, 1999] {
            let mut rng = SplitMix(seed);
            let mut listing = Listing::default();
            let mut truth: HashMap<String, Item> = HashMap::new();
            for _ in 0..600 {
                let name = format!("f{}.png", rng.below(80));
                if rng.below(4) == 0 {
                    let path = format!("/shots/a/{name}");
                    listing.remove(&path);
                    truth.remove(&path);
                } else {
                    let it = item(&name, rng.below(20) as f64);
                    listing.upsert(it.clone());
                    truth.insert(it.path.clone(), it);
                }
            }
            let mut expected: Vec<Item> = truth.into_values().collect();
            expected.sort_by(order);
            assert_eq!(listing.items(), expected.as_slice(), "seed {seed}");
        }
    }

    /// A screenshot landing in a folder of 20 000 files is placed without a re-sort.
    #[test]
    fn upsert_into_a_large_listing_stays_fast() {
        let mut listing =
            Listing::new((0..20_000).map(|i| item(&format!("f{i}.png"), f64::from(i))));
        let start = Instant::now();
        for i in 0..500 {
            listing.upsert(item(&format!("new{i}.png"), 30_000.0 + f64::from(i)));
        }
        let elapsed = start.elapsed();
        assert_eq!(listing.items()[0].name, "new499.png");
        assert!(elapsed.as_secs_f64() < 1.0, "500 upserts into 20 000 items took {elapsed:?}");
    }
}
