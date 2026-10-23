//! A kept tab starts when a request needs its shell (#17587).
//!
//! A kept tab is a dead terminal tab with a `kept_tabs` row: End Sessions,
//! Keep Layout left it, or `park-tabs` parked it. Frontends start one with
//! `restart-tab` when a window shows its workspace, so a launch starts the
//! terminals someone sees, not every terminal of every workspace. A request
//! that needs the tab's shell (input, keys, a pasted image, a wait for
//! output, an attach), from any entrypoint (the CLI's `send`, the socket,
//! MCP's `terminal_*` tools, the resource router's `terminal.input.*` and
//! `terminal.wait`), starts it here first by the same `restart-tab` path
//! and waits for its new shell. So no entrypoint finds a dead tab that a
//! frontend draws as the terminal it becomes.

use super::*;
use crate::mux::terminal_respawn::manual::TabRestartError;

/// How long a request waits for a kept tab's new shell before it reports
/// the tab as not found (the start keeps going).
const KEPT_TAB_START_WAIT: Duration = Duration::from_secs(10);

impl Mux {
    /// The live surface of the tab at `surface`. A kept tab no frontend
    /// started yet is started first (`restart-tab`'s path) and waited for;
    /// one another start already runs for is waited for. None when
    /// `surface` is neither live nor a kept tab, or when its start failed
    /// or did not end within [`KEPT_TAB_START_WAIT`].
    pub(crate) fn live_surface_starting_kept_tab(
        self: &Arc<Self>,
        surface: SurfaceId,
    ) -> Option<Arc<Surface>> {
        let live = || self.surface(surface).filter(|found| !found.is_dead());
        if let Some(found) = live() {
            return Some(found);
        }
        let terminal = self.unstarted_kept_terminal(surface)?;
        // Subscribed before the start, so the worker's `TreeChanged` at its
        // end is never missed.
        let events = self.subscribe();
        if let Err(error) = self.restart_dead_tab(surface) {
            // `NotDead`: a frontend or another request is starting it (or it
            // just started): wait for that start below.
            if !matches!(error.downcast_ref::<TabRestartError>(), Some(TabRestartError::NotDead)) {
                return None;
            }
        }
        let deadline = Instant::now() + KEPT_TAB_START_WAIT;
        loop {
            if let Some(found) = live() {
                return Some(found);
            }
            // The start ended without a live shell (its launch failed): the
            // tab is dead again.
            if !self.terminal_start_pending(&terminal) {
                return None;
            }
            let remaining = deadline.checked_duration_since(Instant::now())?;
            events.recv_timeout(remaining).ok()?;
        }
    }

    /// The live runtime surface of `terminal`, starting its kept tab first
    /// as [`Self::live_surface_starting_kept_tab`] does (the resource
    /// router names terminals, not tabs).
    pub(crate) fn live_terminal_starting_kept(
        self: &Arc<Self>,
        terminal: &TerminalPublicId,
    ) -> Option<SurfaceId> {
        if let Some(found) = self.resource_surface_for_terminal(terminal) {
            return Some(found);
        }
        let slot = self.with_state(|state| {
            state
                .placements_of_content(&ContentPublicId::Terminal(terminal.clone()))
                .first()
                .copied()
        })?;
        self.live_surface_starting_kept_tab(slot)?;
        self.resource_surface_for_terminal(terminal)
    }

    /// The live surface of host terminal `terminal_id` (32 hex: `send
    /// {terminal_id}`), starting its kept tab first as
    /// [`Self::live_surface_starting_kept_tab`] does.
    pub(crate) fn live_host_terminal_starting_kept(
        self: &Arc<Self>,
        terminal_id: &str,
    ) -> Option<Arc<Surface>> {
        let terminal = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_resource_id(terminal_id)
            .ok()??;
        let surface = self.live_terminal_starting_kept(&terminal)?;
        self.surface(surface)
    }

    /// The terminal of the tab at `surface` when that tab is kept (its
    /// `kept_tabs` row goes once its new shell is in the tab); None for any
    /// other tab.
    fn unstarted_kept_terminal(&self, surface: SurfaceId) -> Option<TerminalPublicId> {
        let (content, tab_id) = self.with_state(|state| {
            let indexes = &state.resource_indexes;
            (indexes.content_ids.get(&surface).cloned(), indexes.tab_ids.get(&surface).cloned())
        });
        let (Some(ContentPublicId::Terminal(terminal)), Some(tab_id)) = (content, tab_id) else {
            return None;
        };
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        registry.any_kept_tab(&[tab_id.to_string()]).ok()?.then_some(terminal)
    }

    /// Whether a start (`restart-tab`'s worker) of `terminal` still runs.
    fn terminal_start_pending(&self, terminal: &TerminalPublicId) -> bool {
        self.pending_terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(terminal.as_str())
    }
}
