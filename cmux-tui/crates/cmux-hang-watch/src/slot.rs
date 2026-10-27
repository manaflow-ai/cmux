//! A slot of the slot table and its state word.

use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering};
use std::time::Duration;

use crate::{NAME_BYTES, Shared};

// A slot's state word: 0 while no scope is open. Bits 0-39: the deadline in ms since the watch's
// epoch (34 years); bits 40-59: the scope's deadline duration in ms (at least 1, so an open state
// is never 0); bit 60: ignored (`invalidate_active`); bit 61: reported; bit 62: running (a scope
// whose deadline the thread's CPU time moves, `Guard::watch_running`). A late watcher ignores
// through `Shared::ignore_through_ms` instead.
const DEADLINE_MASK: u64 = (1 << 40) - 1;
const BUDGET_SHIFT: u32 = 40;
pub(crate) const BUDGET_MAX_MS: u64 = (1 << 20) - 1;
pub(crate) const IGNORED: u64 = 1 << 60;
pub(crate) const REPORTED: u64 = 1 << 61;
pub(crate) const RUNNING: u64 = 1 << 62;
/// The bits the watcher or an invalidation set on an open word; the rest is the word the open wrote.
pub(crate) const FLAGS: u64 = IGNORED | REPORTED;

pub(crate) fn pack(deadline_ms: u64, budget_ms: u64) -> u64 {
    deadline_ms.min(DEADLINE_MASK) | (budget_ms << BUDGET_SHIFT)
}

pub(crate) fn deadline_of(state: u64) -> u64 {
    state & DEADLINE_MASK
}

pub(crate) fn budget_of(state: u64) -> u64 {
    (state >> BUDGET_SHIFT) & BUDGET_MAX_MS
}

/// An open scope the watcher may still have to report.
pub(crate) fn armed(state: u64, ignore_through_ms: u64) -> bool {
    state != 0 && state & (IGNORED | REPORTED) == 0 && deadline_of(state) > ignore_through_ms
}

pub(crate) fn budget_ms(deadline: Duration) -> u64 {
    let ms = deadline.as_nanos().div_ceil(1_000_000);
    u64::try_from(ms).unwrap_or(u64::MAX).clamp(1, BUDGET_MAX_MS)
}

pub(crate) fn duration_ns(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

/// One registered thread. The owner thread writes `state`; the watcher only sets `REPORTED` with a
/// compare-exchange. `generation` changes at every register and unregister, so the watcher tells a
/// reused slot apart.
#[repr(align(64))]
pub(crate) struct Slot {
    pub(crate) state: AtomicU64,
    pub(crate) native: AtomicU64,
    pub(crate) generation: AtomicU32,
    pub(crate) in_use: AtomicBool,
    pub(crate) kind: AtomicU8,
    pub(crate) name: [AtomicU64; NAME_BYTES / 8],
}

const _: () = assert!(size_of::<Slot>() == 64);

impl Slot {
    pub(crate) const fn new() -> Slot {
        Slot {
            state: AtomicU64::new(0),
            native: AtomicU64::new(0),
            generation: AtomicU32::new(0),
            in_use: AtomicBool::new(false),
            kind: AtomicU8::new(0),
            name: [const { AtomicU64::new(0) }; NAME_BYTES / 8],
        }
    }

    pub(crate) fn set_name(&self, name: &str) {
        let mut end = name.len().min(NAME_BYTES);
        while !name.is_char_boundary(end) {
            end -= 1;
        }
        let mut bytes = [0u8; NAME_BYTES];
        bytes[..end].copy_from_slice(&name.as_bytes()[..end]);
        for (word, chunk) in self.name.iter().zip(bytes.chunks_exact(8)) {
            let mut le = [0u8; 8];
            le.copy_from_slice(chunk);
            word.store(u64::from_le_bytes(le), Ordering::Relaxed);
        }
    }

    pub(crate) fn read_name(&self) -> String {
        let mut bytes = [0u8; NAME_BYTES];
        for (word, chunk) in self.name.iter().zip(bytes.chunks_exact_mut(8)) {
            chunk.copy_from_slice(&word.load(Ordering::Relaxed).to_le_bytes());
        }
        let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(NAME_BYTES);
        String::from_utf8_lossy(&bytes[..end]).into_owned()
    }

    /// Opens a scope: returns the word it wrote and the enclosing word. The swap keeps a `REPORTED`
    /// bit the watcher sets on the enclosing word up to the open, so that scope is not reported twice.
    #[inline]
    pub(crate) fn open(&self, shared: &Shared, deadline: Duration, running: u64) -> (u64, u64) {
        let budget = budget_ms(deadline);
        let opened = pack(shared.now_ms().saturating_add(budget), budget) | running;
        let previous = self.state.swap(opened, Ordering::AcqRel);
        shared.note_open();
        (opened, previous)
    }

    /// Closes the scope that wrote `opened`, back to the enclosing word `previous`.
    #[inline]
    pub(crate) fn close(&self, shared: &Shared, generation: u32, opened: u64, previous: u64) {
        if self.generation.load(Ordering::Relaxed) != generation {
            return; // The guard went first; the slot is no longer this thread's.
        }
        let mut current = self.state.load(Ordering::Relaxed);
        loop {
            if current & !FLAGS != opened {
                self.close_out_of_order(current);
                return;
            }
            // Only the watcher writes the word meanwhile, and only to add `REPORTED`: the loop
            // retries until the restored word carries every flag the closing word had.
            let restored = shared.restored(current, previous);
            match self.state.compare_exchange_weak(
                current,
                restored,
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(actual) => current = actual,
            }
        }
        if previous != 0 {
            // The enclosing scope watches again: a watcher that parked while only a reported or
            // invalidated scope was open must see it.
            shared.note_open();
        }
    }

    /// A scope closed while a scope it encloses is still open (`current`), or after one did that
    /// (0). Clearing the slot drops the stale scopes the open ones saved; their closes then find a
    /// word that is not theirs and do nothing.
    #[cold]
    pub(crate) fn close_out_of_order(&self, current: u64) {
        self.state.store(0, Ordering::Release);
        debug_assert!(current == 0, "hang-watch scopes close innermost first");
    }

    pub(crate) fn invalidate(&self) {
        if self.state.load(Ordering::Relaxed) != 0 {
            self.state.fetch_or(IGNORED, Ordering::Relaxed);
        }
    }
}
