//! The envelope cause `Mux::emit` stamps on subscriber events
//! (crate::event_cause): the scope's cause or `Program` outside one, scopes
//! that nest and restore, coalescing that keeps the higher cause, and a
//! terminal's own OSC title that stays `Program` whoever created the
//! terminal. The connection paths (CLI and app requests, pool commits) are
//! in server/event_cause_tests.rs.

use std::sync::Arc;
#[cfg(unix)]
use std::time::{Duration, Instant};

use crate::SurfaceOptions;
use crate::event_bus::MuxEventReceiver;
use crate::event_cause::{EventCause, EventCauseScope};
use crate::mux::{Mux, MuxEvent};
use crate::request_origin::RequestOrigin;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("event-cause-{label}"), SurfaceOptions::default())
}

fn drain(events: &MuxEventReceiver) -> Vec<(MuxEvent, EventCause)> {
    std::iter::from_fn(|| events.try_recv_caused().ok()).collect()
}

fn causes(events: &MuxEventReceiver) -> Vec<EventCause> {
    drain(events).into_iter().map(|(_, cause)| cause).collect()
}

fn title(surface: u64, text: &str) -> MuxEvent {
    MuxEvent::TitleChanged { surface, title: Arc::from(text) }
}

#[test]
fn event_cause_follows_the_request_origin() {
    assert_eq!(RequestOrigin::User.event_cause(), EventCause::Frontend);
    assert_eq!(RequestOrigin::Agent.event_cause(), EventCause::Automation);
    assert_eq!(RequestOrigin::Page.event_cause(), EventCause::Automation);
    assert_eq!(RequestOrigin::App.event_cause(), EventCause::Automation);
}

#[test]
fn event_cause_of_an_unscoped_emit_is_program() {
    let mux = mux("unscoped");
    let events = mux.subscribe();
    mux.emit(MuxEvent::TreeChanged);
    assert_eq!(causes(&events), vec![EventCause::Program]);
}

#[test]
fn event_cause_scopes_nest_and_restore() {
    let mux = mux("nest");
    let events = mux.subscribe();
    {
        let _automation = EventCauseScope::enter(EventCause::Automation);
        mux.emit(MuxEvent::TreeChanged);
        {
            let _frontend = EventCauseScope::enter(EventCause::Frontend);
            mux.emit(MuxEvent::TreeChanged);
        }
        mux.emit(MuxEvent::TreeChanged);
    }
    mux.emit(MuxEvent::TreeChanged);
    assert_eq!(
        causes(&events),
        vec![
            EventCause::Automation,
            EventCause::Frontend,
            EventCause::Automation,
            EventCause::Program
        ]
    );
}

#[test]
fn event_cause_scope_does_not_reach_another_thread() {
    let mux = mux("thread");
    let events = mux.subscribe();
    let _frontend = EventCauseScope::enter(EventCause::Frontend);
    std::thread::spawn(move || mux.emit(MuxEvent::TreeChanged)).join().unwrap();
    assert_eq!(causes(&events), vec![EventCause::Program]);
}

/// A coalesced latest-state event keeps the higher of the folded causes,
/// in the order frontend, program, automation.
#[test]
fn event_cause_coalesced_events_keep_the_higher_cause() {
    let mux = mux("coalesce");
    let events = mux.subscribe();
    let emit = |cause: EventCause, text: &str| {
        let _scope = EventCauseScope::enter(cause);
        mux.emit(title(7, text));
    };
    emit(EventCause::Frontend, "person");
    emit(EventCause::Automation, "agent");
    emit(EventCause::Program, "first");
    emit(EventCause::Automation, "second");
    let drained = drain(&events);
    assert_eq!(drained.len(), 1, "one pending title per surface");
    let (event, cause) = &drained[0];
    assert!(matches!(event, MuxEvent::TitleChanged { title, .. } if title.as_ref() == "second"));
    assert_eq!(*cause, EventCause::Frontend);

    emit(EventCause::Automation, "agent");
    emit(EventCause::Program, "program");
    assert_eq!(causes(&events), vec![EventCause::Program]);
    emit(EventCause::Automation, "only agent");
    assert_eq!(causes(&events), vec![EventCause::Automation]);
}

/// The title a program sets with OSC 2 is the program's, also when an
/// agent's request created its terminal: the PTY reader is never in a scope.
#[cfg(unix)]
#[test]
fn event_cause_of_an_osc_title_is_program() {
    let mux = Mux::new(
        "event-cause-osc-title",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "printf '\\033]2;osc title\\007'; exec cat".to_string(),
            ]),
            ..SurfaceOptions::default()
        },
    );
    let events = mux.subscribe();
    let surface = {
        let _automation = EventCauseScope::enter(EventCause::Automation);
        mux.new_workspace(None, Some((20, 4))).unwrap()
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    let cause = loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let caused = events.recv_caused_timeout(remaining).expect("the OSC title");
        if let (MuxEvent::TitleChanged { surface: id, title }, cause) = caused
            && id == surface.id
            && title.as_ref() == "osc title"
        {
            break cause;
        }
    };
    assert_eq!(cause, EventCause::Program);
    mux.shutdown();
}

/// Authorization reads the request origin, never the scheduling cause.
#[test]
fn event_cause_is_never_read_by_authorization() {
    for (file, source) in [
        ("server/origin_gate.rs", include_str!("../server/origin_gate.rs")),
        ("server/app_trust.rs", include_str!("../server/app_trust.rs")),
    ] {
        for needle in ["EventCause", "event_cause"] {
            assert!(!source.contains(needle), "{file} reads the event cause ({needle})");
        }
    }
}
