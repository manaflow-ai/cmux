use super::*;
use std::time::{Duration, Instant};

fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {
            "claude": {"kind": "claude-stdio", "argv": ["claude"]},
            "fake": {"argv": ["python3", fake]},
        },
        "defaultHarness": "claude",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

// Nov 9: the picker lacked Fable 5.2 though Claude Code listed it; the daemon
// had probed Claude Code's list once, at its start, and never again.
#[tokio::test]
async fn a_read_after_the_max_age_probes_the_live_list_again() {
    let hub = hub();
    let t0 = Instant::now();
    assert!(hub.stale_live_probes(t0).await.is_empty(), "the start-up probe owns the first list");
    hub.live_ages.lock().unwrap().started("claude", t0);
    hub.live_ages.lock().unwrap().started("fake", t0);
    assert!(hub.stale_live_probes(t0 + Duration::from_secs(60)).await.is_empty());
    let later = t0 + live_ages::LIVE_MAX_AGE;
    let due = hub.stale_live_probes(later).await;
    // Only a CLI with a live list (Claude Code here) is probed this way.
    assert_eq!(due, std::collections::BTreeSet::from(["claude".to_owned()]));
    assert!(hub.stale_live_probes(later).await.is_empty(), "one probe per old list");
}

fn live(id: &str) -> crate::live_models::LiveModel {
    crate::live_models::LiveModel {
        id: id.into(),
        name: id.to_uppercase(),
        efforts: vec![],
        default_effort: None,
        fast: None,
        service_tiers: vec![],
        is_default: false,
        upgrade: None,
    }
}

// A CLI updated under the running daemon kept its old live list for up to LIVE_MAX_AGE (or, at
// start, until the disk copy's key no longer matched). Its list is now tagged by the program it
// was read from: the next read turns it stale, still served, and names it for one probe.
#[tokio::test]
async fn a_cli_updated_under_the_daemon_turns_its_live_list_stale_once() {
    let dir = tempfile::tempdir().unwrap();
    let program = dir.path().join("codex");
    std::fs::write(&program, b"v1").unwrap();
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"codex": {"argv": ["codex-acp"], "env": {"CODEX_PATH": program}}},
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let read_from = crate::live_models::CacheKey::of(&program).unwrap();
    let stamp = hub.model_lists.stamp();
    hub.model_lists.put_live("codex", vec![live("gpt-a")], Some(read_from), stamp);
    assert!(hub.changed_live_binaries().await.is_empty(), "the same program");

    std::fs::write(&program, b"v2, a longer binary").unwrap();
    let changed = hub.changed_live_binaries().await;
    assert_eq!(changed, std::collections::BTreeSet::from(["codex".to_owned()]));
    assert_eq!(hub.model_lists.live_freshness("codex"), model_lists::Freshness::Stale);
    assert_eq!(hub.live_models_for("codex"), Some(vec![live("gpt-a")]), "served while stale");
    assert!(hub.changed_live_binaries().await.is_empty(), "one probe per update");
}
