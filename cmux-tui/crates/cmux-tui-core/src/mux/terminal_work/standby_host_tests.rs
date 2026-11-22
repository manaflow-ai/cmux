//! The spare host slot (R81): lazy, cap one, burst-safe, a dead spare falls
//! back to the normal launch, memory pressure drops it. A `cat` stand-in
//! waits on its stdin exactly as a standby host waits on its bootstrap pipe.

use std::sync::Arc;
use std::time::{Duration, Instant};

use super::*;
use crate::mux::terminal_work::TerminalWorkPool;

fn slot() -> Arc<StandbyHostSlot> {
    Arc::new(StandbyHostSlot::with_spawner(StandbyTerminalHost::spawn_stand_in))
}

/// Waits for the background refill (test harness polling, not product code).
fn wait_for_spare(slot: &StandbyHostSlot) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if slot.has_spare() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    false
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 probes the process without affecting it.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// Reaps-aware wait for a killed stand-in to disappear.
fn wait_gone(pid: u32) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    false
}

#[test]
fn no_spare_before_the_first_new_tab() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "a headless owner that never opened a tab starts no spare");
}

#[test]
fn the_first_new_tab_starts_one_spare_and_the_next_tab_adopts_it() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    assert!(slot.take().is_none(), "the first tab of a session launches as before");
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let spare = slot.take().expect("the second tab adopts the spare");
    assert!(alive(spare.pid()));
    assert!(!slot.has_spare());
}

#[test]
fn a_burst_takes_the_spare_once_and_refills_at_most_one() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take();
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let first = slot.take();
    let second = slot.take();
    assert!(first.is_some());
    assert!(second.is_none(), "the rest of a burst launches as before");
    slot.refill(&pool);
    slot.refill(&pool);
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    // Cap one: the extra refill requests started no second process.
    let _ = slot.take();
    assert!(!slot.has_spare());
}

#[test]
fn a_spare_killed_before_adoption_falls_back_with_no_error() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take();
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let pid = {
        let spare = slot.take().unwrap();
        let pid = spare.pid();
        // Put it back so the next take sees a dead spare.
        slot.finish_refill_for_test(spare);
        pid
    };
    // SAFETY: the stand-in is our own child.
    unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    std::thread::sleep(Duration::from_millis(50));
    assert!(slot.take().is_none(), "a dead spare is dropped; the tab launches as before");
}

#[test]
fn memory_pressure_drops_the_spare_kills_it_and_stops_refills_until_normal() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take();
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let pid = {
        let spare = slot.take().unwrap();
        let pid = spare.pid();
        slot.finish_refill_for_test(spare);
        pid
    };
    slot.set_memory_pressure(true);
    assert!(!slot.has_spare());
    assert!(wait_gone(pid), "a dropped spare process is killed");
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "no refill under pressure");
    slot.set_memory_pressure(false);
    slot.refill(&pool);
    assert!(wait_for_spare(&slot), "back to normal, the next new tab refills");
}
