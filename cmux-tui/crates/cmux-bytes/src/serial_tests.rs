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
