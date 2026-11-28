use super::*;

fn rep(name: &str, vv: Vv, age_ms: u64) -> Report {
    Report { replica: name.to_owned(), vv, age_ms }
}

#[test]
fn the_vm_that_took_over_the_chat_is_the_truth_once_it_covers_the_mac() {
    let reports = [
        rep("mac", Vv::from([("mac", 10)]), 100),
        rep("vm", Vv::from([("mac", 10), ("vm", 4)]), 200),
    ];
    assert_eq!(most_truthful(&reports, 30_000), Some((1, vec![])));
}

#[test]
fn concurrent_replicas_pick_the_bigger_and_name_the_other_to_pull_from() {
    let reports = [
        rep("mac", Vv::from([("mac", 12), ("vm", 1)]), 100),
        rep("vm", Vv::from([("mac", 10), ("vm", 9)]), 100),
    ];
    assert_eq!(most_truthful(&reports, 30_000), Some((1, vec![0])));
}

#[test]
fn a_stale_replica_loses_to_a_fresh_one_even_with_more_edits() {
    let reports =
        [rep("vm", Vv::from([("vm", 50)]), 120_000), rep("mac", Vv::from([("mac", 3)]), 50)];
    assert_eq!(most_truthful(&reports, 30_000), Some((1, vec![0])));
    assert_eq!(most_truthful(&[], 30_000), None);
}
