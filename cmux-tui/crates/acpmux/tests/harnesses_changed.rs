//! Profile hot reload (BRING-YOUR-OWN-HARNESS H2, slice 2b): a profile file
//! written into a watched source folder reloads the catalog and reaches
//! `_acpmux/watch` connections as `_acpmux/harnesses_changed`, without a
//! request and without polling.

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::serve_connection;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn write(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-hot-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("home")).unwrap();
    std::fs::create_dir_all(root.join("config")).unwrap();
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_profile_file_reaches_watchers_as_harnesses_changed() {
    let root = scratch("user");
    // The user folder does not exist yet: `cmux harness add` creates it.
    let user = root.join("config").join("harnesses");
    let sources = ProfileSources {
        managed: vec![root.join("managed-missing")],
        user_dir: Some(user.clone()),
        cmux_json: Some(root.join("config").join("cmux.json")),
    };
    write(&root.join("home").join("config.json"), "{}");
    let mut cfg = Config::load_from_with(&root.join("home").join("config.json"), &sources).unwrap();
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

    std::fs::create_dir_all(&user).unwrap();
    write(
        &user.join("hotacme.toml"),
        "schema = 1\nid = \"hotacme\"\nname = \"Hot Acme\"\ncommand = \"/bin/echo\"\n",
    );
    let changed = method::MUX_HARNESSES_CHANGED;
    let wait = Duration::from_secs(10);
    note_where(&mut rx, changed, wait, |n| names(n).iter().any(|h| h == "hotacme"))
        .await
        .expect("no harnesses_changed with the new profile after its file was written");
    assert!(hub.config.read().await.harnesses.contains_key("hotacme"));

    // A broken file reloads too, and its problem reaches the watcher.
    write(&user.join("broken.toml"), "schema = 1\nid = \"broken\"\n");
    let note = note_where(&mut rx, changed, wait, |n| {
        n["diagnostics"].to_string().contains("broken.toml")
    })
    .await
    .expect("no harnesses_changed with the broken file's problem");
    assert!(names(&note).iter().any(|h| h == "hotacme"), "{note}");

    // Let the earlier writes settle (one write can end two bursts), then:
    // cmux.json is watched; other files in its folder are not.
    let mut settled = false;
    for _ in 0..10 {
        if note_where(&mut rx, changed, Duration::from_millis(1000), |_| true).await.is_none() {
            settled = true;
            break;
        }
    }
    assert!(settled, "harnesses_changed never stopped: a reload causes another reload");
    write(&root.join("config").join("unrelated.txt"), "x");
    assert!(
        note_where(&mut rx, changed, Duration::from_millis(1500), |_| true).await.is_none(),
        "an unrelated file reloaded the catalog"
    );
}
