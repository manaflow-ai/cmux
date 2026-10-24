//! A kept tab starts when a request needs its shell (#17587).
//!
//! A kept tab is a dead terminal tab with a `kept_tabs` row: End Sessions,
//! Keep Layout left it, or `park-tabs` parked it. Frontends start one with
//! `restart-tab` when a window shows its workspace, so a launch starts the
//! terminals someone sees, not every terminal of every workspace. A request
//! that needs the tab's shell starts it here first, by the same
//! `restart-tab` path, so no entrypoint finds a dead tab that a frontend
//! draws as the terminal it becomes.
//!
//! No request waits for the start on its connection's dispatcher:
//! - input (`send`, `send-key`, `send {terminal_id}`) is queued for the
//!   starting terminal in the `terminal-input-while-creating-v1` queue
//!   (`creating_input.rs`) and answered at once. The start's worker writes
//!   the queue once the new shell's launch stream runs, or gives the bytes
//!   back (`terminal-input-unclaimed`) when the start fails;
//! - a wait for output (`wait-for`, the router's `terminal.wait`) waits for
//!   the start within its own deadline, woken only by topology events, and
//!   stops when its connection closes;
//! - the resource router's input effects cannot give bytes back, so they
//!   start the tab and refuse with "terminal is starting" instead of waiting.

use super::*;
use crate::mux::terminal_respawn::manual::TabRestartError;
use crate::stream_interrupt::StreamInterrupt;

/// Where a request that needs a tab's shell goes.
pub(crate) enum ShellTarget {
    /// The shell runs and no start of it runs: write to it.
    Live(Arc<Surface>),
    /// A start of the terminal runs (a kept tab's start or a respawn): the
    /// host terminal id (32 hex), whose input queues until the new shell's
    /// launch stream runs.
    Starting(String),
}

impl Mux {
    /// Where a request for the shell of the tab at `surface` goes. A kept tab
    /// no frontend started yet is started first (`restart-tab`'s path),
    /// without waiting for its worker. None when `surface` is neither live,
    /// starting nor a kept tab (a plain dead tab, a tab whose start failed
    /// at once, a host this build cannot adopt).
    pub(crate) fn shell_target(self: &Arc<Self>, surface: SurfaceId) -> Option<ShellTarget> {
        if let Some(found) = self.surface(surface).filter(|found| !found.is_dead()) {
            // The worker puts the new shell in the tab before its launch
            // stream starts: until the start ended, input still queues.
            let starting = found
                .terminal_host_identity()
                .map(|identity| identity.terminal_id)
                .filter(|terminal_id| self.terminal_is_respawning(terminal_id));
            return Some(match starting {
                Some(terminal_id) => ShellTarget::Starting(terminal_id),
                None => ShellTarget::Live(found),
            });
        }
        let terminal = self.tab_terminal(surface)?;
        if self.starting_host_terminal(&terminal).is_none()
            && self.tab_is_kept(surface)
            && let Err(error) = self.restart_dead_tab(surface)
            // `NotDead`: a frontend or another request started it already.
            && !matches!(error.downcast_ref::<TabRestartError>(), Some(TabRestartError::NotDead))
        {
            return None;
        }
        match self.starting_host_terminal(&terminal) {
            Some(terminal_id) => Some(ShellTarget::Starting(terminal_id)),
            // The start already ended: its new shell, or none when it failed.
            None => self.surface(surface).filter(|found| !found.is_dead()).map(ShellTarget::Live),
        }
    }

    /// [`Self::shell_target`] for a terminal (the resource router names
    /// terminals, not tabs): its first placement's tab, or its unplaced
    /// runtime.
    pub(crate) fn terminal_shell_target(
        self: &Arc<Self>,
        terminal: &TerminalPublicId,
    ) -> Option<ShellTarget> {
        let slot = self.with_state(|state| {
            state
                .placements_of_content(&ContentPublicId::Terminal(terminal.clone()))
                .first()
                .copied()
        });
        if let Some(slot) = slot {
            return self.shell_target(slot);
        }
        let surface = self.resource_surface_for_terminal(terminal)?;
        self.surface(surface).filter(|found| !found.is_dead()).map(ShellTarget::Live)
    }

    /// Start the kept tab of host terminal `terminal_id` (32 hex, `send
    /// {terminal_id}`) when no frontend started it yet. True when the
    /// terminal now runs or starts.
    pub(crate) fn start_kept_host_terminal(self: &Arc<Self>, terminal_id: &str) -> bool {
        let terminal = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_resource_id(terminal_id)
            .ok()
            .flatten();
        terminal.is_some_and(|terminal| self.terminal_shell_target(&terminal).is_some())
    }

    /// Wait until the start of host terminal `terminal_id` ended: its worker
    /// cleared its pending marker (after the new shell's launch stream
    /// started, or after the start failed) and emitted `TreeChanged`. True
    /// when it ended; false at `deadline` or once `interrupt` fired (the
    /// request's connection closed). The caller then looks the shell up
    /// again. Only topology events wake it, never terminal output.
    pub(crate) fn wait_for_terminal_start(
        &self,
        terminal_id: &str,
        deadline: Option<Instant>,
        interrupt: &StreamInterrupt,
    ) -> bool {
        // Subscribed before the first check, so the worker's `TreeChanged`
        // at the start's end is never missed.
        let events = Arc::new(self.subscribers.subscribe_terminal_topology());
        let woken = Arc::downgrade(&events);
        interrupt.on_fire(move || {
            if let Some(events) = woken.upgrade() {
                events.wake();
            }
        });
        loop {
            if !self.terminal_is_respawning(terminal_id) {
                return true;
            }
            if interrupt.is_fired() {
                return false;
            }
            let received = match deadline {
                Some(deadline) => deadline
                    .checked_duration_since(Instant::now())
                    .is_some_and(|remaining| events.recv_timeout(remaining).is_ok()),
                None => events.recv().is_ok(),
            };
            if !received {
                return !self.terminal_is_respawning(terminal_id);
            }
        }
    }

    /// The terminal shown by the tab at `surface`; None for any other tab.
    fn tab_terminal(&self, surface: SurfaceId) -> Option<TerminalPublicId> {
        self.with_state(|state| match state.resource_indexes.content_ids.get(&surface) {
            Some(ContentPublicId::Terminal(terminal)) => Some(terminal.clone()),
            _ => None,
        })
    }

    /// Whether the tab at `surface` is kept (its `kept_tabs` row goes once
    /// its new shell runs).
    fn tab_is_kept(&self, surface: SurfaceId) -> bool {
        let Some(tab_id) =
            self.with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())
        else {
            return false;
        };
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        registry.any_kept_tab(&[tab_id.to_string()]).unwrap_or(false)
    }

    /// The host terminal id of `terminal` while a start of it runs: its
    /// [`PendingTerminal::Respawning`] marker, which only the start's worker
    /// (or an abandoned respawn) clears. An `Adopting` or `Unadoptable`
    /// marker is not a start.
    fn starting_host_terminal(&self, terminal: &TerminalPublicId) -> Option<String> {
        let pending = self.pending_terminals.lock().unwrap_or_else(PoisonError::into_inner);
        match pending.get(terminal.as_str()) {
            Some((terminal_id, PendingTerminal::Respawning)) => Some(terminal_id.clone()),
            _ => None,
        }
    }
}
