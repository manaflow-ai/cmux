//! A terminal runtime's emulator, hot or cold (p07-memory-041).
//!
//! [`TerminalCell`] holds the runtime's [`Terminal`] (`pty.term`). Every
//! [`TerminalCell::lock`] and [`TerminalCell::try_lock`] restores a cold
//! terminal before it returns the guard, so attach, read-scrollback, search,
//! resize and output all decompress first, and no caller can see a cold
//! terminal. Chrome reloads a discarded tab on its next access the same way
//! (`chrome/browser/resource_coordinator/tab_lifecycle_unit.cc`, `Load`).
//!
//! Only [`Surface::freeze_cold_terminal`] makes a terminal cold, with
//! ghostty-vt's lossless codec ([`Terminal::into_cold`], p07-memory-040),
//! and only for a terminal with no attach or render tap; mux/cold_scrollback.rs
//! decides when. [`Surface::scrollback_memory`] reads a cold terminal's size
//! without restoring it, for the scrollback memory budget.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LockResult, PoisonError, TryLockError, TryLockResult};

use ghostty_vt::{ColdPagesError, ColdRefused, ColdTerminal, Terminal};

use crate::lock_rank::{LockRank, RankedGuard, RankedMutex};
use crate::surface::Surface;

/// Called each time a cold terminal is restored, under its terminal lock:
/// it may only signal (the cold-scrollback worker starts that terminal's
/// idle period again).
pub(crate) type ThawWake = Arc<dyn Fn() + Send + Sync>;

/// What [`Surface::freeze_cold_terminal`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ColdFreeze {
    /// The terminal is cold and holds `held_bytes` for its libghostty state.
    Frozen {
        held_bytes: usize,
    },
    AlreadyCold,
    /// Another thread holds the terminal (it is in use).
    Busy,
    /// An attach or render tap reads the terminal.
    Viewed,
    /// The codec cannot restore this terminal exactly; it stays hot.
    Refused(ColdPagesError),
}

/// A terminal's scrollback memory, read without restoring a cold terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ScrollbackMemory {
    /// Resident bytes of the primary screen's pages.
    Hot(u64),
    /// Bytes the compressed terminal holds.
    Cold(u64),
}

/// The runtime's terminal behind its lock (`LockRank::Terminal`).
pub(crate) struct TerminalCell {
    slot: RankedMutex<TerminalSlot>,
    /// Whether the slot is cold, for a pass that must not take the lock.
    cold: AtomicBool,
}

/// The terminal a [`TerminalCell`] guard dereferences to.
pub(crate) struct TerminalSlot(SlotState);

enum SlotState {
    Hot(Box<Terminal>),
    Cold {
        terminal: Box<ColdTerminal>,
        thawed: ThawWake,
    },
    /// Inside [`TerminalSlot::freeze`] and [`TerminalSlot::thaw`] only,
    /// while the terminal moves between the other two states.
    Moving,
}

impl TerminalCell {
    pub(crate) fn new(terminal: Box<Terminal>) -> Self {
        Self {
            slot: RankedMutex::new(
                LockRank::Terminal,
                "pty.term",
                TerminalSlot(SlotState::Hot(terminal)),
            ),
            cold: AtomicBool::new(false),
        }
    }

    /// Lock the terminal, restoring it first when it is cold.
    #[track_caller]
    #[inline]
    pub(crate) fn lock(&self) -> LockResult<RankedGuard<'_, TerminalSlot>> {
        match self.slot.lock() {
            Ok(mut slot) => {
                slot.thaw(&self.cold);
                Ok(slot)
            }
            Err(poison) => {
                let mut slot = poison.into_inner();
                slot.thaw(&self.cold);
                Err(PoisonError::new(slot))
            }
        }
    }

    /// [`Self::lock`] without waiting.
    #[inline]
    pub(crate) fn try_lock(&self) -> TryLockResult<RankedGuard<'_, TerminalSlot>> {
        match self.slot.try_lock() {
            Ok(mut slot) => {
                slot.thaw(&self.cold);
                Ok(slot)
            }
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                let mut slot = poison.into_inner();
                slot.thaw(&self.cold);
                Err(TryLockError::Poisoned(PoisonError::new(slot)))
            }
        }
    }

    pub(crate) fn is_cold(&self) -> bool {
        self.cold.load(Ordering::Acquire)
    }
}

impl std::ops::Deref for TerminalSlot {
    type Target = Terminal;

    #[inline]
    fn deref(&self) -> &Terminal {
        match &self.0 {
            SlotState::Hot(terminal) => terminal,
            SlotState::Cold { .. } | SlotState::Moving => not_hot(),
        }
    }
}

impl std::ops::DerefMut for TerminalSlot {
    #[inline]
    fn deref_mut(&mut self) -> &mut Terminal {
        match &mut self.0 {
            SlotState::Hot(terminal) => terminal,
            SlotState::Cold { .. } | SlotState::Moving => not_hot(),
        }
    }
}

/// [`TerminalCell`] restores the terminal before it returns any guard, and
/// only this module builds one.
#[cold]
fn not_hot() -> ! {
    // crash-allow: TerminalCell::lock and try_lock thaw before they return a guard.
    unreachable!("a cold terminal behind a TerminalCell guard")
}

impl TerminalSlot {
    #[inline]
    fn thaw(&mut self, cold: &AtomicBool) {
        if matches!(self.0, SlotState::Cold { .. }) {
            self.thaw_cold(cold);
        }
    }

    #[cold]
    fn thaw_cold(&mut self, cold: &AtomicBool) {
        let SlotState::Cold { terminal, thawed } =
            std::mem::replace(&mut self.0, SlotState::Moving)
        else {
            return;
        };
        match (*terminal).thaw() {
            Ok(terminal) => {
                self.0 = SlotState::Hot(Box::new(terminal));
                cold.store(false, Ordering::Release);
                thawed();
            }
            Err(failed) => {
                // The codec restores what it encoded or refuses to encode it
                // (040), so this is libghostty failing to allocate: the
                // process is out of memory, where Rust's allocator aborts too.
                eprintln!("cmux-tui: a cold terminal could not be restored: {}", failed.error);
                // crash-allow: out of memory; a guard cannot be handed out without the terminal.
                std::process::abort();
            }
        }
    }

    fn freeze(&mut self, thawed: ThawWake, cold: &AtomicBool) -> ColdFreeze {
        let (state, outcome) = match std::mem::replace(&mut self.0, SlotState::Moving) {
            SlotState::Hot(terminal) => match (*terminal).into_cold() {
                Ok(frozen) => {
                    let held_bytes = frozen.held_bytes();
                    let state = SlotState::Cold { terminal: Box::new(frozen), thawed };
                    (state, ColdFreeze::Frozen { held_bytes })
                }
                Err(refused) => {
                    let ColdRefused { terminal, reason } = *refused;
                    (SlotState::Hot(Box::new(terminal)), ColdFreeze::Refused(reason))
                }
            },
            other => (other, ColdFreeze::AlreadyCold),
        };
        self.0 = state;
        cold.store(matches!(self.0, SlotState::Cold { .. }), Ordering::Release);
        outcome
    }
}

impl Surface {
    /// Compress this terminal unless it is in use or viewed. `thawed` runs
    /// when an access restores it. `None` for a browser surface.
    pub(crate) fn freeze_cold_terminal(&self, thawed: &ThawWake) -> Option<ColdFreeze> {
        let pty = self.as_pty()?;
        let mut slot = match pty.term.slot.try_lock() {
            Ok(slot) => slot,
            Err(TryLockError::WouldBlock | TryLockError::Poisoned(_)) => {
                return Some(ColdFreeze::Busy);
            }
        };
        if matches!(slot.0, SlotState::Cold { .. }) {
            return Some(ColdFreeze::AlreadyCold);
        }
        // An attach registers its tap under the terminal lock, which this
        // holds, so no viewer can start between this check and the freeze.
        // A dropped receiver cancels its tap; the next output would prune it.
        let mut taps = pty.taps.lock().unwrap_or_else(PoisonError::into_inner);
        taps.retain(|tap| !tap.lifecycle.is_canceled());
        let viewed = !taps.is_empty()
            || !pty.render.lock().unwrap_or_else(PoisonError::into_inner).taps.is_empty();
        drop(taps);
        if viewed {
            return Some(ColdFreeze::Viewed);
        }
        Some(slot.freeze(thawed.clone(), &pty.term.cold))
    }

    /// Whether the terminal is compressed now (no lock).
    pub(crate) fn terminal_is_cold(&self) -> bool {
        self.as_pty().is_some_and(|pty| pty.term.is_cold())
    }

    /// The terminal's scrollback memory; a cold terminal stays cold.
    pub(crate) fn scrollback_memory(&self) -> Option<ScrollbackMemory> {
        let pty = self.as_pty()?;
        let slot = pty.term.slot.lock().unwrap_or_else(PoisonError::into_inner);
        match &slot.0 {
            SlotState::Hot(terminal) => {
                terminal.primary_resident_bytes().map(ScrollbackMemory::Hot)
            }
            SlotState::Cold { terminal, .. } => Some(ScrollbackMemory::Cold(
                u64::try_from(terminal.held_bytes()).unwrap_or(u64::MAX),
            )),
            SlotState::Moving => None,
        }
    }
}
