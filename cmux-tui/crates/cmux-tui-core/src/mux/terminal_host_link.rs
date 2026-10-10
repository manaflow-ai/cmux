//! Terminal host link: lifecycle transitions, pending host registration and callback matching, and host connection loss and reconnect.

use super::*;

impl Mux {
    pub(super) fn transition_terminal_lifecycle(
        &self,
        event_kind: &str,
        operation: &str,
        terminal_id: &str,
        lifecycle: TerminalLifecycle,
        incarnation: Option<&str>,
    ) -> anyhow::Result<(RegistryTerminal, u64)> {
        anyhow::ensure!(
            lifecycle != TerminalLifecycle::Exited,
            "terminal exits must use the durable public exit latch"
        );
        let mut registry = self.workspace_registry.lock().unwrap();
        let result = commit_terminal_lifecycle(
            &mut registry,
            event_kind,
            operation,
            terminal_id,
            lifecycle,
            incarnation,
            None,
        )?;
        self.emit_terminal_registry_changed(&registry, result.1);
        Ok(result)
    }

    #[cfg(unix)]
    pub(crate) fn register_pending_terminal_host(
        self: &Arc<Self>,
        surface_id: SurfaceId,
        identity: TerminalHostIdentity,
    ) -> anyhow::Result<PendingTerminalHostBinding> {
        let registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(&identity.terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("pending terminal host is not registered"))?;
        match terminal.lifecycle {
            TerminalLifecycle::Launching => anyhow::ensure!(
                terminal.incarnation.is_none(),
                "launching terminal has an unexpected durable incarnation"
            ),
            TerminalLifecycle::Adopting => anyhow::ensure!(
                terminal.incarnation.as_deref() == Some(identity.incarnation.as_str()),
                "adopting terminal does not match the pending host incarnation"
            ),
            _ => anyhow::bail!("terminal is not awaiting host topology publication"),
        }
        drop(registry);

        let mut pending = self.pending_terminal_hosts.lock().unwrap();
        anyhow::ensure!(
            !pending.contains_key(&surface_id),
            "surface already has a pending terminal host"
        );
        pending.insert(surface_id, identity.clone());
        Ok(PendingTerminalHostBinding { mux: Arc::downgrade(self), surface_id, identity })
    }

    /// A hosted reader can lose and restore its admin stream before its
    /// runtime enters the topology. Accept only the exact surface and host
    /// incarnation that the launch or adoption path stored before the reader
    /// started. Registered runtimes still use the strict state checks below.
    pub(super) fn pending_terminal_host_callback_matches(
        &self,
        state: &State,
        surface_id: SurfaceId,
        surface_registered: bool,
        terminal: &RegistryTerminal,
        identity: &TerminalHostIdentity,
    ) -> bool {
        let expected = self.pending_terminal_hosts.lock().unwrap().get(&surface_id).cloned();
        let Some(expected) = expected else { return false };
        !surface_registered
            && expected == *identity
            && terminal.terminal_id == expected.terminal_id
            && !state.terminal_catalog.values().any(|candidate| {
                candidate
                    .terminal_host_identity()
                    .is_some_and(|current| current.terminal_id == identity.terminal_id)
            })
            && matches!(
                terminal.lifecycle,
                TerminalLifecycle::Launching
                    | TerminalLifecycle::Adopting
                    | TerminalLifecycle::Running
            )
            && match terminal.lifecycle {
                TerminalLifecycle::Launching => terminal.incarnation.is_none(),
                TerminalLifecycle::Adopting | TerminalLifecycle::Running => {
                    terminal.incarnation.as_deref() == Some(expected.incarnation.as_str())
                }
                _ => false,
            }
    }

    /// A broken admin stream is not evidence that the per-terminal process
    /// died. The surface keeps its tab and reconnects the same incarnation;
    /// this callback only exposes the transient lifecycle to frontends.
    pub(crate) fn terminal_host_connection_lost(
        &self,
        surface_id: SurfaceId,
        identity: &TerminalHostIdentity,
    ) -> bool {
        if self.shutting_down.load(Ordering::Acquire) {
            return false;
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        let state = self.lock_state_pinned(&registry).unwrap();
        let surface =
            state.surfaces.get(&surface_id).or_else(|| state.terminal_runtime_by_id(surface_id));
        let identity_matches = surface
            .and_then(|surface| surface.terminal_host_identity())
            .is_some_and(|current| current == *identity);
        let topology_pending = self.pending_terminal_host_callback_matches(
            &state,
            surface_id,
            surface.is_some(),
            &terminal,
            identity,
        );
        drop(state);
        if topology_pending {
            return true;
        }
        if !identity_matches {
            return false;
        }
        if terminal.incarnation.as_deref() != Some(identity.incarnation.as_str())
            || matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            )
        {
            return false;
        }
        if terminal.lifecycle == TerminalLifecycle::Adopting {
            return true;
        }
        match commit_terminal_lifecycle(
            &mut registry,
            "terminal-adopting",
            "terminal-admin-stream-lost",
            &identity.terminal_id,
            TerminalLifecycle::Adopting,
            Some(&identity.incarnation),
            None,
        ) {
            Ok((_, revision)) => {
                self.emit_terminal_registry_changed(&registry, revision);
                true
            }
            Err(error) => {
                self.emit(MuxEvent::Status(format!(
                    "could not persist terminal {} reconnect state: {error}",
                    identity.terminal_id
                )));
                false
            }
        }
    }

    pub(crate) fn terminal_host_reconnected(
        self: &Arc<Self>,
        surface_id: SurfaceId,
        identity: &TerminalHostIdentity,
        applied_kitty_limits: KittyGraphicsLimits,
    ) -> bool {
        if self.shutting_down.load(Ordering::Acquire) {
            return false;
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        let state = self.lock_state_pinned(&registry).unwrap();
        let surface = state
            .surfaces
            .get(&surface_id)
            .or_else(|| state.terminal_runtime_by_id(surface_id))
            .cloned();
        let identity_matches = surface
            .as_ref()
            .and_then(|surface| surface.terminal_host_identity())
            .is_some_and(|current| current == *identity);
        let topology_pending = self.pending_terminal_host_callback_matches(
            &state,
            surface_id,
            surface.is_some(),
            &terminal,
            identity,
        );
        drop(state);
        if topology_pending {
            return true;
        }
        if !identity_matches {
            return false;
        }
        if terminal.incarnation.as_deref() != Some(identity.incarnation.as_str())
            || matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            )
        {
            return false;
        }
        let lifecycle_ready = if terminal.lifecycle == TerminalLifecycle::Running {
            true
        } else {
            match commit_terminal_lifecycle(
                &mut registry,
                "terminal-ready",
                "terminal-admin-stream-reconnected",
                &identity.terminal_id,
                TerminalLifecycle::Running,
                Some(&identity.incarnation),
                None,
            ) {
                Ok((_, revision)) => {
                    self.emit_terminal_registry_changed(&registry, revision);
                    true
                }
                Err(error) => {
                    self.emit(MuxEvent::Status(format!(
                        "could not persist terminal {} reconnect completion: {error}",
                        identity.terminal_id
                    )));
                    false
                }
            }
        };
        drop(registry);
        if !lifecycle_ready {
            return false;
        }
        #[cfg(debug_assertions)]
        if self
            .terminal_host_reconnect_completion_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| {
                (remaining > 0).then(|| remaining - 1)
            })
            .is_ok()
        {
            return false;
        }
        surface.is_some_and(|surface| {
            self.reconcile_reconnected_kitty_image_surface(&surface, applied_kitty_limits)
        })
    }

    pub(crate) fn lock_client_sizing_lifecycle(&self) -> MutexGuard<'_, ()> {
        self.client_sizing_lifecycle.lock().unwrap()
    }

    #[cfg(debug_assertions)]
    pub(crate) fn take_test_terminal_host_disconnect_after_spawn(&self) -> Option<Duration> {
        let delay_ms = self.terminal_host_test_disconnect_after_spawn_ms.swap(0, Ordering::AcqRel);
        (delay_ms > 0).then(|| Duration::from_millis(delay_ms))
    }
}
