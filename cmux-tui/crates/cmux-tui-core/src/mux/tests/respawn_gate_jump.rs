//! The respawn gate lets a waiter of the person (its terminal is shown, or
//! the person asked for its restart) take its turn with no wait for the
//! tickets in line or for their turns to end
//! (`StartupAdoptionGate::turn_first_if`), and still bounds such waiters by
//! the slots among themselves.

use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::mux::startup_adoption_gate::StartupAdoptionGate;

/// Shown terminals go before hidden ones, but the slots still bound them
/// among themselves (review of #32288: a visible workspace with many tabs
/// must not bring back the all-at-once respawn of STATUS 5931). One slot,
/// held by a turn of the line; one hidden waiter, then three shown waiters,
/// queue behind it. One shown waiter runs at once (it does not wait for the
/// line's turn), the other two wait for it; the end of the line's turn lets
/// nobody in, and the hidden one, first in line, runs only after every
/// shown one.
#[test]
fn shown_waiters_go_first_but_still_take_the_slots() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let held = gate.turn_first_if(gate.ticket(), || false, || false);
    assert!(held.is_some(), "the first ticket did not get the free slot");
    let order = Arc::new(Mutex::new(Vec::new()));
    let release = Arc::new((Mutex::new(false), Condvar::new()));
    let hidden = gate.ticket();
    let shown = (0..3).map(|_| gate.ticket()).collect::<Vec<_>>();
    let mut threads = Vec::new();
    let run = |name: &'static str, ticket, first: bool| {
        let (gate, order, release) = (gate.clone(), order.clone(), release.clone());
        std::thread::spawn(move || {
            let Some(turn) = gate.turn_first_if(ticket, || false, || first) else { return };
            order.lock().unwrap().push(name);
            // Hold the slot until the test releases it.
            let (released, changed) = &*release;
            let mut released = released.lock().unwrap();
            while !*released {
                released = changed.wait(released).unwrap();
            }
            drop(turn);
        })
    };
    threads.push(run("hidden", hidden, false));
    for ticket in shown {
        threads.push(run("shown", ticket, true));
    }
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        *order.lock().unwrap(),
        vec!["shown"],
        "not exactly one shown waiter ran beside the turn of the line"
    );
    drop(held);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        *order.lock().unwrap(),
        vec!["shown"],
        "the end of the line's turn let in a second shown waiter, or the hidden one"
    );
    {
        let (released, changed) = &*release;
        *released.lock().unwrap() = true;
        changed.notify_all();
    }
    for thread in threads {
        thread.join().unwrap();
    }
    let order = order.lock().unwrap();
    assert_eq!(*order, vec!["shown", "shown", "shown", "hidden"], "the hidden waiter ran first");
}

/// A waiter that becomes shown while it waits (the person selects its
/// workspace) is woken and goes before the ticket in line ahead of it, with
/// no wait for the turn that holds the slot; its place is stepped over, so
/// the line keeps moving after it.
#[test]
fn a_waiter_shown_while_it_waits_takes_the_next_slot_before_the_line() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let held = gate.turn_first_if(gate.ticket(), || false, || false);
    assert!(held.is_some());
    let ahead = gate.ticket();
    let behind = gate.ticket();
    let shown = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = std::sync::mpsc::channel();
    let waiter = {
        let (gate, shown, sender) = (gate.clone(), shown.clone(), sender.clone());
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(behind, || false, || shown.load(Ordering::Acquire));
            sender.send("behind").unwrap();
            drop(turn);
        })
    };
    let other = {
        let gate = gate.clone();
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(ahead, || false, || false);
            sender.send("ahead").unwrap();
            drop(turn);
        })
    };
    std::thread::sleep(Duration::from_millis(200));
    shown.store(true, Ordering::Release);
    gate.wake_waiters();
    std::thread::sleep(Duration::from_millis(200));
    drop(held);
    let first = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let second = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!((first, second), ("behind", "ahead"), "the shown waiter did not go first");
    waiter.join().unwrap();
    other.join().unwrap();
    // The stepped-over place does not hold the line: a new ticket runs.
    assert!(gate.turn_first_if(gate.ticket(), || false, || false).is_some());
}

/// A waiter of the person (its terminal is shown, or the person asked for
/// its restart) does not wait for a slot that a turn of the line holds: the
/// terminal the person waits for started only when the launch of a hidden
/// restore had ended. One slot, held by a turn of the line: the person's
/// waiter gets its turn at once.
#[test]
fn a_waiter_of_the_person_does_not_wait_for_a_slot_of_the_line() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let held = gate.turn_first_if(gate.ticket(), || false, || false);
    assert!(held.is_some(), "the first ticket did not get the free slot");
    let ticket = gate.ticket();
    let (sender, receiver) = std::sync::mpsc::channel();
    let waiter = {
        let gate = gate.clone();
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(ticket, || false, || true);
            sender.send(turn.is_some()).unwrap();
            drop(turn);
        })
    };
    let turn = receiver.recv_timeout(Duration::from_secs(2));
    drop(held);
    waiter.join().unwrap();
    assert_eq!(turn, Ok(true), "the person's waiter waited for the turn of the line to end");
}

/// The line is never starved: 5 waiters of the person in a row and one
/// ticket of the line behind them, 1 slot. Every one gets its turn, the
/// line's too.
#[test]
fn the_line_gets_its_turn_after_waiters_of_the_person_in_a_row() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let held = gate.turn_first_if(gate.ticket(), || false, || true);
    assert!(held.is_some());
    let (sender, receiver) = std::sync::mpsc::channel();
    let run = |name: &'static str, first: bool| {
        let (gate, sender, ticket) = (gate.clone(), sender.clone(), gate.ticket());
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(ticket, || false, || first);
            std::thread::sleep(Duration::from_millis(20));
            sender.send(name).unwrap();
            drop(turn);
        })
    };
    let mut threads = vec![run("line", false)];
    threads.extend((0..5).map(|_| run("person", true)));
    std::thread::sleep(Duration::from_millis(100));
    drop(held);
    let done = (0..6)
        .map(|_| receiver.recv_timeout(Duration::from_secs(5)).expect("a waiter got no turn"))
        .collect::<Vec<_>>();
    assert!(done.contains(&"line"), "the line got no turn: {done:?}");
    for thread in threads {
        thread.join().unwrap();
    }
}
