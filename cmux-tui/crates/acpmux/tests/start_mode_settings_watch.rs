//! A change to the cmux setting `agents.defaultPermissionMode` in the app's
//! settings file reaches local `_acpmux/watch` connections as
//! `_acpmux/start_mode_changed`, without a request and without polling, so
//! the composer's start-mode chip asks acpmux only when the answer may have
//! changed, never each time the pane is shown again. A write that leaves the
//! setting as it was tells nobody. Its own test binary: it sets
//! CMUX_NEXT_CONFIG_FILE, which the watcher reads.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn scratch() -> PathBuf {
    let root = std::env::temp_dir()
        .join(format!("acpmux-start-mode-settings-watch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("settings")).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// Whether a `method` notification came within `wait`.
async fn told(rx: &mut mpsc::Receiver<String>, m: &str, wait: Duration) -> bool {
    let end = Instant::now() + wait;
    loop {
        let Some(left) = end.checked_duration_since(Instant::now()) else { return false };
        let Ok(Some(line)) = tokio::time::timeout(left, rx.recv()).await else { return false };
        if let Ok(Message::Notification { method: got, .. }) = Message::parse(&line)
            && got == m
        {
            return true;
        }
    }
}

/// Drains notices until `m` stays quiet for a second (one write can end two
/// bursts); false when it never does.
async fn settle(rx: &mut mpsc::Receiver<String>, m: &str) -> bool {
    for _ in 0..10 {
        if !told(rx, m, Duration::from_millis(1000)).await {
            return true;
        }
    }
    false
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_settings_file_change_to_the_default_permission_mode_reaches_watchers() {
    let root = scratch();
    let settings = root.join("settings").join("cmux-next.json");
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}}"#).unwrap();
    // SAFETY: the only test in this binary, set before the hub starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    std::fs::write(root.join("home").join("config.json"), "{}").unwrap();
    // No harness profile sources: only the settings file is watched.
    let mut cfg =
        Config::load_from_with(&root.join("home").join("config.json"), &ProfileSources::none())
            .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.start_harness_watch();

    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    tx.send(Message::request(1, method::MUX_WATCH, json!({"enabled": true})).to_line())
        .await
        .unwrap();
    let changed = method::MUX_START_MODE_CHANGED;
    assert!(settle(&mut rx, changed).await, "start_mode_changed never stopped before any write");

    // Settings writes the new value (atomically, as the app's settings owner does).
    let next = root.join("settings").join(".cmux-next.json.tmp");
    std::fs::write(&next, r#"{"agents": {"defaultPermissionMode": "ask"}}"#).unwrap();
    std::fs::rename(&next, &settings).unwrap();
    assert!(
        told(&mut rx, changed, Duration::from_secs(10)).await,
        "no start_mode_changed after agents.defaultPermissionMode changed in the settings file"
    );
    assert!(settle(&mut rx, changed).await, "start_mode_changed never stopped after one change");

    // An edit in place is seen too.
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "standard"}}"#).unwrap();
    assert!(
        told(&mut rx, changed, Duration::from_secs(10)).await,
        "no start_mode_changed after an edit in place"
    );
    assert!(settle(&mut rx, changed).await);

    // Another setting changes, the start mode does not: nobody is told.
    let other = r#"{"agents": {"defaultPermissionMode": "standard"}, "app": {"x": 1}}"#;
    std::fs::write(&settings, other).unwrap();
    assert!(
        !told(&mut rx, changed, Duration::from_millis(1500)).await,
        "a write that kept the setting told watchers the start mode changed"
    );
    let _ = std::fs::remove_dir_all(&root);
}
