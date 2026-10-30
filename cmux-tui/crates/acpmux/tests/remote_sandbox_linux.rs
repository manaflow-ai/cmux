#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The canary starts the keeper with a stand-in harness (`/bin/true`). CI sets
// `ACPMUX_REQUIRE_BWRAP` so a missing bwrap fails instead of skipping.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().keep(&["ACPMUX_REQUIRE_BWRAP"]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use serde_json::json;
use std::path::{Path, PathBuf};

fn fixture() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-linux-wire-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("project")).unwrap();
    std::fs::canonicalize(root).unwrap()
}

fn hub(root: &Path) -> std::sync::Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["/bin/true"], "kind": "claude-stdio"}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webRoots": [root.join("project")],
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

#[tokio::test]
async fn linux_remote_sandbox_canary_passes_with_real_bwrap() {
    let root = fixture();
    let hub = hub(&root);
    let result = hub
        .linux_sandbox_canary_for_tests(root.join("project"), PathBuf::from(daemon_env::bin()))
        .await;
    if std::env::var_os("ACPMUX_REQUIRE_BWRAP").is_none()
        && result.as_ref().is_err_and(|e| e.contains("bwrap unavailable"))
    {
        eprintln!("remote_sandbox_linux: skipped ({})", result.unwrap_err());
    } else {
        result.unwrap();
    }
    let _ = std::fs::remove_dir_all(root);
}
