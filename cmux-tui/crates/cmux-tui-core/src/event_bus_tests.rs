//! The per-subscriber mailbox: adjacent `TreeChanged` collapsing and predicate filters.

use super::*;

fn drain(receiver: &MuxEventReceiver) -> Vec<MuxEvent> {
    std::iter::from_fn(|| receiver.try_recv().ok()).collect()
}

fn kinds(events: &[MuxEvent]) -> Vec<&'static str> {
    events
        .iter()
        .map(|event| match event {
            MuxEvent::TreeChanged => "tree",
            MuxEvent::TreeSelectionChanged(_) => "selection",
            MuxEvent::TitleChanged { .. } => "title",
            MuxEvent::Empty => "empty",
            _ => "other",
        })
        .collect()
}

#[test]
fn a_tree_changed_right_behind_an_unread_one_is_dropped() {
    let bus = MuxEventBroadcaster::default();
    let receiver = bus.subscribe();
    for _ in 0..5 {
        bus.emit(MuxEvent::TreeChanged);
    }
    assert_eq!(kinds(&drain(&receiver)), ["tree"]);

    // Once read, the next one is delivered again.
    bus.emit(MuxEvent::TreeChanged);
    assert_eq!(kinds(&drain(&receiver)), ["tree"]);
}

#[test]
fn a_tree_changed_after_another_event_is_kept_in_order() {
    let bus = MuxEventBroadcaster::default();
    let receiver = bus.subscribe();
    bus.emit(MuxEvent::TreeChanged);
    bus.emit(MuxEvent::TreeSelectionChanged(None));
    bus.emit(MuxEvent::TreeChanged);
    // A coalesced event newer than the queued TreeChanged keeps the next one too.
    bus.emit(MuxEvent::terminal_title(7, Arc::from("t")));
    bus.emit(MuxEvent::TreeChanged);
    bus.emit(MuxEvent::TreeChanged);
    assert_eq!(kinds(&drain(&receiver)), ["tree", "selection", "tree", "title", "tree"]);
}

#[test]
fn a_matching_subscriber_gets_only_what_its_predicate_takes() {
    let bus = MuxEventBroadcaster::default();
    let all = bus.subscribe();
    let trees = bus.subscribe_matching(|event| matches!(event, MuxEvent::TreeSelectionChanged(_)));
    bus.emit(MuxEvent::terminal_title(3, Arc::from("busy")));
    bus.emit(MuxEvent::TreeSelectionChanged(None));
    bus.emit(MuxEvent::TreeChanged);
    assert_eq!(kinds(&drain(&trees)), ["selection"]);
    assert_eq!(kinds(&drain(&all)), ["title", "selection", "tree"]);
}

#[test]
fn a_matching_subscriber_never_overflows_on_events_it_does_not_take() {
    let bus = MuxEventBroadcaster::default();
    let trees = bus.subscribe_matching(|event| matches!(event, MuxEvent::TreeChanged));
    for _ in 0..MAX_PENDING_EVENTS + 10 {
        bus.emit(MuxEvent::TreeSelectionChanged(None));
    }
    assert!(!trees.overflowed());
    bus.emit(MuxEvent::TreeChanged);
    assert_eq!(kinds(&drain(&trees)), ["tree"]);
}
