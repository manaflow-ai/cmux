//! Respawn of a placed terminal whose shell was lost with its host
//! (cx-6so.49 L2).
//!
//! When a host loss (never a process end, a close, End Sessions, a session
//! shutdown or this daemon's own shutdown) ends a terminal that still has a
//! tab, the owner starts a new shell for the same terminal id, so tabs,
//! splits, pins and agent references keep pointing at it. The live host
//! death path, startup reconciliation and the adoption loop all commit that
//! loss through `persist_terminal_exit`, which calls
//! [`Mux::schedule_terminal_respawn`].
//!
//! The schedule step runs synchronously: it checks the cause and the crash
//! loop bound, takes the dead runtime out of the tabs (they stay, surfaceless)
//! and marks the terminal [`PendingTerminal::Respawning`], so no tree push
//! shows the tab dead. A worker then reopens the registry row
//! (`terminal_respawn_store`), launches a host through the normal launch
//! path with the previous screen as its seed and one dim marker line, and
//! commits the new incarnation. A failure records the loss again (a reason
//! that never respawns) and the tab shows dead, as before L2.
//!
//! The launch and seed (`terminal_respawn/launch.rs`) and the pre-fill
//! (`terminal_respawn/prefill.rs`): an agent resume command or the terminal's
//! command line is typed on the new prompt without a newline.

#[cfg(unix)]
pub(super) mod launch;
#[cfg(unix)]
mod prefill;

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::*;
#[cfg(unix)]
use crate::terminal_loss_log::Prefilled;

/// At most one respawn per terminal in this window.
const RESPAWN_SPACING: Duration = Duration::from_secs(60);
/// At most [`RESPAWN_BURST`] respawns per terminal in this window.
const RESPAWN_WINDOW: Duration = Duration::from_secs(600);
const RESPAWN_BURST: usize = 3;
/// Disables respawn for a daemon (tests that exercise dead tabs).
const DISABLE_ENV: &str = "CMUX_TUI_TEST_DISABLE_RESPAWN";
/// Holds a scheduled respawn this long before it starts (tests of a close
/// that races the respawn).
const DELAY_ENV: &str = "CMUX_TUI_TEST_RESPAWN_DELAY_MS";
/// Host-loss reasons (`TerminalEnd::wire_json` `reason`) that respawn.
const RESPAWN_REASONS: &[&str] = &[
    "dead_before_adoption",
    "died_during_adoption",
    "died_without_exit_status",
    "missing_record",
    "incarnation_mismatch",
];

/// The crash-loop bound: attempts per terminal, by start time.
#[derive(Debug, Default)]
pub(crate) struct RespawnGuard {
    attempts: HashMap<String, VecDeque<Instant>>,
}

impl RespawnGuard {
    /// Record an attempt for `terminal_id` at `now` unless the bound refuses it.
    pub(crate) fn admit(&mut self, terminal_id: &str, now: Instant) -> bool {
        let attempts = self.attempts.entry(terminal_id.to_string()).or_default();
        attempts.retain(|at| now.saturating_duration_since(*at) < RESPAWN_WINDOW);
        let spaced = attempts
            .back()
            .is_none_or(|last| now.saturating_duration_since(*last) >= RESPAWN_SPACING);
        if !spaced || attempts.len() >= RESPAWN_BURST {
            return false;
        }
        attempts.push_back(now);
        true
    }
}

/// The owner's respawn state.
#[derive(Debug)]
pub(crate) struct TerminalRespawns {
    disabled: bool,
    delay: Option<Duration>,
    guard: Mutex<RespawnGuard>,
    /// Full argv of command terminals this daemon process launched; it is
    /// never persisted, so a later daemon only names the program. Entries go
    /// when their terminal is closed; [`ARGV_LIMIT`] bounds the rest.
    argv: Mutex<ArgvMemory>,
    /// VT replay a new terminal's host applies before its shell's first
    /// byte, by the reserved terminal id of a creation that has not launched
    /// yet (Reopen Closed of an archived terminal, ARCHIVE-1). The launch
    /// takes it; the creator removes it when the creation fails.
    seeds: Mutex<HashMap<String, Vec<u8>>>,
}

/// At most this many command argvs are kept; the oldest goes first.
pub(crate) const ARGV_LIMIT: usize = 512;

#[derive(Debug, Default)]
struct ArgvMemory {
    by_terminal: HashMap<String, Vec<String>>,
    order: std::collections::VecDeque<String>,
}

impl ArgvMemory {
    fn insert(&mut self, terminal_id: &str, argv: &[String]) {
        if self.by_terminal.insert(terminal_id.to_string(), argv.to_vec()).is_none() {
            self.order.push_back(terminal_id.to_string());
        }
        while self.order.len() > ARGV_LIMIT {
            if let Some(oldest) = self.order.pop_front() {
                self.by_terminal.remove(&oldest);
            }
        }
    }

    fn remove(&mut self, terminal_id: &str) {
        if self.by_terminal.remove(terminal_id).is_some() {
            self.order.retain(|id| id != terminal_id);
        }
    }
}

impl TerminalRespawns {
    pub(crate) fn from_env() -> Self {
        Self {
            // Unit tests of this crate model a host loss as a dead tab
            // (invariant 3); the respawn is covered by the daemon's
            // integration tests (`tests/terminal_host_recovery/terminal_respawn.rs`).
            disabled: cfg!(test) || std::env::var(DISABLE_ENV).is_ok_and(|value| value == "1"),
            delay: std::env::var(DELAY_ENV)
                .ok()
                .and_then(|value| value.parse().ok())
                .map(Duration::from_millis),
            guard: Mutex::default(),
            argv: Mutex::default(),
            seeds: Mutex::default(),
        }
    }

    /// Give the launch of reserved terminal `terminal_id` the seed `seed`.
    pub(crate) fn stash_seed(&self, terminal_id: &str, seed: Vec<u8>) {
        self.seeds.lock().unwrap_or_else(PoisonError::into_inner).insert(terminal_id.into(), seed);
    }

    /// The seed of reserved terminal `terminal_id`, once.
    pub(crate) fn take_seed(&self, terminal_id: &str) -> Option<Vec<u8>> {
        self.seeds.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id)
    }

    /// Remember the argv of command terminal `terminal_id`.
    pub(crate) fn remember_argv(&self, terminal_id: &str, argv: &[String]) {
        self.argv.lock().unwrap_or_else(PoisonError::into_inner).insert(terminal_id, argv);
    }

    /// Forget the argv of a closed terminal.
    pub(crate) fn forget_argv(&self, terminal_id: &str) {
        self.argv.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
    }

    pub(crate) fn argv(&self, terminal_id: &str) -> Option<Vec<String>> {
        self.argv
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .by_terminal
            .get(terminal_id)
            .cloned()
    }
}

/// One respawn, decided by [`Mux::schedule_terminal_respawn`].
#[cfg(unix)]
pub(super) struct RespawnPlan {
    pub(super) terminal_id: String,
    pub(super) public_id: TerminalPublicId,
    pub(super) old_incarnation: String,
    /// The `host_lost` reason.
    pub(super) cause: String,
    /// The first placement: the new runtime's slot and tab identity.
    pub(super) slot: SurfaceId,
    pub(super) identity: TabResourceIdentity,
    /// The dead runtime taken out of the tabs, for its geometry and budget.
    pub(super) old_runtime: Option<Arc<Surface>>,
}

impl Mux {
    /// After a committed host loss of `terminal_id`: when the terminal is
    /// placed and the loss qualifies, take its dead runtime out of the tabs,
    /// mark it respawning and start the respawn worker. Never fails the exit
    /// commit; a refused respawn leaves the tab dead.
    #[cfg(unix)]
    pub(super) fn schedule_terminal_respawn(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
        end: &TerminalEnd,
    ) {
        let Some(plan) = self.plan_terminal_respawn(terminal_id, incarnation, end) else { return };
        let Some(mux) = self.exit_settles.owner() else { return };
        let name = format!("terminal-respawn-{terminal_id}");
        let spawned = std::thread::Builder::new().name(name).spawn(move || {
            if let Some(delay) = mux.terminal_respawns.delay {
                std::thread::sleep(delay);
            }
            mux.run_terminal_respawn(plan);
        });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: no thread to respawn terminal {terminal_id}: {error}");
        }
    }

    #[cfg(not(unix))]
    pub(super) fn schedule_terminal_respawn(
        &self,
        _terminal_id: &str,
        _incarnation: Option<&str>,
        _end: &TerminalEnd,
    ) {
    }

    #[cfg(unix)]
    fn respawn_enabled(&self) -> bool {
        !self.terminal_respawns.disabled
            && !self.shutting_down.load(Ordering::Acquire)
            && !self.session_shutdown.began()
            && self.terminal_host_root().is_some()
    }

    #[cfg(unix)]
    fn plan_terminal_respawn(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
        end: &TerminalEnd,
    ) -> Option<RespawnPlan> {
        let TerminalEnd::HostLost(_) = end else { return None };
        let cause = end.wire_json()["reason"].as_str()?.to_string();
        if !RESPAWN_REASONS.contains(&cause.as_str()) || !self.respawn_enabled() {
            return None;
        }
        let old_incarnation = incarnation?.to_string();
        let public_id = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_resource_id(terminal_id)
            .ok()??;
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let content = ContentPublicId::Terminal(public_id.clone());
        let placements = state.placements_of_content(&content).to_vec();
        let slot = *placements.first()?;
        let tab_id = state.resource_indexes.tab_ids.get(&slot)?.clone();
        let admitted = self
            .terminal_respawns
            .guard
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .admit(terminal_id, Instant::now());
        if !admitted {
            eprintln!(
                "cmux-tui: terminal {terminal_id} lost its host again too soon; it stays ended"
            );
            return None;
        }
        // The tabs stay; only the dead runtime leaves them, so they read as
        // respawning, not dead, until the new runtime takes its place.
        let old_runtime = state.terminal_catalog.remove(&public_id);
        if let Some(runtime_id) = old_runtime.as_ref().and_then(|old| old.terminal_runtime_id()) {
            state.terminal_catalog_by_runtime.remove(&runtime_id);
        }
        for placement in &placements {
            state.surfaces.remove(placement);
        }
        drop(state);
        self.pending_terminals.lock().unwrap_or_else(PoisonError::into_inner).insert(
            public_id.as_str().to_string(),
            (terminal_id.to_string(), PendingTerminal::Respawning),
        );
        Some(RespawnPlan {
            terminal_id: terminal_id.to_string(),
            public_id,
            old_incarnation,
            cause,
            slot,
            identity: TabResourceIdentity::new(tab_id, content),
            old_runtime,
        })
    }

    /// The respawn worker: respawn, then pre-fill; on failure or a refused
    /// respawn the tab shows the terminal ended.
    #[cfg(unix)]
    fn run_terminal_respawn(self: &Arc<Self>, plan: RespawnPlan) {
        let terminal_id = plan.terminal_id.clone();
        let public_id = plan.public_id.clone();
        let (old_incarnation, cause) = (plan.old_incarnation.clone(), plan.cause.clone());
        let outcome = self.respawn_terminal(plan);
        self.pending_terminals.lock().unwrap_or_else(PoisonError::into_inner).retain(
            |_, (id, pending)| id != &terminal_id || *pending != PendingTerminal::Respawning,
        );
        match outcome {
            Ok(Some((surface, prefill))) => {
                self.forget_terminal_end(public_id.as_str());
                self.emit(MuxEvent::TreeChanged);
                let new_incarnation =
                    surface.terminal_host_identity().map(|identity| identity.incarnation);
                let prefilled = prefill.as_ref().map_or(Prefilled::None, |prefill| prefill.kind);
                if let Some(root) = self.terminal_host_root() {
                    crate::terminal_loss_log::record_terminal_respawned(
                        &root,
                        &terminal_id,
                        (&old_incarnation, new_incarnation.as_deref().unwrap_or_default()),
                        &cause,
                        prefilled,
                    );
                }
                if let Some(prefill) = prefill {
                    prefill.type_on_prompt(&surface);
                }
            }
            Ok(None) => {
                self.record_terminal_end(&terminal_id);
                self.emit(MuxEvent::TreeChanged);
            }
            Err(error) => {
                eprintln!("cmux-tui: terminal {terminal_id} was not respawned: {error:#}");
                let lost = TerminalEnd::host_lost(format!("respawn-failed: {error:#}"));
                if let Err(error) = self.persist_terminal_exit(&terminal_id, None, &lost) {
                    eprintln!("cmux-tui: could not record terminal {terminal_id} end: {error:#}");
                }
                self.record_terminal_end(&terminal_id);
                self.emit(MuxEvent::TreeChanged);
            }
        }
    }

    #[cfg(unix)]
    fn terminal_host_root(&self) -> Option<std::path::PathBuf> {
        let options = self.surface_options.lock().unwrap_or_else(PoisonError::into_inner);
        options.terminal_host_root.clone()
    }

    /// Reopen the row, launch the new host and put it in the tabs. `None`
    /// when a close or another end won, or the owner is shutting down.
    #[cfg(unix)]
    fn respawn_terminal(
        self: &Arc<Self>,
        mut plan: RespawnPlan,
    ) -> anyhow::Result<Option<(Arc<Surface>, Option<prefill::Prefill>)>> {
        if self.shutting_down.load(Ordering::Acquire) {
            return Ok(None);
        }
        let old_runtime = plan.old_runtime.take();
        let geometry = old_runtime.as_ref().map(|old| (old.size(), old.cell_pixel_size()));
        if let Some(old) = old_runtime.as_ref() {
            self.unregister_kitty_image_surface(old)?;
        }
        drop(old_runtime);
        let (record, seed_source) = {
            let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let record = registry.terminal_relaunch_record(&plan.terminal_id)?;
            (record, self.previous_screen(&registry, &plan))
        };
        let launch = self.respawn_launch(&plan, record.as_ref(), seed_source, geometry);
        let workspace_key = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(revision) =
                registry.begin_terminal_respawn(&plan.terminal_id, &plan.old_incarnation)?
            else {
                return Ok(None);
            };
            self.emit_terminal_registry_changed(&registry, revision);
            registry.terminal_record(&plan.terminal_id)?.map(|terminal| terminal.workspace_key)
        };
        if let Some(root) = self.terminal_host_root() {
            remove_dead_host_records(&root, &plan.terminal_id);
        }
        let terminal_id = TerminalId::from_hex(&plan.terminal_id)
            .context("terminal id is not a canonical UUIDv4")?;
        let surface = Surface::respawn_hosted(
            plan.slot,
            launch.options,
            Arc::downgrade(self),
            terminal_id,
            plan.identity.clone(),
            launch.cell_pixels,
            &launch.seed,
        )?;
        let _pending_host_release = PendingTerminalHostRelease(surface.clone());
        let activated = match self.install_respawned_runtime(&plan, &surface) {
            Ok(true) => surface.activate_hosted_launch_stream().map(drop),
            Ok(false) => {
                surface.kill();
                return Ok(None);
            }
            Err(error) => Err(error),
        };
        if let Err(error) = activated {
            surface.kill();
            return Err(error);
        }
        if let Some(workspace_key) = workspace_key.as_deref() {
            // Deprecated recovery mirror only; SQLite is placement authority.
            let _ = surface.persist_host_workspace(workspace_key);
        }
        self.publish_resource_event();
        let _ = self.retry_pending_agent_hooks_for_terminal(&plan.public_id);
        self.reconcile_agent_roster_projections_for_terminal(&plan.public_id);
        let prefill = self.respawn_prefill(&plan.terminal_id, record.as_ref());
        Ok(Some((surface, prefill)))
    }

    /// Put the new runtime in the terminal's tabs and commit the new
    /// incarnation in one registry + state critical section. False when a
    /// close won.
    #[cfg(unix)]
    fn install_respawned_runtime(
        &self,
        plan: &RespawnPlan,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<bool> {
        let incarnation = surface
            .terminal_host_identity()
            .context("respawned terminal has no host identity")?
            .incarnation;
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(mut durable) = registry.terminal_record(&plan.terminal_id)? else {
            return Ok(false);
        };
        if durable.lifecycle != TerminalLifecycle::Launching {
            return Ok(false);
        }
        let before = state.clone();
        insert_restored_terminal_runtime_checked(&mut state, surface.clone())?;
        let content = ContentPublicId::Terminal(plan.public_id.clone());
        let tab_ids = state
            .placements_of_content(&content)
            .iter()
            .filter_map(|slot| state.resource_indexes.tab_ids.get(slot).cloned())
            .collect::<Vec<_>>();
        durable.lifecycle = TerminalLifecycle::Running;
        durable.incarnation = Some(incarnation.clone());
        let committed = crate::resource_api::public_terminal_snapshot(
            &plan.public_id,
            &durable,
            Some(surface.as_ref()),
            tab_ids,
        )
        .and_then(|snapshot| {
            registry.commit_terminal_respawned(&plan.terminal_id, &incarnation, snapshot)
        });
        match committed {
            Ok(Some((terminal_revision, resource_revision))) => {
                state.resource_revision = resource_revision;
                drop(state);
                self.emit_terminal_registry_changed(&registry, terminal_revision);
                Ok(true)
            }
            Ok(None) => {
                *state = before;
                Ok(false)
            }
            Err(error) => {
                *state = before;
                Err(error)
            }
        }
    }
}

/// Remove the dead host records of `terminal_id` under `root`, so the new
/// host can publish its own. A live record is left alone (the launch then
/// fails and the loss stands).
#[cfg(unix)]
fn remove_dead_host_records(root: &Path, terminal_id: &str) {
    let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(root) else {
        return;
    };
    for (path, record) in records.iter().filter(|(_, record)| record.terminal_id == terminal_id) {
        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(path, record);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_closed_terminals_argv_is_forgotten_and_the_memory_is_bounded() {
        let respawns = TerminalRespawns::from_env();
        let argv = vec!["make".to_string(), "test".to_string()];
        respawns.remember_argv("t1", &argv);
        assert_eq!(respawns.argv("t1"), Some(argv.clone()));
        respawns.forget_argv("t1");
        assert_eq!(respawns.argv("t1"), None);
        for index in 0..ARGV_LIMIT + 10 {
            respawns.remember_argv(&format!("t{index}"), &argv);
        }
        assert_eq!(respawns.argv("t0"), None, "the oldest argv was not evicted");
        assert_eq!(respawns.argv(&format!("t{}", ARGV_LIMIT + 9)), Some(argv));
        let memory = respawns.argv.lock().unwrap_or_else(PoisonError::into_inner);
        assert_eq!(memory.by_terminal.len(), ARGV_LIMIT);
        assert_eq!(memory.order.len(), ARGV_LIMIT);
    }

    #[test]
    fn the_guard_allows_one_respawn_a_minute_and_three_in_ten_minutes() {
        let mut guard = RespawnGuard::default();
        let start = Instant::now();
        assert!(guard.admit("a", start));
        assert!(!guard.admit("a", start + Duration::from_secs(59)), "within the spacing");
        assert!(guard.admit("b", start), "terminals are bounded separately");
        assert!(guard.admit("a", start + Duration::from_secs(60)));
        assert!(guard.admit("a", start + Duration::from_secs(120)));
        assert!(!guard.admit("a", start + Duration::from_secs(180)), "three in ten minutes");
        assert!(!guard.admit("a", start + Duration::from_secs(599)));
        assert!(guard.admit("a", start + Duration::from_secs(600)), "the first attempt aged out");
    }
}
