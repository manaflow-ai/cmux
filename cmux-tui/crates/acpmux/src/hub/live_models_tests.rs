use super::*;
use crate::config::{Config, StoreMode};

fn hub(harnesses: serde_json::Value) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({ "harnesses": harnesses })).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn target(harness: &str, argv: &[&str], env: &[(&str, &str)]) -> Target {
    Target {
        harness: harness.to_owned(),
        cli: Cli::Codex,
        argv: argv.iter().map(|a| (*a).to_owned()).collect(),
        env: env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
    }
}

/// Bench gap 7 (cmuxterm-hq#25113): `codex`, `codex-acp` and `codex-app-server` each started
/// their own `codex app-server` to list the same models. Profiles running the same CLI the same
/// way share one probe; another env or program still gets its own.
#[test]
fn profiles_running_the_same_cli_share_one_probe() {
    let groups = [
        target("codex", &["/bin/codex"], &[]),
        target("codex-acp", &["/bin/codex"], &[]),
        target("codex-app-server", &["/bin/codex"], &[]),
        target("codex-work", &["/bin/codex"], &[("CODEX_HOME", "/w")]),
        target("other", &["/opt/codex"], &[]),
    ]
    .into_iter()
    .fold(Vec::new(), same_cli_once);
    let shape: Vec<(String, Vec<String>)> =
        groups.into_iter().map(|(t, also)| (t.harness, also)).collect();
    assert_eq!(
        shape,
        vec![
            ("codex".to_owned(), vec!["codex-acp".to_owned(), "codex-app-server".to_owned()]),
            ("codex-work".to_owned(), vec![]),
            ("other".to_owned(), vec![]),
        ]
    );
}

/// Every daemon start probed every live list again, though the kept one's program had not
/// changed. A kept list of the same program is now served and left to the age revalidation
/// (`LIVE_MAX_AGE`, on a models read); a changed program or no kept list is probed at start.
#[tokio::test]
async fn the_start_probes_only_live_lists_with_no_kept_copy_of_their_program() {
    let dir = tempfile::tempdir().unwrap();
    let program = dir.path().join("claude");
    std::fs::write(&program, b"v1").unwrap();
    let argv = program.to_string_lossy().into_owned();
    let hub = hub(json!({
        "claude": {"kind": "claude-stdio", "argv": [argv]},
        "fresh": {"kind": "claude-stdio", "argv": [argv]},
    }));
    let cache_dir = dir.path().join("live-models");
    let models = vec![LiveModel {
        id: "opus".into(),
        name: "Opus".into(),
        efforts: vec![],
        default_effort: None,
        fast: None,
        service_tiers: vec![],
        is_default: true,
        upgrade: None,
    }];
    Cache::new(cache_dir.clone())
        .store("claude", &CacheKey::of(&program).unwrap(), &models)
        .unwrap();
    hub.load_live_cache_from(cache_dir).await;

    assert_eq!(hub.live_models_for("claude"), Some(models));
    let due = hub.live_probes_at_start(None).await;
    assert_eq!(due, std::collections::BTreeSet::from(["fresh".to_owned()]));
    // Its kept time stands for its last probe: young, so a read starts none either.
    assert!(hub.stale_live_probes(std::time::Instant::now()).await.is_empty());

    // The CLI updated: its kept list is probed at start again.
    std::fs::write(&program, b"v2, longer").unwrap();
    let due = hub.live_probes_at_start(None).await;
    assert!(due.contains("claude"));
}
