//! Part of `Hub`; see `hub/mod.rs`. Building a hub: the constructors a daemon and the tests
//! use, and `build`, which opens every store-backed cell and starts the background tasks.

use super::*;

impl Hub {
    pub fn new(config: Config, store: Box<dyn Store>) -> Arc<Self> {
        Self::new_with_mailbox(config, store, Mailbox::memory())
    }

    /// A daemon's hub: only the session list is read before it answers. The chat
    /// logs (their tails, queues and unsettled turns) load in `load_logs`, after
    /// the ready line (2026-10-20: reading 3.9 GB of logs first took 26.8 s).
    pub fn new_deferred(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, true, false, None, true)
    }

    pub fn new_with_mailbox(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, false, false, None, true)
    }

    /// A daemon serves immediately; metadata is read after its ready line.
    pub fn new_loading(config: Config, store: Box<dyn Store>, mailbox: Mailbox) -> Arc<Self> {
        Self::build(config, store, mailbox, true, true, None, true)
    }

    /// A hub whose configured peers may dial over `wireguard` first, as a daemon's do: for tests
    /// that run two daemons in one process and cut that carrier (`tests/carrier_faults.rs`).
    #[doc(hidden)]
    pub fn new_with_wireguard(
        config: Config,
        store: Box<dyn Store>,
        wireguard: Arc<crate::wireguard::Transport>,
    ) -> Arc<Self> {
        Self::build(config, store, Mailbox::memory(), false, false, Some(wireguard), true)
    }

    pub(crate) fn new_loading_with_wireguard(
        config: Config,
        store: Box<dyn Store>,
        mailbox: Mailbox,
        wireguard: Option<Arc<crate::wireguard::Transport>>,
    ) -> Arc<Self> {
        Self::build(config, store, mailbox, true, true, wireguard, false)
    }

    pub(super) fn build(
        config: Config,
        store: Box<dyn Store>,
        mailbox: Mailbox,
        deferred: bool,
        loading: bool,
        wireguard: Option<Arc<crate::wireguard::Transport>>,
        start_peers: bool,
    ) -> Arc<Self> {
        let events = list_guard::Events::new(8192);
        let (peer_notices, peer_notices_rx) = mpsc::channel(4096);
        let peers_cfg = config.peers.clone();
        let handoffs = handoff::Handoffs::open(store.handoff_dir());
        // Loaded now, so a forced `sessions.allowFullAccess` off holds from the first request
        // after a restart, before the app pushes again (`start_mode_state.rs`).
        let start_mode_state =
            start_mode_state::StartModeCell::load(start_mode_state::state_file(&config).as_deref());
        // Loaded before the socket serves, so an agent that outlived the previous daemon is
        // known by its caller token from the first request (`caller_registry.rs`).
        let caller_registry =
            caller_registry::CallerRegistry::load(caller_registry::state_file(&config));
        // Beside the peer caches, in the home they are in; a memory store keeps neither.
        let home = store.peer_cache_dir().and_then(|p| p.parent().map(Path::to_path_buf));
        let peer_paths = Arc::new(crate::peer_last_good::LastGood::open(home.as_deref()));
        // `writeJournal.enabled`: the paused machines' replicas and journals (`paused_fs.rs`).
        let paused_fs = paused_fs::open(&config, home.as_deref());
        // A removed peer's kept remote tokens go with it (`peer_kept_tokens.rs`).
        peer_paths
            .tokens
            .retain(peers_cfg.iter().map(|(name, pc)| (name.as_str(), pc.url.as_str())));
        let suggestion_gate = StdMutex::new(crate::suggestion_gate::Gate::open(home.as_deref()));
        // Beside the session store in its home; a memory store keeps it in memory only.
        let ledger = ledger::Ledger::open(home.as_ref().map(|h| h.join("ledger")));
        let peer_snapshots = peer_snapshot::PeerSnapshots::open(home);
        let briefs = dispatch::Briefs::open(store.briefs_path());
        let audit = audit_log::AuditLog::open(store.audit_dir());
        let usage_limits = StdMutex::new(config.usage_warnings.limits());
        let peer_wake = Arc::new(StdMutex::new(config.peer_wake.as_ref().map(|w| w.argv.clone())));
        #[cfg(feature = "hub-carrier")]
        let hub_carrier =
            crate::hub_carrier::HubCarrierSlot::for_daemon(&config, wireguard.as_ref());
        let hub = Arc::new(Self {
            hub_ref: std::sync::OnceLock::new(),
            config: RwLock::new(config),
            usage_limits,
            wireguard,
            #[cfg(feature = "hub-carrier")]
            hub_carrier,
            #[cfg(feature = "hub-carrier")]
            hub_carrier_serve: Default::default(),
            #[cfg(feature = "hub-carrier")]
            hub_carrier_websocket: std::sync::OnceLock::new(),
            #[cfg(feature = "hub-carrier")]
            machine_routes: Default::default(),
            peer_paths,
            store: Box::new(crate::store::ForkView::new(store)),
            mailbox,
            forum: std::sync::OnceLock::new(),
            forum_hosted: std::sync::OnceLock::new(),
            sessions: StdMutex::new(HashMap::new()),
            evicted: Default::default(),
            spoken_handle_renames: StdMutex::new(()),
            live_session_ids: StdMutex::new(std::collections::HashSet::new()),
            closed_summary_cache: StdMutex::new(Default::default()),
            chat_activity_cache: Default::default(),
            book_tee: std::sync::OnceLock::new(),
            rows: Default::default(),
            #[cfg(test)]
            closed_summary_builds: AtomicU64::new(0),
            #[cfg(test)]
            closed_summary_parses: AtomicU64::new(0),
            #[cfg(test)]
            summaries_built: AtomicU64::new(0),
            message_repairs: StdMutex::new(std::collections::HashSet::new()),
            #[cfg(test)]
            message_projection_failures: StdMutex::new(std::collections::HashSet::new()),
            harness_homes: StdMutex::new(crate::adopt::HarnessHomes::from_env()),
            inline_btw: StdMutex::new(HashMap::new()),
            events,
            link_v2: Arc::default(),
            list_guard: Default::default(),
            op_once: Default::default(),
            list_order: Default::default(),
            requests_in_flight: Default::default(),
            usage_stats: Default::default(),
            usage_answers: Default::default(),
            ledger,
            models_fanouts: std::sync::atomic::AtomicUsize::new(0),
            review_index: Default::default(),
            audit,
            shutdown: Notify::new(),
            scope: cmux_scope::Scope::new("acpmux hub"),
            ws_shutdown: Default::default(),
            restart_requested: std::sync::atomic::AtomicBool::new(false),
            fatal: crate::supervise::Fatal::default(),
            started_at: now_ms(),
            peers: Default::default(),
            remote_sessions: Default::default(),
            mesh_book: Default::default(),
            hub_health: Default::default(),
            mesh_read_parts: Default::default(),
            mesh_read_flights: Default::default(),
            child_tags: Default::default(),
            peer_leases: StdMutex::new(HashMap::new()),
            peer_cache_writers: StdMutex::new(HashMap::new()),
            cache_write_gate: Arc::new(StdMutex::new(())),
            #[cfg(test)]
            cache_test_writes: AtomicU64::new(0),
            #[cfg(test)]
            remote_rows_copied: AtomicU64::new(0),
            #[cfg(test)]
            cache_test_bytes: AtomicU64::new(0),
            #[cfg(test)]
            cache_test_write_delay_ms: AtomicU64::new(0),
            #[cfg(test)]
            cache_test_write_started: AtomicBool::new(false),
            #[cfg(test)]
            cache_test_delay_peer: StdMutex::new(None),
            #[cfg(test)]
            cache_test_flush_pause: StdMutex::new(None),
            #[cfg(test)]
            peer_notice_projection_hook: StdMutex::new(None),
            peer_config_gen: std::sync::atomic::AtomicU64::new(0),
            github_owners: Default::default(),
            channels: Default::default(),
            github_app: Default::default(),
            auto_holder: std::sync::OnceLock::new(),
            auto_turns: Default::default(),
            peer_snapshots,
            peer_notices,
            peer_wake,
            peer_notices_rx: Mutex::new(Some(peer_notices_rx)),
            peer_notices_stop: tokio::sync::watch::channel(false).0,
            peer_notices_finished: AtomicBool::new(false),
            peer_notices_done: Arc::new(Notify::new()),
            peer_cache_kick: Notify::new(),
            #[cfg(test)]
            cache_test_save_every_ms: AtomicU64::new(peer_cache::SAVE_EVERY_MS),
            known_models: StdMutex::new(HashMap::new()),
            acp_cached: StdMutex::new(HashMap::new()),
            acp_from_disk: StdMutex::new(std::collections::HashSet::new()),
            probed_choices: StdMutex::new(HashMap::new()),
            known_efforts: StdMutex::new(HashMap::new()),
            live_models: StdMutex::new(HashMap::new()),
            live_rechecks: StdMutex::new(HashMap::new()),
            live_ages: StdMutex::new(live_ages::LiveAges::default()),
            refused_models: StdMutex::new(HashMap::new()),
            startup_ready: tokio::sync::watch::channel(true).0,
            local_ready: tokio::sync::watch::channel(start_peers).0,
            spawn_ready: tokio::sync::watch::channel(true).0,
            startup_work_done: tokio::sync::watch::channel(true).0,
            store_load: store_load::StoreLoad::new(loading),
            logs_ready: tokio::sync::watch::channel(true).0,
            load_plan: Default::default(),
            queues_resumed: AtomicBool::new(false),
            clone_boot: std::sync::OnceLock::new(),
            retention_wake: Arc::new(Notify::new()),
            cold_rehydrated: Default::default(),
            cold_wake: Arc::new(Notify::new()),
            cold_sealed: Default::default(),
            cold_sealed_wake: Arc::new(Notify::new()),
            pack_grown: Default::default(),
            pack_grown_wake: Arc::new(Notify::new()),
            pack_checked: Default::default(),
            #[cfg(test)]
            cold_segments_level: Default::default(),
            adoption_ready: tokio::sync::watch::channel(true).0,
            chat_adopted_wake: Notify::new(),
            catalog_ready: tokio::sync::watch::channel(true).0,
            model_caches_ready: tokio::sync::watch::channel(true).0,
            login_env_requested: AtomicBool::new(false),
            importing: StdMutex::new(std::collections::HashSet::new()),
            pending_forks: Default::default(),
            retention_running: Arc::new(AtomicBool::new(false)),
            handoffs,
            agent_hosts: AtomicBool::new(false),
            shutdown_plan: StdMutex::new(shutdown::ShutdownPlan::default()),
            settled_by_shutdown: StdMutex::new(Default::default()),
            ends_moved: Notify::new(),
            launchers: StdMutex::new(HashMap::new()),
            probe_errors: StdMutex::new(HashMap::new()),
            clock: StdMutex::new(crate::clock::TokioClock::new()),
            idle_child: StdMutex::new(Some(IDLE_CHILD)),
            start_hung: StdMutex::new(start_watch::START_HUNG),
            workflow_runs: crate::workflow_runs::Service::default(),
            bg_runner: StdMutex::new(None),
            bg_starts: tokio::sync::Mutex::new(()),
            bg_folders: bg_folder::BgFolders::default(),
            probe_only: StdMutex::new(None),
            idle_wake: Arc::new(Notify::new()),
            capacity_gate: auto_resume::CapacityGate::default(),
            idle_reaper: AtomicBool::new(false),
            resume_watch: resume::new_watch(),
            resumes: tokio::sync::watch::channel(0).0,
            person_prompts: tokio::sync::watch::channel(0).0,
            paused_fs,
            stopping: AtomicBool::new(false),
            idle_pass: Mutex::new(()),
            pool: Arc::new(pool::PoolState::new()),
            web_modes: StdMutex::new(Default::default()),
            trust_gate: StdMutex::new(None),
            remote_sandbox_exec: StdMutex::new(PathBuf::from(remote_sandbox::SANDBOX_EXEC)),
            #[cfg(target_os = "linux")]
            linux_bwrap_probe: StdMutex::new(None),
            vm_marker_root: StdMutex::new(PathBuf::from("/")),
            chats: std::sync::OnceLock::new(),
            chats_waiters: StdMutex::new(Vec::new()),
            session_recap: AtomicBool::new(away_recap::saved_setting()),
            terminal_chat_writable: AtomicBool::new(release_to_watch::saved_setting()),
            recap_due: StdMutex::new(HashMap::new()),
            host_moved: StdMutex::new(HashSet::new()),
            recap_wake: Arc::new(Notify::new()),
            coach_rewriter: StdMutex::new(None),
            surge_triage_due: StdMutex::new(HashMap::new()),
            surge_triager: StdMutex::new(None),
            surge_inbox: StdMutex::new(None),
            fleet_hold: StdMutex::new(session_hold::FleetHoldCache::default()),
            surge_triage_journals: StdMutex::new(HashMap::new()),
            surge_subscribers: StdMutex::new(None),
            surge_digest_pace: StdMutex::new(HashMap::new()),
            prompt_triager: StdMutex::new(None),
            start_mode_state,
            caller_registry,
            full_access_pushes: tokio::sync::Mutex::new(()),
            family_gate: Arc::new(tokio::sync::RwLock::new(())),
            family_cut: tokio::sync::watch::channel(0).0,
            answer_fences: StdMutex::new(HashMap::new()),
            withdraws: StdMutex::new(HashMap::new()),
            #[cfg(test)]
            family_write_seam: Default::default(),
            #[cfg(test)]
            copy_seam: Default::default(),
            #[cfg(test)]
            fork_seam: Default::default(),
            #[cfg(test)]
            cancel_write_seam: Arc::new(Default::default()),
            #[cfg(test)]
            queued_log_seam: Default::default(),
            #[cfg(test)]
            queue_approval_off: AtomicBool::new(false),
            #[cfg(test)]
            prompt_start_seam: Default::default(),
            #[cfg(test)]
            prompt_admission_seam: Default::default(),
            #[cfg(test)]
            turn_shown_seam: Default::default(),
            #[cfg(test)]
            first_work_seam: Default::default(),
            #[cfg(test)]
            finish_seam: Default::default(),
            #[cfg(test)]
            purge_seam: Default::default(),
            #[cfg(test)]
            old_rules: std::sync::atomic::AtomicU8::new(0),
            #[cfg(test)]
            retry_seam: Default::default(),
            #[cfg(test)]
            settle_seam: Default::default(),
            #[cfg(test)]
            refuse_seam: Default::default(),
            harness_watch: Default::default(),
            watch_ticker: Default::default(),
            settings_watch: Default::default(),
            settings_changes: tokio::sync::watch::channel(0).0,
            git_watch: Default::default(),
            cpu_pressure: Default::default(),
            catalog: Arc::new(crate::catalog::CatalogService::new()),
            chatgpt: Arc::new(crate::chatgpt::Service::default()),
            claude_token: Arc::new(crate::claude_token::Service::default()),
            health: Arc::new(crate::harness_health::HealthService::new()),
            web_token: WebToken::new(String::new()),
            person: Default::default(),
            presence: Default::default(),
            here: Default::default(),
            synced: std::sync::OnceLock::new(),
            workflow_index: Default::default(),
            suggestion_gate,
            page_replies: Default::default(),
            transfer_lease: StdMutex::new(transfer_watch::TRANSFER_LEASE),
            watched_moves: Default::default(),
            transfer_dial: StdMutex::new(None),
            parked_moves: Default::default(),
            background_timeout: StdMutex::new(processes::STOP_TIMEOUT),
            auto_background_after: StdMutex::new(auto_background::auto_background_from_env()),
            auto_background_armed: Default::default(),
            message_background_after: StdMutex::new(Some(
                auto_background::MESSAGE_BACKGROUND_AFTER,
            )),
            offers: Default::default(),
            lane_reports: Default::default(),
            lane_report_reads: Default::default(),
            subsessions: Default::default(),
            races_running: Default::default(),
            admitting: Default::default(),
            subsession_runs: Default::default(),
            open_waits: Default::default(),
            session_update_encodes: Default::default(),
            wait_evaluations: Default::default(),
            subagent_retries: Default::default(),
            subagent_resumes: Default::default(),
            transfer_lease_changed: Notify::new(),
            secrets: Default::default(),
            mcp_connects: Default::default(),
            trust_waits: Default::default(),
            outbox: Default::default(),
            ssh_carry_cooldown: Default::default(),
            mesh: Default::default(),
            mesh_relay: Default::default(),
            join_transition: Default::default(),
            join_start: Default::default(),
            watches: Default::default(),
            peer_accepts: Default::default(),
            held_peer_asks: Default::default(),
            agent_pairs: Default::default(),
            pairing: Default::default(),
            #[cfg(all(unix, feature = "tailnet"))]
            tailnet_controller: std::sync::OnceLock::new(),
            tailnet_placements: Default::default(),
            briefs,
        });
        if let Ok(c) = hub.config.try_read() {
            hub.refresh_web_modes(&c);
        }
        hub.recover_staged_replacements();
        hub.watch_rehydrates();
        if loading {
            hub.logs_ready.send_replace(false);
            hub.adoption_ready.send_replace(false);
        } else {
            hub.load_from_store(deferred);
        }
        if !deferred {
            hub.load_logs();
        }
        if tokio::runtime::Handle::try_current().is_ok() {
            // A self-weak keeps worker threads from owning the hub forever. Install it only for
            // runtime-backed hubs; tests that construct one outside Tokio retain a unique Arc so
            // they can configure fields before entering their runtime.
            let _ = hub.hub_ref.set(Arc::downgrade(&hub));
            // Chats read at start get the synced winners kept for them (`synced.rs`).
            if !loading {
                hub.synced_after_start();
            }
            // Chats made before it read their inboxes through it from now on (`Session::inbox`).
            for session in hub.sessions.lock().unwrap_or_else(|e| e.into_inner()).values() {
                let _ = session.hub_ref.set(Arc::downgrade(&hub));
            }
            // A copy's write tells the records of prompts it put on disk: their deliveries keep
            // them as proof (`open_delivery.rs`). Only a runtime-backed hub has peers to copy;
            // one built outside Tokio keeps a unique Arc, so a test can set fields first.
            let weak = Arc::downgrade(&hub);
            let written: peer_snapshot::Written =
                Arc::new(move |key, generation, link, records, since| {
                    weak.upgrade().is_none_or(|hub| {
                        hub.proof_written(&key.0, &key.1, (generation, link), &records, since)
                    })
                });
            *hub.peer_snapshots.written.lock().unwrap_or_else(|e| e.into_inner()) = Some(written);
            // It takes the notices' receiver: it cannot run twice.
            crate::supervise::once("peer notice", &hub.fatal, hub.clone().peer_notice_loop());
            hub.rehydrate_worker();
            if !loading {
                hub.watch_orphans();
                hub.bg_notify_resume_in_background();
            }
            hub.watch_titles();
            hub.watch_recaps();
            if start_peers {
                for (name, pc) in peers_cfg {
                    hub.start_peer(&name, &pc);
                }
            }
        }
        hub
    }
}
