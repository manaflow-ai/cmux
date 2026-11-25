use super::*;

fn drain(s: &mut Scheduler<&'static str>) -> Vec<(Class, &'static str)> {
    std::iter::from_fn(|| s.next()).collect()
}

#[test]
fn a_keystroke_goes_ahead_of_queued_bulk_and_state() {
    let mut s = Scheduler::new([1024; 4]);
    assert_eq!(s.offer(Class::Bulk, 0, 100, "chunk1"), Offer::Queued);
    assert_eq!(s.offer(Class::Ordered, 0, 10, "rpc"), Offer::Queued);
    assert_eq!(s.offer(Class::State, 1, 50, "screen"), Offer::Queued);
    assert_eq!(s.offer(Class::Input, 0, 5, "key"), Offer::Queued);
    assert_eq!(
        drain(&mut s),
        [
            (Class::Input, "key"),
            (Class::State, "screen"),
            (Class::Ordered, "rpc"),
            (Class::Bulk, "chunk1"),
        ]
    );
    assert!(s.is_empty());
}

#[test]
fn a_newer_state_replaces_the_queued_one_for_its_stream() {
    let mut s = Scheduler::new([1024; 4]);
    s.offer(Class::State, 1, 50, "screen a v1");
    s.offer(Class::State, 2, 50, "screen b v1");
    assert_eq!(s.offer(Class::State, 1, 70, "screen a v2"), Offer::Replaced("screen a v1"));
    assert_eq!(s.queued_bytes(Class::State), 120);
    assert_eq!(drain(&mut s), [(Class::State, "screen a v2"), (Class::State, "screen b v1")]);
}

#[test]
fn full_classes_follow_their_drop_rule() {
    let mut s = Scheduler::new([10, 10, 10, 10]);
    // Input and ordered refuse the newest; nothing is lost silently.
    assert_eq!(s.offer(Class::Input, 0, 8, "k1"), Offer::Queued);
    assert_eq!(s.offer(Class::Input, 0, 8, "k2"), Offer::Refused("k2"));
    // An empty class takes one item even past its bound, so a big item still moves.
    assert_eq!(s.offer(Class::Ordered, 0, 50, "big"), Offer::Queued);
    // Bulk drops its oldest.
    assert_eq!(s.offer(Class::Bulk, 0, 8, "c1"), Offer::Queued);
    assert_eq!(s.offer(Class::Bulk, 0, 8, "c2"), Offer::DroppedOldest("c1"));
    assert_eq!(s.queued_bytes(Class::Bulk), 8);
    // A new stream's state past the bound is refused; its own stream still replaces.
    assert_eq!(s.offer(Class::State, 1, 8, "s1"), Offer::Queued);
    assert_eq!(s.offer(Class::State, 2, 8, "s2"), Offer::Refused("s2"));
    assert_eq!(s.offer(Class::State, 1, 9, "s1b"), Offer::Replaced("s1"));
}
