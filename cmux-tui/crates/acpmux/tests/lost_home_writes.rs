//! A daemon whose home was replaced (moved away, and another folder made at the same path) never
//! writes into the replacement, whenever its home watch hears of it (`daemon/home_watch.rs`).
//! Each writer under the home is checked with the home already replaced and the lost-home flag
//! never set, so no watch timing decides the result: the home this daemon holds is the folder
//! it locked (`config::hold_home`), not a path.
//!
//! The held home is process-wide, so each test runs its body in a process of its own
//! ([`isolated`]) under nextest and `cargo test` alike.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts. The child process of each test reads its home and its role from these two.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["ACPMUX_HOME", "ACPMUX_LOST_HOME_TEST"]);

use std::path::{Path, PathBuf};
use std::sync::Arc;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-lost-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(&dir).unwrap()
}

/// Runs `body` in a process of its own with `ACPMUX_HOME` a fresh home under a scratch folder:
/// the test's own binary, filtered to this test. In that process, `body` gets the home.
fn isolated(name: &str, body: impl FnOnce(&Path)) {
    if std::env::var("ACPMUX_LOST_HOME_TEST").ok().as_deref() == Some(name) {
        let home = PathBuf::from(std::env::var("ACPMUX_HOME").unwrap());
        body(&home);
        return;
    }
    let dir = scratch(name);
    let home = dir.join("h");
    std::fs::create_dir(&home).unwrap();
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args([name, "--exact", "--nocapture", "--test-threads=1"])
        .env("ACPMUX_LOST_HOME_TEST", name)
        .env("ACPMUX_HOME", &home)
        .output()
        .unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        out.status.success(),
        "{name}: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}

/// The daemon holds `home`, then it is moved to `home.old` and a new folder is made at `home`.
fn replace_held(home: &Path) {
    acpmux::config::hold_home();
    std::fs::rename(home, home.with_extension("old")).unwrap();
    std::fs::create_dir(home).unwrap();
}

fn left(home: &Path) -> Vec<String> {
    std::fs::read_dir(home)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

fn sources(acpmux_home: &Path) -> acpmux::chats::ChatSources {
    let user = acpmux_home.parent().unwrap().join("user");
    std::fs::create_dir_all(&user).unwrap();
    acpmux::chats::ChatSources {
        home: user,
        acpmux_home: acpmux_home.to_path_buf(),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    }
}

/// The chat index saves its cache (`chat-index/v1.json`) as it starts.
#[test]
fn the_chat_index_cache_is_not_written_into_a_replaced_home() {
    isolated("the_chat_index_cache_is_not_written_into_a_replaced_home", |home| {
        replace_held(home);
        let _service = acpmux::chats::ChatService::start(sources(home));
        assert_eq!(left(home), Vec::<String>::new(), "the chat index wrote into the new home");
    });
}

/// A spawn's launch roots are recorded in `chat-roots.json`.
#[test]
fn launch_roots_are_not_recorded_into_a_replaced_home() {
    isolated("launch_roots_are_not_recorded_into_a_replaced_home", |home| {
        let service = acpmux::chats::ChatService::start(sources(home));
        let root = home.parent().unwrap().join("claude-projects");
        std::fs::create_dir_all(&root).unwrap();
        replace_held(home);
        service.record_launch_roots(&[cmux_chat_index::RootSpec {
            harness: cmux_chat_index::AdapterKind::ClaudeCode,
            path: root,
            label: None,
        }]);
        assert_eq!(left(home), Vec::<String>::new(), "a launch root was recorded in the new home");
    });
}

/// The folder for agents no person asked for (`<home>/unattended`).
#[test]
fn the_unattended_folder_is_not_made_in_a_replaced_home() {
    isolated("the_unattended_folder_is_not_made_in_a_replaced_home", |home| {
        replace_held(home);
        let _ = acpmux::protected_folders::unattended_cwd_in(home, None);
        assert_eq!(left(home), Vec::<String>::new(), "unattended/ was made in the new home");
    });
}

/// A removed route's backup goes to `<home>/route-backups`.
#[test]
fn a_route_backup_is_not_written_into_a_replaced_home() {
    isolated("a_route_backup_is_not_written_into_a_replaced_home", |home| {
        let routes = home.parent().unwrap().join("routes");
        let file = acpmux::routes::file_from_json(&serde_json::json!({
            "kind": "subrouter", "anthropicBaseUrl": "http://127.0.0.1:9/a"
        }))
        .unwrap();
        acpmux::routes::add(Some(&routes), "proxy-a", &file, false).unwrap();
        replace_held(home);
        let removed = acpmux::routes::remove(Some(&routes), home, "proxy-a");
        assert!(removed.is_err(), "a route was removed into a replaced home: {removed:?}");
        assert_eq!(left(home), Vec::<String>::new(), "route-backups/ was made in the new home");
        assert!(routes.join("proxy-a.toml").exists(), "the route is kept where it was");
    });
}

/// The shared writers refuse too, and the first refusal marks the home lost.
#[test]
fn the_shared_writers_refuse_a_replaced_home() {
    isolated("the_shared_writers_refuse_a_replaced_home", |home| {
        replace_held(home);
        let wrote = acpmux::config::write_atomic(&home.join("x.json"), b"{}");
        assert!(wrote.is_err(), "a state file was written into the new home");
        assert_eq!(left(home), Vec::<String>::new());
    });
}
