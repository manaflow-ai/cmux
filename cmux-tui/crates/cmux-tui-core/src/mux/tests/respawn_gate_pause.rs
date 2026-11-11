//! The respawn gate's line can be stopped (`StartupAdoptionGate::set_line_paused`:
//! the memory pressure of the Mac is above normal). While it is stopped no
//! ticket of the line gets a turn; it goes on by itself when the stop ends,
//! and a waiter of the person (its terminal is shown, the person asked for
//! it, or work waits for it) starts at once all the same.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;

use super::*;
use crate::mux::startup_adoption_gate::StartupAdoptionGate;

/// A restore of 170 kept agents started every one of them, also when the
/// Mac had no memory left for them. Two free slots and a stopped line: the
/// ticket of the line gets no turn. The stop ends: it gets its turn with no
/// new request, so the result with no memory pressure is the same as before.
#[test]
fn the_line_starts_no_turn_while_it_is_stopped_and_goes_on_by_itself() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(2));
    gate.set_line_paused(true);
    let ticket = gate.ticket();
    let (sender, receiver) = std::sync::mpsc::channel();
    let waiter = {
        let gate = gate.clone();
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(ticket, || false, || false);
            sender.send(turn.is_some()).unwrap();
            drop(turn);
        })
    };
    assert_eq!(
        receiver.recv_timeout(Duration::from_millis(300)),
        Err(RecvTimeoutError::Timeout),
        "a ticket of the line got a turn while the line was stopped"
    );
    gate.set_line_paused(false);
    assert_eq!(
        receiver.recv_timeout(Duration::from_secs(2)),
        Ok(true),
        "the line did not go on by itself when its stop ended"
    );
    waiter.join().unwrap();
}

/// A stop of the line that comes while a turn of the line runs does not end
/// that turn, and the next ticket waits for the end of the stop, not only
/// for the slot.
#[test]
fn a_stop_holds_the_next_ticket_after_a_turn_of_the_line_ends() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(1));
    let held = gate.turn_first_if(gate.ticket(), || false, || false);
    assert!(held.is_some(), "the first ticket did not get the free slot");
    gate.set_line_paused(true);
    let ticket = gate.ticket();
    let (sender, receiver) = std::sync::mpsc::channel();
    let waiter = {
        let gate = gate.clone();
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(ticket, || false, || false);
            sender.send(turn.is_some()).unwrap();
            drop(turn);
        })
    };
    drop(held);
    assert_eq!(
        receiver.recv_timeout(Duration::from_millis(300)),
        Err(RecvTimeoutError::Timeout),
        "the end of a turn let the next ticket in while the line was stopped"
    );
    gate.set_line_paused(false);
    assert_eq!(receiver.recv_timeout(Duration::from_secs(2)), Ok(true));
    waiter.join().unwrap();
}

/// A terminal that was not started because the line is stopped starts at
/// once when the person shows it, sends it input, or work waits for it (the
/// waiter's `first` becomes true and the gate is woken), and a waiter that
/// goes first from its start is not stopped either. The line stays stopped
/// for the other ticket.
#[test]
fn a_waiter_of_the_person_starts_at_once_while_the_line_is_stopped() {
    let gate = Arc::new(StartupAdoptionGate::with_slots(2));
    gate.set_line_paused(true);
    let other = gate.ticket();
    let wanted = gate.ticket();
    let asked = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = std::sync::mpsc::channel();
    let run = |name: &'static str, ticket, asked: Arc<AtomicBool>| {
        let (gate, sender) = (gate.clone(), sender.clone());
        std::thread::spawn(move || {
            let turn = gate.turn_first_if(ticket, || false, || asked.load(Ordering::Acquire));
            sender.send((name, turn.is_some())).unwrap();
            drop(turn);
        })
    };
    let threads = [
        run("other", other, Arc::new(AtomicBool::new(false))),
        run("wanted", wanted, asked.clone()),
    ];
    assert_eq!(
        receiver.recv_timeout(Duration::from_millis(300)),
        Err(RecvTimeoutError::Timeout),
        "a ticket of the line got a turn while the line was stopped"
    );
    asked.store(true, Ordering::Release);
    gate.wake_waiters();
    assert_eq!(
        receiver.recv_timeout(Duration::from_secs(2)),
        Ok(("wanted", true)),
        "the waiter that work waits for did not start while the line was stopped"
    );
    let first = gate.turn_first_if(gate.ticket(), || false, || true);
    assert!(first.is_some(), "a waiter of the person waited for the end of the stop");
    drop(first);
    assert_eq!(
        receiver.recv_timeout(Duration::from_millis(300)),
        Err(RecvTimeoutError::Timeout),
        "the other ticket of the line got a turn while the line was stopped"
    );
    gate.set_line_paused(false);
    assert_eq!(receiver.recv_timeout(Duration::from_secs(2)), Ok(("other", true)));
    for thread in threads {
        thread.join().unwrap();
    }
}
