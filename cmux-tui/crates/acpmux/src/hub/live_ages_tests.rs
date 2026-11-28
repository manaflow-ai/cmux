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
