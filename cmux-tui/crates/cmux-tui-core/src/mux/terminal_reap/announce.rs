//! The reaper's slot on the mux: its event receiver while it runs, and the
//! owner's announcement that it starts it (`terminal-reaper-active-v1`).

use super::*;

/// The unplaced-terminal reaper's state on the mux.
#[derive(Default)]
pub(crate) struct TerminalReaperSlot {
    /// The running reaper's event receiver, so keep and grace changes can wake it.
    pub(super) events: Option<MuxEventReceiver>,
    /// The owner starts the reaper ([`Mux::announce_terminal_reaper`]).
    announced: bool,
}

impl Mux {
    /// Announce that this owner starts the unplaced-terminal reaper. The
    /// socket answers `identify` before the reaper thread runs, so a client
    /// that identifies in between must already see
    /// `terminal-reaper-active-v1`. The announcement ends when the reaper
    /// stops or its start fails.
    pub fn announce_terminal_reaper(&self) {
        self.terminal_reaper.lock().unwrap_or_else(PoisonError::into_inner).announced = true;
    }

    /// Whether `identify` lists `terminal-reaper-active-v1`: the reaper runs,
    /// or this owner announced that it starts it.
    pub fn terminal_reaper_advertised(&self) -> bool {
        let slot = self.terminal_reaper.lock().unwrap_or_else(PoisonError::into_inner);
        slot.announced || slot.events.is_some()
    }

    /// The reaper stopped or did not start: `identify` no longer lists it.
    pub(super) fn end_terminal_reaper(&self) {
        *self.terminal_reaper.lock().unwrap_or_else(PoisonError::into_inner) =
            TerminalReaperSlot::default();
    }
}
