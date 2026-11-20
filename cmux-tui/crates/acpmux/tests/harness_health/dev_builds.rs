//! A dev or nightly build (`opencode2 v0.0.0-next-17403`) is not an older
//! release (Lawrence 2026-11-19, "there are duplicates sometimes"): its
//! placeholder `0.0.0` says nothing about how it orders against the newest
//! release its package publishes, so no check calls it outdated, and neither
//! does a copy saved before this rule.

use acpmux::harness_health::{HealthService, Settings, probe};
use serde_json::json;

#[test]
fn a_placeholder_version_never_orders_against_a_release() {
    for dev in ["0.0.0-next", "0.0.0", "v0.0.0-nightly.3", "0.0-dev"] {
        assert_eq!(probe::compare_versions("1.19.6", dev), None, "{dev}");
        assert!(!probe::is_newer("1.19.6", dev), "{dev}");
    }
    assert!(probe::is_newer("1.19.6", "1.19.5"));
    assert!(probe::is_newer("0.0.2", "0.0.1"));
}

#[test]
fn a_saved_copy_that_called_a_dev_build_outdated_is_read_as_current() {
    let root =
        std::env::temp_dir().join(format!("acpmux-health-dev-builds-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let cache = root.join("health.json");
    let row = |id: &str, path: &str, version: &str| {
        json!({"id": id, "program": path, "path": path, "channel": "native", "package": "opencode-ai",
            "version": version, "latest": "1.19.6", "outdated": true, "auth": "unknown", "checkedAt": 1})
    };
    std::fs::write(
        &cache,
        json!([
            row("opencode-v2", "/x/opencode2", "0.0.0-next"),
            row("opencode", "/x/opencode", "1.19.5")
        ])
        .to_string(),
    )
    .unwrap();
    let health = HealthService::new();
    health.attach(Settings { cache: Some(cache), home: root.clone(), ..Settings::default() });
    let outdated: Vec<(String, bool)> =
        health.rows().into_iter().map(|r| (r.id, r.outdated)).collect();
    assert_eq!(outdated, vec![("opencode-v2".into(), false), ("opencode".into(), true)]);
    let _ = std::fs::remove_dir_all(&root);
}
