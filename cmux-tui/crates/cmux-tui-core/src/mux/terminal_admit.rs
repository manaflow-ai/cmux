//! `terminal-async-start-v1` (p05-ipc-130): a receipted `create-terminal`
//! in two steps. [`Mux::admit_terminal_create`] runs before the reply and
//! does everything a request can be refused for: the replay and fingerprint
//! check of its mutation, the `expected_generation`/`expected_revision`
//! CAS and the reservation of its registry row (`launching`).
//! [`Mux::launch_admitted_terminal`] runs after the reply: the host launch,
//! the topology placement and the `running` commit, the synchronous
//! create's own code.
//!
//! Chrome splits a renderer start the same way: `RenderProcessHostImpl::Init`
//! decides and registers the process at once, and the launch reports later
//! (content/browser/renderer_host/render_process_host_impl.cc,
//! content/browser/child_process_launcher.h).

use super::*;
use crate::panic_free::RecoverPoison;

/// What admitting a create found.
pub(crate) enum TerminalCreateAdmission {
    /// The mutation committed before and its start reported: what a
    /// synchronous retry replies.
    Replayed(TerminalPlacementResult),
    /// A retry of an admitted create whose start has not reported yet.
    Starting { terminal_revision: u64 },
    /// The registry reserved the terminal; its launch runs after the reply.
    Reserved(Box<AdmittedTerminalCreate>),
}

/// A create whose registry row is reserved and whose host is not launched.
pub(crate) struct AdmittedTerminalCreate {
    workspace: WorkspaceId,
    name: Option<String>,
    reservation: TerminalReservationRequest,
    /// The terminal registry revision of the reservation.
    pub(crate) terminal_revision: u64,
}

/// A create to admit: the request's own values, unresolved.
pub(crate) struct TerminalCreateRequest<'a> {
    pub(crate) workspace: WorkspaceId,
    pub(crate) terminal_id: TerminalId,
    pub(crate) argv: Option<Vec<String>>,
    pub(crate) cwd: Option<String>,
    pub(crate) name: Option<String>,
    pub(crate) size: Option<(u16, u16)>,
    pub(crate) expected_generation: Option<&'a str>,
    pub(crate) expected_revision: Option<u64>,
    pub(crate) mutation: &'a WorkspaceMutation,
    pub(crate) env: Vec<(String, String)>,
}

impl Mux {
    /// The prepare step of a receipted create: replay, fingerprint, CAS and
    /// reservation, with no host launch. Every refusal is an error here, so
    /// the request's reply carries it.
    #[track_caller]
    pub(crate) fn admit_terminal_create(
        &self,
        request: TerminalCreateRequest<'_>,
    ) -> anyhow::Result<TerminalCreateAdmission> {
        let TerminalCreateRequest {
            workspace,
            terminal_id,
            argv,
            cwd,
            name,
            size,
            expected_generation,
            expected_revision,
            mutation,
            env,
        } = request;
        let workspace_key = self
            .with_state(|state| state.workspace_by_id(workspace).map(|w| w.key.clone()))
            .ok_or_else(|| anyhow::anyhow!("unknown workspace {workspace}"))?;
        let terminal_hex = terminal_id.to_hex();
        // The synchronous create's fingerprint, so either path replays the other.
        let fingerprint = terminal_create_fingerprint(
            &workspace_key,
            Some(&terminal_hex),
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            None,
        )?;
        let replay =
            self.workspace_registry.lock().unwrap().replay_terminal(mutation, &fingerprint)?;
        if let Some(replay) = replay {
            let replayed = replay.result["terminal_id"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored terminal create result is missing id"))?;
            return self.replayed_admission(replayed);
        }
        // The launch runs with the options admitted here: the folder and
        // size the request meant when it arrived.
        let cwd = self.new_terminal_cwd(cwd, None, Some(workspace));
        let (opts, cell_pixels) = self.terminal_spawn_options(cwd, argv, size, &env);
        let terminal = RegistryTerminal {
            terminal_id: terminal_hex.clone(),
            workspace_key: workspace_key.clone(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: terminal_launch_spec(&opts),
            exit: None,
            on_exit: TerminalOnExit::default(),
        };
        let commit = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let commit = registry.commit_terminal(
                mutation,
                &fingerprint,
                expected_generation,
                expected_revision,
                "terminal-reserved",
                &terminal,
                &serde_json::json!({
                    "terminal_id": terminal_hex,
                    "workspace_key": workspace_key,
                    "state": "launching",
                }),
            )?;
            if !commit.replayed {
                self.emit_terminal_registry_changed(&registry, commit.revision);
            }
            commit
        };
        if commit.replayed {
            // A retry of the same mutation reserved it first.
            return self.replayed_admission(&terminal_hex);
        }
        Ok(TerminalCreateAdmission::Reserved(Box::new(AdmittedTerminalCreate {
            workspace,
            name,
            reservation: TerminalReservationRequest {
                terminal_id,
                mutation: mutation.clone(),
                fingerprint,
                expected_generation: None,
                expected_revision: None,
                on_exit: TerminalOnExit::default(),
                tab_id: None,
                env,
                reserved: Some(ReservedLaunch { opts, cell_pixels }),
            },
            terminal_revision: commit.revision,
        })))
    }

    fn replayed_admission(&self, terminal_id: &str) -> anyhow::Result<TerminalCreateAdmission> {
        let lifecycle = self
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_record(terminal_id)?
            .map(|terminal| terminal.lifecycle);
        if matches!(lifecycle, Some(TerminalLifecycle::Launching | TerminalLifecycle::Adopting)) {
            let terminal_revision = self.workspace_registry.lock().unwrap().terminal_revision()?;
            return Ok(TerminalCreateAdmission::Starting { terminal_revision });
        }
        Ok(TerminalCreateAdmission::Replayed(self.replayed_terminal_placement(terminal_id)?))
    }

    /// The launch step: start the host of an admitted create and place its
    /// tab. A failure leaves no `launching` row behind.
    #[track_caller]
    pub(crate) fn launch_admitted_terminal(
        self: &Arc<Self>,
        admitted: Box<AdmittedTerminalCreate>,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let AdmittedTerminalCreate { workspace, name, reservation, .. } = *admitted;
        let terminal_hex = reservation.terminal_id.to_hex();
        // The spawn uses the admitted options; the folder is passed so the
        // create does not look one up again.
        let cwd = reservation.reserved.as_ref().and_then(|reserved| reserved.opts.cwd.clone());
        #[cfg(test)]
        if let Some(hook) = self.terminal_work.start_hook() {
            hook();
        }
        let launched = {
            let _creation_handoff = self.resource_creation_handoff.lock().recover_poison();
            let _creation_execution = self.resource_creation_execution.lock().recover_poison();
            self.create_terminal_in_workspace_impl(
                workspace,
                None,
                cwd,
                name,
                None,
                Some(reservation),
            )
        };
        match launched {
            Ok((placement, surface, created_path)) => {
                self.created_terminal_placement(placement, &surface, created_path)
            }
            Err(error) => {
                self.abandon_admitted_terminal(&terminal_hex);
                Err(error)
            }
        }
    }

    /// A launch that failed before its host started ends its reserved row,
    /// so a retry of the mutation replays the failure.
    fn abandon_admitted_terminal(&self, terminal_id: &str) {
        let launching = self
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_record(terminal_id)
            .ok()
            .flatten()
            .is_some_and(|terminal| terminal.lifecycle == TerminalLifecycle::Launching);
        if launching {
            let _ = self.persist_terminal_exit(
                terminal_id,
                None,
                &TerminalEnd::launch_failed("start-failed"),
            );
        }
    }
}

#[cfg(test)]
impl Mux {
    /// Test seam: the next launch of an admitted terminal fails after its
    /// host started, at its cell-pixel reconcile, as a host that does not
    /// converge does: the cell size changes after the admission.
    pub(crate) fn fail_next_terminal_launch_for_test(self: &Arc<Self>) {
        let (width, height) = self.cell_pixel_size();
        self.set_cell_pixel_size(width + 1, height + 1);
        *self.terminal_spawn_before_cell_pixel_reconcile.lock().unwrap() =
            Some(Arc::new(|surface: &Arc<Surface>| surface.fail_next_test_master_resize()));
    }
}
