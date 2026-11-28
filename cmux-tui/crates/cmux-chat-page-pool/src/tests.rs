use super::*;

fn warm(capacity: usize) -> Pool {
    let mut pool = Pool::new(capacity, DEFAULT_DEBOUNCE_MS);
    for _ in 0..capacity {
        let created = pool.idle(0);
        let [Effect::Create { slot }] = created.as_slice() else { panic!("{created:?}") };
        let slot = *slot;
        assert!(pool.ready(slot, 0).is_empty());
    }
    assert!(pool.idle(0).is_empty(), "never more than capacity");
    pool
}

#[test]
fn fills_one_page_per_idle_up_to_capacity() {
    let mut pool = Pool::default();
    assert_eq!(pool.idle(0), vec![Effect::Create { slot: 1 }]);
    assert_eq!(pool.idle(1), vec![Effect::Create { slot: 2 }]);
    assert!(pool.idle(2).is_empty());
    assert_eq!(pool.slots().len(), 2);
}

#[test]
fn a_hover_waits_for_the_debounce() {
    let mut pool = warm(2);
    pool.hover("a", 100);
    assert_eq!(pool.due_at(), Some(180));
    assert!(pool.tick(179).is_empty());
    assert_eq!(pool.tick(180), vec![Effect::Retarget { slot: 1, session: "a".into() }]);
    assert_eq!(pool.due_at(), None);
}

#[test]
fn fast_hovers_over_many_rows_retarget_once_latest_wins() {
    let mut pool = warm(2);
    for (i, s) in ["a", "b", "c", "d", "e"].iter().enumerate() {
        pool.hover(s, 100 + i as u64 * 20);
        assert!(pool.tick(100 + i as u64 * 20 + 10).is_empty());
    }
    assert_eq!(pool.tick(260), vec![Effect::Retarget { slot: 1, session: "e".into() }]);
    assert_eq!(pool.slots().len(), 2, "no page per hover");
}

#[test]
fn reuses_the_page_already_showing_the_session() {
    let mut pool = warm(2);
    pool.hover("a", 0);
    pool.tick(100);
    pool.hover("b", 200);
    assert_eq!(pool.tick(300), vec![Effect::Retarget { slot: 2, session: "b".into() }]);
    pool.hover("a", 400);
    assert!(pool.tick(500).is_empty(), "slot 1 still shows a");
}

#[test]
fn evicts_the_least_recently_used_page() {
    let mut pool = warm(2);
    pool.hover("a", 0);
    pool.tick(100);
    pool.hover("b", 200);
    pool.tick(300);
    pool.hover("a", 400);
    pool.tick(500); // touches slot 1
    pool.hover("c", 600);
    assert_eq!(pool.tick(700), vec![Effect::Retarget { slot: 2, session: "c".into() }]);
}

#[test]
fn jitter_on_one_row_does_not_push_it_back() {
    let mut pool = warm(1);
    pool.hover("a", 0);
    pool.hover("a", 50);
    assert_eq!(pool.tick(80), vec![Effect::Retarget { slot: 1, session: "a".into() }]);
}

#[test]
fn a_hover_before_any_page_is_ready_applies_on_ready() {
    let mut pool = Pool::default();
    pool.idle(0);
    pool.hover("a", 0);
    assert!(pool.tick(200).is_empty());
    assert_eq!(pool.ready(1, 300), vec![Effect::Retarget { slot: 1, session: "a".into() }]);
}

#[test]
fn hover_ended_drops_the_pending_hover() {
    let mut pool = warm(2);
    pool.hover("a", 0);
    pool.hover_ended();
    assert!(pool.tick(1000).is_empty());
}

#[test]
fn click_adopts_the_warm_page_and_the_pool_refills_at_idle() {
    let mut pool = warm(2);
    pool.hover("a", 0);
    pool.tick(100);
    assert_eq!(pool.click("a"), vec![Effect::Adopt { slot: 1, session: "a".into() }]);
    assert_eq!(pool.slots().len(), 1);
    assert_eq!(pool.idle(200), vec![Effect::Create { slot: 3 }]);
    assert_eq!(pool.slots().len(), 2);
}

#[test]
fn click_on_a_cold_session_adopts_nothing_and_drops_the_hover() {
    let mut pool = warm(2);
    pool.hover("b", 0);
    assert!(pool.click("b").is_empty(), "not yet retargeted");
    assert!(pool.tick(1000).is_empty());
    assert_eq!(pool.slots().len(), 2);
}

#[test]
fn a_loading_page_is_never_adopted_or_retargeted() {
    let mut pool = Pool::new(1, 0);
    pool.idle(0);
    pool.hover("a", 0);
    assert!(pool.tick(0).is_empty());
    assert!(pool.click("a").is_empty());
}

#[test]
fn lost_pages_are_remade() {
    let mut pool = warm(2);
    pool.lost(1);
    assert_eq!(pool.idle(0), vec![Effect::Create { slot: 3 }]);
}

#[test]
fn off_makes_nothing_and_ignores_hovers() {
    let mut pool = Pool::new(0, DEFAULT_DEBOUNCE_MS);
    assert!(pool.idle(0).is_empty());
    pool.hover("a", 0);
    assert_eq!(pool.due_at(), None);
}

#[test]
fn resize_closes_least_recently_used_first() {
    let mut pool = warm(2);
    pool.hover("a", 0);
    pool.tick(100);
    pool.hover("b", 200);
    pool.tick(300);
    assert_eq!(pool.resize(1), vec![Effect::Close { slot: 1 }]);
    assert_eq!(pool.resize(0), vec![Effect::Close { slot: 2 }]);
    assert_eq!(pool.resize(99), vec![]);
    assert_eq!(pool.capacity(), MAX_CAPACITY);
}
