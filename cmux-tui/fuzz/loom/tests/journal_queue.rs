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
//! - after `close_admission`, a waiting producer returns an error instead of
//!   waiting, and the writer stops once the queue is empty.
//!
//! Run: `RUSTFLAGS='--cfg loom' cargo test --release -p cmux-tui-loom --test journal_queue`.
#![cfg(loom)]

use std::collections::VecDeque;

use loom::sync::atomic::{AtomicBool, Ordering};
use loom::sync::{Arc, Condvar, Mutex};
use loom::thread;

fn explore(model: impl Fn() + Sync + Send + 'static) {
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(2);
    builder.check(model);
}

/// A bounded channel's `try_send` / `try_recv` (`sync_channel`).
struct Lane {
    queue: Mutex<VecDeque<u32>>,
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
    fn enqueue(&self, event: u32) -> Result<(), &'static str> {
        loop {
            let space_epoch = self.queue_space_epoch();
            let sent = {
                let _admission = self.enqueue_admission.lock().unwrap();
                if self.closed.load(Ordering::Acquire) {
                    return Err("closed");
                }
                let mut queue = self.lane.queue.lock().unwrap();
                if queue.len() < self.lane.capacity {
                    queue.push_back(event);
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
    fn receive_batch(&self) -> Option<Vec<u32>> {
        loop {
            *self.wake.pending.lock().unwrap() = false;
            let batch: Vec<u32> = self.lane.queue.lock().unwrap().drain(..).collect();
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

#[test]
fn producers_waiting_for_space_are_woken_and_every_event_lands_once() {
    explore(|| {
        let state = State::new(1);
        let producers: Vec<_> = (1..=2u32)
            .map(|event| {
                let state = state.clone();
                thread::spawn(move || state.enqueue(event))
            })
            .collect();
        let writer = {
            let state = state.clone();
            thread::spawn(move || {
                let mut got = Vec::new();
                while got.len() < 2 {
                    match state.receive_batch() {
                        Some(batch) => got.extend(batch),
                        None => break,
                    }
                }
                got
            })
        };
        for producer in producers {
            assert_eq!(producer.join().unwrap(), Ok(()), "a producer was refused while open");
        }
        let mut got = writer.join().unwrap();
        got.sort_unstable();
        assert_eq!(got, vec![1, 2], "an event was lost or landed twice");
    });
}

#[test]
fn closing_admission_releases_a_waiting_producer_and_stops_the_writer() {
    explore(|| {
        let state = State::new(1);
        // The queue is full: the producer must wait for space.
        state.enqueue(1).unwrap();
        let producer = {
            let state = state.clone();
            thread::spawn(move || state.enqueue(2))
        };
        let closer = {
            let state = state.clone();
            thread::spawn(move || state.close_admission())
        };
        let writer = {
            let state = state.clone();
            thread::spawn(move || {
                let mut got = Vec::new();
                while let Some(batch) = state.receive_batch() {
                    got.extend(batch);
                }
                got
            })
        };
        let produced = producer.join().unwrap();
        closer.join().unwrap();
        let got = writer.join().unwrap();
        assert!(got.contains(&1), "a queued event was dropped at close");
        match produced {
            Ok(()) => assert!(got.contains(&2), "an accepted event was dropped at close"),
            Err(_) => assert!(!got.contains(&2), "a refused event reached the writer"),
        }
        assert_eq!(got.len(), if produced.is_ok() { 2 } else { 1 }, "an event landed twice");
    });
}
