use super::*;
use serde_json::json;

fn rec(rows: &[(u64, bool)], bytes: u64, capacity: usize, max: u64) -> Vec<usize> {
    let rows = rows.iter().map(|&(bytes, same)| Row { bytes, same }).collect();
    record(&RecordRequest { rows, bytes, capacity, max_total_bytes: max }).keep
}

#[test]
fn a_repeat_moves_to_the_front() {
    assert_eq!(rec(&[(1, false), (1, true), (1, false)], 1, 20, 100), vec![0, 2]);
}

#[test]
fn capacity_drops_the_oldest() {
    assert_eq!(rec(&[(1, false), (1, false), (1, false)], 1, 3, 100), vec![0, 1]);
    assert_eq!(rec(&[(1, false)], 1, 1, 100), Vec::<usize>::new());
    assert_eq!(rec(&[(1, false)], 1, 0, 100), Vec::<usize>::new(), "a cap under 1 is 1");
}

#[test]
fn the_byte_budget_keeps_the_newest() {
    assert_eq!(rec(&[(4, false), (4, false)], 4, 20, 10), vec![0]);
    assert_eq!(
        rec(&[(4, false)], 50, 20, 10),
        Vec::<usize>::new(),
        "a copy over the budget stays alone"
    );
    assert_eq!(
        rec(&[(2, true), (4, false)], 4, 20, 8),
        vec![1],
        "the repeat's bytes leave with it"
    );
}

#[test]
fn access_cases() {
    for (access, default_reads, want) in [
        (Access::NoPrivacy, false, true),
        (Access::AlwaysAllow, false, true),
        (Access::Default, false, false),
        (Access::Default, true, true),
        (Access::AlwaysDeny, true, false),
    ] {
        assert_eq!(
            reads_without_asking(AccessRequest { access, default_reads }),
            want,
            "{access:?}"
        );
    }
}

#[test]
fn ops_wire() {
    let out = crate::call(
        "compose.clipboard.record",
        &json!({"rows": [{"bytes": 3}, {"bytes": 1, "same": true}], "bytes": 1, "capacity": 20, "maxTotalBytes": 100}),
    );
    assert_eq!(out.unwrap(), json!({"keep": [0]}));
    let out = crate::call(
        "compose.clipboard.readsWithoutAsking",
        &json!({"access": "default", "defaultReads": true}),
    );
    assert_eq!(out.unwrap(), json!(true));
}
