//! The bus fan-out: scoped subscribers indexed by
//! surface, one shared event per emit, delivery outside `Mux::state` in
//! state order, the frontend served first, and per-subscriber order kept.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;

use super::{MuxEventBroadcaster, MuxEventFilter, MuxEventMailbox, MuxEventReceiver};
use crate::event_cause::EventCause;
use crate::{MuxEvent, SurfaceId, SurfaceOptions, TreeDelta, TreeDeltaKind};

const SESSIONS: u64 = 500;

fn title(surface: SurfaceId, text: &str) -> MuxEvent {
    MuxEvent::TitleChanged { surface, title: Arc::from(text) }
}

fn history(revision: u64) -> MuxEvent {
    MuxEvent::HistoryChanged { revision, kinds: Vec::new() }
}

fn delta(kind: TreeDeltaKind, workspace: u64, screen: u64, pane: u64, surface: u64) -> MuxEvent {
    MuxEvent::TreeDelta(TreeDelta {
        kind,
        workspace,
        screen: Some(screen),
        pane: Some(pane),
        surface: Some(surface),
        index: None,
        entity: Value::Null,
        workspace_revision: None,
        transaction: None,
    })
}

/// Surface `n`'s session lives in workspace 100 + n, screen 200 + n and
/// pane 300 + n.
fn session(bus: &MuxEventBroadcaster, surface: SurfaceId) -> MuxEventReceiver {
    bus.subscribe_surface_session(surface, 100 + surface, 200 + surface, 300 + surface)
}

fn filter_runs(bus: &MuxEventBroadcaster) -> usize {
    bus.bus.subscribers.lock().unwrap().stats.filter_runs
}

fn pushes(bus: &MuxEventBroadcaster) -> Vec<usize> {
    bus.bus.subscribers.lock().unwrap().stats.pushes.clone()
}

fn mailbox_id(receiver: &MuxEventReceiver) -> usize {
    Arc::as_ptr(&receiver.mailbox) as usize
}

fn shared(receiver: &MuxEventReceiver) -> Option<Arc<MuxEvent>> {
    receiver.mailbox.state.lock().unwrap().pop_shared().map(|(event, _)| event)
}

fn heard(receiver: &MuxEventReceiver) -> Vec<String> {
    receiver.try_iter().map(|event| format!("{event:?}")).collect()
}

fn mux(label: &str) -> Arc<crate::mux::Mux> {
    crate::mux::Mux::new_for_test(format!("event-bus-{label}"), SurfaceOptions::default())
}

#[test]
fn five_hundred_sessions_run_one_filter_for_a_title() {
    let bus = MuxEventBroadcaster::default();
    let sessions: Vec<_> = (0..SESSIONS).map(|surface| session(&bus, surface)).collect();
    let before = filter_runs(&bus);

    bus.emit(title(7, "build"));

    assert_eq!(filter_runs(&bus) - before, 1);
    for (surface, receiver) in (0..SESSIONS).zip(&sessions) {
        let heard = heard(receiver);
        assert_eq!(heard.len(), usize::from(surface == 7), "surface {surface}: {heard:?}");
    }
}

#[test]
fn every_subscriber_shares_the_one_emitted_event() {
    let bus = MuxEventBroadcaster::default();
    let receivers: Vec<_> = (0..SESSIONS).map(|_| bus.subscribe()).collect();

    bus.emit(history(3));

    let events: Vec<_> =
        receivers.iter().map(|receiver| shared(receiver).expect("heard history")).collect();
    assert!(events.iter().all(|event| Arc::ptr_eq(event, &events[0])), "an event was copied");
    assert_eq!(Arc::strong_count(&events[0]), receivers.len());
}

/// The index only prunes: every subscriber hears exactly what its own
/// filter accepts, in order, as if every filter ran on every event.
#[test]
fn indexed_delivery_matches_running_every_filter() {
    let bus = MuxEventBroadcaster::default();
    let filters = || {
        vec![
            MuxEventFilter::All,
            MuxEventFilter::TerminalTopology,
            MuxEventFilter::LaunchSnapshot,
            MuxEventFilter::AttachedSurface(1),
            MuxEventFilter::AttachedSurface(2),
            MuxEventFilter::SurfaceSession(super::SurfaceSessionScope {
                surface: 1,
                workspace: 101,
                screen: 201,
                pane: 301,
            }),
            MuxEventFilter::SurfaceSession(super::SurfaceSessionScope {
                surface: 2,
                workspace: 102,
                screen: 202,
                pane: 302,
            }),
            MuxEventFilter::SurfaceSession(super::SurfaceSessionScope {
                surface: 3,
                workspace: 103,
                screen: 203,
                pane: 303,
            }),
        ]
    };
    let receivers: Vec<_> =
        filters().into_iter().map(|filter| bus.subscribe_as(filter, false)).collect();
    let events = vec![
        title(1, "one"),
        MuxEvent::SurfaceOutput(2),
        MuxEvent::ScrollChanged { surface: 1, offset: 4, at_bottom: false },
        MuxEvent::Bell(9),
        MuxEvent::Status("ready".to_owned()),
        MuxEvent::TreeChanged,
        delta(TreeDeltaKind::TabAdded, 102, 210, 310, 2),
        delta(TreeDeltaKind::PaneClosed, 102, 210, 310, 0),
        delta(TreeDeltaKind::PaneClosed, 103, 203, 303, 0),
        delta(TreeDeltaKind::ScreenClosed, 101, 201, 0, 0),
        delta(TreeDeltaKind::WorkspaceAdded, 104, 204, 304, 4),
        delta(TreeDeltaKind::TabRenamed, 101, 201, 301, 1),
        history(5),
        MuxEvent::SurfaceExited(3, None),
        delta(TreeDeltaKind::WorkspaceClosed, 103, 0, 0, 0),
    ];
    for event in &events {
        bus.emit(event.clone());
    }

    for (mut filter, receiver) in filters().into_iter().zip(&receivers) {
        let expected = MuxEventMailbox::default();
        for event in &events {
            if filter.accepts(event) {
                expected.push(Arc::new(event.clone()), EventCause::Program);
            }
        }
        let expected = MuxEventReceiver { mailbox: Arc::new(expected) };
        assert_eq!(heard(receiver), heard(&expected));
    }
}

#[test]
fn an_emit_under_the_state_lock_is_delivered_once_it_is_released() {
    let mux = mux("under-state");
    let events = mux.subscribe();
    {
        let _state = mux.state.lock().unwrap();
        mux.emit(history(1));
        mux.emit(history(2));
        assert!(events.try_recv().is_err(), "the fan-out ran under Mux::state");
    }
    assert_eq!(heard(&events), [format!("{:?}", history(1)), format!("{:?}", history(2))]);
}

/// Debug and test builds: the fan-out refuses to run while the thread holds
/// the `Mux::state` rank. The test above, which emits under the real state
/// lock and does not panic, shows an emit never reaches it there.
#[cfg(debug_assertions)]
#[test]
#[should_panic(expected = "the mux event fan-out ran while this thread holds")]
fn the_fan_out_refuses_to_run_under_the_state_rank() {
    let bus = MuxEventBroadcaster::default();
    let _rank =
        crate::lock_rank::HeldRank::record(crate::lock_rank::LockRank::MuxState, "mux.state");
    bus.bus.deliver_queued();
}

/// Emits made under the state lock reach every subscriber in state order,
/// whichever thread releases first.
#[test]
fn emits_under_the_state_lock_keep_state_order_across_threads() {
    const PER_THREAD: u64 = 400;
    let mux = mux("state-order");
    let events = mux.subscribe();
    let next = Arc::new(AtomicU64::new(0));
    let threads: Vec<_> = (0..2)
        .map(|_| {
            let (mux, next) = (Arc::clone(&mux), Arc::clone(&next));
            std::thread::spawn(move || {
                for _ in 0..PER_THREAD {
                    let _state = mux.state.lock().unwrap();
                    mux.emit(history(next.fetch_add(1, Ordering::Relaxed)));
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().expect("emitter");
    }

    let revisions: Vec<u64> = events
        .try_iter()
        .map(|event| match event {
            MuxEvent::HistoryChanged { revision, .. } => revision,
            other => panic!("unexpected {other:?}"),
        })
        .collect();
    assert_eq!(revisions, (0..2 * PER_THREAD).collect::<Vec<_>>());
}

#[test]
fn a_subscriber_hears_nothing_queued_before_it_subscribed() {
    let mux = mux("since");
    let early = mux.subscribe();
    let late = {
        let _state = mux.state.lock().unwrap();
        mux.emit(history(1));
        mux.subscribe()
    };
    mux.emit(history(2));

    assert_eq!(heard(&early).len(), 2);
    assert_eq!(heard(&late), [format!("{:?}", history(2))]);
}

#[test]
fn the_frontend_is_served_first() {
    let bus = MuxEventBroadcaster::default();
    let automation: Vec<_> = (0..8).map(|_| bus.subscribe()).collect();
    let sessions: Vec<_> = (0..8).map(|surface| session(&bus, surface)).collect();
    let frontend = bus.subscribe_frontend();

    bus.emit(history(1));
    bus.emit(MuxEvent::Status("ready".to_owned()));

    let per_emit = automation.len() + sessions.len() + 1;
    let pushes = pushes(&bus);
    assert_eq!(pushes.len(), 2 * per_emit);
    for emit in pushes.chunks(per_emit) {
        assert_eq!(emit[0], mailbox_id(&frontend));
    }
    assert_eq!(heard(&frontend).len(), 2);
}

#[test]
fn a_session_path_update_moves_only_its_surface_in_order() {
    let bus = MuxEventBroadcaster::default();
    let moved = session(&bus, 1);
    let other = session(&bus, 2);

    bus.emit(title(1, "before"));
    bus.update_surface_session_path(1, 900, 901, 902);
    // The old pane closing no longer reaches the moved session; its new
    // pane's does.
    bus.emit(delta(TreeDeltaKind::PaneClosed, 101, 201, 301, 0));
    bus.emit(delta(TreeDeltaKind::PaneClosed, 900, 901, 902, 0));

    let moved = heard(&moved);
    assert_eq!(moved.len(), 3, "{moved:?}");
    assert_eq!(moved[0], format!("{:?}", title(1, "before")));
    assert_eq!(moved[1], format!("{:?}", MuxEvent::TreeChanged));
    assert_eq!(moved[2], format!("{:?}", delta(TreeDeltaKind::PaneClosed, 900, 901, 902, 0)));
    assert!(heard(&other).is_empty());
}

#[test]
fn a_dropped_scoped_subscriber_leaves_the_index() {
    let bus = MuxEventBroadcaster::default();
    drop(session(&bus, 4));
    let kept = session(&bus, 5);

    bus.emit(title(4, "gone"));

    let subscribers = bus.bus.subscribers.lock().unwrap();
    assert!(!subscribers.by_surface.contains_key(&4));
    assert_eq!(subscribers.by_surface.get(&5).map(Vec::len), Some(1));
    drop(subscribers);
    drop(kept);
}
