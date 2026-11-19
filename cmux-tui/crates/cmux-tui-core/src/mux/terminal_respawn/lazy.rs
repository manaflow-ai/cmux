//! Lazy start (infinite-items-flat). Leo, 2026-11-19: "Lazy start: a
//! restored or never-shown tab doesn't spawn its shell until it is first
//! shown. It keeps its title, cwd and scrollback from the snapshot."
//!
//! A restored tab: when a host loss would respawn a plain shell (a relaunch
//! record of kind `shell` with no agent session, no command argv) of a
//! workspace that is not the active one, the respawn decision parks its
//! tabs instead ([`RespawnDecision::Park`]): the same `kept_tabs` row with
//! `on_show` that `park-tabs` writes, with the launch record's directory and
//! the dead runtime's title. Agents and commands respawn as before. When a
//! client shows that workspace by the time the row is written, the tab
//! starts at once.
//!
//! A parked tab (this one, `park-tabs`, a respawn that found no free PTY)
//! starts on its first need, transparently: [`Mux::wake_lazy_tab`] starts
//! it through the restart path (`manual.rs`, outside the respawn gate's
//! line, its previous screen as the seed) and waits until its new runtime is
//! in the tabs, then the request goes on. The server's surface lookup
//! (`server.rs` `get_surface`: attach, input, paste, screen and scrollback
//! reads, waits, resize, process info) and the terminal resource lookups
//! call it; `select-workspace` starts the parked tabs of the workspace it
//! selects, as the app does when it shows one (`wakeParkedTabs`). Concurrent
//! needs start it once: the restart marks the terminal respawning under the
//! registry lock, and every later need waits for that start.
//!
//! The setting: `CMUX_TUI_LAZY_START` (`1`/`on` turns the restore parking
//! on; off by default). The wake on first need is always on: it only acts on
//! tabs that are already parked to start on show.

use super::manual::TabRestartError;
use super::*;
use crate::state::kept_tab_store::kept_title;
use crate::workspace_registry::relaunch_store::RelaunchKind;

/// The environment switch of the restore parking.
pub(crate) const LAZY_START_ENV: &str = "CMUX_TUI_LAZY_START";

/// The longest a request waits for a parked tab's shell to start.
const WAKE_WAIT: Duration = Duration::from_secs(10);

/// Whether `CMUX_TUI_LAZY_START` turns the restore parking on.
pub(crate) fn lazy_start_from_env() -> bool {
    std::env::var(LAZY_START_ENV)
        .is_ok_and(|value| matches!(value.trim(), "1" | "on" | "true" | "yes"))
}

impl Mux {
    /// Turn the restore parking on or off (tests; the daemon reads
    /// [`LAZY_START_ENV`]).
    pub(crate) fn set_lazy_start(&self, on: bool) {
        self.terminal_respawns.lazy_start.store(on, Ordering::Release);
    }

    pub(crate) fn lazy_start(&self) -> bool {
        self.terminal_respawns.lazy_start.load(Ordering::Acquire)
    }

    /// Whether the lost terminal `terminal_id`, first placed at `slot`, is
    /// parked instead of respawned: lazy start is on, its workspace is not
    /// the active one, and it ran a plain shell. Under the registry and
    /// state locks of the respawn decision.
    #[cfg(any(unix, windows))]
    pub(super) fn lazy_restore_parks(
        &self,
        registry: &WorkspaceRegistry,
        state: &State,
        terminal_id: &str,
        slot: SurfaceId,
    ) -> bool {
        if !self.lazy_start() {
            return false;
        }
        let hidden = state
            .pane_of(slot)
            .and_then(|pane| state.screen_of(pane))
            .is_some_and(|(workspace, _)| workspace != state.active_workspace);
        if !hidden || self.terminal_respawns.argv(terminal_id).is_some() {
            return false;
        }
        matches!(
            registry.terminal_relaunch_record(terminal_id),
            Ok(Some(record)) if record.kind == RelaunchKind::Shell && record.agent.is_none()
        )
    }

    /// Park the tabs of the lost plain shell `public_id`
    /// ([`RespawnDecision::Park`]), with no lock held. A workspace a client
    /// shows by now starts its tab at once.
    #[cfg(any(unix, windows))]
    pub(super) fn park_lazy_restored_terminal(&self, public_id: &TerminalPublicId) {
        let content = ContentPublicId::Terminal(public_id.clone());
        let (slots, title) = self.with_state(|state| {
            let slots = state
                .placements_of_content(&content)
                .iter()
                .filter_map(|slot| {
                    state.resource_indexes.tab_ids.get(slot).map(|tab| (*slot, tab.to_string()))
                })
                .collect::<Vec<_>>();
            let title = state
                .terminal_catalog
                .get(public_id)
                .and_then(|runtime| kept_title(&runtime.title()));
            (slots, title)
        });
        let cwd = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            registry
                .terminal_host_id(public_id)
                .ok()
                .flatten()
                .and_then(|terminal_id| {
                    registry.terminal_relaunch_record(&terminal_id).ok().flatten()
                })
                .and_then(|record| record.cwd)
        };
        let rows = slots
            .iter()
            .map(|(_, tab_id)| KeptTab {
                tab_id: tab_id.clone(),
                cwd: cwd.clone(),
                title: title.clone(),
                on_show: true,
                last_command: None,
            })
            .collect::<Vec<_>>();
        if let Err(error) = self.commit_kept_tabs(&rows) {
            // The tab shows its host loss, with its Restart button.
            eprintln!("cmux-tui: could not park lost terminal {public_id}: {error:#}");
            return;
        }
        self.emit(MuxEvent::TreeChanged);
        if let Some((slot, _)) = slots.first()
            && self.slot_workspace_shown(*slot)
            && let Some(mux) = self.exit_settles.owner()
            && let Err(error) = mux.restart_dead_tab(*slot)
        {
            eprintln!("cmux-tui: parked terminal {public_id} did not start: {error:#}");
        }
    }

    /// Whether a client shows the workspace of the tab at `slot`: it is the
    /// active workspace, or a client is attached to one of its tabs.
    pub(crate) fn slot_workspace_shown(&self, slot: SurfaceId) -> bool {
        // The client registry first: never under the state lock.
        let attached = self.control_clients.attached_client_ids_by_surface();
        self.with_state(|state| {
            let workspace_of = |surface: SurfaceId| {
                state.pane_of(surface).and_then(|pane| state.screen_of(pane)).map(|(w, _)| w)
            };
            let Some(workspace) = workspace_of(slot) else { return false };
            workspace == state.active_workspace
                || attached.keys().any(|surface| workspace_of(*surface) == Some(workspace))
        })
    }

    /// Whether the tab at `surface` has a live runtime.
    fn live_runtime_at(&self, surface: SurfaceId) -> bool {
        self.with_state(|state| state.surfaces.get(&surface).is_some_and(|s| !s.is_dead()))
    }

    /// First need of the tab at `surface`: when it is a parked terminal tab
    /// (`relaunch.on_show`), start its shell and wait until the new runtime
    /// is in the tabs. True when the tab runs now because of this call or a
    /// concurrent one; false for any other tab (a live one, a browser, a
    /// dead tab that is not parked) or when the start failed or took longer
    /// than [`WAKE_WAIT`].
    #[cfg(unix)]
    pub(crate) fn wake_lazy_tab(&self, surface: SurfaceId) -> bool {
        if self.live_runtime_at(surface) {
            return false;
        }
        let Some((public_id, tab_id)) = self.with_state(|state| {
            let ContentPublicId::Terminal(id) = state.resource_indexes.content_ids.get(&surface)?
            else {
                return None;
            };
            Some((id.clone(), state.resource_indexes.tab_ids.get(&surface)?.to_string()))
        }) else {
            return false;
        };
        let (parked, terminal_id) = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let parked = registry
                .kept_tabs_of(&[tab_id])
                .is_ok_and(|rows| rows.iter().any(|row| row.on_show));
            (parked, registry.live_terminal_host_id(&public_id).ok().flatten())
        };
        let (true, Some(terminal_id)) = (parked, terminal_id) else { return false };
        let Some(mux) = self.exit_settles.owner() else { return false };
        // Subscribed before the start, so its install is never missed.
        let events = self.subscribe_terminal_lifecycle();
        match mux.restart_dead_tab(surface) {
            Ok(_) => {}
            // A concurrent need started it already: wait for that start.
            Err(error)
                if error.downcast_ref::<TabRestartError>() == Some(&TabRestartError::NotDead) => {}
            Err(error) => {
                eprintln!("cmux-tui: parked terminal {public_id} did not start: {error:#}");
                return false;
            }
        }
        let deadline = Instant::now() + WAKE_WAIT;
        loop {
            if self.live_runtime_at(surface) {
                return true;
            }
            if !self.terminal_is_respawning(&terminal_id) {
                return self.live_runtime_at(surface);
            }
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                eprintln!(
                    "cmux-tui: parked terminal {public_id} did not start within {WAKE_WAIT:?}"
                );
                return false;
            };
            let _ = events.recv_timeout(left);
        }
    }

    #[cfg(not(unix))]
    pub(crate) fn wake_lazy_tab(&self, _surface: SurfaceId) -> bool {
        false
    }

    /// [`Self::wake_lazy_tab`] for the first tab of terminal `terminal`.
    pub(crate) fn wake_lazy_terminal(&self, terminal: &TerminalPublicId) -> bool {
        let content = ContentPublicId::Terminal(terminal.clone());
        let slot = self.with_state(|state| {
            if state.terminal_catalog.get(terminal).is_some_and(|runtime| !runtime.is_dead()) {
                return None;
            }
            state.placements_of_content(&content).first().copied()
        });
        slot.is_some_and(|slot| self.wake_lazy_tab(slot))
    }

    /// Start every parked tab (`relaunch.on_show`) of the active workspace,
    /// as the app does when it shows a workspace. Runs on its own thread:
    /// the selection never waits for it.
    #[cfg(unix)]
    pub(crate) fn wake_parked_tabs_of_active_workspace(self: &Arc<Self>) {
        let tabs = self.with_state(|state| {
            let active = state.active_workspace;
            state
                .panes
                .values()
                .filter(|pane| state.screen_of(pane.id).is_some_and(|(w, _)| w == active))
                .flat_map(|pane| pane.tabs.iter().copied())
                .filter(|slot| state.surfaces.get(slot).is_none_or(|s| s.is_dead()))
                .filter(|slot| {
                    matches!(
                        state.resource_indexes.content_ids.get(slot),
                        Some(ContentPublicId::Terminal(_))
                    )
                })
                .filter_map(|slot| {
                    Some((slot, state.resource_indexes.tab_ids.get(&slot)?.to_string()))
                })
                .collect::<Vec<_>>()
        });
        if tabs.is_empty() {
            return;
        }
        let mux = Arc::clone(self);
        let spawned =
            std::thread::Builder::new().name("terminal-wake-parked".into()).spawn(move || {
                let parked = {
                    let registry =
                        mux.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
                    let ids = tabs.iter().map(|(_, tab)| tab.clone()).collect::<Vec<_>>();
                    registry.kept_tabs_of(&ids).unwrap_or_default()
                };
                for (slot, tab) in tabs {
                    if parked.iter().any(|row| row.tab_id == tab && row.on_show)
                        && let Err(error) = mux.restart_dead_tab(slot)
                        && error.downcast_ref::<TabRestartError>()
                            != Some(&TabRestartError::NotDead)
                    {
                        eprintln!("cmux-tui: parked tab {tab} did not start: {error:#}");
                    }
                }
            });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: no thread to start parked tabs: {error}");
        }
    }

    #[cfg(not(unix))]
    pub(crate) fn wake_parked_tabs_of_active_workspace(self: &Arc<Self>) {}
}
