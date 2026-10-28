//! The journal writer runs a commit attempt at utility only while no request
//! waits on it. Where the platform cannot take utility
//! back (Linux without root or `RLIMIT_NICE`) nothing is lowered.
//!
//! Each check reads the thread's own live value first and compares with it:
//! in a niced process (`nice -n 10 cargo test`) an unprivileged thread
//! started at user-initiated stays at the process's nice value.

use std::sync::Arc;
use std::time::Duration;

use cmux_threads::{LiveQos, ThreadQos};
use cmux_tui_platform::qos::work_qos;

use super::super::{
    JOURNAL_TERMINAL_QUEUE_CAPACITY, JournalIngressEvent, JournalIngressSender,
    PendingRegistryReceipt,
};
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

/// What the kernel reports for a thread that entered `qos`.
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

/// One attempt's classes on a writer thread.
struct Attempt {
    /// The writer thread's live value before the attempt.
    base: LiveQos,
    /// The attempt's class and live value, read inside it.
    inside: (Option<ThreadQos>, LiveQos),
    /// The same after the attempt.
    after: (Option<ThreadQos>, LiveQos),
}

impl Attempt {
    /// Inside the attempt the writer kept its own class.
    fn kept_base(&self) -> bool {
        self.inside == (None, self.base)
    }
}

/// An attempt with `waits` as the writer reads it, on a writer thread.
fn attempt_with(mux: Arc<Mux>, waits: RequestWaits) -> Attempt {
    on(WRITER_QOS, move || {
        let base = cmux_threads::current();
        let attempt = enter_attempt(&mux, &waits);
        let inside = (work_qos(), cmux_threads::current());
        drop(attempt);
        Attempt { base, inside, after: (work_qos(), cmux_threads::current()) }
    })
}

/// An attempt while `waiting` requests wait, counted on the writer thread.
fn attempt_classes(mux: Arc<Mux>, waiting: bool) -> Attempt {
    let waits = RequestWaits::default();
    let wait = waiting.then(|| waits.enter());
    let attempt = attempt_with(mux, waits);
    drop(wait);
    attempt
}

#[test]
fn writer_qos_attempt_no_request_waits_on_runs_at_utility() {
    let mux = Mux::new_for_test("writer-qos-idle", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let attempt = attempt_classes(mux, false);
    if cmux_threads::reversible(IDLE_WRITER_QOS) {
        assert_eq!(attempt.inside, (Some(IDLE_WRITER_QOS), live_at(IDLE_WRITER_QOS)));
    } else {
        assert!(attempt.kept_base(), "{:?} from {:?}", attempt.inside, attempt.base);
    }
    assert_eq!(attempt.after, (None, attempt.base));
}

#[test]
fn writer_qos_attempt_a_request_waits_on_stays_user_initiated() {
    let mux = Mux::new_for_test("writer-qos-waited", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let attempt = attempt_classes(mux, true);
    assert!(attempt.kept_base(), "{:?} from {:?}", attempt.inside, attempt.base);
    assert_eq!(attempt.after, (None, attempt.base));
}

#[test]
fn writer_qos_feature_off_keeps_the_declared_class() {
    let mux = Mux::new_for_test("writer-qos-off", SurfaceOptions::default());
    mux.set_request_qos_for_test(false);
    let attempt = attempt_classes(mux, false);
    assert!(attempt.kept_base(), "{:?} from {:?}", attempt.inside, attempt.base);
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

/// Priority-inversion sites recorded in `file` so far.
#[cfg(debug_assertions)]
fn inversions_in(file: &str) -> Vec<cmux_threads::blocking::BlockingSite> {
    cmux_threads::blocking::snapshot()
        .sites
        .into_iter()
        .filter(|site| site.kinds.contains(cmux_threads::BlockingKind::PriorityInversion))
        .filter(|site| site.file.contains(file))
        .collect()
}

/// An indeterminate registry receipt stays a counted wait after its
/// request returned: the later attempt that answers it runs at the writer's
/// class, and the request that then blocks on it in `drain_unsettled`
/// records no inversion. Taking the answer ends the wait.
#[test]
fn writer_qos_indeterminate_receipt_answered_later_runs_at_the_writer_class() {
    let mux = Mux::new_for_test("writer-qos-indeterminate", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let waits = RequestWaits::default();
    let (answer, receiver) = cmux_threads::sync::mpsc::sync_channel(1);
    let pending = PendingRegistryReceipt::counted(receiver, waits.enter());
    assert!(waits.any(), "the indeterminate receipt is not counted");

    let writer_waits = waits.clone();
    let attempt = on(WRITER_QOS, move || {
        let base = cmux_threads::current();
        let attempt = enter_attempt(&mux, &writer_waits);
        let inside = (work_qos(), cmux_threads::current());
        answer.send(Err("rolled back".to_string())).expect("receipt open");
        drop(attempt);
        Attempt { base, inside, after: (work_qos(), cmux_threads::current()) }
    });
    assert!(attempt.kept_base(), "{:?} from {:?}", attempt.inside, attempt.base);

    let (taken, pending) = on(ThreadQos::UserInitiated, move || {
        let mut pending = pending;
        let taken = pending.wait_take(Duration::from_secs(5), std::panic::Location::caller());
        (taken, pending)
    });
    assert!(matches!(&taken, Some(Err(error)) if error == "rolled back"), "receipt not taken");
    assert!(!waits.any(), "a taken receipt still counts as a wait");
    drop(pending);
    #[cfg(debug_assertions)]
    {
        let inversions = inversions_in("effect_intents.rs");
        assert!(inversions.is_empty(), "receipt sent below the waiting request: {inversions:?}");
    }
}

/// A terminal producer blocked on a full lane waits on the writer: the next
/// attempt stays at the writer's class until the producer's event is queued.
#[test]
fn writer_qos_producer_waiting_for_terminal_queue_space_keeps_the_writer_class() {
    let mux = Mux::new_for_test("writer-qos-full-lane", SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let (sender, receivers) = JournalIngressSender::new(true);
    let receivers = receivers.expect("journal receivers");
    let sender = Arc::new(sender);
    let terminal_id =
        Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 2120)).expect("terminal id"));
    let resize = |occurred_at_ms: u64| JournalIngressEvent::TerminalResize {
        terminal_id: terminal_id.clone(),
        generation: Arc::from("writer-qos-full-lane"),
        occurred_at_ms,
        cols: 80,
        rows: 24,
        cell_width: 8,
        cell_height: 16,
    };
    for index in 0..JOURNAL_TERMINAL_QUEUE_CAPACITY {
        sender.send(resize(u64::try_from(index).expect("index")));
    }
    assert!(!sender.state.request_waits.any());

    let (queue_full, queue_full_receiver) = std::sync::mpsc::sync_channel(1);
    sender.install_enqueue_full_notifier_for_test(queue_full);
    let blocked_sender = sender.clone();
    let blocked_event = resize(u64::MAX);
    let blocked = std::thread::spawn(move || blocked_sender.send(blocked_event));
    queue_full_receiver.recv_timeout(Duration::from_secs(5)).expect("producer blocked");
    assert!(sender.state.request_waits.any(), "the producer waiting for space is not counted");

    let attempt = attempt_with(mux, sender.state.request_waits.clone());
    assert!(attempt.kept_base(), "{:?} from {:?}", attempt.inside, attempt.base);

    receivers.terminal.recv().expect("queued event");
    sender.state.publish_queue_space();
    blocked.join().expect("producer");
    assert!(!sender.state.request_waits.any(), "a queued producer still counts as a wait");
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
    let inversions = inversions_in("journal_ingress");
    assert!(inversions.is_empty(), "receipts sent below the waiting request: {inversions:?}");
    let _ = std::fs::remove_dir_all(root);
}
