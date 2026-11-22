//! The harness profile watcher (BRING-YOUR-OWN-HARNESS H2) during shutdown:
//! dropping the runtime or the hub while a burst of profile changes is still
//! being gathered must not panic (in any thread) or hang. Its own test
//! binary: it installs a process-wide panic hook.

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

static PANICS: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn write(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn scratch(name: &str) -> (PathBuf, ProfileSources) {
    let root = std::env::temp_dir().join(format!("acpmux-watch-end-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config").join("harnesses")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    write(&root.join("home").join("config.json"), "{}");
    let sources = ProfileSources {
        managed: vec![],
        user_dir: Some(root.join("config").join("harnesses")),
        cmux_json: None,
    };
    (root, sources)
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
}

/// A hub with a running watcher, built inside `rt`.
fn watched_hub(rt: &tokio::runtime::Runtime, root: &Path, sources: &ProfileSources) -> Arc<Hub> {
    let mut cfg = Config::load_from_with(&root.join("home").join("config.json"), sources).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    rt.block_on(async move {
        let hub = Hub::new(cfg, store);
        hub.start_harness_watch();
        hub
    })
}

fn burst(sources: &ProfileSources, id: &str) {
    let dir = sources.user_dir.as_ref().unwrap();
    write(
        &dir.join(format!("{id}.toml")),
        &format!("schema = 1\nid = \"{id}\"\ncommand = \"/bin/echo\"\n"),
    );
    // The watcher thread is now inside the burst's debounce (up to 2 s).
    std::thread::sleep(Duration::from_millis(50));
}

/// Live threads named like the watcher's (Linux; None elsewhere).
fn watch_threads() -> Option<usize> {
    let tasks = std::fs::read_dir("/proc/self/task").ok()?;
    Some(
        tasks
            .filter_map(|t| std::fs::read_to_string(t.ok()?.path().join("comm")).ok())
            .filter(|name| name.starts_with("acpmux-harness"))
            .count(),
    )
}

fn scenario() {
    let wait_burst = Duration::from_millis(2600);
    // 1. The runtime ends first, the hub lives on, the burst ends later.
    let (root, sources) = scratch("runtime");
    let rt = runtime();
    let hub = watched_hub(&rt, &root, &sources);
    burst(&sources, "first");
    rt.shutdown_timeout(Duration::from_secs(5));
    std::thread::sleep(wait_burst);
    drop(hub);

    // 2. The hub ends first, the runtime lives on, the burst ends later.
    let (root, sources) = scratch("hub");
    let rt = runtime();
    let hub = watched_hub(&rt, &root, &sources);
    burst(&sources, "second");
    drop(hub);
    std::thread::sleep(wait_burst);
    rt.shutdown_timeout(Duration::from_secs(5));
}

#[test]
fn dropping_the_runtime_or_the_hub_with_a_burst_pending_neither_panics_nor_hangs() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let name = std::thread::current().name().unwrap_or("?").to_owned();
        PANICS.lock().unwrap_or_else(|p| p.into_inner()).push(format!("{name}: {info}"));
        previous(info);
    }));
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        scenario();
        let _ = done_tx.send(());
    });
    done_rx.recv_timeout(Duration::from_secs(60)).expect("the shutdown scenario hung");
    // The watcher threads end with their hubs.
    if watch_threads().is_some() {
        let mut left = watch_threads();
        for _ in 0..50 {
            if left == Some(0) {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
            left = watch_threads();
        }
        assert_eq!(left, Some(0), "a harness watch thread outlived its hub");
    }
    let panics = PANICS.lock().unwrap_or_else(|p| p.into_inner()).clone();
    assert!(panics.is_empty(), "panics during shutdown: {panics:#?}");
}
