//! The spare host slot (R81): lazy, cap one, burst-safe, a dead spare falls
//! back to the normal launch, memory pressure drops it. A `cat` stand-in
//! waits on its stdin exactly as a standby host waits on its bootstrap pipe.

use std::sync::Arc;
use std::time::{Duration, Instant};

use super::*;
use crate::mux::terminal_work::TerminalWorkPool;

fn memory() -> Arc<DaemonMemory> {
    Arc::new(DaemonMemory::without_system_source())
}

fn slot_in(memory: &Arc<DaemonMemory>) -> Arc<StandbyHostSlot> {
    StandbyHostSlot::with_spawner(memory.clone(), StandbyTerminalHost::spawn_stand_in)
}

fn slot() -> Arc<StandbyHostSlot> {
    slot_in(&memory())
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
    let (slot, pool) = (slot(), TerminalWorkPool::for_test());
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "a headless owner that never opened a tab starts no spare");
}

#[test]
fn the_first_new_tab_starts_one_spare_and_the_next_tab_adopts_it() {
    let (slot, pool) = (slot(), TerminalWorkPool::for_test());
    assert!(slot.take().is_none(), "the first tab of a session launches as before");
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let spare = slot.take().expect("the second tab adopts the spare");
    assert!(alive(spare.pid()));
    assert!(!slot.has_spare());
}

#[test]
fn a_burst_takes_the_spare_once_and_refills_at_most_one() {
    let (slot, pool) = (slot(), TerminalWorkPool::for_test());
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
    let (slot, pool) = (slot(), TerminalWorkPool::for_test());
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
    let memory = memory();
    let (slot, pool) = (slot_in(&memory), TerminalWorkPool::for_test());
    let _ = slot.take();
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let pid = {
        let spare = slot.take().unwrap();
        let pid = spare.pid();
        slot.finish_refill_for_test(spare);
        pid
    };
    let app = memory.registry().voter();
    app.set_level(PressureLevel::Warning);
    assert!(!slot.has_spare());
    assert!(wait_gone(pid), "a dropped spare process is killed");
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "no refill under pressure");
    app.set_level(PressureLevel::Critical);
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "no refill under critical pressure");
    app.set_level(PressureLevel::Normal);
    slot.refill(&pool);
    assert!(wait_for_spare(&slot), "back to normal, the next new tab refills");
}

#[test]
fn a_slot_made_under_pressure_starts_no_spare_until_normal() {
    let memory = memory();
    let app = memory.registry().voter();
    app.set_level(PressureLevel::Warning);
    let (slot, pool) = (slot_in(&memory), TerminalWorkPool::for_test());
    let _ = slot.take();
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "the slot hears the current level when it registers");
    app.set_level(PressureLevel::Normal);
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
}

/// Spares started by [`counting_spawn`]; only the test below uses it.
static FIRST_WATCH_SPAWNS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn counting_spawn() -> anyhow::Result<StandbyTerminalHost> {
    FIRST_WATCH_SPAWNS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    StandbyTerminalHost::spawn_stand_in()
}

#[test]
fn a_first_refill_under_system_pressure_starts_no_spare() {
    // The system is already under pressure when the first new tab starts
    // the kernel source: its initial read must suppress the slot before the
    // slot decides to refill.
    let memory = Arc::new(DaemonMemory::with_stand_in_system_level(PressureLevel::Warning));
    let slot = StandbyHostSlot::with_spawner(memory.clone(), counting_spawn);
    let pool = TerminalWorkPool::for_test();
    let _ = slot.take();
    slot.refill(&pool);
    assert_eq!(memory.registry().level(), PressureLevel::Warning);
    assert!(!slot.is_refilling(), "no refill job is submitted under pressure");
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(FIRST_WATCH_SPAWNS.load(std::sync::atomic::Ordering::SeqCst), 0, "no spare process");
    assert!(!slot.has_spare());
}

#[test]
fn the_slot_is_one_lossless_consumer_and_leaves_the_registry_when_dropped() {
    let memory = memory();
    let slot = slot_in(&memory);
    let report = memory.registry().report();
    assert_eq!(report.len(), 1);
    assert_eq!(report[0].name, "terminal.standby-host");
    assert_eq!(report[0].retention, Retention::Lossless);
    drop(slot);
    assert!(memory.registry().report().is_empty());
}
