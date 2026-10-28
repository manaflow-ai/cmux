//! The request class gate and the cause scope (crate::request_qos). The
//! classes each scope and each upkeep or `enter_class` pass entered on this
//! thread are noted, so a test can see the class a request asked for also
//! where the platform refuses it (Linux without `RLIMIT_NICE`).

use std::cell::RefCell;
use std::sync::{Arc, Mutex};

use cmux_threads::ThreadQos;

use super::{FEATURE, RequestQosGate};
use crate::event_cause::EventCause;

/// The classes noted for one test thread, shared with the threads its
/// requests continue on ([`follow_recorder`]).
pub(crate) type Recorder = Arc<Mutex<Vec<ThreadQos>>>;

thread_local! {
    static ENTERED: RefCell<Recorder> = RefCell::new(Recorder::default());
}

pub(super) fn note_entered(class: ThreadQos) {
    ENTERED.with(|entered| entered.borrow().lock().unwrap().push(class));
}

/// The classes cause scopes and passes entered on this thread, and on
/// threads that followed its recorder, since the last call.
pub(crate) fn take_entered() -> Vec<ThreadQos> {
    ENTERED.with(|entered| std::mem::take(&mut *entered.borrow().lock().unwrap()))
}

/// This thread's recorder, for the thread a request continues on.
pub(crate) fn recorder() -> Recorder {
    ENTERED.with(|entered| entered.borrow().clone())
}

/// Runs `f` noting into `recorder`: a request handed from a test thread to
/// a work item notes its classes where the test reads them.
pub(crate) fn follow_recorder<R>(recorder: Recorder, f: impl FnOnce() -> R) -> R {
    let previous = ENTERED.with(|entered| entered.replace(recorder));
    let result = f();
    ENTERED.with(|entered| *entered.borrow_mut() = previous);
    result
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

/// What `cmux_threads::current` reads for a thread running at `class`.
pub(crate) fn live_at(class: ThreadQos) -> cmux_threads::LiveQos {
    #[cfg(target_vendor = "apple")]
    return cmux_threads::LiveQos::Class(class);
    #[cfg(any(target_os = "linux", target_os = "android"))]
    return cmux_threads::LiveQos::Nice(class.linux_nice());
    #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
    {
        let _ = class;
        cmux_threads::LiveQos::Unknown
    }
}

/// What a request helper reads in its body (its declared class, its work
/// class, its live class), with what its creator read in its own: its live
/// class and, per class, `cmux_threads::reachable` (a helper starts at its
/// creator's class or nice, so it reaches the same classes).
struct HelperReads {
    declared: ThreadQos,
    work: Option<ThreadQos>,
    live: cmux_threads::LiveQos,
    creator_live: cmux_threads::LiveQos,
    reachable: [bool; 5],
}

impl HelperReads {
    /// The work class the helper enters: its cause's class where it can
    /// enter it and take it back.
    fn expected_work(&self, enabled: bool, cause: EventCause) -> Option<ThreadQos> {
        cause.request_qos().filter(|&class| {
            enabled && cmux_threads::reversible(class) && self.reachable[class as usize]
        })
    }

    /// The class the helper runs at: its work class, else its declared class
    /// where it could reach it, else its creator's.
    fn expected_live(&self, enabled: bool, cause: EventCause) -> cmux_threads::LiveQos {
        self.expected_work(enabled, cause)
            .or_else(|| self.reachable[self.declared as usize].then_some(self.declared))
            .map_or(self.creator_live, live_at)
    }
}

/// Starts a request helper from a creator at the echo class, as a person's
/// reader is (a plain thread would inherit that class), with `cause` as the
/// creator's request cause. Every class is read inside the thread bodies.
fn helper_reads(enabled: bool, cause: EventCause) -> HelperReads {
    use super::RequestQos;
    let creator = cmux_threads::spawn(
        "mux-helper-creator-test",
        crate::echo_thread::ECHO_PATH_QOS,
        move || {
            let _cause = crate::event_cause::EventCauseScope::enter(cause);
            let creator_live = cmux_threads::current();
            let reachable = ThreadQos::ALL.map(cmux_threads::reachable);
            let (declared, work, live) = RequestQos { enabled }
                .spawn_helper("mux-helper-test", || {
                    let declared = cmux_threads::current_slot().expect("registered").declared();
                    (declared, cmux_tui_platform::qos::work_qos(), cmux_threads::current())
                })
                .expect("spawn the helper")
                .join()
                .expect("the helper returns");
            HelperReads { declared, work, live, creator_live, reachable }
        },
    );
    creator.expect("spawn the creator").join().expect("the creator returns")
}

/// A request's one-shot helper starts at the dispatcher's
/// class, never the class it would inherit from its creator, and with the
/// feature on runs at the class of the request's cause; with it off it
/// keeps its declared class. Where the process cannot reach a class (Linux
/// under `nice` without `RLIMIT_NICE`) the helper stays where it started.
#[test]
fn request_qos_helper_starts_at_the_dispatcher_class_and_runs_at_the_cause_class() {
    use super::REQUEST_HELPER_QOS;

    for enabled in [false, true] {
        for cause in [EventCause::Frontend, EventCause::Automation, EventCause::Program] {
            let reads = helper_reads(enabled, cause);
            let context = format!("enabled {enabled}, {cause:?}");
            assert_eq!(reads.declared, REQUEST_HELPER_QOS, "{context}");
            assert_eq!(reads.work, reads.expected_work(enabled, cause), "{context}");
            assert_eq!(reads.live, reads.expected_live(enabled, cause), "{context}");
            #[cfg(target_vendor = "apple")]
            assert_ne!(
                reads.live,
                live_at(crate::echo_thread::ECHO_PATH_QOS),
                "{context}: not the echo class it would inherit"
            );
        }
    }
    // Where the classes are reachable (macOS; Linux at nice 0 or with the
    // right to lower nice), a person's request runs at user-initiated.
    let reads = helper_reads(true, EventCause::Frontend);
    if reads.reachable[ThreadQos::UserInitiated as usize] {
        assert_eq!(reads.work, Some(ThreadQos::UserInitiated), "a person's request's class");
    }
}
