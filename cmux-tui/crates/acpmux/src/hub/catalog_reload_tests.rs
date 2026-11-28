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

/// `acpmux config --set remote_pipe.ssh=true` on a running daemon lets the next circuit reach
/// loopback sshd beside the remote daemon, with no restart; clearing it stops it.
#[cfg(feature = "hub-carrier")]
#[tokio::test]
async fn config_set_remote_pipe_ssh_reaches_the_gate_without_a_restart() {
    use crate::hub_carrier::CmuxTuiGate;
    let root = tempfile::tempdir().unwrap();
    let (path, hub) = hub_on_disk(root.path());
    let gate = crate::cmux_tui_service::ConfiguredGate::new(&hub);
    assert_eq!(gate.admit(22).await.unwrap_err().reason, "service.off");

    let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    changed.set("remote_daemon", "127.0.0.1:7781").unwrap();
    changed.set("remote_pipe.ssh", "true").unwrap();
    changed.save().unwrap();
    hub.reload_catalog().await.unwrap();
    assert!(hub.config.read().await.remote_pipe.ssh);
    for (port, want) in [(22, "127.0.0.1:22"), (7781, "127.0.0.1:7781")] {
        match gate.admit(port).await {
            Ok(address) => assert_eq!(address, want.parse().unwrap()),
            Err(refused) => {
                assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED, "{refused:?}")
            }
        }
    }

    let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    changed.set("remote_pipe.ssh", "false").unwrap();
    changed.save().unwrap();
    hub.reload_catalog().await.unwrap();
    assert!(!hub.config.read().await.remote_pipe.ssh);
    let refused = gate.admit(22).await.unwrap_err();
    assert!(
        refused.reason == "service.port"
            || refused.reason == crate::cli::cloud_join::CONSENT_REQUIRED,
        "{refused:?}"
    );
}

#[tokio::test]
async fn reload_replaces_and_clears_page_rule_sessions() {
    let root = tempfile::tempdir().unwrap();
    let (path, hub) = hub_on_disk(root.path());
    for name in [Some("old"), Some("new"), None] {
        let mut config = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
        config.page_rule = name
            .map(|name| crate::config::PageRuleConfig { sessions: vec![format!("host/{name}")] });
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
    changed.coderouter_claude_route = Some("claude".into());
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
    assert_eq!(current.coderouter_claude_route, expected.coderouter_claude_route);
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
