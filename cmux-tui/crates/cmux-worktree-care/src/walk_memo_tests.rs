use super::*;
use crate::store::care_tests::scratch;
use std::time::{Duration, Instant};

fn measure(root: &Path, now: u64) -> Sizes {
    sizes(root, &[], now, || crate::disk::sizes(root, &[], Instant::now() + Duration::from_secs(10)))
}

#[test]
fn without_an_open_memo_every_measure_walks() {
    reset_for_test();
    let root = scratch("memo-closed");
    std::fs::write(root.join("a"), vec![1u8; 8192]).unwrap();
    let first = measure(&root, 1);
    std::fs::write(root.join("b"), vec![1u8; 8192]).unwrap();
    let second = measure(&root, 2);
    assert!(second.total > first.total);
    let cost = take_cost();
    assert_eq!((cost.sizes_walked, cost.sizes_reused), (2, 0));
    assert!(cost.stats >= 3, "{cost:?}");
}

#[test]
fn a_measured_folder_is_answered_from_the_memo_until_its_time_runs_out() {
    reset_for_test();
    let store = scratch("memo-store");
    let root = scratch("memo-tree");
    std::fs::create_dir_all(root.join("deep/er")).unwrap();
    std::fs::write(root.join("deep/er/a"), vec![1u8; 8192]).unwrap();
    open(&store);
    let first = measure(&root, 1_000);
    let walked = take_cost();
    assert_eq!(walked.sizes_walked, 1);
    assert!(walked.stats >= 3 && walked.dirs >= 3, "{walked:?}");
    close(1_000).unwrap();

    // Another process's pass, a minute later: the memo stands, nothing is stat'ed.
    std::fs::write(root.join("deep/b"), vec![1u8; 64 * 1024]).unwrap();
    open(&store);
    let again = measure(&root, 61_000);
    assert_eq!(again.total, first.total);
    let reused = take_cost();
    assert_eq!((reused.sizes_walked, reused.sizes_reused, reused.stats), (0, 1, 0));

    // Past its time to live it is walked again and sees the new file.
    let later = measure(&root, 1_000 + 2 * TTL_MS);
    assert!(later.total >= first.total + 64 * 1024, "{} {}", later.total, first.total);
    close(1_000 + 2 * TTL_MS).unwrap();
    reset_for_test();
}

#[test]
fn a_spent_walk_budget_keeps_old_sizes_but_a_new_folder_is_still_measured() {
    reset_for_test();
    let store = scratch("memo-budget");
    let old = scratch("memo-old");
    let new = scratch("memo-new");
    std::fs::write(old.join("a"), vec![1u8; 8192]).unwrap();
    std::fs::write(new.join("a"), vec![1u8; 8192]).unwrap();
    open(&store);
    let first = measure(&old, 0);
    with(|open| open.as_mut().unwrap().budget = 0);
    std::fs::write(old.join("b"), vec![1u8; 8192]).unwrap();
    assert_eq!(measure(&old, 3 * TTL_MS).total, first.total);
    assert!(measure(&new, 3 * TTL_MS).total >= 8192);
    let cost = take_cost();
    assert_eq!((cost.sizes_walked, cost.sizes_reused), (2, 1));
    reset_for_test();
}

#[test]
fn facts_stand_while_their_signature_does() {
    reset_for_test();
    let store = scratch("memo-facts");
    let path = Path::new("/nowhere/wt");
    let sig = |n: u64| Signature { head: Some("abc".into()), branch: None, times: vec![n] };
    let facts = Facts { changed: 3, ..Facts::default() };
    open(&store);
    assert!(super::facts(path, 10, |_| sig(1)).is_none());
    keep_facts(path, 10, sig(1), &facts);
    close(10).unwrap();
    open(&store);
    assert_eq!(super::facts(path, 20, |_| sig(1)).map(|f| f.changed), Some(3));
    assert!(super::facts(path, 20, |_| sig(2)).is_none());
    assert!(super::facts(path, 10 + 2 * TTL_MS, |_| sig(1)).is_none());
    reset_for_test();
}
