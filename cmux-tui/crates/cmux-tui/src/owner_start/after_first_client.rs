//! The owner's "after first client" gate (plans/cmux-next/chrome-parity/p08-startup.md, task 094).
//!
//! A headless owner's background work (network checks, crash forwarding, the
//! memory guard, pollers, plugins, apps, Chief brains, reapers) does not run
//! while its first client connects: it starts once a control connection has
//! attached its first surface (identify and the snapshot are served by then),
//! or after [`STARTUP_BUDGET`] when no client comes. This is Chrome's
//! after-startup queue (chrome/browser/after_startup_task_utils.cc: tasks
//! wait for the first paint of the initial tab, with a failsafe), with a
//! 5 s failsafe because cmux clients are local.
//!
//! The gate is one thread at [`ThreadQos::Utility`] that waits on a mux event
//! subscription with the remaining budget as its timeout (no polling). It
//! only marks the work due and wakes the owner loop; the owner thread starts
//! the work, so on Linux the processes that work spawns keep nice 0.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_threads::ThreadQos;
use cmux_tui_core::{Mux, MuxEvent, MuxEventReceiver};

/// How long background work waits for a first client at most.
pub(crate) const STARTUP_BUDGET: Duration = Duration::from_secs(5);
/// The gate thread's name.
pub(crate) const THREAD_NAME: &str = "owner-first-client";

/// What one wait on the subscription saw.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Seen {
    /// A control connection attached its first surface.
    ClientAttached,
    /// Any other event.
    Other,
    /// The wait's timeout passed.
    TimedOut,
    /// The subscription closed: `overflowed` when the mailbox overflowed,
    /// otherwise the owner cancelled the gate.
    Closed { overflowed: bool },
}

/// Why the gate ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Outcome {
    /// A client attached first.
    FirstClient,
    /// The budget ran out first, or the subscription overflowed (a busy
    /// owner, so not one to keep waiting on).
    Budget,
    /// The owner is stopping: nothing starts.
    Cancelled,
}

/// The gate's time source (a fake one in tests).
pub(super) trait Clock {
    fn now(&self) -> Instant;
}

struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// Waits until a client attaches, `budget` passes on `clock`, or the
/// subscription closes. `next(remaining)` blocks for one event for at most
/// `remaining`. Events that are not an attach never extend the budget.
pub(super) fn wait(
    clock: &dyn Clock,
    budget: Duration,
    mut next: impl FnMut(Duration) -> Seen,
) -> Outcome {
    let deadline = clock.now() + budget;
    loop {
        let remaining = deadline.saturating_duration_since(clock.now());
        if remaining.is_zero() {
            return Outcome::Budget;
        }
        match next(remaining) {
            Seen::ClientAttached => return Outcome::FirstClient,
            Seen::Other | Seen::TimedOut => {}
            Seen::Closed { overflowed: true } => return Outcome::Budget,
            Seen::Closed { overflowed: false } => return Outcome::Cancelled,
        }
    }
}

fn seen(receiver: &MuxEventReceiver, remaining: Duration) -> Seen {
    // wakeup-allow: deadline the one startup budget, never extended; the gate thread ends at it
    match receiver.recv_timeout(remaining) {
        Ok(MuxEvent::ClientAttached { .. }) => Seen::ClientAttached,
        Ok(_) => Seen::Other,
        Err(RecvTimeoutError::Timeout) => Seen::TimedOut,
        Err(RecvTimeoutError::Disconnected) => Seen::Closed { overflowed: receiver.overflowed() },
    }
}

/// The running gate. Subscribe it before the owner serves clients.
pub(crate) struct FirstClientGate {
    due: Arc<AtomicBool>,
    subscription: MuxEventReceiver,
    thread: Option<JoinHandle<()>>,
}

impl FirstClientGate {
    /// Subscribes to `mux` and starts the gate thread; `wake` runs once the
    /// work is due, after [`Self::take_due`] reads true. Err when the thread
    /// cannot start: the caller then starts the work at once.
    pub(crate) fn start(mux: &Mux, wake: fn()) -> std::io::Result<Self> {
        let subscription = mux.subscribe();
        let due = Arc::new(AtomicBool::new(false));
        let (receiver, marked) = (subscription.clone(), due.clone());
        let thread = cmux_threads::spawn(THREAD_NAME, ThreadQos::Utility, move || {
            let outcome =
                wait(&SystemClock, STARTUP_BUDGET, |remaining| seen(&receiver, remaining));
            receiver.close();
            if outcome != Outcome::Cancelled {
                crate::client_log::info(
                    "startup",
                    &format!("owner background work starts ({outcome:?})"),
                );
                marked.store(true, Ordering::Release);
                wake();
            }
        })?;
        Ok(Self { due, subscription, thread: Some(thread) })
    }

    /// True once, when the work is due.
    pub(crate) fn take_due(&self) -> bool {
        self.due.swap(false, Ordering::AcqRel)
    }

    /// Ends the gate: a gate still waiting starts nothing. Joins the thread.
    pub(crate) fn stop(mut self) {
        self.subscription.close();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for FirstClientGate {
    /// A gate dropped on a failed start ends without starting anything.
    fn drop(&mut self) {
        self.subscription.close();
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::collections::VecDeque;

    use super::*;

    struct FakeClock(Cell<Instant>);

    impl FakeClock {
        fn new() -> Self {
            Self(Cell::new(Instant::now()))
        }

        fn advance(&self, by: Duration) {
            self.0.set(self.0.get() + by);
        }
    }

    impl Clock for FakeClock {
        fn now(&self) -> Instant {
            self.0.get()
        }
    }

    /// Plays `script`: each step takes `after` of fake time (capped at the
    /// wait's timeout, which is then a timeout) and sees its event. An empty
    /// script times out every wait. Returns the outcome and the fake time
    /// the gate took.
    fn run(script: &[(Duration, Seen)]) -> (Outcome, Duration) {
        let clock = FakeClock::new();
        let started = clock.now();
        let mut steps: VecDeque<_> = script.iter().copied().collect();
        let outcome = wait(&clock, STARTUP_BUDGET, |remaining| match steps.pop_front() {
            Some((after, event)) if after < remaining => {
                clock.advance(after);
                event
            }
            _ => {
                clock.advance(remaining);
                Seen::TimedOut
            }
        });
        (outcome, clock.now() - started)
    }

    #[test]
    fn the_first_attach_starts_the_work_before_the_budget() {
        let ms = Duration::from_millis;
        let (outcome, took) =
            run(&[(ms(40), Seen::Other), (ms(80), Seen::Other), (ms(30), Seen::ClientAttached)]);
        assert_eq!(outcome, Outcome::FirstClient);
        assert_eq!(took, ms(150));
    }

    #[test]
    fn with_no_client_the_work_starts_at_the_budget_and_events_do_not_extend_it() {
        let (outcome, took) = run(&[]);
        assert_eq!((outcome, took), (Outcome::Budget, STARTUP_BUDGET));
        let busy: Vec<_> = (0..20).map(|_| (Duration::from_millis(300), Seen::Other)).collect();
        let (outcome, took) = run(&busy);
        assert_eq!((outcome, took), (Outcome::Budget, STARTUP_BUDGET));
    }

    #[test]
    fn an_attach_after_the_budget_is_too_late_to_matter() {
        let (outcome, took) = run(&[(Duration::from_secs(6), Seen::ClientAttached)]);
        assert_eq!((outcome, took), (Outcome::Budget, STARTUP_BUDGET));
    }

    #[test]
    fn a_cancelled_gate_starts_nothing_and_an_overflowed_one_starts_at_once() {
        let second = Duration::from_secs(1);
        let (outcome, took) = run(&[(second, Seen::Closed { overflowed: false })]);
        assert_eq!((outcome, took), (Outcome::Cancelled, second));
        let (outcome, took) = run(&[(second, Seen::Closed { overflowed: true })]);
        assert_eq!((outcome, took), (Outcome::Budget, second));
    }

    /// The QoS the gate thread declared, read on that thread when it wakes
    /// the owner (`ThreadQos as u8 + 1`; 0 before any wake).
    static WOKE_AT: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

    fn record_wake() {
        let declared = cmux_threads::snapshot()
            .into_iter()
            .find(|row| row.name == THREAD_NAME)
            .map_or(0, |row| row.declared as u8 + 1);
        WOKE_AT.store(declared, Ordering::SeqCst);
    }

    #[test]
    fn a_real_attach_wakes_the_owner_from_a_utility_thread_and_a_stopped_gate_starts_nothing() {
        let mux = Mux::new("after-first-client-test", Default::default());
        // Stopped before any client: the work never becomes due.
        let gate = FirstClientGate::start(&mux, record_wake).expect("the gate thread starts");
        gate.stop();
        assert_eq!(WOKE_AT.load(Ordering::SeqCst), 0, "a stopped gate must not wake the owner");

        // An attach queued before the stop is still seen: events are read
        // before the closed subscription.
        let gate = FirstClientGate::start(&mux, record_wake).expect("the gate thread starts");
        mux.emit(MuxEvent::ClientAttached {
            client: 1,
            transport: "unix".into(),
            name: None,
            kind: None,
        });
        let due = Arc::clone(&gate.due);
        gate.stop();
        assert!(due.load(Ordering::SeqCst), "the attach marks the work due");
        assert_eq!(WOKE_AT.load(Ordering::SeqCst), ThreadQos::Utility as u8 + 1);
        assert!(
            !cmux_threads::snapshot().iter().any(|row| row.name == THREAD_NAME),
            "stop joins the gate thread"
        );
        mux.shutdown();
    }
}
