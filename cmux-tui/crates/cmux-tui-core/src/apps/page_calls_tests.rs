use super::*;

/// Every slot busy: a new page gets none and the count stays at
/// `MAX_PAGES` (base red: the idle sweep removed nothing and the slot was
/// added anyway); an open page keeps its slot, and one idle slot makes
/// room.
#[test]
fn a_new_page_gets_no_slot_while_every_slot_is_busy() {
    let grant = Grant::default();
    let mut pages = Pages::default();
    for n in 0..MAX_PAGES {
        pages.slot(&(1, format!("p{n}")), &grant).expect("room").inflight = 1;
    }
    assert!(pages.slot(&(2, "new".into()), &grant).is_none());
    assert_eq!(pages.slots.len(), MAX_PAGES);
    assert!(pages.slot(&(1, "p0".into()), &grant).is_some(), "an open page keeps its slot");
    pages.slot(&(1, "p7".into()), &grant).expect("open").inflight = 0;
    assert!(pages.slot(&(2, "new".into()), &grant).is_some());
    assert_eq!(pages.slots.len(), MAX_PAGES);
    assert!(!pages.slots.contains_key(&(1, "p7".into())), "the idle slot made room");
}
