//! A terminal's input FIFO: turns run one at a time, in the order they were
//! taken, and rank after `Mux::state` and before the terminal lock.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::PtyInputFifo;
use crate::lock_rank::{LockRank, RankedMutex};

#[test]
fn pty_input_order_turns_run_in_the_order_they_were_taken() {
    let fifo = Arc::new(PtyInputFifo::default());
    let order = Arc::new(Mutex::new(Vec::new()));
    let first = fifo.enter();
    let mut waiters = Vec::new();
    for index in 0..16 {
        let (waiter_fifo, order) = (fifo.clone(), order.clone());
        waiters.push(std::thread::spawn(move || {
            let _turn = waiter_fifo.enter();
            order.lock().unwrap().push(index);
        }));
        // The next waiter takes its ticket only after this one waits.
        while fifo.waiting() <= index {
            std::thread::yield_now();
        }
    }
    assert!(order.lock().unwrap().is_empty(), "a turn started while an earlier one ran");
    drop(first);
    for waiter in waiters {
        waiter.join().unwrap();
    }
    assert_eq!(*order.lock().unwrap(), (0..16).collect::<Vec<_>>());
    assert_eq!(fifo.waiting(), 0);
}

#[test]
fn pty_input_order_a_turn_keeps_the_time_its_input_queued() {
    let fifo = Arc::new(PtyInputFifo::default());
    let first = fifo.enter();
    let before = Instant::now();
    let waiter = std::thread::spawn({
        let fifo = fifo.clone();
        move || {
            let turn = fifo.enter();
            (turn.queued_at(), Instant::now())
        }
    });
    while fifo.waiting() == 0 {
        std::thread::yield_now();
    }
    std::thread::sleep(Duration::from_millis(50));
    drop(first);
    let (queued_at, started) = waiter.join().unwrap();
    assert!(queued_at >= before, "queued before it asked for its turn");
    assert!(
        started.duration_since(queued_at) >= Duration::from_millis(50),
        "the turn's time is when it started, not when its input queued"
    );
}

#[test]
fn pty_input_order_one_turn_at_a_time_under_contention() {
    let fifo = Arc::new(PtyInputFifo::default());
    let inside = Arc::new(AtomicBool::new(false));
    let threads: Vec<_> = (0..8)
        .map(|_| {
            let (fifo, inside) = (fifo.clone(), inside.clone());
            std::thread::spawn(move || {
                for _ in 0..2_000 {
                    let _turn = fifo.enter();
                    assert!(!inside.swap(true, Ordering::AcqRel), "two turns at once");
                    inside.store(false, Ordering::Release);
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    // Every turn ended: the next one starts at once.
    drop(fifo.enter());
}

#[test]
fn pty_input_order_the_terminal_and_runtime_locks_rank_after_a_turn() {
    let fifo = PtyInputFifo::default();
    let term = RankedMutex::new(LockRank::Terminal, "pty.term", ());
    let runtime = RankedMutex::new(LockRank::Runtime, "pty.runtime", ());
    let state = RankedMutex::new(LockRank::MuxState, "mux.state", ());
    let held_state = state.lock().unwrap();
    let turn = fifo.enter();
    drop((term.lock().unwrap(), runtime.lock().unwrap()));
    drop((turn, held_state));
}

#[cfg(debug_assertions)]
#[test]
#[should_panic(expected = "acquiring pty.input (PtyInput) while this thread holds pty.term")]
fn pty_input_order_a_turn_taken_under_the_terminal_lock_panics() {
    let fifo = PtyInputFifo::default();
    let term = RankedMutex::new(LockRank::Terminal, "pty.term", ());
    let _term = term.lock().unwrap();
    let _turn = fifo.enter();
}

#[cfg(debug_assertions)]
#[test]
#[should_panic(expected = "acquiring mux.state (MuxState) while this thread holds pty.input")]
fn pty_input_order_the_state_lock_is_never_taken_in_a_turn() {
    let fifo = PtyInputFifo::default();
    let state = RankedMutex::new(LockRank::MuxState, "mux.state", ());
    let _turn = fifo.enter();
    let _state = state.lock().unwrap();
}
