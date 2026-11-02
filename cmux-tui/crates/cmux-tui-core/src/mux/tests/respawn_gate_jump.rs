//! The respawn gate lets a waiter whose terminal the person now sees take
//! the next free slot before the tickets in line
//! (`StartupAdoptionGate::turn_first_if`), and still bounds it by the slots.

use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::mux::startup_adoption_gate::StartupAdoptionGate;

/// Shown terminals go before hidden ones, but they still take slots: the
/// cap bounds them too (review of #32288: a visible workspace with many
/// tabs must not bring back the all-at-once respawn of STATUS 5931). One
/// slot, held; one hidden waiter, then three shown waiters, queue behind
/// it. None may run while the slot is held; when it frees, one shown waiter
/// runs, and the hidden one, first in line, runs only after every shown one.
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
    assert!(
        order.lock().unwrap().is_empty(),
        "a waiter ran while the only slot was held: {:?}",
        order.lock().unwrap()
    );
    drop(held);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        *order.lock().unwrap(),
        vec!["shown"],
        "one freed slot let in more than one waiter, or the hidden one first"
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
/// workspace) is woken and goes before the ticket in line ahead of it; its
/// place is stepped over, so the line keeps moving after it.
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
