//! Spawning a new terminal surface on a durable host under a registry
//! reservation. When the host launch already started for the reserved id
//! (`tab_launch`), the create accepts it and returns a launching surface
//! without waiting for the host. Otherwise it reserves the terminal row,
//! launches the host, commits `running`, and inserts the surface.

use super::*;

impl Mux {
    /// The durable-host branch of `spawn_surface_with`.
    pub(super) fn spawn_hosted_reserved_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        opts: SurfaceOptions,
        cell_pixels: (u16, u16),
        workspace_key: &str,
        reservation: Option<TerminalReservationRequest>,
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_id = reservation
            .as_ref()
            .map(|reservation| reservation.terminal_id)
            .map(Ok)
            .unwrap_or_else(TerminalId::random)?;
        let terminal_hex = terminal_id.to_hex();
        // A host launch started ahead of this creation for the same
        // reserved id: accept it and reply before the host is ready.
        if let Some(accepted) =
            self.accept_launching_terminal(&terminal_hex, workspace_key, reservation.as_ref())
        {
            return accepted;
        }
        let launch_spec = terminal_launch_spec(&opts);
        let terminal = RegistryTerminal {
            terminal_id: terminal_hex.clone(),
            workspace_key: workspace_key.to_string(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec,
            exit: None,
            on_exit: reservation
                .as_ref()
                .map(|reservation| reservation.on_exit)
                .unwrap_or_default(),
        };
        let reserve_replayed = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let (replayed, revision) = if let Some(reservation) = reservation.as_ref() {
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
            } else {
                let revision = commit_terminal_transition(
                    &mut registry,
                    "terminal-reserved",
                    "reserve-terminal",
                    &terminal,
                )?;
                (false, revision)
            };
            if !replayed {
                self.emit_terminal_registry_changed(&registry, revision);
            }
            replayed
        };
        if reserve_replayed {
            anyhow::bail!("terminal_create_replayed");
        }
        let spawned = Surface::spawn_with_terminal_id_at_cell_pixels(
            id,
            opts,
            Arc::downgrade(self),
            Some(terminal_id),
            cell_pixels,
        );
        let surface = match spawned {
            Ok(surface) => surface,
            Err(error) => {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    None,
                    &TerminalEnd::launch_failed(format!("launch-failed: {error}")),
                );
                return Err(error);
            }
        };
        let _pending_host_release = PendingTerminalHostRelease(surface.clone());
        let identity = surface
            .terminal_host_identity()
            .ok_or_else(|| anyhow::anyhow!("reserved terminal did not return host identity"))?;
        if identity.terminal_id != terminal_hex {
            let _ = self.persist_terminal_exit(
                &terminal_hex,
                None,
                &TerminalEnd::launch_failed("host-identity-mismatch"),
            );
            surface.kill();
            anyhow::bail!("terminal host changed registry-reserved identity");
        }
        {
            let mut registry = self.workspace_registry.lock().unwrap();
            let ready = commit_terminal_lifecycle(
                &mut registry,
                "terminal-ready",
                "terminal-ready",
                &terminal_hex,
                TerminalLifecycle::Running,
                Some(&identity.incarnation),
                None,
            );
            let (_, ready_revision) = match ready {
                Ok(ready) => ready,
                Err(error) => {
                    surface.kill();
                    return Err(error);
                }
            };
            self.emit_terminal_registry_changed(&registry, ready_revision);
        }
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                let persistence = self.persist_terminal_cell_pixel_reconcile_failure(
                    &terminal_hex,
                    Some(&identity.incarnation),
                    &error,
                );
                surface.kill();
                persistence?;
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            let _ = self.persist_terminal_exit(
                &terminal_hex,
                Some(&identity.incarnation),
                &TerminalEnd::launch_failed("surface-insert-failed"),
            );
            surface.kill();
            return Err(error);
        }
        // Deprecated recovery mirror only; SQLite is placement authority.
        let _ = surface.persist_host_workspace(workspace_key);
        Ok(surface)
    }
}
