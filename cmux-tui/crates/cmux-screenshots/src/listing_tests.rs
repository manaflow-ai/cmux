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
    let mut listing = Listing::new([item_in("a.png", 1.0, "a", 1), item_in("b.png", 2.0, "b", 1)]);
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
    let mut listing = Listing::new((0..20_000).map(|i| item(&format!("f{i}.png"), f64::from(i))));
    let start = Instant::now();
    for i in 0..500 {
        listing.upsert(item(&format!("new{i}.png"), 30_000.0 + f64::from(i)));
    }
    let elapsed = start.elapsed();
    assert_eq!(listing.items()[0].name, "new499.png");
    assert!(elapsed.as_secs_f64() < 1.0, "500 upserts into 20 000 items took {elapsed:?}");
}
