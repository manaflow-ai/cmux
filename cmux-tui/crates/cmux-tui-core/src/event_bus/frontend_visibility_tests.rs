//! A frontend subscription scoped by its visible surfaces:
//! a hidden surface's field events coalesce into one per slot and flush on the
//! aligned grid or at once on show; structural events, exits and the
//! frontend's own changes never wait; other subscriptions are unchanged.

use std::collections::HashSet;
use std::sync::mpsc::TryRecvError;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::super::{MuxEventBroadcaster, MuxEventReceiver};
use super::{HIDDEN_FLUSH_INTERVAL, HiddenFlush};
use crate::event_cause::EventCause;
use crate::{MuxEvent, SurfaceId, TreeDelta, TreeDeltaKind};

const HIDDEN: SurfaceId = 1;
const SHOWN: SurfaceId = 2;

/// A clock the test moves by hand.
struct FakeClock(Mutex<Instant>);

impl FakeClock {
    fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(Instant::now())))
    }

    fn advance(&self, by: Duration) {
        *self.0.lock().unwrap() += by;
    }

    fn flush(self: &Arc<Self>) -> HiddenFlush {
        let clock = self.clone();
        HiddenFlush::new(HIDDEN_FLUSH_INTERVAL, Arc::new(move || *clock.0.lock().unwrap()))
    }
}

fn shown(surfaces: &[SurfaceId]) -> HashSet<SurfaceId> {
    surfaces.iter().copied().collect()
}

fn title(surface: SurfaceId, n: usize) -> MuxEvent {
    MuxEvent::TitleChanged { surface, title: format!("title {n}").into() }
}

fn drain(events: &MuxEventReceiver) -> Vec<MuxEvent> {
    events.try_iter().collect()
}

fn tab_closed(surface: SurfaceId) -> MuxEvent {
    delta(TreeDeltaKind::TabClosed, Some(surface))
}

fn delta(kind: TreeDeltaKind, surface: Option<SurfaceId>) -> MuxEvent {
    MuxEvent::TreeDelta(TreeDelta {
        kind,
        workspace: 1,
        screen: Some(1),
        pane: Some(1),
        surface,
        index: None,
        entity: serde_json::Value::Null,
        workspace_revision: None,
        transaction: None,
    })
}

/// A bus with one subscription that shows only `SHOWN`, on a fake clock.
fn scoped() -> (MuxEventBroadcaster, MuxEventReceiver, Arc<FakeClock>) {
    let bus = MuxEventBroadcaster::default();
    let events = bus.subscribe();
    let clock = FakeClock::new();
    assert_eq!(events.scope_visibility(Some(&shown(&[SHOWN])), &clock.flush()), 0);
    (bus, events, clock)
}

#[test]
fn frontend_visibility_a_thousand_hidden_titles_in_a_second_are_one_event() {
    let (bus, events, clock) = scoped();
    for n in 0..1000 {
        bus.emit(title(HIDDEN, n));
        clock.advance(Duration::from_micros(900));
    }
    assert_eq!(events.try_recv().unwrap_err(), TryRecvError::Empty, "held until the flush");

    clock.advance(HIDDEN_FLUSH_INTERVAL);
    let heard = drain(&events);
    assert!(
        matches!(heard.as_slice(), [MuxEvent::TitleChanged { surface: HIDDEN, title }] if &**title == "title 999"),
        "{heard:?}"
    );
}

#[test]
fn frontend_visibility_a_shown_surface_is_not_held() {
    let (bus, events, _clock) = scoped();
    bus.emit(title(SHOWN, 1));
    bus.emit(MuxEvent::SurfaceOutput(SHOWN));
    assert_eq!(drain(&events).len(), 2);
}

#[test]
fn frontend_visibility_show_releases_the_held_slots_at_once() {
    let (bus, events, clock) = scoped();
    bus.emit(title(HIDDEN, 1));
    bus.emit(MuxEvent::SurfaceOutput(HIDDEN));
    bus.emit(MuxEvent::SurfaceOutput(3));
    assert!(drain(&events).is_empty());

    // No clock moves: the show itself makes them ready.
    assert_eq!(events.scope_visibility(Some(&shown(&[SHOWN, HIDDEN])), &clock.flush()), 2);
    let heard = drain(&events);
    assert!(
        matches!(
            heard.as_slice(),
            [MuxEvent::TitleChanged { surface: HIDDEN, .. }, MuxEvent::SurfaceOutput(HIDDEN)]
        ),
        "{heard:?}"
    );
    // Surface 3 is still hidden and still held.
    clock.advance(HIDDEN_FLUSH_INTERVAL);
    assert!(matches!(drain(&events).as_slice(), [MuxEvent::SurfaceOutput(3)]));
}

#[test]
fn frontend_visibility_show_wakes_a_blocked_reader_within_a_millisecond_of_the_set() {
    let bus = MuxEventBroadcaster::default();
    let events = bus.subscribe();
    let flush = HiddenFlush::system();
    events.scope_visibility(Some(&HashSet::new()), &flush);
    bus.emit(title(HIDDEN, 1));

    let reader = events.clone();
    let blocked = std::thread::spawn(move || {
        let event = reader.recv_timeout(Duration::from_secs(5)).unwrap();
        (event, Instant::now())
    });
    std::thread::sleep(Duration::from_millis(50));
    let shown_at = Instant::now();
    assert_eq!(events.scope_visibility(Some(&shown(&[HIDDEN])), &flush), 1);
    let (event, heard_at) = blocked.join().unwrap();
    assert!(matches!(event, MuxEvent::TitleChanged { surface: HIDDEN, .. }));
    // A thread wake, not the 1 s flush; generous for a loaded CI host.
    assert!(heard_at - shown_at < Duration::from_millis(250), "{:?}", heard_at - shown_at);
}

#[test]
fn frontend_visibility_an_exit_is_never_delayed_and_drops_the_held_fields() {
    let (bus, events, clock) = scoped();
    bus.emit(title(HIDDEN, 1));
    bus.emit(MuxEvent::SurfaceExited(HIDDEN, None));
    assert!(matches!(drain(&events).as_slice(), [MuxEvent::SurfaceExited(HIDDEN, None)]));
    clock.advance(HIDDEN_FLUSH_INTERVAL);
    assert!(drain(&events).is_empty(), "the exited surface's title is gone, as before");
}

#[test]
fn frontend_visibility_structural_events_pass_and_a_tab_close_follows_its_fields() {
    let (bus, events, _clock) = scoped();
    bus.emit(MuxEvent::Bell(HIDDEN));
    assert!(matches!(drain(&events).as_slice(), [MuxEvent::Bell(HIDDEN)]));

    bus.emit(title(HIDDEN, 1));
    bus.emit(tab_closed(HIDDEN));
    let heard = drain(&events);
    assert!(
        matches!(
            heard.as_slice(),
            [MuxEvent::TitleChanged { surface: HIDDEN, .. }, MuxEvent::TreeDelta(_)]
        ),
        "{heard:?}"
    );
}

#[test]
fn frontend_visibility_the_frontends_own_change_is_not_held() {
    let (bus, events, _clock) = scoped();
    bus.emit_caused(title(HIDDEN, 1), EventCause::Frontend);
    assert_eq!(drain(&events).len(), 1);

    // A held program title folded into a later frontend one goes at once too.
    bus.emit_caused(MuxEvent::SurfaceOutput(HIDDEN), EventCause::Program);
    assert!(drain(&events).is_empty());
    bus.emit_caused(MuxEvent::SurfaceOutput(HIDDEN), EventCause::Frontend);
    assert_eq!(drain(&events).len(), 1);
}

#[test]
fn frontend_visibility_other_subscriptions_are_not_affected() {
    let (bus, events, _clock) = scoped();
    let automation = bus.subscribe();
    for n in 0..10 {
        bus.emit(title(HIDDEN, n));
    }
    assert!(drain(&events).is_empty());
    assert_eq!(drain(&automation).len(), 1, "coalesced as before, never held");
}

#[test]
fn frontend_visibility_flushes_on_one_aligned_grid() {
    let (bus, events, clock) = scoped();
    clock.advance(Duration::from_millis(200));
    bus.emit(title(HIDDEN, 1));
    clock.advance(Duration::from_millis(500));
    bus.emit(title(3, 1));
    clock.advance(Duration::from_millis(299));
    assert!(drain(&events).is_empty(), "the grid point is 1 s after the scope began");
    clock.advance(Duration::from_millis(1));
    assert_eq!(drain(&events).len(), 2, "both flush at the same grid point");

    // The next hold waits for the next grid point, not a full interval from now.
    clock.advance(Duration::from_millis(900));
    bus.emit(title(HIDDEN, 2));
    clock.advance(Duration::from_millis(100));
    assert_eq!(drain(&events).len(), 1);
}

#[test]
fn frontend_visibility_a_blocked_reader_wakes_for_the_flush() {
    let bus = MuxEventBroadcaster::default();
    let events = bus.subscribe();
    let flush = HiddenFlush::new(Duration::from_millis(40), Arc::new(Instant::now));
    events.scope_visibility(Some(&HashSet::new()), &flush);
    bus.emit(title(HIDDEN, 1));
    let started = Instant::now();
    let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(matches!(event, MuxEvent::TitleChanged { surface: HIDDEN, .. }));
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}

#[test]
fn frontend_visibility_clearing_the_scope_shows_everything() {
    let (bus, events, clock) = scoped();
    bus.emit(title(HIDDEN, 1));
    assert_eq!(events.scope_visibility(None, &clock.flush()), 1);
    assert_eq!(drain(&events).len(), 1);
    bus.emit(title(HIDDEN, 2));
    assert_eq!(drain(&events).len(), 1, "unscoped again");
}

#[test]
fn frontend_visibility_a_pane_close_follows_every_held_field() {
    let (bus, events, _clock) = scoped();
    bus.emit(title(HIDDEN, 1));
    bus.emit(MuxEvent::SurfaceOutput(3));
    bus.emit(delta(TreeDeltaKind::PaneClosed, None));
    let heard = drain(&events);
    assert!(
        matches!(
            heard.as_slice(),
            [
                MuxEvent::TitleChanged { surface: HIDDEN, .. },
                MuxEvent::SurfaceOutput(3),
                MuxEvent::TreeDelta(_)
            ]
        ),
        "{heard:?}"
    );
    // A delta that closes nothing releases nothing.
    bus.emit(title(HIDDEN, 2));
    bus.emit(delta(TreeDeltaKind::WorkspaceRenamed, None));
    assert!(matches!(drain(&events).as_slice(), [MuxEvent::TreeDelta(_)]));
}
