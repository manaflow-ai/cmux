use super::*;

#[test]
fn the_level_follows_the_link() {
    // A LAN takes a fast level; a slow ssh a stronger one; the 2026-11-22 relay stronger still.
    let lan = EVENT_LOG.best(1.0, 125.0 * MB);
    let wifi = EVENT_LOG.best(1.0, 6.0 * MB);
    let slow = EVENT_LOG.best(1.0, 1.0 * MB);
    let relay = EVENT_LOG.best(1.0, 96e3);
    assert!(lan <= 3, "lan {lan}");
    assert!(wifi <= slow && slow <= relay, "{wifi} {slow} {relay}");
    assert!(relay >= 9, "relay {relay}");
}

#[test]
fn a_slower_machine_takes_a_lighter_level() {
    let fast = EVENT_LOG.best(1.0, 1.0 * MB);
    let slow = EVENT_LOG.best(0.2, 1.0 * MB);
    assert!(slow < fast, "{slow} vs {fast}");
}

#[test]
fn the_best_level_beats_level_three_on_a_slow_link_and_never_loses() {
    for link in [96e3, 1.0 * MB, 6.0 * MB, 125.0 * MB, 1.2e9] {
        let best = EVENT_LOG.best(1.0, link);
        assert!(EVENT_LOG.serial_cost(best, 1.0, link) <= EVENT_LOG.serial_cost(3, 1.0, link));
    }
    let relay = 96e3;
    let gain = 1.0
        - EVENT_LOG.serial_cost(EVENT_LOG.best(1.0, relay), 1.0, relay)
            / EVENT_LOG.serial_cost(3, 1.0, relay);
    assert!(gain > 0.10, "relay gain {gain}");
}

#[test]
fn a_climb_starts_where_it_was_told_and_moves_on_measurements() {
    let mut climb = Climb::new(EVENT_LOG, 3);
    assert_eq!(climb.level(), 3);
    // Small writes say nothing of the link: the level stays.
    climb.observe(4 << 20, 1000, 0.008, 0.05);
    assert_eq!(climb.level(), 3);
    // 4 MiB at 537 MB/s, 400 KB on the wire in 4 s (100 KB/s): a slow link.
    for _ in 0..3 {
        climb.observe(4 << 20, 400_000, 0.0078, 4.0);
    }
    assert!(climb.level() >= 9, "{}", climb.level());
    // The link turns fast: back down.
    for _ in 0..8 {
        climb.observe(4 << 20, 400_000, 0.05, 0.003);
    }
    assert!(climb.level() <= 3, "{}", climb.level());
}

#[test]
fn a_resumed_climb_starts_at_what_the_last_copy_learned() {
    // A copy over the relay climbs to a strong level, and keeps what it learned.
    let mut first = Climb::new(EVENT_LOG, 3);
    assert_eq!(first.learned(), None, "nothing measured, nothing learned");
    for _ in 0..4 {
        first.observe(4 << 20, 400_000, 0.0078, 4.0);
    }
    let learned = first.learned().expect("a measured link");
    assert!(learned.level >= 9, "{learned:?}");
    // The next copy over that link sends its first page at that level, not at 3.
    let next = Climb::resume(EVENT_LOG, learned);
    assert_eq!(next.level(), learned.level);
    assert_eq!(next.resumed(), Some(learned.level));
    assert_eq!(Climb::new(EVENT_LOG, 3).resumed(), None);
    // Small writes say nothing new: it holds the learned level.
    let mut held = next.clone();
    held.observe(4 << 20, 1000, 0.05, 0.05);
    assert_eq!(held.level(), learned.level);
}

#[test]
fn a_resumed_climb_still_follows_the_link_it_finds() {
    // Learned on the relay; this copy's link is a LAN: its own pages outweigh the prior.
    let learned = Learned { level: 12, link: 96e3, cpu: 1.0 };
    let mut climb = Climb::resume(EVENT_LOG, learned);
    for _ in 0..3 {
        climb.observe(4 << 20, 400_000, 0.0078, 0.003);
    }
    assert!(climb.level() <= 3, "{}", climb.level());
    // And the other way: learned on a LAN, now on the relay.
    let mut climb = Climb::resume(EVENT_LOG, Learned { level: 1, link: 125e6, cpu: 1.0 });
    for _ in 0..3 {
        climb.observe(4 << 20, 400_000, 0.0078, 4.0);
    }
    assert!(climb.level() >= 9, "{}", climb.level());
}

#[test]
fn a_learned_level_out_of_range_is_clamped() {
    let climb = Climb::resume(EVENT_LOG, Learned { level: 40, link: 0.0, cpu: -1.0 });
    assert_eq!(climb.level(), 19);
    assert!(climb.link().is_some_and(|l| l >= 1.0));
}

#[test]
fn a_resumed_copys_small_tail_neither_drops_its_level_nor_overwrites_what_was_learned() {
    // The freeze's tail: a few KB pages, compressed in under a millisecond of mostly overhead.
    let learned = Learned { level: 7, link: 1_000_000.0, cpu: 0.6 };
    let mut tail = Climb::resume(EVENT_LOG, learned);
    for _ in 0..3 {
        tail.observe(20_000, 3_000, 0.001, 0.003);
    }
    assert_eq!(tail.level(), 7, "a tiny page is not a slow CPU");
    assert_eq!(tail.learned(), None, "it measured no link: the store keeps the whole copy's");
    // Its first real page is measured as before.
    tail.observe(4 << 20, 500_000, 0.02, 0.5);
    assert!(tail.learned().is_some());
}
