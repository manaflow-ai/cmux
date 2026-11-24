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
    assert!(Arc::ptr_eq(&list.last().unwrap().upgrade().unwrap(), &link));
    assert!(list.iter().all(|o| o.upgrade().is_some_and(|c| open(&c))));
}
