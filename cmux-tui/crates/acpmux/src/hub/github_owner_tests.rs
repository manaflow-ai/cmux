use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

/// The review of the lane part at 1ea8bb6: each `initialize` on one link added it again.
#[test]
fn a_link_is_listed_once_and_the_list_stays_bounded() {
    let open = |c: &AtomicBool| c.load(Ordering::SeqCst);
    let mut list = Vec::new();
    let link = Arc::new(AtomicBool::new(true));
    for _ in 0..100 {
        register(&mut list, &link, open);
    }
    assert_eq!(list.len(), 1);
    let others: Vec<_> = (0..40).map(|_| Arc::new(AtomicBool::new(true))).collect();
    for o in &others {
        register(&mut list, o, open);
    }
    assert_eq!(list.len(), OWNERS_MAX);
    others.last().unwrap().store(false, Ordering::SeqCst);
    register(&mut list, &link, open);
    assert!(Arc::ptr_eq(&list.last().unwrap().link.upgrade().unwrap(), &link));
    assert!(list.iter().all(|o| o.link.upgrade().is_some_and(|c| open(&c))));
}

fn owners(n: usize) -> (Vec<Arc<AtomicBool>>, Vec<Owner<AtomicBool>>) {
    let open = |c: &AtomicBool| c.load(Ordering::SeqCst);
    let links: Vec<_> = (0..n).map(|_| Arc::new(AtomicBool::new(true))).collect();
    let mut list = Vec::new();
    for l in &links {
        register(&mut list, l, open);
    }
    (links, list)
}

fn first(list: &[Owner<AtomicBool>], now: u64) -> Arc<AtomicBool> {
    ranked(list, |c: &AtomicBool| c.load(Ordering::SeqCst), now).remove(0)
}

/// Two Macs lend; the newer one wedges (its action never answers). Within the stall bound
/// the next action goes to the older one, and once the wedged one answers it is back first.
#[test]
fn a_wedged_owner_is_gone_around_and_a_recovered_one_comes_back() {
    let (links, mut list) = owners(2);
    let (old, new) = (&links[0], &links[1]);
    assert!(Arc::ptr_eq(&first(&list, 0), new), "newest first while both are healthy");
    begin(&mut list, new, 1, 0);
    end(&mut list, new, 1, Outcome::Answered, 2_000);
    begin(&mut list, new, 2, 10_000);
    assert!(Arc::ptr_eq(&first(&list, 20_000), new), "under the floor it is not stalled yet");
    assert!(Arc::ptr_eq(&first(&list, 10_000 + STALL_FLOOR_MS + 1), old));
    end(&mut list, new, 2, Outcome::Answered, 40_000);
    assert!(Arc::ptr_eq(&first(&list, 40_000), new));
    assert_eq!(find(&mut list, new).unwrap().longest_ok_ms, 30_000);
}

/// An owner whose actions are lost goes behind one that answers; a busy refusal (not run)
/// leaves no mark; one answer clears the count.
#[test]
fn lost_actions_rank_an_owner_down_and_an_answer_clears_it() {
    let (links, mut list) = owners(2);
    let (old, new) = (&links[0], &links[1]);
    begin(&mut list, new, 1, 0);
    end(&mut list, new, 1, Outcome::NotRun, 1);
    assert!(Arc::ptr_eq(&first(&list, 2), new));
    begin(&mut list, new, 2, 2);
    end(&mut list, new, 2, Outcome::Lost, 3);
    assert!(Arc::ptr_eq(&first(&list, 4), old));
    begin(&mut list, new, 3, 5);
    end(&mut list, new, 3, Outcome::Answered, 6);
    assert!(Arc::ptr_eq(&first(&list, 7), new));
}

/// A Mac that reconnects on the same link keeps its record; a closed link is never asked.
#[test]
fn a_link_listed_again_keeps_its_record_and_closed_ones_are_skipped() {
    let open = |c: &AtomicBool| c.load(Ordering::SeqCst);
    let (links, mut list) = owners(2);
    begin(&mut list, &links[1], 1, 0);
    end(&mut list, &links[1], 1, Outcome::Lost, 1);
    register(&mut list, &links[1], open);
    assert_eq!(find(&mut list, &links[1]).unwrap().failures, 1);
    links[0].store(false, Ordering::SeqCst);
    let r = ranked(&list, open, 2);
    assert_eq!(r.len(), 1);
    assert!(Arc::ptr_eq(&r[0], &links[1]));
}
