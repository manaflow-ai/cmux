//! Rings sized from the memory budget, and the pages of cold ones given
//! back (p07-memory-094).
//!
//! Each terminal's ring is `DaemonBudget::holder_ring_bytes` (512 KiB on an
//! 8 GB Mac, 1 MiB from 16 GB). A terminal that printed nothing for
//! `DaemonBudget::cold_scrollback_after` is cold: its ring drops the bytes
//! no reader needs any more and gives their pages to the kernel
//! ([`crate::ring::Ring::release_before`]), as Chrome purges an unlocked
//! discardable segment (`base/memory/discardable_shared_memory.cc`). No
//! reader needs a byte that is before both
//!
//! - the offset the daemon acknowledged it parsed: a holder that adopts the
//!   ring after this one died continues from what the daemon received, past
//!   it, so a holder crash loses no byte; and
//! - the base of the terminal's prologue (the daemon's newest SNAPSHOT): a
//!   restarted daemon replays the prologue and the ring from its base on.
//!
//! A terminal without a prologue keeps its ring: a restarted daemon replays
//! all of it. No wire change: ACK and SNAPSHOT already say both offsets.

use std::time::{Duration, Instant};

use cmux_memory::DaemonBudget;

use super::{Holder, Link, Terminal};

/// The holder's ring sizes and when a terminal's ring counts as cold.
pub(super) struct RingBudget {
    /// The capacity of a ring this holder makes.
    pub(super) ring_bytes: usize,
    /// A terminal with no output for this long releases its ring's pages.
    cold_after: Duration,
}

impl RingBudget {
    /// The budget of this Mac's installed RAM (read once, at the start).
    pub(super) fn for_host() -> Self {
        let budget = DaemonBudget::for_host();
        Self { ring_bytes: budget.holder_ring_bytes, cold_after: budget.cold_scrollback_after }
    }
}

impl Holder {
    /// Count a terminal's ring cold after `after` with no output (default
    /// `DaemonBudget::cold_scrollback_after`).
    pub fn set_ring_cold_after(&mut self, after: Duration) {
        self.ring_budget.cold_after = after;
    }

    /// Give back the ring pages of every cold terminal, and once nothing
    /// waits on the link, the heap its queued frames took in a burst (up to
    /// `LINK_QUEUE_BYTES`, freed to the allocator when the socket took them,
    /// but kept by it).
    pub(super) fn release_cold_rings(&mut self, now: Instant) {
        let cold_after = self.ring_budget.cold_after;
        let mut released = 0;
        for terminal in self.terminals.values_mut() {
            if terminal.cold_at(cold_after).is_some_and(|at| at <= now)
                && let Some(confirmed) = terminal.confirmed_before()
            {
                released += terminal.ring.release_before(confirmed);
            }
        }
        if released > 0
            && let Some(link) = self.link.as_mut()
            && !link.has_output()
        {
            link.shrink();
            relieve_heap();
        }
    }

    /// When the next terminal with releasable ring bytes turns cold.
    pub(super) fn cold_ring_deadline(&self) -> Option<Instant> {
        let cold_after = self.ring_budget.cold_after;
        self.terminals.values().filter_map(|terminal| terminal.cold_at(cold_after)).min()
    }
}

impl Terminal {
    /// When this terminal's ring turns cold, while it has bytes to release.
    fn cold_at(&self, cold_after: Duration) -> Option<Instant> {
        let confirmed = self.confirmed_before()?;
        if !self.ring.can_release_before(confirmed) {
            return None;
        }
        // A cold time too far to represent never comes.
        self.last_output.checked_add(cold_after)
    }

    /// The offset before which no reader needs this terminal's output (the
    /// module docs); `None` without a prologue.
    fn confirmed_before(&self) -> Option<u64> {
        (!self.prologue.is_empty()).then(|| self.acked.min(self.prologue_base))
    }
}

impl Link {
    /// Free the room the queues grew to in a burst (empty queues only).
    fn shrink(&mut self) {
        self.urgent.shrink_to_fit();
        self.bulk.shrink_to_fit();
        self.bulk_per_chan.shrink_to_fit();
    }
}

/// Return the allocator's free pages to the kernel.
#[cfg(target_vendor = "apple")]
fn relieve_heap() {
    unsafe extern "C" {
        fn malloc_zone_pressure_relief(zone: *mut libc::c_void, goal: libc::size_t)
        -> libc::size_t;
    }
    // SAFETY: a null zone relieves every zone; goal 0 frees all it can.
    unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
fn relieve_heap() {
    // SAFETY: trims glibc's heap; no pointer is involved.
    unsafe { libc::malloc_trim(0) };
}

#[cfg(not(any(target_vendor = "apple", all(target_os = "linux", target_env = "gnu"))))]
fn relieve_heap() {}
