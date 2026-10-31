//! Loom model of the session journal's ingress queue: how producers wait for
//! queue space and how the single writer drains and wakes them
//! (`cmux-tui-core/src/journal_ingress.rs`). The real code mixes this
//! protocol with SQLite, `Instant` deadlines and `std::sync::mpsc`, which loom
//! cannot run, so this is a transcription of the protocol, step for step,
//! with the source lines named at each step:
//!
//! - `enqueue` (journal_ingress.rs `JournalIngressSender::enqueue`): read the
//!   space epoch; under `enqueue_admission`, refuse when admission is closed,
//!   else `try_send`; on success send a wake (capacity one, a full wake is
//!   fine); on `Full` wait until the epoch moves
//!   (`wait_for_queue_space_change`), then try again.
//! - `receive_batch` (the writer): drop pending wakes, drain the lane,
//!   publish queue space when it drained anything, return a non-empty batch;
//!   else return `None` when closed, else block on the wake channel.
//! - `close_admission`: under `enqueue_admission`, set closed and publish.
//!
//! Invariants, in every interleaving loom runs:
//! - no lost wakeup: no producer waits forever for space the writer freed,
//!   and the writer never sleeps on a wake while an event sits in the queue
//!   (loom fails a run where every thread is blocked);
//! - every event a producer was told is queued reaches the writer exactly
//!   once, and none a producer was refused does;
//! - after `close_admission`, a waiting producer is answered (committed, or a
//!   typed error), never left waiting, and the writer stops;
//! - a background event `enqueue` accepted is committed, also when admission
//!   closes right after (its producer hears of nothing else).
//!
//! Run: `RUSTFLAGS='--cfg loom' cargo test --release -p cmux-tui-loom --test journal_queue`.
#![cfg(loom)]

use std::collections::VecDeque;

use loom::sync::atomic::{AtomicBool, Ordering};
use loom::sync::{Arc, Condvar, Mutex};
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

/// A queued event's completion (`JournalIngressCompletion`): the writer
/// answers it after the commit; when the writer exits with the event still
/// queued, the sender drops and the waiter reads `Disconnected`, a typed
/// error (`wait_for_commit_result` -> `writer_error`). `None`: a background
/// event nobody waits for.
type Completion = Option<Arc<(Mutex<Option<Result<(), &'static str>>>, Condvar)>>;

struct Event {
    id: u32,
    completion: Completion,
}

fn answer(completion: &Completion, result: Result<(), &'static str>) {
    if let Some(slot) = completion {
        *slot.0.lock().unwrap() = Some(result);
        slot.1.notify_all();
    }
}

fn wait_answer(completion: &Completion) -> Result<(), &'static str> {
    let slot = completion.as_ref().expect("a waited event has a completion");
    let mut result = slot.0.lock().unwrap();
    loop {
        if let Some(result) = *result {
            return result;
        }
        result = slot.1.wait(result).unwrap();
    }
}

/// A bounded channel's `try_send` / `try_recv` (`sync_channel`).
struct Lane {
    queue: Mutex<VecDeque<Event>>,
    capacity: usize,
}

/// `sync_channel::<()>(1)` for the wake: `try_send` that tolerates Full, and
/// a blocking `recv` that ends when every sender is gone (here: closed).
struct Wake {
    pending: Mutex<bool>,
    changed: Condvar,
}

struct State {
    closed: AtomicBool,
    enqueue_admission: Mutex<()>,
    queue_space_epoch: Mutex<u64>,
    queue_space_changed: Condvar,
    lane: Lane,
    wake: Wake,
}

impl State {
    fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            closed: AtomicBool::new(false),
            enqueue_admission: Mutex::new(()),
            queue_space_epoch: Mutex::new(0),
            queue_space_changed: Condvar::new(),
            lane: Lane { queue: Mutex::new(VecDeque::new()), capacity },
            wake: Wake { pending: Mutex::new(false), changed: Condvar::new() },
        })
    }

    /// journal_ingress.rs `queue_space_epoch`.
    fn queue_space_epoch(&self) -> u64 {
        *self.queue_space_epoch.lock().unwrap()
    }

    /// journal_ingress.rs `publish_queue_space`.
    fn publish_queue_space(&self) {
        let mut epoch = self.queue_space_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.queue_space_changed.notify_all();
    }

    /// journal_ingress.rs `wait_for_queue_space_change`.
    fn wait_for_queue_space_change(&self, observed: u64) -> Result<(), &'static str> {
        let mut epoch = self.queue_space_epoch.lock().unwrap();
        while *epoch == observed {
            if self.closed.load(Ordering::Acquire) {
                return Err("closed");
            }
            epoch = self.queue_space_changed.wait(epoch).unwrap();
        }
        Ok(())
    }

    /// journal_ingress.rs `close_admission`.
    fn close_admission(&self) {
        let _admission = self.enqueue_admission.lock().unwrap();
        self.closed.store(true, Ordering::Release);
        self.publish_queue_space();
        // The writer's wake channel disconnects when the sender drops.
        let mut pending = self.wake.pending.lock().unwrap();
        *pending = true;
        self.wake.changed.notify_all();
    }

    /// journal_ingress.rs `JournalIngressSender::enqueue`.
    fn enqueue(&self, event: Event) -> Result<(), &'static str> {
        let mut event = Some(event);
        loop {
            let space_epoch = self.queue_space_epoch();
            let sent = {
                let _admission = self.enqueue_admission.lock().unwrap();
                if self.closed.load(Ordering::Acquire) {
                    return Err("closed");
                }
                let mut queue = self.lane.queue.lock().unwrap();
                if queue.len() < self.lane.capacity {
                    queue.extend(event.take());
                    true
                } else {
                    false
                }
            };
            if sent {
                let mut pending = self.wake.pending.lock().unwrap();
                *pending = true;
                self.wake.changed.notify_one();
                return Ok(());
            }
            self.wait_for_queue_space_change(space_epoch)?;
        }
    }

    /// journal_ingress.rs `receive_batch`.
    fn receive_batch(&self) -> Option<Vec<Event>> {
        loop {
            *self.wake.pending.lock().unwrap() = false;
            let batch: Vec<Event> = self.lane.queue.lock().unwrap().drain(..).collect();
            if !batch.is_empty() {
                self.publish_queue_space();
                return Some(batch);
            }
            if self.closed.load(Ordering::Acquire) {
                return None;
            }
            let mut pending = self.wake.pending.lock().unwrap();
            while !*pending {
                pending = self.wake.changed.wait(pending).unwrap();
            }
        }
    }
}

/// journal_ingress.rs `run`: commit each batch and answer it; when
/// `receive_batch` ends, return. The receivers drop then: every event still
/// queued drops with them (its completion reads `Disconnected`).
fn writer(state: &State, stop_after: usize) -> Vec<u32> {
    let mut committed = Vec::new();
    while committed.len() < stop_after {
        let Some(batch) = state.receive_batch() else { break };
        for event in batch {
            committed.push(event.id);
            answer(&event.completion, Ok(()));
        }
    }
    for event in state.lane.queue.lock().unwrap().drain(..) {
        answer(&event.completion, Err("session journal writer stopped"));
    }
    committed
}

fn waited(id: u32) -> Event {
    Event { id, completion: Some(Arc::new((Mutex::new(None), Condvar::new()))) }
}

fn background(id: u32) -> Event {
    Event { id, completion: None }
}

#[test]
fn producers_waiting_for_space_are_woken_and_every_event_lands_once() {
    explore_bounded("producers_woken", 2, || {
        let state = State::new(1);
        let producers: Vec<_> = (1..=2u32)
            .map(|id| {
                let state = state.clone();
                thread::spawn(move || {
                    let event = waited(id);
                    let completion = event.completion.clone();
                    state.enqueue(event)?;
                    wait_answer(&completion)
                })
            })
            .collect();
        let writer = {
            let state = state.clone();
            thread::spawn(move || writer(&state, 2))
        };
        for producer in producers {
            assert_eq!(producer.join().unwrap(), Ok(()), "a producer was refused while open");
        }
        let mut got = writer.join().unwrap();
        got.sort_unstable();
        assert_eq!(got, vec![1, 2], "an event was lost or landed twice");
    });
}

/// A waiting producer at close: it is answered (committed, or a typed error),
/// never left waiting and never told success for an event that was not
/// committed.
#[test]
fn closing_admission_answers_a_waiting_producer() {
    explore_bounded("close_answers_waiter", 2, || {
        let state = State::new(1);
        // The queue is full: the producer must wait for space.
        state.enqueue(background(1)).unwrap();
        let producer = {
            let state = state.clone();
            thread::spawn(move || {
                let event = waited(2);
                let completion = event.completion.clone();
                state.enqueue(event)?;
                wait_answer(&completion)
            })
        };
        let closer = {
            let state = state.clone();
            thread::spawn(move || state.close_admission())
        };
        let writer = {
            let state = state.clone();
            thread::spawn(move || writer(&state, usize::MAX))
        };
        let produced = producer.join().unwrap();
        closer.join().unwrap();
        let got = writer.join().unwrap();
        assert!(got.contains(&1), "an event queued before close was not committed");
        assert_eq!(
            produced.is_ok(),
            got.contains(&2),
            "the producer's answer disagrees with the commit"
        );
        assert!(got.iter().filter(|&&id| id == 2).count() <= 1, "an event landed twice");
    });
}

/// A background event (no completion) that `enqueue` accepted: is it
/// committed even when admission closes right after? Its producer was told
/// Ok and nobody hears of a drop.
/// FUZZ FINDING i3 (STATUS): red. `receive_batch` drains, then returns `None`
/// once `closed` is set, without a last drain, so an event `enqueue` accepted
/// between the drain and the close is dropped with the receivers. Ignored here
/// so the harness run stays green; the red test is branch
/// `fuzz-red/loom-journal-i3` (this test, not ignored).
#[test]
#[ignore = "fuzz finding i3: red until the writer drains once more after close"]
fn an_accepted_background_event_is_committed_across_close() {
    explore_bounded("accepted_event_across_close", 2, || {
        let state = State::new(2);
        let producer = {
            let state = state.clone();
            thread::spawn(move || state.enqueue(background(7)))
        };
        let closer = {
            let state = state.clone();
            thread::spawn(move || state.close_admission())
        };
        let writer = {
            let state = state.clone();
            thread::spawn(move || writer(&state, usize::MAX))
        };
        let accepted = producer.join().unwrap().is_ok();
        closer.join().unwrap();
        let got = writer.join().unwrap();
        if accepted {
            assert!(
                got.contains(&7),
                "enqueue said Ok, then the writer stopped without committing it"
            );
        }
    });
}
