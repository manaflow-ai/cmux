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
    /// Whether the restore parking is on ([`LAZY_START_ENV`]).
    #[cfg(any(unix, windows))]
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
        // A never-started tab whose creation has not parked it yet.
        self.finish_lazy_created_at(surface);
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
                // A never-started tab whose park is still pending is parked
                // first, so it starts below.
                for (slot, _) in &tabs {
                    mux.finish_lazy_created_at(*slot);
                }
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

// Never-started tabs.
//
// A plain shell created by `new-workspace`, `new-tab` or `create-terminal`
// (no command, no extra environment, no shell arguments, not by the app,
// which shows what it creates) in a workspace no client shows, with lazy
// start on, gets no host: its tab is placed with a dead placeholder runtime
// of the request's size and directory (`Surface::exited_terminal_placeholder_with_identities`),
// and once the tab is placed its terminal is parked like a kept tab
// (`kept_tabs` with `on_show` and the request's cwd, then an exit commit the
// kept row holds the tab through). Its first need starts its first shell,
// with no previous screen and no marker line.

/// A never-started tab (`Mux::create_lazy_terminal`).
#[derive(Debug, Clone)]
pub(crate) struct LazyCreated {
    /// The incarnation its placeholder was committed under.
    incarnation: String,
    /// The directory the request asked for.
    cwd: Option<String>,
    /// Parked: its kept row and exit are committed.
    parked: bool,
}

thread_local! {
    /// Set by the request handlers that may create a never-started tab
    /// ([`lazy_create_scope`]).
    static LAZY_CREATE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The never-started runtimes this thread made in a scope, parked when
    /// the scope ends.
    static LAZY_PENDING: std::cell::RefCell<Vec<Arc<Surface>>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// A line of the lazy-start trace (`CMUX_TUI_LAZY_TRACE`, a file the
/// recovery tests read when a lazy tab is not parked).
fn lazy_trace(line: impl FnOnce() -> String) {
    use std::io::Write as _;
    let Some(path) = std::env::var_os("CMUX_TUI_LAZY_TRACE") else { return };
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}", line());
    }
}

/// While it lives, a terminal this thread creates may start lazily
/// (`allow`); the handler decided it is a plain shell from a creator that
/// is not showing it. When it ends, after the request placed its tabs, it
/// parks every tab it left unstarted, so a creation path that places the
/// tab after its last reap still reads parked (`relaunch.on_show`).
pub(crate) struct LazyCreateScope {
    previous: bool,
    pending_from: usize,
    mux: Arc<Mux>,
}

pub(crate) fn lazy_create_scope(mux: &Arc<Mux>, allow: bool) -> LazyCreateScope {
    LazyCreateScope {
        previous: LAZY_CREATE.with(|cell| cell.replace(allow)),
        pending_from: LAZY_PENDING.with(|pending| pending.borrow().len()),
        mux: mux.clone(),
    }
}

impl Drop for LazyCreateScope {
    fn drop(&mut self) {
        LAZY_CREATE.with(|cell| cell.set(self.previous));
        let made = LAZY_PENDING.with(|pending| {
            let mut pending = pending.borrow_mut();
            let from = self.pending_from.min(pending.len());
            pending.split_off(from)
        });
        lazy_trace(|| format!("scope end: {} pending", made.len()));
        for surface in made {
            #[cfg(unix)]
            {
                let parked = self.mux.finish_lazy_created(&surface);
                lazy_trace(|| format!("scope end: surface {} finish={parked}", surface.id));
            }
            #[cfg(not(unix))]
            drop(surface);
        }
    }
}

/// Whether `actor` is the app, which shows the tabs it creates.
pub(crate) fn actor_shows_what_it_creates(actor: &Actor) -> bool {
    matches!(actor, Actor::Frontend { .. } | Actor::App { .. })
}

impl Mux {
    /// Whether a `new-tab` in `pane` may start lazily, so its creation
    /// launches no host ahead of its commit (`server/terminal_create.rs`):
    /// lazy start is on and no client shows the pane's workspace. The
    /// create decides again ([`Self::lazy_create_allowed`]); a tab this
    /// skips that then starts at once only loses the head start.
    pub(crate) fn lazy_tab_skips_prelaunch(&self, pane: Option<PaneId>) -> bool {
        if !self.lazy_start() {
            return false;
        }
        let Some(pane) = pane else { return true };
        let key = self.with_state(|state| {
            state
                .screen_of(pane)
                .and_then(|(workspace, _)| state.workspaces.get(workspace))
                .map(|workspace| workspace.key.to_string())
        });
        key.is_none_or(|key| !self.workspace_key_shown(&key))
    }

    /// Whether a client shows the workspace `workspace_key`: one is
    /// attached to a tab of it.
    fn workspace_key_shown(&self, workspace_key: &str) -> bool {
        let attached = self.control_clients.attached_client_ids_by_surface();
        if attached.is_empty() {
            return false;
        }
        self.with_state(|state| {
            let Some(index) = state.workspaces.iter().position(|w| w.key == workspace_key) else {
                return false;
            };
            attached.keys().any(|surface| {
                state.pane_of(*surface).and_then(|pane| state.screen_of(pane)).map(|(w, _)| w)
                    == Some(index)
            })
        })
    }

    /// Whether the terminal this thread creates in `workspace_key` starts
    /// lazily.
    pub(in crate::mux) fn lazy_create_allowed(
        &self,
        workspace_key: &str,
        reservation_env: &[(String, String)],
    ) -> bool {
        LAZY_CREATE.with(std::cell::Cell::get)
            && self.lazy_start()
            && reservation_env.is_empty()
            && !self.workspace_key_shown(workspace_key)
    }

    /// Whether `terminal_id` is a never-started tab (its first shell has no
    /// previous screen).
    pub(in crate::mux) fn lazy_never_started(&self, terminal_id: &str) -> bool {
        self.terminal_respawns
            .lazy_created
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(terminal_id)
    }

    pub(in crate::mux) fn forget_lazy_created(&self, terminal_id: &str) {
        self.terminal_respawns
            .lazy_created
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_id);
    }

    /// The runtime of a never-started tab, in place of a launch: the
    /// registry row `terminal_hex` was reserved and its relaunch record
    /// written by the caller (`surface_spawn.rs`). Commits it running under
    /// a new incarnation with the dead placeholder in the catalog; the park
    /// follows once the tab is placed ([`Self::finish_lazy_created`]).
    #[cfg(unix)]
    pub(in crate::mux) fn create_lazy_terminal(
        self: &Arc<Self>,
        id: SurfaceId,
        opts: SurfaceOptions,
        tab_id: Option<TabPublicId>,
        terminal_hex: &str,
        workspace_key: &str,
    ) -> anyhow::Result<Arc<Surface>> {
        let failed = |reason: &str, incarnation: Option<&str>| {
            let _ = self.persist_terminal_exit(
                terminal_hex,
                incarnation,
                &TerminalEnd::launch_failed(reason.to_string()),
            );
        };
        let identity = self.spawn_identity(tab_id, false)?;
        let ContentPublicId::Terminal(public_id) = identity.content_id.clone() else {
            failed("lazy-identity-not-terminal", None);
            anyhow::bail!("a lazy terminal has a browser identity");
        };
        let incarnation = TerminalId::random()?.to_hex();
        let cwd = opts.cwd.clone();
        let surface = match Surface::exited_terminal_placeholder_with_identities(
            id,
            opts,
            Arc::downgrade(self),
            TerminalHostIdentity {
                terminal_id: terminal_hex.to_string(),
                incarnation: incarnation.clone(),
            },
            public_id,
            Some(identity),
        ) {
            Ok(surface) => surface,
            Err(error) => {
                failed("lazy-placeholder-failed", None);
                return Err(error);
            }
        };
        {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let (_, revision) = commit_terminal_lifecycle(
                &mut registry,
                "terminal-ready",
                "terminal-ready",
                terminal_hex,
                TerminalLifecycle::Running,
                Some(&incarnation),
                None,
            )?;
            self.emit_terminal_registry_changed(&registry, revision);
        }
        self.terminal_respawns.lazy_created.lock().unwrap_or_else(PoisonError::into_inner).insert(
            terminal_hex.to_string(),
            LazyCreated { incarnation: incarnation.clone(), cwd, parked: false },
        );
        lazy_trace(|| format!("create: surface {id} terminal {terminal_hex}"));
        LAZY_PENDING.with(|pending| pending.borrow_mut().push(surface.clone()));
        if let Err(error) = self.insert_created_terminal(surface.clone(), workspace_key) {
            self.forget_lazy_created(terminal_hex);
            failed("surface-insert-failed", Some(&incarnation));
            return Err(error);
        }
        // Never started, it holds a blank screen until its tab is shown;
        // the start makes a new runtime, so park this one's mirror now.
        surface.park_exited_mirror();
        Ok(surface)
    }

    /// Park the never-started tab at `slot`, when it is one whose park is
    /// pending.
    #[cfg(unix)]
    pub(crate) fn finish_lazy_created_at(&self, slot: SurfaceId) {
        if let Some(runtime) = self.surface(slot) {
            self.finish_lazy_created(&runtime);
        }
    }

    /// Park the never-started tab of `surface` once its tab is placed: its
    /// kept row (`on_show`, the request's directory), then the exit commit
    /// that row keeps the tab through. True when `surface` is a
    /// never-started tab's runtime (parked now, before, or still waiting for
    /// its placement): a creator's reap must leave it alone.
    #[cfg(unix)]
    pub(in crate::mux) fn finish_lazy_created(&self, surface: &Arc<Surface>) -> bool {
        let Some(host) = surface.terminal_host_identity() else {
            lazy_trace(|| format!("finish {}: no host identity", surface.id));
            return false;
        };
        let Some(public_id) = surface.terminal_public_id().cloned() else {
            lazy_trace(|| format!("finish {}: no public id", surface.id));
            return false;
        };
        let _turn =
            self.terminal_respawns.lazy_finish.lock().unwrap_or_else(PoisonError::into_inner);
        let pending = {
            let created =
                self.terminal_respawns.lazy_created.lock().unwrap_or_else(PoisonError::into_inner);
            match created.get(&host.terminal_id) {
                Some(entry) if entry.incarnation == host.incarnation => entry.clone(),
                entry => {
                    lazy_trace(|| {
                        format!("finish {}: no pending entry ({entry:?}, {host:?})", surface.id)
                    });
                    return false;
                }
            }
        };
        if pending.parked {
            return true;
        }
        let content = ContentPublicId::Terminal(public_id.clone());
        let tab_ids = self.with_state(|state| {
            state
                .placements_of_content(&content)
                .iter()
                .filter_map(|slot| state.resource_indexes.tab_ids.get(slot).map(|t| t.to_string()))
                .collect::<Vec<_>>()
        });
        lazy_trace(|| format!("finish {}: tabs {tab_ids:?}", surface.id));
        if tab_ids.is_empty() {
            return true;
        }
        let rows = tab_ids
            .into_iter()
            .map(|tab_id| KeptTab {
                tab_id,
                cwd: pending.cwd.clone(),
                title: None,
                on_show: true,
                last_command: None,
            })
            .collect::<Vec<_>>();
        if let Err(error) = self.commit_kept_tabs(&rows) {
            lazy_trace(|| format!("finish {}: kept rows failed: {error:#}", surface.id));
            eprintln!("cmux-tui: could not park new terminal {public_id}: {error:#}");
            return true;
        }
        if let Err(error) = self.persist_terminal_exit(
            &host.terminal_id,
            Some(&host.incarnation),
            &TerminalEnd::launch_failed("not-started-until-shown"),
        ) {
            lazy_trace(|| format!("finish {}: exit commit failed: {error:#}", surface.id));
            eprintln!("cmux-tui: could not park new terminal {public_id}: {error:#}");
            return true;
        }
        lazy_trace(|| format!("finish {}: parked", surface.id));
        if let Some(entry) = self
            .terminal_respawns
            .lazy_created
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&host.terminal_id)
        {
            entry.parked = true;
        }
        true
    }

    #[cfg(not(unix))]
    pub(crate) fn finish_lazy_created_at(&self, _slot: SurfaceId) {}
}
