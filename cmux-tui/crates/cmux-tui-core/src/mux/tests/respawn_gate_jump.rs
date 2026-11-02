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
