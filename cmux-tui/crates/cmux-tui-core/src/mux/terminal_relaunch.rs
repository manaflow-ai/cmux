//! A terminal whose launch failed after its accept keeps its tab, its
//! cause and its queued input (R81 stage A, 3.5, R5, G2). Two operations
//! act on it:
//!
//! - `terminal.relaunch` starts a clean shell in the same tab under the same
//!   terminal id, with a new incarnation. It never replays the kept input.
//! - `terminal.input.send_kept` sends the kept input once, through the
//!   normal input path, when the user chooses; the clear and the send are
//!   one step.

use super::*;
use crate::surface::launching::LaunchControl;
use tab_launch::replace_launching_surface;

/// How long `terminal.relaunch` waits for the new shell to run.
const RELAUNCH_WAIT: Duration = Duration::from_secs(15);

/// The program, directory and environment of a relaunch.
pub(crate) struct TerminalRelaunch {
    pub(crate) argv: Option<Vec<String>>,
    pub(crate) cwd: Option<String>,
    pub(crate) env: Vec<(String, String)>,
}

impl Mux {
    /// Relaunch the exited terminal `terminal_hex` in its failed-launch tab.
    /// Waits until the new shell runs and returns its incarnation.
    pub(crate) fn relaunch_exited_terminal(
        self: &Arc<Self>,
        terminal_hex: &str,
        relaunch: TerminalRelaunch,
    ) -> anyhow::Result<String> {
        let terminal = self
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_record(terminal_hex)?
            .with_context(|| format!("unknown terminal {terminal_hex}"))?;
        anyhow::ensure!(
            terminal.lifecycle == TerminalLifecycle::Exited,
            "terminal-not-exited: only an exited terminal can be relaunched"
        );
        let failed = self
            .failed_launch_surface(terminal_hex)
            .context("terminal-not-relaunchable: the terminal has no failed-launch tab")?;
        let identity = failed
            .resource_identity()
            .cloned()
            .context("a failed-launch tab omitted its identity")?;
        let terminal_id = TerminalId::from_hex(terminal_hex).context("invalid terminal id")?;
        let (launch_opts, cell_pixels) = self.terminal_spawn_options(
            relaunch.cwd,
            relaunch.argv,
            Some(failed.size()),
            &relaunch.env,
        );
        anyhow::ensure!(
            launch_opts.terminal_host_root.is_some(),
            "this owner does not run terminal hosts"
        );
        {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let revived = RegistryTerminal {
                terminal_id: terminal.terminal_id.clone(),
                workspace_key: terminal.workspace_key.clone(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: terminal_launch_spec(&launch_opts),
                exit: None,
                on_exit: terminal.on_exit,
            };
            let revision = commit_terminal_transition(
                &mut registry,
                crate::workspace_registry::TERMINAL_RELAUNCHED_EVENT,
                "relaunch-terminal",
                &revived,
            )?;
            self.emit_terminal_registry_changed(&registry, revision);
        }
        let launch = self.start_pending_launch(
            terminal_id,
            failed.id,
            identity.clone(),
            launch_opts.clone(),
            cell_pixels,
        )?;
        let control = LaunchControl::new(terminal_hex.to_string());
        // The topology is already durable: the job may activate at once.
        control.mark_accepted();
        let placeholder = Surface::launching_placeholder(
            failed.id,
            launch_opts,
            Arc::downgrade(self),
            identity,
            control.clone(),
        );
        let placeholder = placeholder.and_then(|placeholder| {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            anyhow::ensure!(
                replace_launching_surface(&mut state, &failed, &placeholder),
                "the tab closed during its relaunch"
            );
            Ok(placeholder)
        });
        let placeholder = match placeholder {
            Ok(placeholder) => placeholder,
            Err(error) => {
                launch.cancel();
                return Err(error);
            }
        };
        self.start_launch_job(&launch, &placeholder, control.clone(), &terminal.workspace_key)?;
        self.emit(MuxEvent::TreeChanged);
        let hosted = control
            .wait_settled(RELAUNCH_WAIT)
            .context("terminal-relaunch-failed: the new shell did not start")?;
        Ok(hosted.terminal_host_identity().context("relaunched host has no identity")?.incarnation)
    }

    /// Send the input kept from the failed launch of `terminal_hex` to its
    /// running shell, once. Returns the number of bytes sent.
    pub(crate) fn send_kept_terminal_input(&self, terminal_hex: &str) -> anyhow::Result<usize> {
        let surface = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            self.catalog_terminal_by_host(&state, terminal_hex)?
        }
        .filter(|surface| !surface.is_launching() && !surface.is_dead())
        .context("terminal-not-running: kept input goes only to a running terminal")?;
        let kept = self
            .take_kept_terminal_input(terminal_hex)
            .context("terminal-no-kept-input: the terminal has no kept input")?;
        if let Err(error) = surface.write_bytes(&kept) {
            // Nothing reached the shell; keep the bytes for a retry.
            self.tab_launches
                .kept_input
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(terminal_hex.to_string(), kept);
            return Err(error.into());
        }
        Ok(kept.len())
    }

    /// The placeholder tab of the failed launch of `terminal_hex`.
    fn failed_launch_surface(&self, terminal_hex: &str) -> Option<Arc<Surface>> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state
            .surfaces
            .values()
            .find(|surface| {
                surface
                    .launch_control()
                    .is_some_and(|control| control.terminal_id() == terminal_hex)
            })
            .cloned()
    }
}
