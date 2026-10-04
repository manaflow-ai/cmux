//! A new tab replies after its durable accept commit (R81 stage A,
//! `plans/cmux-next/new-tab-accept-first.md` 3.1-3.6).
//!
//! The order of one terminal create through this path:
//!
//! 1. [`Mux::begin_tab_launch`] (on the request's arrival): reserve the
//!    terminal id, the surface id and the tab identity, then start the host
//!    launch on the terminal work pool. The host publishes its discovery
//!    record without a workspace key, so a restarted owner that finds the
//!    record but no terminal row exact-kills it (R1).
//! 2. The accept ([`Mux::accept_launching_terminal`], inside the shared
//!    creation transaction): commit the terminal row as `launching`, insert a
//!    launching placeholder surface (`surface::launching`) and start the
//!    launch job. The creation commits its topology and replies with
//!    `lifecycle:"launching"`; it does not wait for the host.
//! 3. The launch job ([`Mux::run_launch_job`]): wait until the topology is
//!    durable, adopt the host, commit `running` under the registry lock only
//!    while the row is still `launching` (A1), send Activate, flush the input
//!    queue, replace the placeholder with the hosted surface, and publish one
//!    `terminal-lifecycle` event.
//! 4. A failed launch commits `exited` with its cause; the tab stays and its
//!    queued input is kept for `terminal.input.send_kept` (R5).
//!
//! Every create that makes a terminal can take this path by registering a
//! pending launch for its reserved terminal id; `new-tab` is the first.

use super::*;
use crate::surface::launching::LaunchControl;

/// How long the launch job waits for its creation to commit. A creation
/// that has not committed by then failed; its job cancels the launch.
const LAUNCH_ACCEPT_TIMEOUT: Duration = Duration::from_secs(30);

/// How long an attach to a launching terminal waits for its host.
const LAUNCH_ATTACH_WAIT: Duration = Duration::from_secs(10);

/// Test seams for the crash windows (G4). Test and debug builds only;
/// release builds ignore these variables.
pub(crate) mod test_hooks {
    pub(crate) const LAUNCH_JOB_DELAY: &str = "CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS";
    pub(crate) const ACCEPT_COMMIT_DELAY: &str = "CMUX_TUI_TEST_ACCEPT_COMMIT_DELAY_MS";
    pub(crate) const ACTIVATE_DELAY: &str = "CMUX_TUI_TEST_ACTIVATE_DELAY_MS";
    pub(crate) const ADOPT_HOLD: &str = "CMUX_TUI_TEST_ADOPT_HOLD_MS";

    /// Sleep for the test delay named by `variable`, bounded to 10 s.
    pub(crate) fn pause(variable: &str) {
        #[cfg(any(test, debug_assertions))]
        if let Ok(value) = std::env::var(variable)
            && let Ok(delay) = value.parse::<u64>()
            && delay > 0
        {
            std::thread::sleep(std::time::Duration::from_millis(delay.min(10_000)));
        }
        #[cfg(not(any(test, debug_assertions)))]
        let _ = variable;
    }
}

/// A terminal launch started before its creation commits.
pub(crate) struct PendingLaunch {
    terminal_id: TerminalId,
    surface_id: SurfaceId,
    resource_identity: TabResourceIdentity,
    /// Spawn options before the surface identity environment: the registry
    /// records them as the launch spec, and the placeholder takes its size.
    launch_opts: SurfaceOptions,
    host: Mutex<HostSlot>,
    done: Condvar,
}

enum HostSlot {
    Launching,
    Ready(Box<anyhow::Result<crate::surface::PrelaunchedHost>>),
    Taken,
    Cancelled,
}

impl PendingLaunch {
    /// Store the launched host, or end it at once when the launch was
    /// cancelled meanwhile (dropping a prelaunched host exact-kills it).
    fn finish(&self, host: anyhow::Result<crate::surface::PrelaunchedHost>) {
        let mut slot = self.host.lock().unwrap_or_else(PoisonError::into_inner);
        if matches!(*slot, HostSlot::Cancelled) {
            drop(slot);
            drop(host);
            return;
        }
        *slot = HostSlot::Ready(Box::new(host));
        drop(slot);
        self.done.notify_all();
    }

    fn is_cancelled(&self) -> bool {
        matches!(*self.host.lock().unwrap_or_else(PoisonError::into_inner), HostSlot::Cancelled)
    }

    /// Wait for the launched host. `None` when the launch was cancelled.
    fn take_host(&self) -> Option<anyhow::Result<crate::surface::PrelaunchedHost>> {
        let mut slot = self.host.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            match std::mem::replace(&mut *slot, HostSlot::Taken) {
                HostSlot::Ready(host) => return Some(*host),
                HostSlot::Launching => {
                    *slot = HostSlot::Launching;
                    slot = self.done.wait(slot).unwrap_or_else(PoisonError::into_inner);
                }
                HostSlot::Cancelled => {
                    *slot = HostSlot::Cancelled;
                    return None;
                }
                HostSlot::Taken => return None,
            }
        }
    }

    /// Cancel the launch; a host already launched ends now.
    pub(super) fn cancel(&self) {
        let previous = std::mem::replace(
            &mut *self.host.lock().unwrap_or_else(PoisonError::into_inner),
            HostSlot::Cancelled,
        );
        self.done.notify_all();
        drop(previous);
    }
}

struct AcceptedLaunch {
    control: Arc<LaunchControl>,
    launch: Arc<PendingLaunch>,
}

/// Launches between their start and their creation's accept, and input
/// kept from failed launches.
#[derive(Default)]
pub(crate) struct TabLaunches {
    pending: Mutex<HashMap<String, Arc<PendingLaunch>>>,
    /// Accepted launches by their placeholder's surface id, so a close of
    /// the tab cancels the launch at once.
    accepted: Mutex<HashMap<SurfaceId, AcceptedLaunch>>,
    /// Queued input of failed launches, by terminal host id (R5).
    pub(super) kept_input: Mutex<HashMap<String, Vec<u8>>>,
}

impl Mux {
    /// Start the host of a new terminal for `pane` (the active pane when
    /// `None`) before its creation commits, under `terminal_id` or a fresh
    /// id. Returns the terminal id the create must reserve so that it takes
    /// this launch, or `None` when this owner does not host terminals or has
    /// no such pane; the create then launches its host itself.
    ///
    /// The caller must finish with [`Mux::discard_pending_launch`], which
    /// cancels the launch when no create took it.
    pub(crate) fn begin_tab_launch(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        terminal_id: Option<TerminalId>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<String>> {
        if !self.uses_terminal_host_runtime() {
            return Ok(None);
        }
        let target = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            match pane {
                Some(pane) => state.panes.contains_key(&pane).then_some(pane),
                None => state.active_pane(),
            }
        };
        let Some(target) = target else { return Ok(None) };
        crate::debug_spans::mark("prelaunch.target");
        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let (launch_opts, cell_pixels) = self.terminal_spawn_options(cwd, command, size, &env);
        if launch_opts.terminal_host_root.is_none() {
            return Ok(None);
        }
        let terminal_id = match terminal_id {
            Some(terminal_id) => terminal_id,
            None => TerminalId::random()?,
        };
        let terminal_hex = terminal_id.to_hex();
        let mut pending = self.tab_launches.pending.lock().unwrap_or_else(PoisonError::into_inner);
        anyhow::ensure!(
            !pending.contains_key(&terminal_hex),
            "terminal {terminal_hex} is already launching"
        );
        let launch = self.start_pending_launch(
            terminal_id,
            self.next_id(),
            TabResourceIdentity::terminal(None)?,
            launch_opts,
            cell_pixels,
        )?;
        pending.insert(terminal_hex.clone(), launch);
        Ok(Some(terminal_hex))
    }

    /// Start the host launch of a terminal whose surface will carry
    /// `surface_id` and `resource_identity`, on the terminal work pool.
    pub(super) fn start_pending_launch(
        self: &Arc<Self>,
        terminal_id: TerminalId,
        surface_id: SurfaceId,
        resource_identity: TabResourceIdentity,
        launch_opts: SurfaceOptions,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<PendingLaunch>> {
        let launch = Arc::new(PendingLaunch {
            terminal_id,
            surface_id,
            resource_identity,
            launch_opts,
            host: Mutex::new(HostSlot::Launching),
            done: Condvar::new(),
        });
        let mux = self.clone();
        let job_launch = launch.clone();
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            test_hooks::pause(test_hooks::LAUNCH_JOB_DELAY);
            if job_launch.is_cancelled() {
                return;
            }
            let host = mux.launch_pending_host(&job_launch, cell_pixels);
            job_launch.finish(host);
        });
        if let Err(job) = self.submit_terminal_work(job) {
            // The pool is saturated; the accept must not wait for this
            // launch on the request thread, so give it its own thread.
            std::thread::Builder::new().name("mux-tab-launch".into()).spawn(job)?;
        }
        Ok(launch)
    }

    /// Launch the host of `launch`, on the pool's spare host when one is
    /// ready (R81).
    fn launch_pending_host(
        self: &Arc<Self>,
        launch: &PendingLaunch,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<crate::surface::PrelaunchedHost> {
        let standby = self.terminal_work.take_standby();
        let used_spare = standby.is_some();
        crate::debug_spans::mark(if used_spare { "spare.taken" } else { "spare.none" });
        let launch_host = |standby| {
            Surface::prelaunch_hosted(
                launch.surface_id,
                launch.launch_opts.clone(),
                Arc::downgrade(self),
                launch.terminal_id,
                launch.resource_identity.clone(),
                cell_pixels,
                standby,
            )
        };
        let mut launched = launch_host(standby);
        // A spare that died after its liveness check fails before
        // bootstrap: launch on a fresh process, so the tab never fails or
        // slows down because of the spare.
        if launched.is_err() && used_spare {
            launched = launch_host(None);
        }
        crate::debug_spans::mark("host.launched");
        self.terminal_work.refill_standby();
        launched
    }

    /// The pending launch reserved under `terminal_hex`, for the create that
    /// reserves the same id.
    fn take_pending_launch(&self, terminal_hex: &str) -> Option<Arc<PendingLaunch>> {
        self.tab_launches
            .pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_hex)
    }

    /// Cancel the launch under `terminal_hex` unless its create took it.
    pub(crate) fn discard_pending_launch(&self, terminal_hex: &str) {
        let unclaimed = self
            .tab_launches
            .pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_hex);
        if let Some(launch) = unclaimed {
            launch.cancel();
        }
    }

    /// The accept of a create whose host launch is pending: commit the
    /// terminal row as `launching`, insert the launching placeholder, and
    /// start the launch job. `None` when no launch is pending for the id.
    pub(super) fn accept_launching_terminal(
        self: &Arc<Self>,
        terminal_hex: &str,
        workspace_key: &str,
        reservation: Option<&TerminalReservationRequest>,
    ) -> Option<anyhow::Result<Arc<Surface>>> {
        let launch = self.take_pending_launch(terminal_hex)?;
        let accepted =
            self.accept_pending_launch(&launch, terminal_hex, workspace_key, reservation);
        if accepted.is_err() {
            launch.cancel();
        }
        Some(accepted)
    }

    fn accept_pending_launch(
        self: &Arc<Self>,
        launch: &Arc<PendingLaunch>,
        terminal_hex: &str,
        workspace_key: &str,
        reservation: Option<&TerminalReservationRequest>,
    ) -> anyhow::Result<Arc<Surface>> {
        test_hooks::pause(test_hooks::ACCEPT_COMMIT_DELAY);
        let terminal = RegistryTerminal {
            terminal_id: terminal_hex.to_string(),
            workspace_key: workspace_key.to_string(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: terminal_launch_spec(&launch.launch_opts),
            exit: None,
            on_exit: reservation.map(|reservation| reservation.on_exit).unwrap_or_default(),
        };
        {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let (replayed, revision) = match reservation {
                Some(reservation) => {
                    let commit = registry.commit_terminal(
                        &reservation.mutation,
                        &reservation.fingerprint,
                        reservation.expected_generation.as_deref(),
                        reservation.expected_revision,
                        "terminal-reserved",
                        &terminal,
                        &serde_json::json!({
                            "terminal_id":terminal_hex,
                            "workspace_key":workspace_key,
                            "state":"launching",
                        }),
                    )?;
                    (commit.replayed, commit.revision)
                }
                None => (
                    false,
                    commit_terminal_transition(
                        &mut registry,
                        "terminal-reserved",
                        "reserve-terminal",
                        &terminal,
                    )?,
                ),
            };
            anyhow::ensure!(!replayed, "terminal_create_replayed");
            self.emit_terminal_registry_changed(&registry, revision);
        }
        let control = LaunchControl::new(terminal_hex.to_string());
        let placeholder = Surface::launching_placeholder(
            launch.surface_id,
            launch.launch_opts.clone(),
            Arc::downgrade(self),
            launch.resource_identity.clone(),
            control.clone(),
        );
        let inserted = placeholder.and_then(|placeholder| {
            insert_surface_checked(
                &mut self.state.lock().unwrap_or_else(PoisonError::into_inner),
                placeholder.clone(),
            )
            .map(|()| placeholder)
        });
        let placeholder = match inserted {
            Ok(placeholder) => placeholder,
            Err(error) => {
                let _ = self.persist_terminal_exit(
                    terminal_hex,
                    None,
                    &TerminalEnd::launch_failed("surface-insert-failed"),
                );
                return Err(error);
            }
        };
        self.start_launch_job(launch, &placeholder, control, workspace_key)?;
        Ok(placeholder)
    }

    /// Run the launch job of `placeholder` on the terminal work pool.
    pub(super) fn start_launch_job(
        self: &Arc<Self>,
        launch: &Arc<PendingLaunch>,
        placeholder: &Arc<Surface>,
        control: Arc<LaunchControl>,
        workspace_key: &str,
    ) -> anyhow::Result<()> {
        self.tab_launches.accepted.lock().unwrap_or_else(PoisonError::into_inner).insert(
            placeholder.id,
            AcceptedLaunch { control: control.clone(), launch: launch.clone() },
        );
        let mux = self.clone();
        let job_launch = launch.clone();
        let job_placeholder = placeholder.clone();
        let workspace_key = workspace_key.to_string();
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            let finished =
                mux.run_launch_job(&job_launch, &job_placeholder, &control, &workspace_key);
            mux.tab_launches
                .accepted
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&job_placeholder.id);
            if finished == LaunchJobEnd::Cancelled {
                // The tab closed during the launch: retire its terminal.
                mux.retire_cancelled_launch(control.terminal_id());
            }
        });
        if let Err(job) = self.submit_terminal_work(job) {
            // Never inline: the job waits for this creation to commit.
            std::thread::Builder::new().name("mux-launch-job".into()).spawn(job)?;
        }
        Ok(())
    }

    /// The launch job of one accepted terminal (3.2).
    fn run_launch_job(
        self: &Arc<Self>,
        launch: &PendingLaunch,
        placeholder: &Arc<Surface>,
        control: &Arc<LaunchControl>,
        workspace_key: &str,
    ) -> LaunchJobEnd {
        let terminal_hex = control.terminal_id().to_string();
        if !control.wait_accepted(LAUNCH_ACCEPT_TIMEOUT) {
            if control.is_cancelled() {
                launch.cancel();
                return LaunchJobEnd::Cancelled;
            }
            // The creation never committed its topology.
            control.cancel();
            launch.cancel();
            let _ = self.persist_terminal_exit(
                &terminal_hex,
                None,
                &TerminalEnd::launch_failed("creation-not-committed"),
            );
            return LaunchJobEnd::Settled;
        }
        let Some(host) = launch.take_host() else { return LaunchJobEnd::Cancelled };
        if control.is_cancelled() {
            return LaunchJobEnd::Cancelled;
        }
        let hosted =
            match host.and_then(|host| Surface::spawn_prelaunched(host, Arc::downgrade(self))) {
                Ok(hosted) => hosted,
                Err(error) => {
                    self.fail_launch(control, &format!("launch-failed: {error:#}"));
                    return LaunchJobEnd::Settled;
                }
            };
        let _pending_host_release = PendingTerminalHostRelease(hosted.clone());
        test_hooks::pause(test_hooks::ADOPT_HOLD);
        let Some(identity) = hosted.terminal_host_identity() else {
            hosted.kill();
            self.fail_launch(control, "launch-failed: host returned no identity");
            return LaunchJobEnd::Settled;
        };
        if identity.terminal_id != terminal_hex {
            hosted.kill();
            self.fail_launch(control, "launch-failed: host-identity-mismatch");
            return LaunchJobEnd::Settled;
        }
        if let Err(error) = self.commit_launched_terminal(control, placeholder, &identity) {
            // A1: the tab closed during the launch, or the row moved on.
            eprintln!("cmux-tui: terminal {terminal_hex} launch not committed: {error:#}");
            hosted.kill();
            control.cancel();
            return LaunchJobEnd::Cancelled;
        }
        test_hooks::pause(test_hooks::ACTIVATE_DELAY);
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&hosted) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                let _ = self.persist_terminal_cell_pixel_reconcile_failure(
                    &terminal_hex,
                    Some(&identity.incarnation),
                    &error,
                );
                hosted.kill();
                return LaunchJobEnd::Settled;
            }
        };
        if let Err(error) = hosted.activate_hosted_launch_stream() {
            eprintln!("cmux-tui: terminal {terminal_hex} activation failed: {error:#}");
        }
        let swapped = control.adopt(&hosted) && {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            replace_launching_surface(&mut state, placeholder, &hosted)
        };
        drop(cell_pixel_lifecycle);
        if !swapped {
            // Closed between the commit and the swap.
            hosted.kill();
            return LaunchJobEnd::Cancelled;
        }
        let _ = hosted.persist_host_workspace(workspace_key);
        let (cols, rows) = placeholder.size();
        if hosted.size() != (cols, rows) {
            let _ = hosted.resize(cols, rows);
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit_terminal_lifecycle(
            &terminal_hex,
            control.elapsed_ms(),
            "running",
            Some(&identity.incarnation),
            None,
        );
        if let Some(public_id) = hosted.terminal_public_id() {
            let _ = self.retry_pending_agent_hooks_for_terminal(public_id);
        }
        self.reap_if_dead(&hosted);
        LaunchJobEnd::Settled
    }

    /// The tab of a launching terminal closed (every tab close purges its
    /// surface's side tables): cancel the launch now, so a host still
    /// launching never starts and a launched one ends.
    pub(super) fn cancel_closed_launching_tab(&self, surface: SurfaceId) {
        let accepted = self
            .tab_launches
            .accepted
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&surface);
        let Some(accepted) = accepted else { return };
        if accepted.control.cancel().is_none() {
            accepted.launch.cancel();
        }
    }

    /// End the durable row of a launch whose tab closed before it ran.
    fn retire_cancelled_launch(&self, terminal_hex: &str) {
        let retired = self.close_terminal_with_mutation(
            terminal_hex,
            None,
            None,
            None,
            &WorkspaceMutation::local("cmux-tui"),
        );
        if let Err(error) = retired {
            eprintln!("cmux-tui: closed launching terminal {terminal_hex} not retired: {error:#}");
        }
    }

    /// Commit `running` for the adopted host, under the registry lock, only
    /// while the row is still `launching` with no incarnation and the launch
    /// was not cancelled (A1).
    fn commit_launched_terminal(
        &self,
        control: &LaunchControl,
        placeholder: &Arc<Surface>,
        identity: &TerminalHostIdentity,
    ) -> anyhow::Result<()> {
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let placed = self
            .state
            .lock()
            .unwrap()
            .surfaces
            .get(&placeholder.id)
            .is_some_and(|current| Arc::ptr_eq(current, placeholder));
        anyhow::ensure!(placed && !control.is_cancelled(), "the tab closed during its launch");
        let terminal = registry
            .terminal_record(&identity.terminal_id)?
            .context("the launching terminal disappeared")?;
        anyhow::ensure!(
            terminal.lifecycle == TerminalLifecycle::Launching && terminal.incarnation.is_none(),
            "the terminal is no longer launching"
        );
        let (_, revision) = commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "terminal-ready",
            &identity.terminal_id,
            TerminalLifecycle::Running,
            Some(&identity.incarnation),
            None,
        )?;
        self.emit_terminal_registry_changed(&registry, revision);
        Ok(())
    }

    /// A launch failed after its accept (3.5): keep the tab and the queued
    /// input, commit `exited` with `cause`.
    fn fail_launch(&self, control: &LaunchControl, cause: &str) {
        let Some(kept) = control.fail() else { return };
        let terminal_hex = control.terminal_id();
        if !kept.is_empty() {
            self.tab_launches
                .kept_input
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(terminal_hex.to_string(), kept);
        }
        let end = TerminalEnd::launch_failed(cause);
        if let Err(error) = self.persist_terminal_exit_with(terminal_hex, None, &end, true) {
            eprintln!("cmux-tui: terminal {terminal_hex} launch failure not committed: {error:#}");
        }
        self.emit(MuxEvent::TreeChanged);
        self.emit_terminal_lifecycle(
            terminal_hex,
            control.elapsed_ms(),
            "exited",
            None,
            Some(cause),
        );
    }

    fn emit_terminal_lifecycle(
        &self,
        terminal_id: &str,
        elapsed_ms: u64,
        to: &str,
        incarnation: Option<&str>,
        cause: Option<&str>,
    ) {
        let terminal = self
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id(terminal_id)
            .ok()
            .flatten()
            .map(|public_id| public_id.to_string());
        self.emit(MuxEvent::TerminalLifecycle(Box::new(TerminalLifecycleEvent {
            terminal_id: terminal_id.to_string(),
            terminal,
            from: "launching",
            to: to.to_string(),
            elapsed_ms,
            cause: cause.map(str::to_string),
            terminal_incarnation: incarnation.map(str::to_string),
        })));
    }

    /// Restart recovery of an accepted create whose host never published
    /// its record (3.6): relaunch it in its placement with a new incarnation
    /// (R6). A failed relaunch commits `exited` with its cause. False when
    /// the terminal has no placement, so the caller ends it.
    pub(super) fn relaunch_accepted_terminal(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
    ) -> bool {
        let started = Instant::now();
        let relaunched = self.relaunch_terminal_in_place(terminal, options);
        let elapsed_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        match relaunched {
            Ok(Some(incarnation)) => {
                self.emit_terminal_lifecycle(
                    &terminal.terminal_id,
                    elapsed_ms,
                    "running",
                    Some(&incarnation),
                    None,
                );
                true
            }
            Ok(None) => false,
            Err(error) => {
                let cause = format!("launch-failed: {error:#}");
                eprintln!("cmux-tui: terminal {} relaunch failed: {cause}", terminal.terminal_id);
                let _ = self.persist_terminal_exit(
                    &terminal.terminal_id,
                    None,
                    &TerminalEnd::launch_failed(cause.clone()),
                );
                self.emit_terminal_lifecycle(
                    &terminal.terminal_id,
                    elapsed_ms,
                    "exited",
                    None,
                    Some(&cause),
                );
                true
            }
        }
    }

    /// Launch a host for `terminal` in its first placement and adopt it.
    /// The owner's default shell runs: the registry keeps no argv, cwd or
    /// environment, which can hold credentials. Returns the new incarnation.
    fn relaunch_terminal_in_place(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
    ) -> anyhow::Result<Option<String>> {
        let Some(binding) = self.restored_terminal_binding(&terminal.terminal_id)? else {
            return Ok(None);
        };
        let Some((slot, identity)) = binding.placements.first().cloned() else {
            return Ok(None);
        };
        let terminal_id =
            TerminalId::from_hex(&terminal.terminal_id).context("invalid terminal host id")?;
        let mut opts = options.clone();
        let spec_size = |field: &str| {
            terminal.launch_spec[field]
                .as_u64()
                .and_then(|value| u16::try_from(value).ok())
                .filter(|value| *value > 0)
        };
        if let (Some(cols), Some(rows)) = (spec_size("cols"), spec_size("rows")) {
            opts.cols = cols;
            opts.rows = rows;
        }
        let host = Surface::prelaunch_hosted(
            slot,
            opts,
            Arc::downgrade(self),
            terminal_id,
            identity,
            self.cell_pixel_creation_size(),
            None,
        )?;
        let surface = Surface::spawn_prelaunched(host, Arc::downgrade(self))?;
        let _pending_host_release = PendingTerminalHostRelease(surface.clone());
        let incarnation = surface
            .terminal_host_identity()
            .context("relaunched host returned no identity")?
            .incarnation;
        let adopted = self
            .transition_terminal_lifecycle(
                "terminal-adopting",
                "relaunch-terminal",
                &terminal.terminal_id,
                TerminalLifecycle::Adopting,
                Some(&incarnation),
            )
            .and_then(|_| {
                self.finish_terminal_adoption(&terminal.terminal_id, &incarnation, surface.clone())
            });
        if let Err(error) = adopted {
            surface.kill();
            return Err(error);
        }
        if let Err(error) = surface.activate_hosted_launch_stream() {
            eprintln!("cmux-tui: terminal {} activation failed: {error:#}", terminal.terminal_id);
        }
        let _ = surface.persist_host_workspace(&terminal.workspace_key);
        self.reap_if_dead(&surface);
        Ok(Some(incarnation))
    }

    /// The surface an attach should use: a launching terminal's hosted
    /// surface once it runs, waiting a bounded time for it; the placeholder
    /// itself when the launch failed or is still pending.
    pub(crate) fn wait_for_launched_surface(&self, surface: Arc<Surface>) -> Arc<Surface> {
        match surface.launch_control() {
            Some(control) => control.wait_settled(LAUNCH_ATTACH_WAIT).unwrap_or(surface),
            None => surface,
        }
    }

    /// Bytes kept from the failed launch of `terminal_hex` (R5).
    pub(crate) fn kept_terminal_input_len(&self, terminal_hex: &str) -> usize {
        self.tab_launches
            .kept_input
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(terminal_hex)
            .map_or(0, Vec::len)
    }

    /// Take the bytes kept from the failed launch of `terminal_hex`.
    pub(crate) fn take_kept_terminal_input(&self, terminal_hex: &str) -> Option<Vec<u8>> {
        self.tab_launches
            .kept_input
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_hex)
    }
}

/// How a launch job ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LaunchJobEnd {
    /// The terminal runs, or its failure is committed.
    Settled,
    /// The tab closed first; the job ended the host.
    Cancelled,
}

/// Put the adopted `hosted` surface where `placeholder` was, keeping the
/// surface id, tab identity and terminal catalog entry. False when the
/// placeholder left the state (its tab closed).
pub(super) fn replace_launching_surface(
    state: &mut State,
    placeholder: &Arc<Surface>,
    hosted: &Arc<Surface>,
) -> bool {
    let current = state.surfaces.get(&placeholder.id);
    if !current.is_some_and(|current| Arc::ptr_eq(current, placeholder)) {
        return false;
    }
    state.surfaces.insert(placeholder.id, hosted.clone());
    if let Some(public_id) = hosted.terminal_public_id()
        && state
            .terminal_catalog
            .get(public_id)
            .is_some_and(|current| Arc::ptr_eq(current, placeholder))
    {
        state.terminal_catalog.insert(public_id.clone(), hosted.clone());
    }
    true
}
