//! The manual restart of a dead terminal tab (`restart-tab`,
//! `tab-restart-v1`, plans/cmux-next/ownership.md section 3.2, cx-7e7b).
//!
//! It covers the tabs the automatic respawn leaves dead: a terminal whose
//! supervisor used every attempt (`restart_exhausted`) or whose respawn
//! launch failed (`restart_failed`), a host loss whose reason never
//! respawns, a process end the tab kept (`on_exit` keep), and a tab kept by
//! keep-layout. The user asked, so any end of the terminal's last
//! incarnation qualifies, no backoff applies, and the supervisor's attempt
//! count starts over (`supervisor.rs`). The restart runs the L2 worker
//! (`run_terminal_respawn`): the same terminal id gets a new shell and
//! incarnation in its tabs, below the previous screen and the marker line.
//! The tab id, placement, name, pin and group stay. A restarted keep-layout
//! tab starts in its recorded directory and stops being kept
//! (`tab-restart-kept-layout-v1`).
//!
//! A tab whose host link failed (`terminal_state` `failed`) is not dead:
//! its shell may still run. Restarting it is the user's Recover: the
//! unreachable host is ended and the same shell is rehosted in place
//! (`recover_failed_link_tab`), so an ssh session survives.

use super::*;

/// The `user_restart` cause in the loss log (`terminal_respawned`).
#[cfg(unix)]
const USER_RESTART_CAUSE: &str = "user_restart";

/// A refused restart, with its stable `error_code`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TabRestartError {
    /// The tab shows no daemon terminal (a browser, page or chat tab).
    NotTerminal,
    /// The tab's terminal runs, launches, adopts or already restarts.
    NotDead,
    /// This owner cannot start terminal hosts now (it shuts down, or it has
    /// no host root).
    Unavailable,
}

impl TabRestartError {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotTerminal => "tab-not-terminal",
            Self::NotDead => "tab-not-dead",
            Self::Unavailable => "tab-restart-unavailable",
        }
    }
}

impl fmt::Display for TabRestartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            Self::NotTerminal => "only a terminal tab can restart",
            Self::NotDead => "only a terminal tab whose shell ended can restart",
            Self::Unavailable => "this owner cannot start a terminal now",
        };
        formatter.write_str(text)
    }
}

impl std::error::Error for TabRestartError {}

/// An accepted restart: the worker runs; the tree shows the tab
/// restarting, then running (or dead again when the launch fails).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TabRestart {
    /// The public terminal id (`term_…`), the same before and after.
    pub(crate) terminal: String,
    pub(crate) previous_incarnation: String,
}

impl Mux {
    /// Restart the dead terminal of the tab at `surface` under the same
    /// terminal id. Returns once the worker started.
    #[cfg(unix)]
    pub(crate) fn restart_dead_tab(
        self: &Arc<Self>,
        surface: SurfaceId,
    ) -> anyhow::Result<TabRestart> {
        if let Some(recovered) = self.recover_failed_link_tab(surface) {
            return Ok(recovered);
        }
        let plan = self.plan_user_restart(surface)?;
        let accepted = TabRestart {
            terminal: plan.public_id.as_str().to_string(),
            previous_incarnation: plan.old_incarnation.clone(),
        };
        let mux = Arc::clone(self);
        let name = format!("terminal-restart-{}", plan.terminal_id);
        let spawned = std::thread::Builder::new().name(name).spawn(move || {
            mux.run_terminal_respawn(plan);
        });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: no thread to restart terminal {}: {error}", accepted.terminal);
        }
        Ok(accepted)
    }

    #[cfg(not(unix))]
    pub(crate) fn restart_dead_tab(
        self: &Arc<Self>,
        _surface: SurfaceId,
    ) -> anyhow::Result<TabRestart> {
        Err(TabRestartError::Unavailable.into())
    }

    /// Recover in place the tab at `surface` whose terminal still runs
    /// behind a failed host link (`terminal_state` `failed`): its
    /// unreachable host is ended and the reconnect loop rehosts the same
    /// shell on its PTY custody copy, under the same terminal id and
    /// incarnation (`surface/link_recover.rs`). None for any other tab.
    #[cfg(unix)]
    fn recover_failed_link_tab(&self, surface: SurfaceId) -> Option<TabRestart> {
        let (public_id, runtime) = self.with_state(|state| {
            let ContentPublicId::Terminal(public_id) =
                state.resource_indexes.content_ids.get(&surface)?
            else {
                return None;
            };
            let runtime = state.terminal_catalog.get(public_id)?.clone();
            Some((public_id.clone(), runtime))
        })?;
        let identity = runtime.terminal_host_identity()?;
        runtime.recover_failed_host_link().then(|| TabRestart {
            terminal: public_id.as_str().to_string(),
            previous_incarnation: identity.incarnation,
        })
    }

    /// Check the tab, mark its terminal respawning and take the dead runtime
    /// out of its tabs, as the automatic plan does.
    #[cfg(unix)]
    fn plan_user_restart(&self, surface: SurfaceId) -> anyhow::Result<RespawnPlan> {
        if self.shutting_down.load(Ordering::Acquire)
            || self.session_shutdown.began()
            || self.terminal_host_root().is_none()
        {
            return Err(TabRestartError::Unavailable.into());
        }
        let (content, tab_id) = self.with_state(|state| {
            let indexes = &state.resource_indexes;
            (indexes.content_ids.get(&surface).cloned(), indexes.tab_ids.get(&surface).cloned())
        });
        let (Some(content), Some(tab_id)) = (content, tab_id) else {
            anyhow::bail!("unknown surface {surface}");
        };
        let ContentPublicId::Terminal(public_id) = content.clone() else {
            return Err(TabRestartError::NotTerminal.into());
        };
        // The automatic plan's lock order: registry, pinned state, then the
        // pending leaf lock.
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let terminal_id =
            registry.live_terminal_host_id(&public_id)?.ok_or(TabRestartError::NotTerminal)?;
        let record = registry.terminal_record(&terminal_id)?.ok_or(TabRestartError::NotTerminal)?;
        if record.lifecycle != TerminalLifecycle::Exited {
            return Err(TabRestartError::NotDead.into());
        }
        let recorded = TerminalEnd::from_receipt(record.exit.as_ref()).exit().clone();
        let old_incarnation = record.incarnation.ok_or(TabRestartError::Unavailable)?;
        let mut state = self.lock_state_pinned(&registry).unwrap_or_else(PoisonError::into_inner);
        let placements = state.placements_of_content(&content).to_vec();
        // Keep-layout tabs (`kept_tabs`, `tab-restart-kept-layout-v1`): the
        // shell starts in the restarted tab's kept directory, and the worker
        // forgets these rows once the new runtime is in the tabs. Read under
        // the registry lock, so no commit lands between the read and the plan, and
        // before the pending marker, so a failed read leaves nothing behind.
        let mut tab_ids = vec![tab_id.to_string()];
        tab_ids.extend(
            placements
                .iter()
                .filter_map(|slot| {
                    state.resource_indexes.tab_ids.get(slot).map(|id| id.to_string())
                })
                .filter(|id| id != tab_id.as_str()),
        );
        let kept = registry.kept_tabs_of(&tab_ids)?;
        {
            let mut pending = self.pending_terminals.lock().unwrap_or_else(PoisonError::into_inner);
            if pending.contains_key(public_id.as_str())
                || pending.values().any(|(id, marker)| {
                    id == &terminal_id && *marker == PendingTerminal::Respawning
                })
            {
                return Err(TabRestartError::NotDead.into());
            }
            pending.insert(
                public_id.as_str().to_string(),
                (terminal_id.clone(), PendingTerminal::Respawning),
            );
        }
        // The user asked: the supervisor starts over for this terminal, so a
        // later loss of the new shell gets the full backoff schedule again.
        self.terminal_respawns
            .guard
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .forget(&terminal_id);
        let old_runtime = state.remove_catalog_terminal(&public_id);
        for placement in &placements {
            state.surfaces.remove(placement);
        }
        drop(state);
        drop(registry);
        Ok(RespawnPlan {
            terminal_id,
            public_id,
            old_incarnation,
            cause: USER_RESTART_CAUSE.to_string(),
            slot: surface,
            identity: TabResourceIdentity::new(tab_id, content),
            old_runtime,
            delay: Duration::ZERO,
            recorded,
            user_restart: true,
            kept,
        })
    }
}
