//! `restart-tab` (`tab-restart-v1`): restart a dead terminal tab in place.
//!
//! User decision 2026-10-02 (plans/cmux-next/ownership.md section 3.2): a
//! dead tab offers one-click Restart. Every dead terminal tab qualifies: a
//! host loss, a process end kept by `keep_on_exit`, and a keep-layout tab.
//! The restart starts what `new-tab` starts (the default shell with shell
//! integration; the registry keeps no argv by policy, so a command tab
//! restarts as a shell) in the dead terminal's last directory: the dead
//! runtime's reported directory while this owner still has it, else the
//! keep-layout record's, else the request's `cwd`, else the default.
//!
//! Two steps, like every terminal creation: the session host launches the
//! new terminal (its registry reservation and ready commits), then one
//! resource commit swaps the tab's content to it and tombstones the dead
//! terminal once no tab shows it. The tab id, placement, name, pin and group
//! stay. The layout reducer checks the swap as `RestartTab`. A failed swap
//! ends the new terminal again; a replayed key returns the first result and
//! launches nothing.

use super::*;
use cmux_layout_reducer::{LayoutOpKind, TabContent};

const TAB_RESTART_OPERATION: &str = "tab.restart";
/// Every client uses this origin, so one idempotency key (for example one
/// derived from the dead terminal's id) restarts a tab once across clients.
const TAB_RESTART_ORIGIN: &str = "tab-restart";

/// Why a tab cannot be restarted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabRestartError {
    UnknownTab(SurfaceId),
    NotTerminal(SurfaceId),
    /// The tab's terminal has not ended (its registry row is not exited).
    NotDead(SurfaceId),
    /// `only_lost` and the terminal's end is a process end, not a host loss.
    NotLost(SurfaceId),
}

impl TabRestartError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownTab(_) => "tab-restart-unknown-tab",
            Self::NotTerminal(_) => "tab-restart-not-terminal",
            Self::NotDead(_) => "tab-restart-not-dead",
            Self::NotLost(_) => "tab-restart-not-lost",
        }
    }
}

impl fmt::Display for TabRestartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownTab(surface) => write!(formatter, "unknown tab {surface}"),
            Self::NotTerminal(surface) => write!(formatter, "tab {surface} is not a terminal"),
            Self::NotDead(surface) => {
                write!(formatter, "tab {surface} is not dead; only a dead tab can restart")
            }
            Self::NotLost(surface) => {
                write!(formatter, "tab {surface} ended on its own; its terminal host was not lost")
            }
        }
    }
}

impl std::error::Error for TabRestartError {}

/// One `restart-tab` request.
#[derive(Debug, Clone, Default)]
pub struct TabRestartRequest {
    pub surface: SurfaceId,
    pub idempotency_key: Option<String>,
    /// Used only when the daemon knows no directory for the dead terminal.
    pub cwd: Option<String>,
    /// Extra environment for the new terminal's child, as on `new-tab`.
    pub env: Vec<(String, String)>,
    /// Restart only a host loss (`TerminalEnd::HostLost`, which includes a
    /// signal during a session shutdown): the app's automatic restart
    /// (`terminal.restartLostTerminals`) leaves a process that ended on its
    /// own dead. The owner decides from its receipt and shutdown clock.
    pub only_lost: bool,
}

/// What `restart-tab` committed (or first committed, for a replay).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabRestartOutcome {
    pub result: Value,
    pub resource_revision: u64,
    pub replayed: bool,
}

/// The dead tab and what its restart launches.
struct RestartTarget {
    tab: TabPublicId,
    dead: TerminalPublicId,
    cwd: Option<String>,
    size: Option<(u16, u16)>,
    workspace_key: String,
    /// The dead terminal's durable exit receipt.
    receipt: Option<Value>,
}

impl Mux {
    /// Restart the dead terminal tab `request.surface` in place.
    pub fn restart_tab(
        self: &Arc<Self>,
        request: TabRestartRequest,
        transaction: Option<Arc<str>>,
    ) -> anyhow::Result<TabRestartOutcome> {
        let surface = request.surface;
        let mutation = match &request.idempotency_key {
            Some(key) => WorkspaceMutation::new(key.clone(), TAB_RESTART_ORIGIN)?,
            None => WorkspaceMutation::local(TAB_RESTART_ORIGIN),
        };
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let tab = self
            .with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())
            .ok_or(TabRestartError::UnknownTab(surface))?;
        let fingerprint = serde_json::json!({"operation": TAB_RESTART_OPERATION, "tab": tab});
        let replay = self.workspace_registry.lock().unwrap().replay_resource_patch(
            &mutation,
            TAB_RESTART_OPERATION,
            &fingerprint,
        )?;
        if let Some(replay) = replay {
            return Ok(TabRestartOutcome {
                result: replay.result,
                resource_revision: replay.revision,
                replayed: true,
            });
        }
        let kept = self.presentation_snapshot();
        let target = {
            let registry = self.workspace_registry.lock().unwrap();
            let state = self.state.lock().unwrap();
            restart_target_locked(&registry, &state, &kept.kept_tabs, surface)?
        };
        if request.only_lost {
            // A signal end still inside the shutdown lead is not yet a host
            // loss; the automatic restart treats it as a process end.
            let receipt = TerminalEnd::from_receipt(target.receipt.as_ref());
            let settled = self.session_shutdown.settle(receipt);
            if !matches!(settled.end(), TerminalEnd::HostLost(_)) {
                return Err(TabRestartError::NotLost(surface).into());
            }
        }
        let cwd = target.cwd.clone().or(request.cwd);
        let terminal_id = TerminalId::random()?;
        let reservation = TerminalReservationRequest {
            fingerprint: terminal_create_fingerprint(
                &target.workspace_key,
                Some(&terminal_id.to_hex()),
                None,
                cwd.as_deref(),
                None,
                target.size,
                None,
            )?,
            terminal_id,
            mutation: WorkspaceMutation::local("cmux-tui-tab-restart"),
            expected_generation: None,
            expected_revision: None,
            on_exit: TerminalOnExit::default(),
            env: request.env,
        };
        let fresh = self.spawn_surface_with(
            cwd.clone(),
            None,
            target.size,
            Some(&target.workspace_key),
            Some(reservation),
        )?;
        let committed =
            self.commit_tab_restart(&mutation, &fingerprint, surface, &target, &fresh, cwd);
        let (commit, retired) = match committed {
            Ok(committed) if !committed.0.replayed => committed,
            other => {
                if let Err(error) = self.fail_hosted_terminal_attachment(
                    &fresh,
                    TAB_RESTART_OPERATION,
                    "tab-restart-not-committed",
                ) {
                    eprintln!("cmux-tui: could not end an uncommitted restart: {error:#}");
                }
                let (commit, _) = other?;
                return Ok(TabRestartOutcome {
                    result: commit.result,
                    resource_revision: commit.revision,
                    replayed: true,
                });
            }
        };
        if let Some(retired) = retired {
            self.purge_terminal_runtime_side_tables(&retired);
        }
        if kept.kept_tabs.contains_key(target.tab.as_str()) {
            // The restarted tab is live again; its keep-layout record must not
            // keep it after the new terminal's own exit.
            self.forget_kept_tabs(&[target.tab.to_string()])?;
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit_tab_changed_for_transaction(surface, transaction);
        Ok(TabRestartOutcome {
            result: commit.result,
            resource_revision: commit.revision,
            replayed: false,
        })
    }

    /// The swap commit: the tab shows `fresh`, the dead terminal leaves the
    /// catalog once no other tab shows it, and the projection tombstones it.
    /// Returns the commit and the retired dead runtime, if one was live.
    fn commit_tab_restart(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        surface: SurfaceId,
        target: &RestartTarget,
        fresh: &Arc<Surface>,
        cwd: Option<String>,
    ) -> anyhow::Result<(ResourcePatchCommit, Option<Arc<Surface>>)> {
        let new_terminal =
            fresh.terminal_public_id().cloned().context("restarted terminal has no public id")?;
        let host = self
            .resource_terminal_host_identity(fresh)
            .context("restarted terminal has no durable host identity")?;
        let kept = self.presentation_snapshot();
        let mux = Arc::clone(self);
        let mut retired = None;
        let commit = self.commit_resource_mutation_plan(
            mutation,
            TAB_RESTART_OPERATION,
            fingerprint,
            None,
            None,
            |state, registry| {
                let current = restart_target_locked(registry, state, &kept.kept_tabs, surface)?;
                anyhow::ensure!(
                    current.dead == target.dead,
                    "stale: tab {surface} changed while it restarted"
                );
                // The new runtime is the tab's content, never a tab of its
                // own: it leaves its unplaced slot before the layout check.
                let runtime = state
                    .surfaces
                    .remove(&fresh.id)
                    .context("restarted terminal runtime disappeared")?;
                let mut projected = state.clone();
                let dead_content = ContentPublicId::Terminal(current.dead.clone());
                let shown_elsewhere = projected
                    .placements_of_content(&dead_content)
                    .iter()
                    .any(|placement| *placement != surface);
                if !shown_elsewhere {
                    retired = projected.terminal_catalog.remove(&current.dead);
                    if let Some(id) = retired.as_ref().and_then(|old| old.terminal_runtime_id()) {
                        projected.terminal_catalog_by_runtime.remove(&id);
                    }
                }
                let content_id = ContentPublicId::Terminal(new_terminal.clone());
                let view = runtime.project_terminal(
                    surface,
                    TabResourceIdentity::new(current.tab.clone(), content_id.clone()),
                )?;
                let content = TabContent {
                    runtime: Arc::as_ptr(&view) as *const () as usize as u64,
                    terminal: Some(new_terminal.to_string()),
                    dead: false,
                };
                projected.surfaces.insert(surface, view);
                // Tab identity is the topology's: the index names the content.
                projected.resource_indexes.content_ids.insert(surface, content_id);
                let result = serde_json::json!({
                    "surface": surface,
                    "tab": current.tab,
                    "terminal": new_terminal,
                    "terminal_id": host.terminal_id,
                    "terminal_incarnation": host.incarnation,
                    "replaced_terminal": current.dead,
                    "cwd": cwd,
                });
                let mut projection =
                    mux.resource_effect_projection_locked(registry, &mut projected, result)?;
                if !shown_elsewhere {
                    projection.ensure_terminal_close(&current.dead, None)?;
                }
                Ok(ResourceMutationPlan::replacing(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    projected,
                )
                .with_layout_op(LayoutOpKind::RestartTab { tab: surface, content }))
            },
        )?;
        Ok((commit, retired))
    }
}

/// The restart target of `surface`, or the typed reason it has none. Only a
/// terminal tab whose terminal's registry row is exited is dead.
fn restart_target_locked(
    registry: &WorkspaceRegistry,
    state: &State,
    kept_tabs: &HashMap<String, crate::workspace_registry::KeptTabRecord>,
    surface: SurfaceId,
) -> anyhow::Result<RestartTarget> {
    let pane = state.pane_of(surface).ok_or(TabRestartError::UnknownTab(surface))?;
    let (workspace, _) = state.screen_of(pane).ok_or(TabRestartError::UnknownTab(surface))?;
    let tab = state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .cloned()
        .ok_or(TabRestartError::UnknownTab(surface))?;
    let Some(ContentPublicId::Terminal(dead)) = state.resource_indexes.content_ids.get(&surface)
    else {
        return Err(TabRestartError::NotTerminal(surface).into());
    };
    let host = registry.live_terminal_host_id(dead)?.ok_or(TabRestartError::NotDead(surface))?;
    let record = registry.terminal_record(&host)?.ok_or(TabRestartError::NotDead(surface))?;
    if record.lifecycle != TerminalLifecycle::Exited {
        return Err(TabRestartError::NotDead(surface).into());
    }
    let view = state.surfaces.get(&surface);
    let runtime = state.terminal_catalog.get(dead).or(view);
    let cwd = runtime
        .and_then(|runtime| runtime.pwd().or_else(|| runtime.presented_directory()))
        .or_else(|| kept_tabs.get(tab.as_str()).and_then(|kept| kept.cwd.clone()));
    Ok(RestartTarget {
        tab,
        dead: dead.clone(),
        cwd,
        size: view.map(|view| view.size()),
        workspace_key: state.workspaces[workspace].key.clone(),
        receipt: record.exit,
    })
}

#[cfg(test)]
#[path = "tab_restart_tests.rs"]
mod tests;
