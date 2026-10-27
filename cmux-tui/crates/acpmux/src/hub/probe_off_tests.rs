//! Model probes against MDM's off that comes and goes as they begin (review 77 of #23322).

use super::*;

/// Review 77 of #23322: an MDM off that comes and goes while a model probe reads it is the
/// probe's, so a profile pinning full access is never started.
#[tokio::test]
async fn a_pinned_probe_never_starts_after_an_off_that_came_and_went_as_it_began() {
    let dir = std::env::temp_dir().join(format!("acpmux-probe-off-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let marker = dir.join("started");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = ["sh", "-c", "echo $$ > \"$0\"; exec python3 \"$1\"", "", fake, "--yolo"];
    let mut argv: Vec<String> = argv.iter().map(|a| (*a).to_owned()).collect();
    argv[3] = marker.to_string_lossy().into_owned();
    let profile: HarnessProfile = serde_json::from_value(json!({"argv": argv})).unwrap();
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let came_and_went: fn(&Hub) = |hub| {
        hub.update_start_mode_state(None, |s| s.full_access_managed = Some(false));
        hub.update_start_mode_state(None, |s| s.full_access_managed = None);
    };
    super::super::full_access_bound::AFTER_OFF_COUNT.set(Some(came_and_went));
    let probed = hub.probe_one("pinned", &profile).await;
    let started = marker.exists();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(probed.is_err(), "the pinned probe kept its models");
    assert!(!started, "a profile pinning full access started after the off came and went");
}
