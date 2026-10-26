//! The journal writer runs a commit attempt at utility only while no request
//! waits on it (p02-threads-212). Where the platform cannot take utility
//! back (Linux without root or `RLIMIT_NICE`) nothing is lowered.

use std::sync::Arc;

use cmux_threads::{LiveQos, ThreadQos};
use cmux_tui_platform::qos::work_qos;

use super::{IDLE_WRITER_QOS, RequestWaits, WRITER_QOS, enter_attempt};
use crate::resource::TerminalPublicId;
use crate::{Mux, SurfaceOptions};

/// Runs `f` on a registered thread at `qos`, as the writer and the request
/// threads are.
fn on<R: Send + 'static>(qos: ThreadQos, f: impl FnOnce() -> R + Send + 'static) -> R {
    cmux_threads::spawn("journal-writer-qos-test", qos, f)
        .expect("spawn")
        .join()
        .expect("test thread")
}

/// What the kernel reports for a thread running at `qos`.
fn live_at(qos: ThreadQos) -> LiveQos {
    #[cfg(target_vendor = "apple")]
    {
        LiveQos::Class(qos)
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        LiveQos::Nice(qos.linux_nice())
    }
    #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
    {
        let _ = qos;
        LiveQos::Unknown
    }
}

/// The class an attempt runs at, read inside it, and the class after it.
fn attempt_classes(
    mux: Arc<Mux>,
    waiting: bool,
) -> ((Option<ThreadQos>, LiveQos), (Option<ThreadQos>, LiveQos)) {
    on(WRITER_QOS, move || {
        let waits = RequestWaits::default();
        let wait = waiting.then(|| waits.enter());
        let attempt = enter_attempt(&mux, &waits);
        let inside = (work_qos(), cmux_threads::current());
        drop(attempt);
        drop(wait);
        (inside, (work_qos(), cmux_threads::current()))
    })
}

#[test]
fn writer_qos_attempt_no_request_waits_on_runs_at_utility() {
    let mux = Mux::new_for_test("writer-qos-idle", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let (inside, after) = attempt_classes(mux, false);
    if cmux_threads::reversible(IDLE_WRITER_QOS) {
        assert_eq!(inside, (Some(IDLE_WRITER_QOS), live_at(IDLE_WRITER_QOS)));
    } else {
        assert_eq!(inside, (None, live_at(WRITER_QOS)));
    }
    assert_eq!(after, (None, live_at(WRITER_QOS)));
}

#[test]
fn writer_qos_attempt_a_request_waits_on_stays_user_initiated() {
    let mux = Mux::new_for_test("writer-qos-waited", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let (inside, after) = attempt_classes(mux, true);
    assert_eq!(inside, (None, live_at(WRITER_QOS)));
    assert_eq!(after, (None, live_at(WRITER_QOS)));
}

#[test]
fn writer_qos_feature_off_keeps_the_declared_class() {
    let mux = Mux::new_for_test("writer-qos-off", SurfaceOptions::default());
    mux.set_request_qos_for_test(false);
    let (inside, _) = attempt_classes(mux, false);
    assert_eq!(inside, (None, live_at(WRITER_QOS)));
}

#[test]
fn writer_qos_request_waits_count_until_the_guard_drops() {
    let waits = RequestWaits::default();
    assert!(!waits.any());
    let first = waits.enter();
    let second = waits.enter();
    drop(first);
    assert!(waits.any());
    drop(second);
    assert!(!waits.any());
}

/// Receipts reach a user-initiated request from the writer at its class:
/// 0 `priority-inversion` sites in the ingress (cmux_threads::sync, task
/// 206), while background batches between the waits let the writer drop to
/// utility.
#[cfg(debug_assertions)]
#[test]
fn writer_qos_user_initiated_request_records_no_inversion_on_its_receipts() {
    let root = std::env::temp_dir().join(format!(
        "cmux-writer-qos-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("writer-qos-receipts", SurfaceOptions::default(), &root)
        .expect("persistent mux");
    mux.set_request_qos_for_test(true);
    let terminal_id =
        Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 212)).expect("terminal id"));
    on(ThreadQos::UserInitiated, move || {
        for round in 0..16_u8 {
            mux.journal_terminal_output(
                terminal_id.clone(),
                Arc::from("writer-qos-generation"),
                vec![b'a' + round % 26],
            );
            mux.flush_terminal_journal().expect("durable flush");
        }
        mux.shutdown();
    });
    let inversions = cmux_threads::blocking::snapshot()
        .sites
        .into_iter()
        .filter(|site| site.kinds.contains(cmux_threads::BlockingKind::PriorityInversion))
        .filter(|site| site.file.contains("journal_ingress"))
        .collect::<Vec<_>>();
    assert!(inversions.is_empty(), "receipts sent below the waiting request: {inversions:?}");
    let _ = std::fs::remove_dir_all(root);
}
