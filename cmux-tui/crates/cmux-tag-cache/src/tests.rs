use super::*;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Tag {
    Session(u32),
    Host(u32),
}

fn cache(capacity: usize) -> TagCache<u32, String, Tag> {
    TagCache::new(capacity)
}

#[test]
fn a_tag_invalidation_marks_only_the_entries_carrying_it_stale() {
    let mut c = cache(8);
    c.insert(1, "one".into(), vec![Tag::Session(1), Tag::Host(9)]);
    c.insert(2, "two".into(), vec![Tag::Session(2), Tag::Host(9)]);
    assert_eq!(c.get(&1), Lookup::Fresh(&"one".to_owned()));
    c.invalidate(Tag::Session(1));
    assert_eq!(c.get(&1), Lookup::Stale(&"one".to_owned()));
    assert_eq!(c.get(&2), Lookup::Fresh(&"two".to_owned()));
    c.invalidate(Tag::Host(9));
    assert_eq!(c.get(&2), Lookup::Stale(&"two".to_owned()));
    assert_eq!(c.get(&3), Lookup::Miss);
}

#[test]
fn a_rewrite_after_the_invalidation_is_fresh_again() {
    let mut c = cache(8);
    c.insert(1, "old".into(), vec![Tag::Session(1)]);
    c.invalidate(Tag::Session(1));
    c.insert(1, "new".into(), vec![Tag::Session(1)]);
    assert_eq!(c.get(&1), Lookup::Fresh(&"new".to_owned()));
    assert_eq!(c.len(), 1);
}

#[test]
fn a_value_read_while_its_tag_was_invalidated_is_written_stale() {
    let mut c = cache(8);
    let before = c.stamp();
    // The value is read outside the lock, and its session changes meanwhile.
    c.invalidate(Tag::Session(1));
    c.insert_at(1, "read before the change".into(), vec![Tag::Session(1)], before);
    assert!(matches!(c.get(&1), Lookup::Stale(_)));
    // Read after it: fresh.
    let after = c.stamp();
    c.insert_at(1, "read after".into(), vec![Tag::Session(1)], after);
    assert!(matches!(c.get(&1), Lookup::Fresh(_)));
}

#[test]
fn past_its_capacity_the_entry_written_first_goes() {
    let mut c = cache(3);
    for key in 0..3 {
        c.insert(key, key.to_string(), vec![Tag::Session(key)]);
    }
    // Key 0 written again: key 1 is now the one written first.
    c.insert(0, "zero".into(), vec![Tag::Session(0)]);
    c.insert(3, "three".into(), vec![Tag::Session(3)]);
    assert_eq!(c.len(), 3);
    assert_eq!(c.get(&1), Lookup::Miss);
    assert!(c.get(&0).fresh().is_some());
    assert!(c.get(&2).fresh().is_some());
    assert!(c.get(&3).fresh().is_some());
}

#[test]
fn rewrites_and_invalidations_keep_the_memory_bounded_by_the_capacity() {
    let mut c = cache(16);
    for round in 0..100_000_u32 {
        let key = round % 16;
        c.insert(key, round.to_string(), vec![Tag::Session(round), Tag::Host(key)]);
        c.invalidate(Tag::Session(round.wrapping_mul(7)));
        c.invalidate(Tag::Host(round % 5));
    }
    assert_eq!(c.len(), 16);
    assert!(c.order.len() <= 16 * 2 + 16 + 1, "order {}", c.order.len());
    assert!(c.tracked_tags() <= 16 * 4 + 64 + 1, "tags {}", c.tracked_tags());
}

#[test]
fn a_tag_forgotten_by_the_sweep_never_brings_back_a_stale_entry() {
    let mut c = cache(4);
    c.insert(1, "one".into(), vec![Tag::Session(1)]);
    c.invalidate(Tag::Session(1));
    // Enough other invalidations to sweep the tag times.
    for n in 2..1_000 {
        c.invalidate(Tag::Session(n));
    }
    // Session 1's time is newer than entry 1's write: the sweep kept it.
    assert!(matches!(c.get(&1), Lookup::Stale(_)));
}

/// Leo's ask for the Session Info cache: invalidating a tag costs the same at 10 entries as at
/// 10,000. Each round invalidates one tag the entries carry; the median of many rounds at each
/// size is compared, with headroom for a noisy runner.
#[test]
fn one_invalidation_costs_the_same_at_ten_entries_as_at_ten_thousand() {
    fn median_invalidation_ns(entries: u32) -> f64 {
        let mut c: TagCache<u32, u64, Tag> = TagCache::new(entries as usize);
        for key in 0..entries {
            c.insert(key, u64::from(key), vec![Tag::Session(key), Tag::Host(key % 8)]);
        }
        let mut rounds = Vec::with_capacity(51);
        for round in 0..51_u32 {
            let start = std::time::Instant::now();
            for n in 0..2_000_u32 {
                c.invalidate(Tag::Host((round * 2_000 + n) % 8));
            }
            rounds.push(start.elapsed().as_nanos() as f64 / 2_000.0);
        }
        rounds.sort_by(f64::total_cmp);
        rounds[rounds.len() / 2]
    }
    let small = median_invalidation_ns(10);
    let large = median_invalidation_ns(10_000);
    eprintln!("tag-cache invalidation: 10 entries {small:.1} ns, 10,000 entries {large:.1} ns");
    assert!(large < small * 4.0 + 50.0, "10 entries {small:.1} ns, 10,000 entries {large:.1} ns");
}
