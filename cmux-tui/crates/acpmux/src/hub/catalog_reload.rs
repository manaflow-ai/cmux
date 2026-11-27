//! Part of `Hub`; see `hub/mod.rs`. Catalog reload: config.json, the
//! harness profile files and PATH discovery read again, sessions kept.
//! Called by `_acpmux/reload_config`, `cmux harness reload` and the profile
//! watcher (`harness_watch.rs`).

use super::*;

impl Hub {
    /// Refresh the configured catalog while keeping all session processes alive.
    pub async fn reload_catalog(self: &Arc<Self>) -> Result<Value, RpcError> {
        // One reload at a time: each drops idle pooled sessions and probes the
        // model lists again, and several pages (or the profile watcher) may
        // ask at once after an install. The next waits for the one running.
        static RELOADING: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
        let _one = RELOADING.get_or_init(|| tokio::sync::Mutex::new(())).lock().await;
        let (path, sources) = self.config_sources().await?;
        let peers_read = self.peer_read_gen().await;
        // Disk reads and PATH discovery run outside the async executor. An
        // invalid/missing file never replaces the last accepted configuration.
        // Nor does one the daemon would refuse to start with (`config/start_check.rs`): the next
        // restart would leave the daemon down, so the refusal is said now, to whoever reloaded.
        let mut next = tokio::task::spawn_blocking(move || {
            std::fs::metadata(&path)?;
            let next = crate::config::Config::load_from_with(&path, &sources)?;
            next.start_refusal()
                .map_err(|e| e.context("the acpmux daemon would refuse to start with it"))?;
            anyhow::Ok(next)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        // With every cause (`{:#}`): the refusal's reason is the innermost one.
        .map_err(|e| RpcError::invalid_params(format!("reload config: {e:#}")))?;
        let (harnesses, default_harness, retained) = {
            let mut current = self.config.write().await;
            let mut retained = Vec::new();
            for session in self.sessions.lock().unwrap().values() {
                let name = session.meta().harness;
                if !next.harnesses.contains_key(&name)
                    && let Some(old) = current.harnesses.get(&name)
                {
                    next.harnesses.insert(name.clone(), old.clone());
                    // Do not resurrect a deleted profile in config.json on
                    // the next preset/default save.
                    next.discovered.insert(name.clone());
                    retained.push(name);
                }
            }
            // Only unchanged launchers inherit a startup validation failure.
            next.unavailable = current
                .unavailable
                .iter()
                .filter(|(n, _)| current.harnesses.get(*n) == next.harnesses.get(*n))
                .map(|(n, reason)| (n.clone(), reason.clone()))
                .collect();
            // Keep cached models until fresh probes finish, invalidating only
            // changed/removed profiles (`model_lists`): their ACP list, read under another
            // profile, is dropped, and their live list turns stale until its probe answers.
            // Listeners, peers, store and policy stay put.
            self.known_efforts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .retain(|name, _| current.harnesses.get(name) == next.harnesses.get(name));
            for name in current.harnesses.keys() {
                if current.harnesses.get(name) != next.harnesses.get(name) {
                    self.model_lists.profile_changed(name);
                }
            }
            // Every field of `Config` is named here, with no `..`: a field added to it does not
            // build until it is copied below or listed as kept until a restart, with why. A
            // field in neither is how `remoteDaemon` stayed at its start value, and
            // `acpmux config --set remote_daemon=...` did nothing until a restart (cmux#43305
            // review, P1-F1). A binding named here and not copied is an unused variable.
            let crate::config::Config {
                harnesses,
                default_harness,
                defaults,
                session,
                presets,
                discovered,
                auto_fallback,
                auto_default,
                auto_prefer,
                unavailable,
                profile_meta,
                profile_diagnostics,
                shadowed_config,
                pool,
                web_roots,
                vm_host,
                auto_cloud_enroll,
                peers,
                web_asking_modes,
                agent_start_timeout_ms,
                uploads_max_age_days,
                silent_turn_ms,
                queue_max_prompts,
                queue_max_bytes,
                stalled_turn_ms,
                stalled_turn_end_ms,
                usage_warnings,
                auto_evacuate,
                default_permission_mode,
                remote_daemon,
                lane_gh_broker,
                lane_gh_carrier,
                direct_port,
                notify_command,
                disk_low_bytes,
                agent_inbox,
                person_hold,
                page_rule,
                hold_agent_starts_to_starter,
                auto_resume_delays_ms,
                capacity_fallback_after,
                auto_resume_disk_free_bytes,
                login_env_allow,
                machine_wake,
                peer_wake,
                btw,
                titles,
                context_overrides,
                send_relay,
                send_hop,
                new_relay,
                artifacts,
                composer_max_rows,
                tui,
                // Kept until a restart: each is read once, when the daemon starts what it
                // configures (`daemon.rs`), or is this run's own state.
                acpmux_v2: _,      // the v2 surfaces are registered at start
                artifacts_sync: _, // its sync task starts with the daemon
                memory: _,         // its sync task starts with the daemon
                write_journal: _,  // the replica and journal open at start
                store: _,          // the open store
                // The bound listener, its port and token stay; the hosts and origins it admits
                // follow the file at once (`server::configured_policy`, `acpmux web --tailnet`).
                websocket,
                transport: _,  // WireGuard and the hub carrier start with the daemon
                mesh_relay: _, // started at start, then owned by join and leave
                // The daemon's default policy is its own setter's (`_acpmux/start_mode`), not
                // the file's: an agent can write the file.
                permission_policy: _,
                path: _,               // where this daemon reads, the same file
                profile_sources: _,    // the profile sources it reads, the same ones
                folder_gate: _,        // the folder profile records it reads
                file_missing: _,       // whether the start found a file (`policy_source.rs`)
                cloud_host: _,         // a fact of the machine
                web_unbound: _,        // this run's listener
                dev_origins: _,        // this run's flags
                web_token_override: _, // this run's flags
                saved: _,              // what this process last wrote (`save_merge.rs`)
                mcp_store,
            } = next;
            if let (Some(now), Some(next)) = (current.websocket.as_mut(), websocket) {
                now.allowed_origins = next.allowed_origins;
                now.allowed_hosts = next.allowed_hosts;
            }
            current.harnesses = harnesses;
            // A profile that is new or changed back is served its disk list, if any.
            self.serve_acp_cache(&current.harnesses);
            current.default_harness = default_harness;
            // A harness's own start mode (`permissionMode`) changing is a start-mode change too.
            let modes_of =
                |d: &std::collections::BTreeMap<String, crate::config::SessionDefaults>| {
                    d.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v.permission_mode.clone()?)))
                        .collect::<Vec<_>>()
                };
            let harness_modes_changed = modes_of(&current.defaults) != modes_of(&defaults);
            current.defaults = defaults;
            current.session = session;
            current.presets = presets;
            current.discovered = discovered;
            current.auto_fallback = auto_fallback;
            current.auto_default = auto_default;
            current.auto_prefer = auto_prefer;
            current.unavailable = unavailable;
            current.profile_meta = profile_meta;
            current.profile_diagnostics = profile_diagnostics;
            current.shadowed_config = shadowed_config;
            current.pool = pool;
            current.web_roots = web_roots;
            current.vm_host = vm_host;
            current.auto_cloud_enroll = auto_cloud_enroll;
            // The peers stay put, but a saved peer's VM boundary follows the file at once: a
            // `false` there is the caller taking it back (`vm_boundary.rs`).
            // So does whether this Mac lends it GitHub (`github_broker.rs`).
            self.reload_saved_peers(&mut current, &peers, peers_read);
            current.web_asking_modes = web_asking_modes;
            // The start budget applies from the next start, like a restart would.
            current.agent_start_timeout_ms = agent_start_timeout_ms;
            current.uploads_max_age_days = uploads_max_age_days;
            current.silent_turn_ms = silent_turn_ms;
            // The next prompt that would wait is held to the new queue limits.
            current.queue_max_prompts = queue_max_prompts;
            current.queue_max_bytes = queue_max_bytes;
            current.stalled_turn_ms = stalled_turn_ms;
            current.stalled_turn_end_ms = stalled_turn_end_ms;
            // The next circuit asking for the cmux-tui remote daemon reads it
            // (`cmux_tui_service.rs`): `acpmux config --set remote_daemon=...` serves it at once.
            current.remote_daemon = remote_daemon;
            // The next broker stream reads it (`hub_carrier_broker.rs`).
            current.lane_gh_broker = lane_gh_broker;
            // The daemon starts the carrier forward once, at its start (`server/machine_enroll.rs`);
            // a restart applies a change.
            current.lane_gh_carrier = lane_gh_carrier;
            // The carrier binds its direct port at its start (`hub_carrier_direct.rs`); a
            // restart applies a change.
            current.direct_port = direct_port;
            // Each of these is read where it is used, so the next use follows the file.
            current.notify_command = notify_command;
            current.disk_low_bytes = disk_low_bytes;
            current.agent_inbox = agent_inbox;
            // The next person's prompt to an idle chat reads it (`person_hold.rs`).
            current.person_hold = person_hold;
            // The next message to a coordinator's inbox reads it (`inbox_page_rule.rs`).
            let names = super::inbox::page_rule::session_names(page_rule.as_ref());
            *self.page_rule_sessions.lock().unwrap_or_else(|e| e.into_inner()) = names;
            current.page_rule = page_rule;
            current.mcp_store = mcp_store;
            current.hold_agent_starts_to_starter = hold_agent_starts_to_starter;
            current.auto_resume_delays_ms = auto_resume_delays_ms;
            current.capacity_fallback_after = capacity_fallback_after;
            // The disk waiter reads it at each re-check (`auto_resume/disk_wait.rs`).
            current.auto_resume_disk_free_bytes = auto_resume_disk_free_bytes;
            current.machine_wake = machine_wake;
            // The next wake of any peer runs the new command (`Peer::wake`).
            *self.peer_wake.lock().unwrap_or_else(|e| e.into_inner()) =
                peer_wake.as_ref().map(|w| w.argv.clone());
            current.peer_wake = peer_wake;
            current.btw = btw;
            current.titles = titles;
            current.context_overrides = context_overrides;
            current.send_relay = send_relay;
            current.send_hop = send_hop;
            current.new_relay = new_relay;
            current.artifacts = artifacts;
            current.composer_max_rows = composer_max_rows;
            current.tui = tui;
            // The next agent started gets the new login variables (`login_env.rs`).
            crate::login_env::set_extra_allow(login_env_allow.clone());
            current.login_env_allow = login_env_allow;
            // The next summary read warns by the new thresholds (`usage_warnings.rs`).
            *self.usage_limits.lock().unwrap_or_else(|e| e.into_inner()) = usage_warnings.limits();
            current.usage_warnings = usage_warnings;
            // On starts its timer below (`start_auto_evacuate`); its next tick reads the new
            // setting, and off ends it there (`auto_evacuate.rs`).
            current.auto_evacuate = auto_evacuate;
            let start_changed = current.default_permission_mode != default_permission_mode;
            current.default_permission_mode = default_permission_mode;
            if start_changed || harness_modes_changed {
                self.start_mode_changed();
            }
            self.refresh_web_modes(&current);
            (
                current.harnesses.keys().cloned().collect::<Vec<_>>(),
                current.default_harness.clone(),
                retained,
            )
        };
        self.start_auto_evacuate().await;
        // Enrollment turned on since: its timer starts (`owner_return.rs`).
        self.start_owner_return().await;
        // Every row, closed ones too, reads the new usage warning thresholds.
        self.events.changed(None);
        // A new `stalledTurnEndMs` moves the stalled turns' deadlines (`stalled_turn.rs`).
        self.idle_wake.notify_one();
        // Pooled sessions started under the old catalog are never served.
        self.drain_pool();
        // Nor do live agents keep running a profile's old launch: each restarts on the new
        // one between turns (`profile_respawn.rs`).
        self.spawn_profile_respawns();
        self.probe_models_with(true, false, None).await;
        Ok(json!({"reloaded": true, "harnesses": harnesses, "defaultHarness": default_harness,
            "retainedProfiles": retained, "modelProbePending": true}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, ProfileSources, SessionResourceConfig, StoreMode};

    #[tokio::test]
    async fn reloaded_session_limits_survive_a_later_daemon_config_save() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let config = Config {
            path: Some(path.clone()),
            profile_sources: ProfileSources::none(),
            ..Config::default()
        };
        config.save().unwrap();
        let mut config = config;
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, root.path()).unwrap();
        let hub = Hub::new(config, store);
        // Reload may discover installed profiles, but this test starts none.
        *hub.probe_only.lock().unwrap() = Some(Default::default());

        for expected in [
            SessionResourceConfig {
                memory_mb: Some(6144),
                swap_mb: Some(2048),
                tasks_max: Some(8192),
                sessions_tasks_max: Some(131_072),
                lanes: Some(6),
                disk_mb: Some(8192),
                cpu_class: Some(crate::cpu_class::CpuClass::Normal),
            },
            SessionResourceConfig::default(),
        ] {
            let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
            changed.session = expected.clone();
            changed.save().unwrap();

            hub.reload_catalog().await.unwrap();
            let current = hub.config.read().await;
            assert_eq!(current.session, expected);
            current.save().unwrap();
            drop(current);

            let saved: Config = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(saved.session, expected, "daemon save must retain the reloaded limits");
        }
    }

    /// Edited `usageWarnings` thresholds apply at the next reload: summaries warn by them, and a
    /// later daemon save keeps them in the file.
    #[tokio::test]
    async fn reloaded_usage_warnings_apply_and_survive_a_later_daemon_config_save() {
        use crate::config::{UsageLimits, UsageWarningsConfig};
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let config = Config {
            path: Some(path.clone()),
            profile_sources: ProfileSources::none(),
            ..Config::default()
        };
        config.save().unwrap();
        let mut config = config;
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, root.path()).unwrap();
        let hub = Hub::new(config, store);
        *hub.probe_only.lock().unwrap() = Some(Default::default());
        assert_eq!(*hub.usage_limits.lock().unwrap(), UsageLimits::default());

        for expected in [
            UsageWarningsConfig {
                context_tokens: Some(1_000_000),
                subagents_per_hour: Some(0),
                autocompact_cap: Some(false),
            },
            UsageWarningsConfig::default(),
        ] {
            let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
            changed.usage_warnings = expected.clone();
            changed.save().unwrap();

            hub.reload_catalog().await.unwrap();
            assert_eq!(*hub.usage_limits.lock().unwrap(), expected.limits());
            let current = hub.config.read().await;
            assert_eq!(current.usage_warnings, expected);
            current.save().unwrap();
            drop(current);

            let saved: Config = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(
                saved.usage_warnings, expected,
                "daemon save must retain the reloaded thresholds"
            );
        }
    }

    /// A hub whose config is `root/config.json` (memory store, no profiles), as the daemon runs.
    fn hub_on_disk(root: &std::path::Path) -> (std::path::PathBuf, Arc<Hub>) {
        let path = root.join("config.json");
        let config = Config {
            path: Some(path.clone()),
            profile_sources: ProfileSources::none(),
            ..Config::default()
        };
        config.save().unwrap();
        let mut config = config;
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, root).unwrap();
        let hub = Hub::new(config, store);
        *hub.probe_only.lock().unwrap() = Some(Default::default());
        (path, hub)
    }

    /// `acpmux config --set remote_daemon=127.0.0.1:PORT` on a running daemon (step 4 of the
    /// fleet Mac bootstrap) serves the cmux-tui remote daemon at once, and clearing it stops it,
    /// with no restart (cmux#43305 review, P1-F1).
    #[cfg(feature = "hub-carrier")]
    #[tokio::test]
    async fn config_set_remote_daemon_reaches_the_cmux_tui_service_without_a_restart() {
        use crate::hub_carrier::CmuxTuiGate;
        let root = tempfile::tempdir().unwrap();
        let (path, hub) = hub_on_disk(root.path());
        let gate = crate::cmux_tui_service::ConfiguredGate::new(&hub);
        assert_eq!(gate.admit(7781).await.unwrap_err().reason, "service.off");

        // What `acpmux config --set` does: load, set, save, then `_acpmux/reload_config`.
        let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
        changed.set("remote_daemon", "127.0.0.1:7781").unwrap();
        changed.save().unwrap();
        hub.reload_catalog().await.unwrap();
        assert_eq!(hub.config.read().await.remote_daemon.as_deref(), Some("127.0.0.1:7781"));
        // Served now: admitted, or held only by this machine's own consent.
        match gate.admit(7781).await {
            Ok(address) => assert_eq!(address, "127.0.0.1:7781".parse().unwrap()),
            Err(refused) => {
                assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED, "{refused:?}")
            }
        }

        let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
        changed.set("remote_daemon", "none").unwrap();
        changed.save().unwrap();
        hub.reload_catalog().await.unwrap();
        assert_eq!(gate.admit(7781).await.unwrap_err().reason, "service.off");
    }

    #[tokio::test]
    async fn reload_replaces_and_clears_page_rule_sessions() {
        let root = tempfile::tempdir().unwrap();
        let (path, hub) = hub_on_disk(root.path());
        for name in [Some("old"), Some("new"), None] {
            let mut config = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
            config.page_rule = name.map(|name| crate::config::PageRuleConfig {
                sessions: vec![format!("host/{name}")],
            });
            config.save().unwrap();
            hub.reload_catalog().await.unwrap();
            let _config_writer = hub.config.write().await;
            assert_eq!(hub.page_rule_lists(" old "), name == Some("old"));
            assert_eq!(hub.page_rule_lists("host/new"), name == Some("new"));
        }
    }

    /// The other settings a reload used to leave behind until a restart follow the file too.
    #[tokio::test]
    async fn reload_applies_every_setting_read_where_it_is_used() {
        let root = tempfile::tempdir().unwrap();
        let (path, hub) = hub_on_disk(root.path());
        let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
        changed.notify_command = Some("true".into());
        changed.disk_low_bytes = Some(4096);
        changed.agent_inbox = Some(false);
        changed.hold_agent_starts_to_starter = true;
        changed.auto_resume_delays_ms = Some(vec![]);
        changed.capacity_fallback_after = Some(0);
        changed.login_env_allow = vec!["RELOAD_TEST_*".into()];
        changed.btw.model.insert("claude".into(), "claude-haiku".into());
        changed.titles.generate = Some(false);
        changed.context_overrides.user = Some("from the file".into());
        changed.save().unwrap();
        let expected = Config::load_from_with(&path, &ProfileSources::none()).unwrap();

        hub.reload_catalog().await.unwrap();
        let current = hub.config.read().await;
        assert_eq!(current.notify_command, expected.notify_command);
        assert_eq!(current.disk_low_bytes, Some(4096));
        assert_eq!(current.agent_inbox, Some(false));
        assert!(current.hold_agent_starts_to_starter);
        assert_eq!(current.auto_resume_delays_ms, Some(vec![]));
        assert_eq!(current.capacity_fallback_after, Some(0));
        assert_eq!(current.login_env_allow, expected.login_env_allow);
        assert_eq!(current.btw, expected.btw);
        assert_eq!(current.titles, expected.titles);
        assert_eq!(current.context_overrides, expected.context_overrides);
    }

    /// A config.json the daemon would refuse to start with (WireGuard on, no `wireguardStatic`)
    /// is refused by `_acpmux/reload_config`, which says why and keeps the running config.
    #[tokio::test]
    async fn reload_refuses_a_config_the_daemon_would_not_start_with() {
        let root = tempfile::tempdir().unwrap();
        let (path, hub) = hub_on_disk(root.path());
        let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
        changed.transport.wireguard = true;
        changed.session.memory_mb = Some(6144);
        changed.save().unwrap();
        let refused = format!("{:?}", hub.reload_catalog().await.unwrap_err());
        assert!(refused.contains("wireguardStatic.listen"), "{refused}");
        assert_eq!(hub.config.read().await.session.memory_mb, None, "the refused file applied");
    }
}
