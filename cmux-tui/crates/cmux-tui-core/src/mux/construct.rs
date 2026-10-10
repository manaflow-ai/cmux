//! Mux construction: in-memory, persistent and provider-managed constructors,
//! the shared `from_workspace_registry` bootstrap, and test constructors.

use super::*;

impl Mux {
    pub fn new(session: impl Into<String>, surface_options: SurfaceOptions) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState::default(),
            false,
        )
    }

    /// Builds a mux whose workspace lifecycle is provider-owned from its
    /// first control connection. The authority must be provisioned by the
    /// provider that owns this mux generation.
    pub fn new_provider_managed(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        authority: ProviderWorkspaceAuthority,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: None,
                authority_generation: 1,
                authority: Some(authority),
            },
            false,
        )
    }

    /// Builds a provider-owned mux whose authority will be installed through
    /// the root-only management socket before lifecycle mutations are allowed.
    pub fn new_provider_managed_pending(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        mux_generation: impl Into<String>,
    ) -> anyhow::Result<Arc<Self>> {
        let mux_generation = mux_generation.into();
        validate_mux_generation(&mux_generation)?;
        Ok(Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: Some(mux_generation.into_boxed_str()),
                authority_generation: 0,
                authority: None,
            },
            false,
        ))
    }

    pub(super) fn new_with_test_surface_runtime(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        provider_workspace: ProviderWorkspaceState,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> Arc<Self> {
        let session = session.into();
        let registry = WorkspaceRegistry::in_memory(&session)
            .expect("in-memory workspace registry must initialize");
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            provider_workspace,
            test_surface_runtime,
        )
        .expect("in-memory workspace registry must load")
    }

    pub fn open_persistent(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        state_root: &Path,
    ) -> anyhow::Result<Arc<Self>> {
        let session = session.into();
        let registry = WorkspaceRegistry::open(state_root, &session)?;
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            ProviderWorkspaceState::default(),
            false,
        )
    }

    pub fn open_persistent_provider_managed(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        state_root: &Path,
        authority: ProviderWorkspaceAuthority,
    ) -> anyhow::Result<Arc<Self>> {
        let session = session.into();
        let registry = WorkspaceRegistry::open(state_root, &session)?;
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: None,
                authority_generation: 1,
                authority: Some(authority),
            },
            false,
        )
    }

    pub fn open_persistent_provider_managed_pending(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        state_root: &Path,
        mux_generation: impl Into<String>,
    ) -> anyhow::Result<Arc<Self>> {
        let mux_generation = mux_generation.into();
        validate_mux_generation(&mux_generation)?;
        let session = session.into();
        let registry = WorkspaceRegistry::open(state_root, &session)?;
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: Some(mux_generation.into_boxed_str()),
                authority_generation: 0,
                authority: None,
            },
            false,
        )
    }

    pub(crate) fn from_workspace_registry(
        session: String,
        surface_options: SurfaceOptions,
        mut registry: WorkspaceRegistry,
        provider_workspace: ProviderWorkspaceState,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let snapshot = registry.snapshot()?;
        let topology = registry.resource_topology_snapshot()?;
        let session_shutdown = crate::session_shutdown::SessionShutdownClock::open(
            registry
                .session_journal_database_path()
                .map(|database| crate::session_shutdown::owner_shutdown_marker_path(&database)),
            crate::session_shutdown::unix_now_ms(),
        );
        let RestoredResourceState { mut state, next_id, contents } =
            restore_resource_state(snapshot, topology)?;
        let RestoredPublicProjections {
            default_colors,
            has_terminal_defaults,
            next_notification_id,
            agent_records,
            agent_hook_fences,
            terminal_notifications,
            notification_ledger,
            notification_reads,
        } = restore_public_projections(&state, registry.public_projections()?)?;
        let agent_roster_restore::RestoredAgentRoster {
            host: agent_roster,
            diagnostic: agent_roster_diagnostic,
        } = agent_roster_restore::restore_agent_roster(&registry)?;
        let feed_local = Mutex::new(registry.open_feed_local()?);
        let presentation = registry.presentation_snapshot()?;
        let journal_producers = registry.journal_producer_manifests()?;
        let session_public_id = registry.session_id().clone();
        let machine_public_id = registry.machine_id().clone();
        let journal_kernel = crate::journal_kernel::JournalKernel::new(
            registry.session_journal_database_path(),
            &journal_producers,
        )?;
        let (journal_ingress, journal_ingress_receiver) =
            crate::journal_ingress::JournalIngressSender::new(
                registry.session_journal_database_path().is_some(),
            );
        Self::rebuild_split_screen_index(&mut state);
        let resource_projection_stats = registry.resource_projection_stats().clone();
        let mux = Arc::new(Mux {
            registry_connection: registry.connection.clone(),
            workspace_registry: SignaledMutex::new(registry),
            session_public_id,
            machine_public_id,
            connection_stats: Arc::default(),
            resource_projection_stats,
            started_at: Instant::now(),
            state: signaled_mutex::StateMutex::new(state),
            subscribers: MuxEventBroadcaster::default(),
            config_reload: Mutex::new(ConfigReloadState::default()),
            config_reload_changed: Condvar::new(),
            next_id: AtomicU64::new(next_id),
            next_notification_id: AtomicU64::new(next_notification_id),
            next_active_at: AtomicU64::new(1),
            next_in_process_resize_owner: AtomicU64::new(1),
            surface_options: Mutex::new(surface_options),
            provider_managed: AtomicBool::new(provider_workspace.managed),
            provider_workspace: Mutex::new(provider_workspace),
            workspace_lifecycles: Mutex::new(HashMap::new()),
            pending_workspace_surfaces: Mutex::new(HashMap::new()),
            client_sizing_lifecycle: Mutex::new(()),
            client_sizing: Mutex::new(ClientSizingState::default()),
            client_focus_memory: Mutex::new(Vec::new()),
            last_reported_focus: Mutex::new(None),
            conversations: Default::default(),
            cloud_conversations: OnceLock::new(),
            #[cfg(test)]
            client_resize_before_apply: Mutex::new(None),
            #[cfg(test)]
            terminal_move_before_projection: Mutex::new(None),
            #[cfg(test)]
            client_rollback_before_wait: Mutex::new(None),
            #[cfg(test)]
            workspace_close_before_empty_check: Mutex::new(None),
            #[cfg(test)]
            workspace_close_after_selector_resolution: Mutex::new(None),
            #[cfg(test)]
            workspace_delta_before_emit: Mutex::new(None),
            #[cfg(test)]
            resource_rename_after_selector_resolution: Mutex::new(None),
            #[cfg(test)]
            layout_apply_after_workspace_reservation: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_empty_check: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_materialization_lock: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_workspace_reservation: Mutex::new(None),
            #[cfg(test)]
            terminal_spawn_after_cell_pixel_snapshot: Mutex::new(None),
            #[cfg(test)]
            terminal_spawn_before_cell_pixel_reconcile: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_terminal_reservation: Mutex::new(None),
            pending_terminal_hosts: Mutex::new(HashMap::new()),
            reserved_in_process_terminals: Mutex::new(HashMap::new()),
            #[cfg(test)]
            viewport_split_after_spawn: Mutex::new(None),
            #[cfg(test)]
            resource_mutation_metrics: Mutex::new(None),
            #[cfg(test)]
            resource_projection_before_commit: Mutex::new(None),
            #[cfg(test)]
            resource_close_after_commit: Mutex::new(None),
            #[cfg(test)]
            layout_undo_before_commit: Mutex::new(None),
            #[cfg(test)]
            resource_close_cleanup: Mutex::new(None),
            browser_providers: Arc::new(BrowserProviderRegistry::default()),
            browser_runtime: Mutex::new(None),
            active_render_attachments: Arc::new(AtomicUsize::new(0)),
            deadline_fanout_pool: DeadlineFanoutPool::new(),
            kitty_image_budget: Mutex::new(KittyImageBudgetState::default()),
            kitty_image_budget_changed: Condvar::new(),
            app_terminals: Mutex::default(),
            #[cfg(debug_assertions)]
            terminal_host_reconnect_completion_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_RECONNECT_COMPLETION_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            #[cfg(debug_assertions)]
            terminal_host_test_disconnect_after_spawn_ms: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_DISCONNECT_HOST_AFTER_SPAWN_MS")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            #[cfg(test)]
            kitty_image_budget_operation: Mutex::new(None),
            cell_pixel_lifecycle: Mutex::new(()),
            next_cell_pixel_generation: AtomicU64::new(1),
            cell_pixels: Mutex::new((8, 16)),
            pending_cell_pixels: Mutex::new(None),
            cell_pixel_retries: Mutex::new(CellPixelRetryQueue::default()),
            #[cfg(test)]
            cell_pixel_before_publish: Mutex::new(None),
            #[cfg(test)]
            cell_pixel_operation: Mutex::new(None),
            #[cfg(test)]
            cell_pixel_fanout_timeout: Mutex::new(None),
            default_colors: crate::lock_rank::RankedMutex::new(
                crate::lock_rank::LockRank::Leaf,
                "mux.default_colors",
                default_colors,
            ),
            durable_terminal_defaults: AtomicBool::new(has_terminal_defaults),
            sidebar_plugin: Mutex::new(SidebarPluginRuntime::default()),
            journal_plugin: crate::journal_plugin::JournalPluginRuntime::default(),
            machine_usage: Mutex::new(None),
            agent_records: Mutex::new(agent_records),
            agent_hook_fences: Mutex::new(agent_hook_fences),
            agent_roster: Mutex::new(agent_roster),
            agent_roster_fold: Mutex::new(()),
            placement_notifications: Mutex::new(HashMap::new()),
            terminal_notifications: Mutex::new(terminal_notifications),
            terminal_command_history: AtomicBool::new(false),
            shell_command_journal: Mutex::new(None),
            notification_ledger: Mutex::new(notification_ledger),
            notification_reads: Mutex::new(notification_reads),
            notification_read_prunes: Mutex::new(Vec::new()),
            feed_local,
            presentation: Mutex::new(Arc::new(presentation)),
            git_heads: Mutex::new(HashMap::new()),
            resource_machine_service: OnceLock::new(),
            journal_kernel,
            journal_ingress,
            journal_hook_dispatcher_started: AtomicBool::new(false),
            journal_hook_runtime: Arc::new(crate::journal_hooks::JournalHookRuntime::default()),
            journal_event_epoch: Mutex::new(0),
            journal_event_changed: Condvar::new(),
            reconnect_checkpoint_skip_reported: AtomicBool::new(false),
            journal_retention: Default::default(),
            diagnostic_reporter: OnceLock::new(),
            pending_diagnostics: Mutex::new(Vec::new()),
            #[cfg(test)]
            journal_segment_prepare_hook: Mutex::new(None),
            #[cfg(test)]
            screen_created_hook: Mutex::new(None),
            terminal_exit_waiters: TerminalExitWaiters::default(),
            #[cfg(test)]
            terminal_exit_state_queries: AtomicU64::new(0),
            resource_creation_handoff: Mutex::new(()),
            initial_bootstrap: Mutex::new(()),
            resource_creation_execution: Mutex::new(()),
            resource_creation_active: AtomicBool::new(false),
            terminal_adoptions: Mutex::new(HashSet::new()),
            pending_terminals: Mutex::new(HashMap::new()),
            terminal_ends: Mutex::new(HashMap::new()),
            terminal_loss_causes: Mutex::new(loss_causes::LossCauses::default()),
            terminal_exit_detaches: Arc::new(TerminalExitDetachTracker::default()),
            terminal_adoption_insert_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_ADOPTION_INSERT_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            template_completion_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_TEMPLATE_COMPLETION_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            server_lifecycle_ready: AtomicBool::new(false),
            shutting_down: AtomicBool::new(false),
            session_shutdown,
            exit_settles: Arc::default(),
            terminal_respawns: terminal_respawn::TerminalRespawns::from_env(),
            daemon_shutdown_waker: Mutex::new(None),
            control_clients: crate::server::ClientRegistry::new(),
            activity: Default::default(),
            idle_close: Mutex::new(idle_close::IdleCloseTracker::default()),
            idle_close_waker: Mutex::new(None),
            terminal_host_closes: Arc::new(host_close::TerminalHostCloses::default()),
            terminal_reap_grace_ms: AtomicU64::new(
                u64::try_from(DEFAULT_TERMINAL_REAP_GRACE.as_millis()).unwrap_or(u64::MAX),
            ),
            terminal_reaper_events: Mutex::new(None),
            launch_snapshot_path: Mutex::new(None),
            terminal_work: terminal_work::TerminalWorkPool::default(),
            #[cfg(unix)]
            prelaunched_terminals: Mutex::new(HashMap::new()),
            #[cfg(unix)]
            image_pastes: crate::image_paste::ImagePasteStore::default(),
            history: crate::history_ops::HistoryHost::default(),
            surface_operation_admission: Arc::new(
                crate::server::ServerSurfaceOperationAdmission::default(),
            ),
            pairing: PairingBroker::new(),
            #[cfg(test)]
            test_surface_runtime,
            session,
        });
        mux.exit_settles.bind(Arc::downgrade(&mux));
        let weak_mux = Arc::downgrade(&mux);
        mux.journal_plugin.set_exit_handler(Some(Arc::new(move |plugin_id, generation| {
            let Some(mux) = weak_mux.upgrade() else { return };
            // Do not drop a late exit callback here. The reducer uses the
            // child generation to fence a replacement process.
            mux.record_journal_plugin_exit(plugin_id, generation);
        })));
        crate::journal_ingress::start(&mux, journal_ingress_receiver)?;
        mux.materialize_interrupted_resource_workspaces()?;
        mux.materialize_restored_browsers(&contents)?;
        #[cfg(unix)]
        mux.adopt_terminal_hosts()?;
        {
            let mut state = mux.state.lock().unwrap();
            state.rebuild_resource_indexes();
            for content in &contents {
                if let Some(surface) = state.surfaces.get(&content.slot) {
                    surface.set_name(content.name.clone());
                }
            }
        }
        // The roster reducer and the public projection are durable in
        // separate transactions. A crash can therefore leave a plugin row in
        // the roster while dropping the projection side effect. Reconcile
        // after restored surfaces exist, and repeat at the end of asynchronous
        // terminal adoption for hosts that were not available yet.
        mux.reconcile_agent_roster_projections();
        if let Some(diagnostic) = agent_roster_diagnostic {
            mux.report_internal_diagnostic(diagnostic);
        }
        let recovery_deadline = Instant::now() + Duration::from_secs(15);
        while mux.reconcile_interrupted_resource_creations()? {
            if Instant::now() >= recovery_deadline {
                mux.shutdown();
                anyhow::bail!("interrupted resource creation did not settle during startup");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        mux.close_ephemeral_workspaces()?;
        mux.retry_pending_agent_hooks()?;
        crate::journal_hooks::start(&mux)?;
        Ok(mux)
    }

    pub fn lock_initial_bootstrap(&self) -> MutexGuard<'_, ()> {
        self.initial_bootstrap.lock().unwrap()
    }

    #[cfg(test)]
    pub(crate) fn new_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState::default(),
            true,
        )
    }

    #[cfg(test)]
    pub(crate) fn new_provider_managed_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        authority: ProviderWorkspaceAuthority,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: None,
                authority_generation: 1,
                authority: Some(authority),
            },
            true,
        )
    }

    #[cfg(test)]
    pub(crate) fn new_provider_managed_pending_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        mux_generation: &str,
    ) -> Arc<Self> {
        let mux = Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: Some(mux_generation.into()),
                authority_generation: 0,
                authority: None,
            },
            true,
        );
        validate_mux_generation(mux_generation).unwrap();
        mux
    }
}
