//! Workspace identity and authority: id allocation, workspace keys and names,
//! provider-managed lifecycle authority, and workspace lookups and revision
//! checks used by mutations.

use super::*;

impl Mux {
    pub(super) fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    pub(super) fn next_active_at(&self) -> u64 {
        self.next_active_at.fetch_add(1, Ordering::Relaxed)
    }

    pub(super) fn next_notification_id(&self) -> u64 {
        self.next_notification_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Allocate an undo-coalescing owner for one in-process frontend.
    ///
    /// Layout undo is in-memory state, so this namespace intentionally follows
    /// the mux lifecycle rather than durable workspace identity.
    pub fn allocate_in_process_resize_owner(&self) -> u64 {
        self.next_in_process_resize_owner
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |owner| {
                Some(owner.wrapping_add(1).max(1))
            })
            .expect("in-process resize owner allocation cannot fail")
    }

    pub(super) fn new_workspace_key() -> anyhow::Result<String> {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| {
            anyhow::anyhow!(
                "could not create workspace identity; retry, then restart cmux if the problem continues"
            )
        })?;
        // RFC 9562 UUIDv4 version and variant bits. Keeping the formatter
        // local avoids making stable workspace identity depend on a UUID
        // library at the protocol boundary.
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Ok(format!(
            "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }

    pub(super) fn validate_workspace_key(key: &str) -> anyhow::Result<()> {
        if key.trim().is_empty() {
            anyhow::bail!("workspace key cannot be empty");
        }
        if key.len() > WORKSPACE_KEY_MAX_BYTES {
            anyhow::bail!("workspace key exceeds {WORKSPACE_KEY_MAX_BYTES} bytes");
        }
        Ok(())
    }

    pub(super) fn validate_workspace_name(name: &str) -> anyhow::Result<()> {
        if name.len() > WORKSPACE_NAME_MAX_BYTES {
            anyhow::bail!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes");
        }
        Ok(())
    }

    pub(super) fn workspace_lifecycle(&self, workspace: WorkspaceId) -> Arc<Mutex<()>> {
        let mut lifecycles = self.workspace_lifecycles.lock().unwrap();
        lifecycles.retain(|_, lifecycle| lifecycle.strong_count() > 0);
        if let Some(lifecycle) = lifecycles.get(&workspace).and_then(Weak::upgrade) {
            return lifecycle;
        }
        let lifecycle = Arc::new(Mutex::new(()));
        lifecycles.insert(workspace, Arc::downgrade(&lifecycle));
        lifecycle
    }

    /// Permanently assigns workspace rename/delete ownership to the external
    /// provider for this mux generation. The transition is intentionally
    /// one-way so a stale frontend cannot reopen ordinary mutation paths.
    pub fn mark_workspaces_provider_managed_internal(&self) {
        self.provider_workspace.lock().unwrap().managed = true;
        self.provider_managed.store(true, Ordering::Release);
    }

    pub fn workspaces_are_provider_managed(&self) -> bool {
        self.provider_workspace.lock().unwrap().managed
    }

    pub fn provider_workspace_authority_status(&self) -> ProviderWorkspaceAuthorityStatus {
        self.provider_workspace.lock().unwrap().status()
    }

    pub fn install_or_rotate_provider_workspace_authority(
        &self,
        mux_generation: &str,
        expected_authority_generation: u64,
        authority_generation: u64,
        authority: ProviderWorkspaceAuthority,
    ) -> Result<ProviderWorkspaceAuthorityStatus, ProviderWorkspaceAuthorityUpdateError> {
        let mut state = self.provider_workspace.lock().unwrap();
        if !state.managed || state.mux_generation.is_none() {
            return Err(ProviderWorkspaceAuthorityUpdateError::Unmanaged);
        }
        if state.mux_generation.as_deref() != Some(mux_generation) {
            return Err(ProviderWorkspaceAuthorityUpdateError::MuxGenerationMismatch);
        }

        if authority_generation == state.authority_generation {
            let identical = state
                .authority
                .as_ref()
                .is_some_and(|installed| constant_time_eq(authority.expose(), installed.expose()));
            return if identical {
                Ok(state.status())
            } else {
                Err(ProviderWorkspaceAuthorityUpdateError::GenerationConflict)
            };
        }

        if expected_authority_generation != state.authority_generation {
            return Err(ProviderWorkspaceAuthorityUpdateError::ExpectedGenerationMismatch);
        }
        let valid_initial_install = state.authority_generation == 0
            && state.authority.is_none()
            && authority_generation > 0;
        let valid_rotation = state.authority.is_some()
            && authority_generation == state.authority_generation.saturating_add(1);
        if !valid_initial_install && !valid_rotation {
            return Err(ProviderWorkspaceAuthorityUpdateError::InvalidGeneration);
        }
        state.authority_generation = authority_generation;
        state.authority = Some(authority);
        Ok(state.status())
    }

    /// Validates the secret provisioned for this provider-owned mux
    /// generation. The same rejection covers missing and incorrect secrets so
    /// the control socket cannot be used to probe whether a value was set.
    pub fn authorize_provider_workspace_authority(&self, provided: &str) -> anyhow::Result<()> {
        let authorized = self
            .provider_workspace
            .lock()
            .unwrap()
            .authority
            .as_ref()
            .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.expose()));
        if !authorized {
            anyhow::bail!("invalid provider workspace authority");
        }
        Ok(())
    }

    pub(super) fn authorize_workspace_lifecycle_mutation(
        &self,
        authorization: WorkspaceMutationAuthority<'_>,
        operation: &str,
    ) -> anyhow::Result<MutexGuard<'_, ProviderWorkspaceState>> {
        let authority = self.provider_workspace.lock().unwrap();
        if authority.managed && matches!(authorization, WorkspaceMutationAuthority::Ordinary) {
            anyhow::bail!(
                "cannot {operation} a provider-managed workspace directly; use the managed workspace lifecycle controls"
            );
        }
        if !authority.managed && !matches!(authorization, WorkspaceMutationAuthority::Ordinary) {
            anyhow::bail!(
                "cannot apply provider workspace {operation}; this session is not provider-managed"
            );
        }
        if let WorkspaceMutationAuthority::ProviderCredential(provided) = authorization {
            let authorized = authority
                .authority
                .as_ref()
                .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.expose()));
            if !authorized {
                anyhow::bail!("invalid provider workspace authority");
            }
        }
        Ok(authority)
    }

    pub(super) fn pending_workspace_surface(
        &self,
        surface: SurfaceId,
    ) -> PendingWorkspaceSurface<'_> {
        PendingWorkspaceSurface { pending: &self.pending_workspace_surfaces, surface }
    }

    pub(super) fn workspace_for_surface_in_state(
        state: &State,
        surface: SurfaceId,
    ) -> Option<WorkspaceId> {
        let pane = state.pane_of(surface)?;
        let (workspace, _) = state.screen_of(pane)?;
        Some(state.workspaces[workspace].id)
    }

    pub(super) fn workspace_for_tree_target_in_state(
        state: &State,
        target: TreeCloseTarget,
    ) -> Option<WorkspaceId> {
        match target {
            TreeCloseTarget::Pane(pane) => {
                let (workspace, _) = state.screen_of(pane)?;
                Some(state.workspaces[workspace].id)
            }
            TreeCloseTarget::Screen(screen) => state
                .workspaces
                .iter()
                .find(|workspace| workspace.screens.iter().any(|candidate| candidate.id == screen))
                .map(|workspace| workspace.id),
        }
    }

    pub(super) fn surface_workspace(&self, surface: SurfaceId) -> Option<WorkspaceId> {
        self.pending_workspace_surfaces.lock().unwrap().get(&surface).copied().or_else(|| {
            let state = self.state.lock().unwrap();
            Self::workspace_for_surface_in_state(&state, surface)
        })
    }

    pub(super) fn require_workspace_revision(
        state: &State,
        expected: Option<u64>,
    ) -> anyhow::Result<()> {
        if let Some(expected) = expected
            && expected != state.workspace_revision
        {
            anyhow::bail!(
                "workspace revision conflict: expected {expected}, current {}",
                state.workspace_revision
            );
        }
        Ok(())
    }
}
