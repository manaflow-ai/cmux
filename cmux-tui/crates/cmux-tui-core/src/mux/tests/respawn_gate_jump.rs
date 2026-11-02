//! The respawn gate lets a waiter whose terminal the person now sees go
//! first (`StartupAdoptionGate::turn_or_jump`), without a slot, while the
//! only slot is still held; a waiter that does not jump keeps its place.

use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::mux::startup_adoption_gate::{Admission, StartupAdoptionGate};

#[test]
fn a_waiter_the_person_now_sees_jumps_the_line_while_the_slot_is_held() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let first = gate.ticket();
    let held = match gate.turn_or_jump(first, || false, || false) {
        Admission::Turn(turn) => turn,
        _ => panic!("the first ticket did not get the free slot"),
    };
    let shown = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = std::sync::mpsc::channel();
    let waiter = {
        let (gate, shown) = (gate.clone(), shown.clone());
        let ticket = gate.ticket();
        std::thread::spawn(move || {
            let jumped = matches!(
                gate.turn_or_jump(ticket, || false, || shown.load(Ordering::Acquire)),
                Admission::Jumped
            );
            sender.send(jumped).unwrap();
        })
    };
    assert!(
        receiver.recv_timeout(Duration::from_millis(200)).is_err(),
        "a hidden waiter went before the held slot was free"
    );
    shown.store(true, Ordering::Release);
    gate.wake_waiters();
    assert!(
        receiver.recv_timeout(Duration::from_secs(2)).unwrap(),
        "a waiter the person now sees did not go first"
    );
    waiter.join().unwrap();
    // Its ticket was given up: the next one gets the slot when it frees.
    let next = gate.ticket();
    drop(held);
    assert!(matches!(gate.turn_or_jump(next, || false, || false), Admission::Turn(_)));
}

/// Shown terminals go before hidden ones, but they still take slots: the
/// cap bounds them too (review of #32288: a visible workspace with many
/// tabs must not bring back the all-at-once respawn of STATUS 5931). One
/// slot, held; three shown waiters and one hidden waiter queue behind it.
/// None may run while the slot is held; when it frees, one shown waiter
/// runs, and the hidden one runs only after every shown one.
#[test]
fn shown_waiters_go_first_but_still_take_the_slots() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let held = match gate.turn_or_jump(gate.ticket(), || false, || false) {
        Admission::Turn(turn) => turn,
        _ => panic!("the first ticket did not get the free slot"),
    };
    let order = Arc::new(Mutex::new(Vec::new()));
    let release = Arc::new((Mutex::new(false), Condvar::new()));
    let hidden = gate.ticket();
    let shown = (0..3).map(|_| gate.ticket()).collect::<Vec<_>>();
    let mut threads = Vec::new();
    let run = |name: &'static str, ticket, prioritized: bool| {
        let (gate, order, release) = (gate.clone(), order.clone(), release.clone());
        std::thread::spawn(move || {
            let admission = gate.turn_or_jump(ticket, || false, || prioritized);
            if matches!(admission, Admission::GaveUp) {
                return;
            }
            order.lock().unwrap().push(name);
            // Hold whatever was granted until the test releases it.
            let (released, changed) = &*release;
            let mut released = released.lock().unwrap();
            while !*released {
                released = changed.wait(released).unwrap();
            }
            drop(admission);
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
    assert_eq!(
        order.last(),
        Some(&"hidden"),
        "the hidden waiter ran before a shown one: {order:?}"
    );
}
