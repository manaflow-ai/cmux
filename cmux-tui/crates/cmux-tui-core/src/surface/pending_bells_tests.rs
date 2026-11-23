use super::*;

/// One read that holds thousands of BEL bytes is one `Bell` event, not one per byte: each
/// event takes `Mux::state` and fills every subscriber's mailbox.
#[test]
fn a_read_with_many_bells_publishes_one_bell_event() {
    let mux = Mux::new_for_test("bells", SurfaceOptions::default());
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let events = mux.subscribe();
    let bells = PendingBells::default();
    let mut ring = bells.callback();
    for _ in 0..10_000 {
        ring();
    }
    bells.publish(&Arc::downgrade(&mux), source.id);
    assert!(!events.overflowed(), "one read of bells closed the subscriber");
    let mut published = 0;
    while let Ok(event) = events.try_recv() {
        if matches!(event, MuxEvent::Bell(surface) if surface == source.id) {
            published += 1;
        }
    }
    assert_eq!(published, 1);
}
