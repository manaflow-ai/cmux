//! The harness profile watch follows its source folders by path, not by the folder it found at
//! start (Codex review of #42548, F1 and F2):
//!
//! - a user folder replaced by another one (`mv`) is watched again, so a profile written into the
//!   new folder reloads the catalog;
//! - a user folder that is a symbolic link to a folder not made yet is picked up when that folder
//!   is made, so a profile written into it reloads the catalog.
//!
//! Only folders under a temp dir: never the real config.

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
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn write(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn profile(id: &str) -> String {
    format!("schema = 1\nid = \"{id}\"\nname = \"{id}\"\ncommand = \"/bin/echo\"\n")
}

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-follow-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config")).unwrap();
    // The settings watch starts with the harness watch: keep it off the real config too, with
    // one settings path for the whole process, set once before the first hub starts.
    static SETTINGS: std::sync::Once = std::sync::Once::new();
    SETTINGS.call_once(|| {
        let settings = std::env::temp_dir()
            .join(format!("acpmux-follow-settings-{}", std::process::id()))
            .join("cmux-next.json");
        // SAFETY: once, before any hub (and its threads) starts in this process.
        unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", settings) };
    });
    std::fs::canonicalize(&root).unwrap()
}

/// The first `method` notification that `wanted` accepts, or None after `wait`.
async fn note_where(
    rx: &mut mpsc::Receiver<String>,
    m: &str,
    wait: Duration,
    wanted: impl Fn(&Value) -> bool,
) -> Option<Value> {
    let end = Instant::now() + wait;
    loop {
        let left = end.checked_duration_since(Instant::now())?;
        let line = tokio::time::timeout(left, rx.recv()).await.ok()??;
        if let Ok(Message::Notification { method: got, params }) = Message::parse(&line)
            && got == m
        {
            let params = params.unwrap_or(Value::Null);
            if wanted(&params) {
                return Some(params);
            }
        }
    }
}

fn names(note: &Value) -> Vec<String> {
    note["harnesses"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

/// A hub watching `sources`, and a connection that has answered its watch request.
async fn watching(
    root: &Path,
    sources: &ProfileSources,
) -> (Arc<Hub>, mpsc::Sender<String>, mpsc::Receiver<String>) {
    write(&root.join("config").join("config.json"), "{}");
    let mut cfg =
        Config::load_from_with(&root.join("config").join("config.json"), sources).unwrap();
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
    let answered = async {
        while let Some(line) = rx.recv().await {
            if let Ok(Message::Response { id, error, .. }) = Message::parse(&line)
                && serde_json::to_value(&id).ok() == Some(json!(1))
            {
                assert!(error.is_none(), "{line}");
                return;
            }
        }
        panic!("the connection ended before it answered the watch request");
    };
    tokio::time::timeout(Duration::from_secs(10), answered).await.expect("no watch answer");
    (hub, tx, rx)
}

/// Drains harnesses_changed until it stays quiet for a second (one change can end two bursts).
async fn settle(rx: &mut mpsc::Receiver<String>) {
    for _ in 0..10 {
        let quiet = Duration::from_millis(1000);
        if note_where(rx, method::MUX_HARNESSES_CHANGED, quiet, |_| true).await.is_none() {
            return;
        }
    }
    panic!("harnesses_changed never stopped");
}

/// F1: the user folder is replaced by another folder under the same name (`mv` away, `mv` the
/// new one in). An inotify watch is on a folder, not a name: the old watch follows the folder
/// that moved away, so the new folder must be watched again, or a profile written into it is
/// never seen until the daemon restarts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_profile_in_a_user_folder_replaced_by_mv_reaches_watchers() {
    let root = scratch("replaced");
    let user = root.join("config").join("harnesses");
    std::fs::create_dir_all(&user).unwrap();
    write(&user.join("first.toml"), &profile("first"));
    let sources = ProfileSources {
        managed: vec![root.join("managed-missing")],
        user_dir: Some(user.clone()),
        cmux_json: Some(root.join("config").join("cmux.json")),
    };
    let (hub, _tx, mut rx) = watching(&root, &sources).await;
    settle(&mut rx).await;

    // Replace the folder: the new one is made beside it, then moved over the name.
    let new = root.join("config").join("harnesses.new");
    std::fs::create_dir_all(&new).unwrap();
    std::fs::rename(&user, root.join("config").join("harnesses.old")).unwrap();
    std::fs::rename(&new, &user).unwrap();
    settle(&mut rx).await;

    write(&user.join("replaced.toml"), &profile("replaced"));
    let changed = method::MUX_HARNESSES_CHANGED;
    note_where(&mut rx, changed, Duration::from_secs(10), |n| {
        names(n).iter().any(|h| h == "replaced")
    })
    .await
    .expect("no harnesses_changed with the profile written into the replacement user folder");
    assert!(hub.config.read().await.harnesses.contains_key("replaced"));
    let _ = std::fs::remove_dir_all(&root);
}

/// F2: the user folder is a symbolic link (a dotfiles checkout) to a folder that does not exist
/// when the daemon starts. Making that folder and a profile in it reloads the catalog: the
/// watch follows the link's target, through its nearest existing folder, not only the folders
/// on the link's own path.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_profile_behind_a_link_to_a_folder_made_later_reaches_watchers() {
    let root = scratch("link");
    let user = root.join("config").join("harnesses");
    let target = root.join("dots").join("cmux").join("harnesses");
    std::os::unix::fs::symlink(&target, &user).unwrap();
    let sources = ProfileSources {
        managed: vec![root.join("managed-missing")],
        user_dir: Some(user.clone()),
        cmux_json: Some(root.join("config").join("cmux.json")),
    };
    let (hub, _tx, mut rx) = watching(&root, &sources).await;
    settle(&mut rx).await;

    std::fs::create_dir_all(&target).unwrap();
    write(&target.join("linked.toml"), &profile("linked"));
    let changed = method::MUX_HARNESSES_CHANGED;
    note_where(&mut rx, changed, Duration::from_secs(10), |n| {
        names(n).iter().any(|h| h == "linked")
    })
    .await
    .expect("no harnesses_changed after the link's target folder and a profile in it were made");
    assert!(hub.config.read().await.harnesses.contains_key("linked"));
    let _ = std::fs::remove_dir_all(&root);
}
