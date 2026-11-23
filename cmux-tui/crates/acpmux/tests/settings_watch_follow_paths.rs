//! The settings watch follows the settings file by path, not by the folders it found at start
//! (Codex review of #42548, F1 and F2):
//!
//! - when the settings folder is moved away and made again, the watch on the folder that moved
//!   away is let go, as is the stand-in watch on its parent once the folder is back: the
//!   process's inotify watch count goes back to where it was;
//! - a settings folder that is a symbolic link to a folder not made yet is picked up when that
//!   folder is made, so a settings file written into it reaches watchers.
//!
//! Its own test binary: it sets CMUX_NEXT_CONFIG_FILE, which the watcher reads, and counts the
//! inotify watches of the descriptors its hub opened. The tests take turns (`TURN`).

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
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// One test at a time: each sets the settings path and counts the descriptors its hub opened.
static TURN: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn scratch(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-settings-follow-{name}-{}", std::process::id()));
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

/// Drains notices until `m` stays quiet for a second (one write can end two bursts); false
/// when it never does.
async fn settle(rx: &mut mpsc::Receiver<String>, m: &str) -> bool {
    for _ in 0..10 {
        if !told(rx, m, Duration::from_millis(1000)).await {
            return true;
        }
    }
    false
}

/// The inotify descriptors open in this process.
fn inotify_fds() -> Vec<String> {
    let Ok(read) = std::fs::read_dir("/proc/self/fd") else { return Vec::new() };
    read.filter_map(Result::ok)
        .filter(|entry| {
            std::fs::read_link(entry.path())
                .is_ok_and(|to| to.to_string_lossy() == "anon_inode:inotify")
        })
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect()
}

/// The kernel's count of inotify watches on `fds` (`/proc/self/fdinfo`: one `inotify wd:` line
/// per watch).
fn watches(fds: &[String]) -> usize {
    fds.iter()
        .filter_map(|fd| std::fs::read_to_string(format!("/proc/self/fdinfo/{fd}")).ok())
        .map(|info| info.lines().filter(|l| l.starts_with("inotify wd:")).count())
        .sum()
}

/// A hub watching `settings` (no harness profile sources), a connection that has answered its
/// watch request, and the inotify descriptors the hub opened.
async fn watching(
    root: &Path,
    settings: &Path,
) -> (Arc<Hub>, mpsc::Sender<String>, mpsc::Receiver<String>, Vec<String>) {
    // SAFETY: set while this test holds its turn, before its hub starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", settings) };
    std::fs::write(root.join("home").join("config.json"), "{}").unwrap();
    let mut cfg =
        Config::load_from_with(&root.join("home").join("config.json"), &ProfileSources::none())
            .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let before = inotify_fds();
    let hub = Hub::new(cfg, store);
    hub.start_harness_watch();
    let mut fds = inotify_fds();
    fds.retain(|fd| !before.contains(fd));
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    tx.send(Message::request(1, method::MUX_WATCH, json!({"enabled": true})).to_line())
        .await
        .unwrap();
    assert!(
        settle(&mut rx, method::MUX_START_MODE_CHANGED).await,
        "start_mode_changed never stopped before any write"
    );
    (hub, tx, rx, fds)
}

/// F1: a refresh that drops a folder lets its watch go. The settings folder is moved away (its
/// watch would follow the moved folder) and a new one is made under the name (the parent stood
/// in while it was missing): once the change is told, the hub's inotify watches are as many as
/// before, not one more for each folder that ever stood in or moved away.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_settings_folder_moved_away_and_made_again_leaves_no_watch_behind() {
    let _turn = TURN.lock().await;
    let root = scratch("unwatch");
    let folder = root.join("settings").join("cmux");
    let settings = folder.join("cmux-next.json");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "ask"}}"#).unwrap();
    let (_hub, _tx, mut rx, fds) = watching(&root, &settings).await;
    let changed = method::MUX_START_MODE_CHANGED;
    assert!(!fds.is_empty(), "the hub opened no inotify descriptor");
    let start = watches(&fds);

    std::fs::rename(&folder, root.join("settings").join("cmux.old")).unwrap();
    // The move ends its burst and the watch refreshes before the folder comes back.
    let _ = settle(&mut rx, changed).await;
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}}"#).unwrap();
    assert!(
        told(&mut rx, changed, Duration::from_secs(10)).await,
        "no start_mode_changed after the settings folder was made again and written"
    );
    assert!(settle(&mut rx, changed).await, "start_mode_changed never stopped after one change");
    let end = watches(&fds);
    assert_eq!(
        end, start,
        "inotify watches went from {start} to {end} after the settings folder was moved away and \
         made again: a dropped folder's watch was kept"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// F2: the settings folder is a symbolic link (a dotfiles checkout) to a folder that does not
/// exist when the daemon starts. Making that folder and the settings file in it reaches the
/// watchers: the watch follows the link's target through its nearest existing folder.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_settings_file_behind_a_link_to_a_folder_made_later_reaches_watchers() {
    let _turn = TURN.lock().await;
    let root = scratch("link");
    let folder = root.join("settings").join("cmux");
    let target = root.join("dots").join("cmux");
    std::os::unix::fs::symlink(&target, &folder).unwrap();
    let settings = folder.join("cmux-next.json");
    let (_hub, _tx, mut rx, _fds) = watching(&root, &settings).await;
    let changed = method::MUX_START_MODE_CHANGED;

    std::fs::create_dir_all(&target).unwrap();
    std::fs::write(
        target.join("cmux-next.json"),
        r#"{"agents": {"defaultPermissionMode": "fullAccess"}}"#,
    )
    .unwrap();
    assert!(
        told(&mut rx, changed, Duration::from_secs(10)).await,
        "no start_mode_changed after the link's target folder and the settings file were made"
    );
    let _ = std::fs::remove_dir_all(&root);
}
