//! Detached terminals (`detached-terminals-v1`): kept terminals with no
//! workspace, pane, screen or tab. The cmux-next app shows them as
//! remote-terminal tabs in another session's layout.

use super::*;
use crate::workspace_registry::DETACHED_TERMINAL_WORKSPACE_KEY;

/// Whether a durable `workspace_key` is a detached terminal's sentinel.
pub(super) fn is_detached_key(workspace_key: &str) -> bool {
    workspace_key == DETACHED_TERMINAL_WORKSPACE_KEY
}

/// Whether a terminal host record's `workspace_key` can name a workspace.
#[cfg(unix)]
pub(super) fn names_a_workspace(workspace_key: &str) -> bool {
    !workspace_key.is_empty() && !is_detached_key(workspace_key)
}

/// A detached terminal whose daemon died before its resource row committed
/// has no restored binding. It never had a tab, so it is adopted as a
/// catalog-only runtime under a new public id, which the next resource
/// projection persists, instead of being given a placement in a workspace
/// its sentinel key cannot name.
#[cfg(unix)]
pub(super) fn detached_adoption_binding(
    registry: &WorkspaceRegistry,
    terminal_id: &str,
) -> anyhow::Result<Option<RestoredTerminalBinding>> {
    let detached = registry
        .terminal_record(terminal_id)?
        .is_some_and(|terminal| is_detached_key(&terminal.workspace_key));
    if !detached {
        return Ok(None);
    }
    Ok(Some(RestoredTerminalBinding {
        public_id: TerminalPublicId::random()?,
        placements: Vec::new(),
    }))
}

impl Mux {
    /// Create a kept terminal with no workspace, pane, screen or tab
    /// (`detached-terminals-v1`). Its durable row names no workspace
    /// ([`DETACHED_TERMINAL_WORKSPACE_KEY`]), its runtime enters only the
    /// terminal catalog, and the creation receipt replays like any other.
    /// The caller commits the resource projection, which gives it the
    /// resource-terminal row that a later attach or `terminal.project`
    /// selects by its public id.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn create_detached_terminal_with_mutation(
        self: &Arc<Self>,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        requested_terminal_id: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        env: Vec<(String, String)>,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_execution = self.resource_creation_execution.lock().unwrap();
        if let Some(terminal_id) = requested_terminal_id {
            validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        }
        let mut fingerprint = terminal_create_fingerprint(
            DETACHED_TERMINAL_WORKSPACE_KEY,
            requested_terminal_id,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            None,
        )?;
        // Marks a detached receipt explicitly, beyond its sentinel key.
        fingerprint["detached"] = Value::Bool(true);
        let replay =
            { self.workspace_registry.lock().unwrap().replay_terminal(mutation, &fingerprint)? };
        if let Some(replay) = replay {
            let terminal_id = replay.result["terminal_id"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored terminal create result is missing id"))?;
            return self.detached_terminal_result(terminal_id, true);
        }
        let terminal_id = match requested_terminal_id {
            Some(value) => TerminalId::from_hex(value).expect("validated terminal UUID"),
            None => TerminalId::random()?,
        };
        let reservation = TerminalReservationRequest {
            terminal_id,
            mutation: mutation.clone(),
            fingerprint,
            expected_generation: expected_generation.map(str::to_string),
            expected_revision,
            on_exit: TerminalOnExit::default(),
            env,
        };
        let surface = self.spawn_surface_with(
            cwd,
            argv,
            size,
            Some(DETACHED_TERMINAL_WORKSPACE_KEY),
            Some(reservation),
        )?;
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let identity = self
            .resource_terminal_host_identity(&surface)
            .ok_or_else(|| anyhow::anyhow!("created terminal has no host identity"))?;
        self.detached_terminal_result(&identity.terminal_id, false)
    }

    /// End a detached terminal whose creation failed before its resource
    /// projection committed. Nothing else would end it (it is kept and has no
    /// tab), and the caller was told the creation failed. It has no resource
    /// row yet, so its exit commits to the terminal registry alone, which
    /// works even when the resource commit that failed keeps failing.
    pub(crate) fn end_unpublished_detached_terminal(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
    ) -> anyhow::Result<()> {
        self.persist_terminal_exit(
            terminal_id,
            incarnation,
            &TerminalExit::unknown("detached-create-failed"),
        )?;
        let runtime = {
            let mut state = self.state.lock().unwrap();
            let public_id = self
                .catalog_terminal_by_host(&state, terminal_id)?
                .and_then(|runtime| runtime.terminal_public_id().cloned());
            public_id.and_then(|public_id| {
                remove_terminal_content_from_state(self, &mut state, &public_id).0
            })
        };
        if let Some(runtime) = runtime {
            runtime.kill();
        }
        Ok(())
    }

    fn detached_terminal_result(
        &self,
        terminal_id: &str,
        replayed: bool,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let resolved = self
            .resolve_terminal(terminal_id)?
            .context("created terminal result has no durable terminal row")?;
        // No placement: the created surface is the catalog runtime, which the
        // caller activates and reaps like a placed terminal's surface.
        let runtime = {
            let state = self.state.lock().unwrap();
            self.catalog_terminal_by_host(&state, &resolved.terminal.terminal_id)?
                .map(|runtime| runtime.id)
        };
        Ok(TerminalPlacementResult {
            placement: None,
            terminal_id: resolved.terminal.terminal_id,
            terminal_incarnation: resolved.terminal.incarnation,
            terminal_revision: resolved.terminal_revision,
            replayed,
            created_path: None,
            created_surface: runtime,
        })
    }

    /// Publish a newly spawned terminal: an ordinary one as a surface that
    /// its creator then places in a pane; a detached one only in the
    /// terminal catalog, like a kept terminal whose last tab closed.
    pub(super) fn insert_created_terminal(
        &self,
        surface: Arc<Surface>,
        detached: bool,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        if !detached {
            return insert_surface_checked(&mut state, surface);
        }
        anyhow::ensure!(surface.kind() == SurfaceKind::Pty, "terminal catalog requires a PTY");
        anyhow::ensure!(!state.surfaces.contains_key(&surface.id), "duplicate_surface_id");
        register_terminal_runtime_checked(&mut state, &surface)
    }

    /// Persist the public id of a detached terminal adopted after its daemon
    /// died before the creating projection committed. A failure leaves it
    /// for the next projection to persist.
    #[cfg(unix)]
    pub(super) fn publish_adopted_detached_terminal(&self, workspace_key: &str, terminal_id: &str) {
        if !is_detached_key(workspace_key) {
            return;
        }
        let unpublished = self
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id(terminal_id)
            .is_ok_and(|public_id| public_id.is_none());
        if !unpublished {
            return;
        }
        let detail = serde_json::json!({"terminal_id":terminal_id, "detached":true});
        if let Err(error) = self.commit_full_resource_projection_with_mutation(
            &WorkspaceMutation::local("cmux-tui-detached-adoption"),
            "raw.terminal.adopt_detached",
            &detail,
            detail.clone(),
        ) {
            eprintln!(
                "cmux-tui: could not publish adopted detached terminal {terminal_id}: {error:#}"
            );
        }
    }

    /// Raw v12 clients subscribed with `tree_events` learn about a tab that
    /// `terminal.project` or `terminal.move` added or moved: the resource
    /// journal alone reaches only resource API v2 subscribers.
    pub(super) fn emit_raw_tree_changed_for(&self, operation: &str) {
        if matches!(operation, "terminal.project" | "terminal.move") {
            self.emit(MuxEvent::TreeChanged);
        }
    }
}
