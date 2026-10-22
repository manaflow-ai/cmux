//! The spare host slot (R81, new-terminal-100x): lazy, up to two spares,
//! burst-safe, a dead spare falls back to the normal launch, memory pressure
//! and PTY exhaustion drop them, spares for another launch are replaced. A `cat` stand-in
//! waits on its stdin exactly as a standby host waits on its bootstrap pipe.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context as _;

use super::*;
use crate::mux::terminal_work::TerminalWorkPool;

fn slot() -> Arc<StandbyHostSlot> {
    Arc::new(StandbyHostSlot::with_spawner(StandbyTerminalHost::spawn_stand_in))
}

/// Waits until `count` spares exist (test harness polling, not product code).
fn wait_for_spares(slot: &StandbyHostSlot, count: usize) -> bool {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if slot.spares() >= count {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
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
fn the_first_new_tab_starts_one_spare_and_the_next_tab_adopts_it() -> anyhow::Result<()> {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    assert!(slot.take(None).is_none(), "the first tab of a session launches as before");
    slot.refill(&pool);
    assert!(wait_for_spare(&slot));
    let spare = slot.take(None).context("the second tab adopts the spare")?;
    assert!(alive(spare.pid()));
    Ok(())
}

#[test]
fn a_burst_takes_the_spares_and_refills_up_to_two() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take(None);
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES));
    let first = slot.take(None);
    let second = slot.take(None);
    let third = slot.take(None);
    assert!(first.is_some() && second.is_some());
    assert!(third.is_none(), "the rest of a burst launches as before");
    slot.refill(&pool);
    slot.refill(&pool);
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES));
    std::thread::sleep(Duration::from_millis(100));
    // The cap: the extra refill requests started no third process.
    assert_eq!(slot.spares(), SPARES);
}

#[test]
fn a_launch_that_finds_no_free_pty_drops_the_spares_until_one_succeeds() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take(None);
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES));
    assert_eq!(slot.release_for_pty_capacity(), SPARES, "every spare gives its PTY back");
    assert!(!slot.has_spare());
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(100));
    assert!(!slot.has_spare(), "no spare while PTYs run out");
    let key: PrepareKey = (Some("/tmp".into()), None);
    slot.prepare_for(key, crate::terminal_host_runtime::HostLaunch::stand_in_for_tests());
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES), "a successful launch makes spares worth keeping again");
}

#[test]
fn spares_prepared_for_another_launch_are_dropped() {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take(None);
    let here: PrepareKey = (Some("/tmp/here".into()), None);
    slot.prepare_for(here.clone(), crate::terminal_host_runtime::HostLaunch::stand_in_for_tests());
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES));
    let elsewhere: PrepareKey = (Some("/tmp/elsewhere".into()), None);
    slot.prepare_for(elsewhere, crate::terminal_host_runtime::HostLaunch::stand_in_for_tests());
    assert!(!slot.has_spare(), "spares prepared for another launch are dropped");
}

#[test]
fn a_spare_killed_before_adoption_falls_back_with_no_error() -> anyhow::Result<()> {
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take(None);
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES));
    // Hold every spare, so no refill runs; put one back to kill it.
    let spare = slot.take(None).context("a spare")?;
    let _other = slot.take(None).context("a second spare")?;
    let pid = spare.pid();
    slot.finish_refill_for_test(spare);
    // SAFETY: the stand-in is our own child.
    unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    std::thread::sleep(Duration::from_millis(50));
    assert!(slot.take(None).is_none(), "a dead spare is dropped; the tab launches as before");
    Ok(())
}

#[test]
fn memory_pressure_drops_the_spares_kills_them_and_stops_refills_until_normal() -> anyhow::Result<()>
{
    let (slot, pool) = (slot(), TerminalWorkPool::default());
    let _ = slot.take(None);
    slot.refill(&pool);
    assert!(wait_for_spares(&slot, SPARES));
    let spare = slot.take(None).context("a spare")?;
    let _other = slot.take(None).context("a second spare")?;
    let pid = spare.pid();
    slot.finish_refill_for_test(spare);
    slot.set_memory_pressure(true);
    assert!(!slot.has_spare());
    assert!(wait_gone(pid), "a dropped spare process is killed");
    slot.refill(&pool);
    std::thread::sleep(Duration::from_millis(50));
    assert!(!slot.has_spare(), "no refill under pressure");
    slot.set_memory_pressure(false);
    slot.refill(&pool);
    assert!(wait_for_spare(&slot), "back to normal, the next new tab refills");
    Ok(())
}
