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
