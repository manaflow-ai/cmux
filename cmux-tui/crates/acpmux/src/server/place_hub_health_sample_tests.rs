//! RFD 0181 B3's measure: how many machines one placement waits on, at 40 and at 139.
use super::*;

fn hosts(n: usize) -> BTreeSet<String> {
    (0..n).map(|i| format!("lane-{i}")).collect()
}

#[test]
fn a_placement_waits_on_the_same_few_machines_at_40_as_at_139() {
    for seed in [1, 7, 0xdead_beef, u64::MAX] {
        let at_40 = wait_on(&hosts(40), Some("lane-3"), seed);
        let at_139 = wait_on(&hosts(139), Some("lane-3"), seed);
        // Before: 40 and 139 (each machine with no reading).
        assert_eq!((at_40.len(), at_139.len()), (SAMPLE + 1, SAMPLE + 1), "seed {seed}");
        assert!(at_40.contains("lane-3") && at_139.contains("lane-3"), "the last that answered");
        assert!(at_139.is_subset(&hosts(139)));
    }
    // A last good machine no longer missing a reading is not waited on in its place.
    let w = wait_on(&hosts(139), Some("elsewhere"), 42);
    assert_eq!(w.len(), SAMPLE);
}

#[test]
fn a_few_machines_with_no_reading_are_all_waited_on() {
    assert_eq!(wait_on(&hosts(3), None, 9), hosts(3));
    assert!(wait_on(&BTreeSet::new(), Some("lane-0"), 9).is_empty());
}

#[test]
fn draws_spread_over_every_machine() {
    let all = hosts(139);
    let mut seen = BTreeSet::new();
    let mut x = 0x9e37_79b9_7f4a_7c15u64;
    for _ in 0..2_000 {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        seen.extend(wait_on(&all, None, x));
    }
    assert_eq!(seen.len(), 139, "no machine is never drawn");
}
