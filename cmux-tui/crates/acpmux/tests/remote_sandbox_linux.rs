#![cfg(target_os = "linux")]

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
    hub.set_linux_remote_sandbox_for_tests(true);
    let result = hub
        .linux_sandbox_canary_for_tests(
            root.join("project"),
            PathBuf::from(env!("CARGO_BIN_EXE_acpmux")),
        )
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
