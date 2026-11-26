use super::*;

#[test]
fn a_sleep_shows_as_the_clocks_drifting_apart() {
    let mut watch = SleepWatch::default();
    assert!(!watch.observe(0, 5_000_000));
    // Awake: both clocks advance together, a long poll included.
    assert!(!watch.observe(1_000_000, 6_000_000));
    assert!(!watch.observe(1_900_000, 6_950_000));
    // Asleep for 200 s: the link's clock moved 10 ms.
    assert!(watch.observe(1_910_000, 206_960_000));
    assert!(!watch.observe(1_920_000, 206_970_000));
}

#[test]
fn addresses_changing_is_a_network_change_and_order_is_not() {
    let mut watch = AddressWatch::default();
    assert!(watch.due(0));
    assert!(!watch.observe(vec![2, 1], 0), "the first read only records");
    assert!(!watch.due(ADDRESS_CHECK_US - 1));
    assert!(!watch.observe(vec![1, 2], ADDRESS_CHECK_US));
    assert!(watch.observe(vec![1, 3], 2 * ADDRESS_CHECK_US));
    assert!(watch.observe(vec![1], 3 * ADDRESS_CHECK_US));
}
