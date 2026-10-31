//! Loom model of the workspace registry, the journal writer's commit and the
//! late-receipt settle (B3, cmux #28147). The real code (SQLite, the
//! `SignaledMutex`, `parking_lot`'s reentrant connection lock, `Instant`
//! deadlines) does not run under loom, so this is a transcription of the
//! protocol, with the source named at each step:
//!
//! - A request (`mux/resource_effects/effect_commit.rs`): holds the registry,
//!   sends its commit to the journal writer and waits for the receipt, never
//!   holding the connection lock while it waits
//!   (`registry_connection.rs` `is_held_by_current_thread`). Its wait can time
//!   out (a timer thread in the model, so loom tries both orders); a commit
//!   that answers after that is a late receipt, left for the next holder.
//! - The journal writer (`journal_ingress.rs` `run`, rank `JournalWriter`):
//!   takes the connection lock (never the registry), commits, and answers the
//!   waiter or records the late receipt (`take_settled_receipts`).
//! - A pinning holder (`mux/signaled_mutex.rs` `lock_state_pinned`): holds the
//!   registry, pins the connection, locks state, settles every late receipt
//!   (`settle_registry_receipts`) and then publishes only the journal event,
//!   the fix of #28147. The `before_28147` variant also publishes pending
//!   terminal directories, which locks state again: the B3 self-deadlock.
//!
//! Invariants, in every interleaving loom runs:
//! - lock rank order (`lock_rank.rs`): registry -> journal writer ->
//!   connection -> state -> leaf, ascending on every thread (a per-thread
//!   rank stack, as the debug checker keeps);
//! - no deadlock (loom fails a run where every thread is blocked, or a thread
//!   locks a mutex it holds);
//! - every commit's receipt is settled exactly once (by its waiter, or by a
//!   pinning holder when late), and the state revision only goes up;
//! - the `before_28147` variant deadlocks (the model reaches B3: it is red on
//!   the code before the fix; run alone, see its test).
//!
//! Run: `RUSTFLAGS='--cfg loom' cargo test --release -p cmux-tui-loom --test registry_receipt`.
#![cfg(loom)]

use std::cell::RefCell;

use loom::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use loom::sync::{Arc, Condvar, Mutex, MutexGuard};
use loom::thread;

/// Runs `model` in every interleaving loom allows at preemption bound `bound`,
/// then prints the iteration count and the time: the run log shows each model's
/// size, so a model near the job's time limit is named before it passes it.
fn explore_bounded(name: &str, bound: usize, model: impl Fn() + Sync + Send + 'static) {
    static ITERATIONS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    ITERATIONS.store(0, std::sync::atomic::Ordering::Relaxed);
    let started = std::time::Instant::now();
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(bound);
    builder.check(move || {
        ITERATIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        model();
    });
    println!(
        "loom model {name}: {} iterations in {:.1} s at preemption bound {bound}",
        ITERATIONS.load(std::sync::atomic::Ordering::Relaxed),
        started.elapsed().as_secs_f64()
    );
}

/// `lock_rank.rs` `LockRank`, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Rank {
    Registry,
    JournalWriter,
    Connection,
    State,
    Leaf,
}

loom::thread_local! {
    static HELD: RefCell<Vec<Rank>> = RefCell::new(Vec::new());
}

/// A rank held for a scope (the debug checker's `HeldRank`).
struct Held(Rank);

impl Held {
    fn take(rank: Rank) -> Self {
        HELD.with(|held| {
            let mut held = held.borrow_mut();
            if let Some(&top) = held.iter().max() {
                assert!(top < rank, "lock order: {rank:?} taken while holding {top:?}");
            }
            held.push(rank);
        });
        Self(rank)
    }
}

impl Drop for Held {
    fn drop(&mut self) {
        HELD.with(|held| {
            let mut held = held.borrow_mut();
            if let Some(at) = held.iter().rposition(|&r| r == self.0) {
                held.remove(at);
            }
        });
    }
}

fn lock<'a, T>(mutex: &'a Mutex<T>, rank: Rank) -> (Held, MutexGuard<'a, T>) {
    let held = Held::take(rank);
    (held, mutex.lock().unwrap())
}

#[derive(Default)]
struct Receipt {
    answer: Option<u64>,
    timed_out: bool,
}

struct Mux {
    registry: Mutex<()>,
    connection: Mutex<()>,
    state: Mutex<u64>,
    event_bus: Mutex<u64>,
    /// The writer's queue: one commit (its revision).
    commit: Mutex<Option<u64>>,
    commit_ready: Condvar,
    receipt: Mutex<Receipt>,
    receipt_changed: Condvar,
    /// `take_settled_receipts`: late receipts for the next pinning holder.
    settled: Mutex<Vec<u64>>,
    settles: AtomicU64,
    before_28147: bool,
    stop: AtomicBool,
}

impl Mux {
    fn new(before_28147: bool) -> Arc<Self> {
        Arc::new(Self {
            registry: Mutex::new(()),
            connection: Mutex::new(()),
            state: Mutex::new(0),
            event_bus: Mutex::new(0),
            commit: Mutex::new(None),
            commit_ready: Condvar::new(),
            receipt: Mutex::new(Receipt::default()),
            receipt_changed: Condvar::new(),
            settled: Mutex::new(Vec::new()),
            settles: AtomicU64::new(0),
            before_28147,
            stop: AtomicBool::new(false),
        })
    }

    fn apply(state: &mut u64, revision: u64, settles: &AtomicU64) {
        assert!(revision >= 1);
        *state = (*state).max(revision);
        settles.fetch_add(1, Ordering::SeqCst);
    }

    /// The request: commit revision 1 under the registry, wait for its
    /// receipt (or the timer).
    fn request(&self) {
        let (_registry_rank, _registry) = lock(&self.registry, Rank::Registry);
        {
            *self.commit.lock().unwrap() = Some(1);
            self.commit_ready.notify_all();
        }
        let mut receipt = self.receipt.lock().unwrap();
        loop {
            if let Some(revision) = receipt.answer.take() {
                drop(receipt);
                let (_rank, mut state) = lock(&self.state, Rank::State);
                Self::apply(&mut state, revision, &self.settles);
                return;
            }
            if receipt.timed_out {
                // Indeterminate: the writer still owns the commit; its late
                // receipt goes to `settled`.
                return;
            }
            receipt = self.receipt_changed.wait(receipt).unwrap();
        }
    }

    fn timer(&self) {
        let mut receipt = self.receipt.lock().unwrap();
        receipt.timed_out = true;
        self.receipt_changed.notify_all();
    }

    /// The journal writer: one commit, then its receipt.
    fn writer(&self) {
        let _writer_rank = Held::take(Rank::JournalWriter);
        let revision = {
            let mut commit = self.commit.lock().unwrap();
            loop {
                if let Some(revision) = commit.take() {
                    break revision;
                }
                if self.stop.load(Ordering::SeqCst) {
                    return;
                }
                commit = self.commit_ready.wait(commit).unwrap();
            }
        };
        let (_rank, _connection) = lock(&self.connection, Rank::Connection);
        // The commit is durable here. Answer the waiter, or leave it late.
        let mut receipt = self.receipt.lock().unwrap();
        if receipt.timed_out {
            drop(receipt);
            self.settled.lock().unwrap().push(revision);
        } else {
            receipt.answer = Some(revision);
            self.receipt_changed.notify_all();
        }
    }

    /// `lock_state_pinned` + `settle_registry_receipts`.
    fn pin(&self) {
        let (_registry_rank, _registry) = lock(&self.registry, Rank::Registry);
        let (_connection_rank, _connection) = lock(&self.connection, Rank::Connection);
        let (_state_rank, mut state) = lock(&self.state, Rank::State);
        let settled: Vec<u64> = std::mem::take(&mut *self.settled.lock().unwrap());
        if settled.is_empty() {
            return;
        }
        for revision in settled {
            Self::apply(&mut state, revision, &self.settles);
        }
        // publish_journal_event: the event bus, a leaf.
        {
            let (_rank, mut bus) = lock(&self.event_bus, Rank::Leaf);
            *bus += 1;
        }
        if self.before_28147 {
            // publish_resource_event's pending terminal directories: state
            // again, while this thread holds it (the B3 self-deadlock).
            let _again = self.state.lock().unwrap();
        }
    }
}

/// Bound 2 covers B3: the late receipt needs one switch (the timer before the
/// writer's answer), and the pinning holder's settle needs none after that.
fn run(before_28147: bool) {
    let mux = Mux::new(before_28147);
    let writer = {
        let mux = mux.clone();
        thread::spawn(move || mux.writer())
    };
    let timer = {
        let mux = mux.clone();
        thread::spawn(move || mux.timer())
    };
    let pinner = {
        let mux = mux.clone();
        thread::spawn(move || mux.pin())
    };
    mux.request();
    timer.join().unwrap();
    writer.join().unwrap();
    pinner.join().unwrap();
    // The next holder settles what is still late.
    mux.pin();
    assert_eq!(mux.settles.load(Ordering::SeqCst), 1, "a receipt was settled twice or never");
    assert_eq!(*mux.state.lock().unwrap(), 1, "the revision was lost");
}

#[test]
fn a_late_receipt_is_settled_once_without_deadlock() {
    explore_bounded("late_receipt_settle", 2, || run(false));
}

/// Red before #28147: settling a late receipt locked state again. Loom's
/// deadlock panic aborts the process in its cleanup, which `should_panic`
/// cannot catch, so this runs alone: `run-fleet.sh loom registry_receipt`
/// runs it with `--ignored` and requires loom's `deadlock;` report.
#[test]
#[ignore = "the red variant: run-fleet.sh loom requires loom to report its deadlock"]
fn before_28147_the_settle_deadlocks() {
    explore_bounded("before_28147", 2, || run(true));
}
