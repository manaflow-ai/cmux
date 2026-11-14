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
