//! The request class gate and the cause scope (crate::request_qos). The
//! classes each scope entered on this thread are noted, so a test can see
//! the class a request asked for also where the platform refuses it (Linux
//! without `RLIMIT_NICE`).

use std::cell::RefCell;

use cmux_threads::ThreadQos;

use super::{FEATURE, RequestQosGate};
use crate::event_cause::EventCause;

thread_local! {
    static ENTERED: RefCell<Vec<ThreadQos>> = const { RefCell::new(Vec::new()) };
}

pub(super) fn note_entered(class: ThreadQos) {
    ENTERED.with(|entered| entered.borrow_mut().push(class));
}

/// The classes cause scopes entered on this thread since the last call.
pub(crate) fn take_entered() -> Vec<ThreadQos> {
    ENTERED.with(|entered| std::mem::take(&mut *entered.borrow_mut()))
}

#[test]
fn request_qos_gate_reads_the_feature_lists() {
    fn on(enable: Option<&str>, disable: Option<&str>) -> bool {
        RequestQosGate::from_lists(enable, disable).snapshot().enabled
    }
    assert!(!on(None, None), "off by default");
    assert!(on(Some(FEATURE), None));
    assert!(on(Some(&format!("other, {FEATURE} ,")), None));
    assert!(!on(Some(FEATURE), Some(FEATURE)), "disable wins");
    assert!(!on(Some("daemonrequestqos"), None), "names are exact");
}

#[test]
fn request_qos_scope_enters_the_class_only_with_the_feature_on() {
    std::thread::spawn(|| {
        let gate = RequestQosGate::default();
        {
            let _scope = gate.snapshot().enter(EventCause::Automation);
            assert_eq!(EventCause::current(), EventCause::Automation);
            assert_eq!(cmux_tui_platform::qos::work_qos(), None);
        }
        assert!(take_entered().is_empty(), "the feature is off");

        gate.set_for_test(true);
        for (cause, class) in [
            (EventCause::Automation, Some(ThreadQos::Utility)),
            (EventCause::Frontend, Some(ThreadQos::UserInitiated)),
            (EventCause::Program, None),
        ] {
            {
                let _scope = gate.snapshot().enter(cause);
                assert_eq!(EventCause::current(), cause);
            }
            assert_eq!(take_entered(), Vec::from_iter(class), "{cause:?}");
            assert_eq!(cmux_tui_platform::qos::work_qos(), None, "{cause:?}: restored");
        }
    })
    .join()
    .expect("scope thread");
}

/// An upkeep pass (output store writer, journal retention and maintenance)
/// at utility is raised to user-initiated while it holds a hot terminal: a
/// PTY reader that waits for that terminal never waits behind a utility
/// thread. Where utility cannot be taken back (Linux without root or
/// `RLIMIT_NICE`) the pass is not lowered and nothing is raised.
#[test]
fn request_qos_upkeep_pass_holding_a_hot_terminal_runs_user_initiated() {
    use std::sync::Arc;

    use cmux_threads::LiveQos;
    use cmux_tui_platform::qos::{boosted, work_qos};

    use super::{UPKEEP_PASS_QOS, UPKEEP_THREAD_QOS};
    use crate::surface::Surface;
    use crate::{Mux, SurfaceOptions};

    let mux = Mux::new_for_test("upkeep-pass-hot-terminal", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let surface = Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux))
        .expect("terminal surface");
    let pass_mux = mux.clone();
    let (base, lowered, held, after) =
        cmux_threads::spawn("mux-output-store-writer-test", UPKEEP_THREAD_QOS, move || {
            let base = cmux_threads::current();
            let pass = pass_mux.request_qos().enter_upkeep_pass();
            let lowered = work_qos();
            let held = surface
                .try_with_hot_terminal(|_| (boosted(), cmux_threads::current()))
                .expect("terminal")
                .expect("hot terminal");
            drop(pass);
            (base, lowered, held, cmux_threads::current())
        })
        .expect("spawn")
        .join()
        .expect("upkeep thread");
    if cmux_threads::reversible(UPKEEP_PASS_QOS) {
        assert_eq!(lowered, Some(UPKEEP_PASS_QOS));
        #[cfg(target_vendor = "apple")]
        let raised = LiveQos::Class(ThreadQos::UserInitiated);
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let raised = LiveQos::Nice(ThreadQos::UserInitiated.linux_nice());
        #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
        let raised = LiveQos::Unknown;
        assert_eq!(held, (true, raised), "the terminal holder was not raised");
    } else {
        assert_eq!(lowered, None);
        assert_eq!(held, (false, base));
    }
    assert_eq!(after, base);
    drop(mux);
}

/// What a request helper reads in its body: its declared class, its work
/// class and its live class (`qos_class_self` on macOS, nice on Linux).
type HelperReads = (ThreadQos, Option<ThreadQos>, cmux_threads::LiveQos);

/// Starts a request helper from a creator at the echo class, as a person's
/// reader is (a plain thread would inherit that class), with `cause` as the
/// creator's request cause.
fn helper_reads(enabled: bool, cause: EventCause) -> HelperReads {
    use super::RequestQos;
    let creator = cmux_threads::spawn(
        "mux-helper-creator-test",
        crate::echo_thread::ECHO_PATH_QOS,
        move || {
            let _cause = crate::event_cause::EventCauseScope::enter(cause);
            RequestQos { enabled }
                .spawn_helper("mux-helper-test", Some(256 * 1024), || {
                    let declared = cmux_threads::current_slot().expect("registered").declared();
                    (declared, cmux_tui_platform::qos::work_qos(), cmux_threads::current())
                })
                .expect("spawn the helper")
                .join()
                .expect("the helper returns")
        },
    );
    creator.expect("spawn the creator").join().expect("the creator returns")
}

/// A request's one-shot helper (p05-ipc-080) starts at the dispatcher's
/// class, never the class it would inherit from its creator, and with the
/// feature on runs at the class of the request's cause; with it off it
/// keeps its declared class.
#[test]
fn request_qos_helper_starts_at_the_dispatcher_class_and_runs_at_the_cause_class() {
    use super::REQUEST_HELPER_QOS;

    let (declared, work, live) = helper_reads(false, EventCause::Automation);
    assert_eq!(declared, REQUEST_HELPER_QOS);
    assert_eq!(work, None, "the feature is off");
    #[cfg(target_vendor = "apple")]
    assert_eq!(live, cmux_threads::LiveQos::Class(REQUEST_HELPER_QOS), "not the echo class");
    let _ = live;

    let (declared, work, live) = helper_reads(true, EventCause::Automation);
    assert_eq!(declared, REQUEST_HELPER_QOS);
    if cmux_threads::reversible(ThreadQos::Utility) {
        assert_eq!(work, Some(ThreadQos::Utility), "an automation request's class");
        #[cfg(target_vendor = "apple")]
        assert_eq!(live, cmux_threads::LiveQos::Class(ThreadQos::Utility));
    } else {
        assert_eq!(work, None, "a class the process cannot take back is not entered");
    }
    let _ = live;

    let (_, work, _) = helper_reads(true, EventCause::Frontend);
    assert_eq!(work, Some(ThreadQos::UserInitiated), "a person's request's class");
    let (_, work, _) = helper_reads(true, EventCause::Program);
    assert_eq!(work, None, "program work keeps the declared class");
}
