//! The state and registry locks raise an automation request's thread while
//! it holds them (p06-scheduler-035, crate::lock_rank `raises_holder`,
//! cmux_tui_platform::qos). Where the platform refuses the UTILITY class
//! (Linux without `RLIMIT_NICE`, or under `nice`) nothing is lowered and
//! nothing is raised.

use std::sync::Arc;

use cmux_threads::ThreadQos;
use cmux_tui_platform::qos::{WorkQos, boosted, work_qos};

use crate::SurfaceOptions;
use crate::event_cause::EventCause;
use crate::mux::Mux;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("lock-qos-{label}"), SurfaceOptions::default())
}

#[test]
fn qos_request_class_follows_its_cause() {
    assert_eq!(EventCause::Frontend.request_qos(), Some(ThreadQos::UserInitiated));
    assert_eq!(EventCause::Automation.request_qos(), Some(ThreadQos::Utility));
    assert_eq!(EventCause::Program.request_qos(), None);
}

#[test]
fn qos_automation_holder_of_the_state_or_registry_lock_is_raised() {
    let mux = mux("holder");
    std::thread::spawn(move || {
        let request = WorkQos::enter(ThreadQos::Utility);
        let lowered = request.applied();

        let state = mux.state.lock().expect("state");
        assert_eq!(boosted(), lowered, "mux.state");
        drop(state);
        assert!(!boosted());

        let registry = mux.workspace_registry.lock().expect("registry");
        assert_eq!(boosted(), lowered, "workspace.registry");
        {
            // Registry, then connection, then state: one raise for all.
            let pinned = mux.lock_state_pinned(&registry).expect("pinned state");
            assert_eq!(boosted(), lowered, "registry.connection and mux.state");
            drop(pinned);
        }
        assert_eq!(boosted(), lowered, "the registry is still held");
        drop(registry);
        assert!(!boosted(), "every lock released");
        assert_eq!(work_qos(), lowered.then_some(ThreadQos::Utility));
    })
    .join()
    .expect("holder thread");
}

#[test]
fn qos_frontend_holder_is_not_raised() {
    let mux = mux("frontend");
    std::thread::spawn(move || {
        let _request = WorkQos::enter(ThreadQos::UserInitiated);
        let state = mux.state.lock().expect("state");
        assert!(!boosted(), "a USER_INITIATED holder needs no raise");
        drop(state);
    })
    .join()
    .expect("frontend thread");
}
