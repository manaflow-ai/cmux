//! A terminal runtime's emulator, hot or cold.
//!
//! [`TerminalCell`] holds the runtime's [`Terminal`] (`pty.term`). Every
//! [`TerminalCell::lock`] and [`TerminalCell::try_lock`] restores a cold
//! terminal before it returns the guard, so attach, read-scrollback, search,
//! resize and output all decompress first, and no caller can see a cold
//! terminal. Chrome reloads a discarded tab on its next access the same way
//! (`chrome/browser/resource_coordinator/tab_lifecycle_unit.cc`, `Load`).
//!
//! Only [`Surface::freeze_cold_terminal`] makes a terminal cold, with
//! ghostty-vt's lossless codec ([`Terminal::into_cold`]),
//! and only for a terminal with no attach or render tap; mux/cold_scrollback.rs
//! decides when. [`Surface::scrollback_memory`] reads a cold terminal's size
//! without restoring it, for the scrollback memory budget, and
//! [`Surface::try_with_hot_terminal`] lets a background pass skip a cold one.
//!
//! A restore is a new libghostty instance, so a view's scroll anchor
//! (`TrackedScreenPoint`, bound to its instance) cannot cross it. A freeze
//! records the row each view's anchor resolves to, and the restore tracks
//! that row again on the new instance under the same lock, before any
//! output can move the rows.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LockResult, PoisonError, TryLockError, TryLockResult, Weak};

use ghostty_vt::{ColdPagesError, ColdRefused, ColdTerminal, Screen, Terminal};

use crate::lock_rank::{LockRank, RankedGuard, RankedMutex};
use crate::surface::{Surface, TerminalMemory};

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
    /// A view is scrolled back on the inactive screen. libghostty tracks a
    /// point on the active screen only, so that anchor could not be tracked
    /// again after a restore; the terminal stays hot.
    InactiveScreenScrolled,
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
        anchors: Vec<FrozenAnchor>,
    },
    /// Inside [`TerminalSlot::freeze`] and [`TerminalSlot::thaw`] only,
    /// while the terminal moves between the other two states.
    Moving,
}

/// A view's scroll anchor while its terminal is cold: the row it resolved to.
struct FrozenAnchor {
    view: Weak<Surface>,
    screen: Screen,
    row: u32,
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

    /// The terminal's memory; a cold terminal stays cold. `None` while it
    /// moves between hot and cold, or when libghostty-vt cannot report it.
    pub(crate) fn memory(&self) -> Option<TerminalMemory> {
        let slot = self.slot.lock().unwrap_or_else(PoisonError::into_inner);
        match &slot.0 {
            SlotState::Hot(terminal) => terminal.memory_usage().ok().map(TerminalMemory::Hot),
            SlotState::Cold { terminal, .. } => Some(TerminalMemory::Cold {
                held_bytes: u64::try_from(terminal.held_bytes()).unwrap_or(u64::MAX),
                snapshot_bytes: terminal.snapshot_bytes(),
            }),
            SlotState::Moving => None,
        }
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
#[allow(
    clippy::unreachable,
    reason = "INVARIANT: TerminalCell::lock and try_lock thaw before they return a guard"
)]
fn not_hot() -> ! {
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
        let SlotState::Cold { terminal, thawed, anchors } =
            std::mem::replace(&mut self.0, SlotState::Moving)
        else {
            return;
        };
        match (*terminal).thaw() {
            Ok(mut terminal) => {
                track_anchors_again(&mut terminal, anchors);
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

    fn freeze(
        &mut self,
        thawed: ThawWake,
        cold: &AtomicBool,
        views: &[Arc<Surface>],
    ) -> ColdFreeze {
        let anchors = match &self.0 {
            SlotState::Hot(terminal) => match resolve_anchors(terminal, views) {
                Some(anchors) => anchors,
                None => return ColdFreeze::InactiveScreenScrolled,
            },
            SlotState::Cold { .. } | SlotState::Moving => return ColdFreeze::AlreadyCold,
        };
        let (state, outcome) = match std::mem::replace(&mut self.0, SlotState::Moving) {
            SlotState::Hot(terminal) => match (*terminal).into_cold() {
                Ok(frozen) => {
                    // The old instance's anchors go with it; the restore
                    // tracks their rows again.
                    for anchor in &anchors {
                        if let Some(view) = anchor.view.upgrade()
                            && let Some(pty) = view.as_pty()
                        {
                            *pty.viewport
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .anchor_mut(anchor.screen) = None;
                        }
                    }
                    let held_bytes = frozen.held_bytes();
                    let state = SlotState::Cold { terminal: Box::new(frozen), thawed, anchors };
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

/// The row each view's anchor resolves to now, on the active screen; `None`
/// when a view holds an anchor on the inactive screen. An anchor that no
/// longer resolves (its row was pruned) stays as it is: it would resolve to
/// nothing after a restore either.
fn resolve_anchors(terminal: &Terminal, views: &[Arc<Surface>]) -> Option<Vec<FrozenAnchor>> {
    let active = terminal.active_screen();
    let inactive = match active {
        Screen::Primary => Screen::Alternate,
        Screen::Alternate => Screen::Primary,
    };
    let mut anchors = Vec::new();
    for view in views {
        let Some(pty) = view.as_pty() else { continue };
        let viewport = pty.viewport.lock().unwrap_or_else(PoisonError::into_inner);
        if viewport.anchor(inactive).is_some() {
            return None;
        }
        let row = viewport
            .anchor(active)
            .and_then(|anchor| terminal.tracked_screen_point(anchor))
            .map(|(_, row)| row);
        if let Some(row) = row {
            anchors.push(FrozenAnchor { view: Arc::downgrade(view), screen: active, row });
        }
    }
    Some(anchors)
}

/// Track each frozen anchor's row on the restored instance: the same rows,
/// as the restore is exact and nothing has printed since the freeze.
fn track_anchors_again(terminal: &mut Terminal, anchors: Vec<FrozenAnchor>) {
    for anchor in anchors {
        let Some(view) = anchor.view.upgrade() else { continue };
        let Some(pty) = view.as_pty() else { continue };
        let tracked = terminal.track_screen_point(0, anchor.row).ok();
        *pty.viewport.lock().unwrap_or_else(PoisonError::into_inner).anchor_mut(anchor.screen) =
            tracked;
    }
}

impl Surface {
    /// Compress this terminal unless it is in use or viewed. `views` are the
    /// placements that show it: their scroll anchors cross the restore (this
    /// surface's own always does). `thawed` runs when an access restores it.
    /// `None` for a browser surface.
    pub(crate) fn freeze_cold_terminal(
        self: &Arc<Self>,
        views: &[Arc<Surface>],
        thawed: &ThawWake,
    ) -> Option<ColdFreeze> {
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
        let mut sharing = vec![self.clone()];
        for view in views {
            if self.shares_terminal_runtime(view)
                && !sharing.iter().any(|known| Arc::ptr_eq(known, view))
            {
                sharing.push(view.clone());
            }
        }
        Some(slot.freeze(thawed.clone(), &pty.term.cold, &sharing))
    }

    /// `f` on the terminal while it is hot; `Ok(None)` while it is cold, and
    /// it stays cold. For a background pass that must not restore a terminal
    /// to read content that cannot have changed since it printed last.
    pub(crate) fn try_with_hot_terminal<R>(
        &self,
        f: impl FnOnce(&mut Terminal) -> R,
    ) -> anyhow::Result<Option<R>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut slot = pty.term.slot.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(match &mut slot.0 {
            SlotState::Hot(terminal) => Some(f(terminal)),
            SlotState::Cold { .. } | SlotState::Moving => None,
        })
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
