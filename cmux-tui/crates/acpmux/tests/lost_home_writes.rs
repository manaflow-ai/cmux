//! A daemon whose home was replaced (moved away, and another folder made at the same path) never
//! writes into the replacement, whenever its home watch hears of it (`daemon/home_watch.rs`).
//! Each writer under the home is checked with the home already replaced and the lost-home flag
//! never set, so no watch timing decides the result: the home this daemon holds is the folder
//! it locked (`config::hold_home`), not a path. One test forces the race a path check leaves
//! open instead: the chat text save checks the home, the home is replaced, then the save writes.
//! Each hold point it uses asserts it was reached in the state the test names.
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

/// The daemon holds `home`, then it is replaced ([`replace`]).
fn replace_held(home: &Path) {
    acpmux::config::hold_home();
    replace(home);
}

/// `home` is moved to `home.old` and a new folder is made at `home`.
fn replace(home: &Path) {
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
        replace_held(home);
        let service = acpmux::chats::ChatService::start(sources(home));
        let ended = service.subscribe();
        record_a_launch_root(home, &service);
        end_service(service, ended);
        assert_eq!(left(home), Vec::<String>::new(), "a launch root was recorded in the new home");
    });
}

/// The race itself, in the order the test sets (`chats::text::SAVE_CHECKED`): the service starts
/// in the held home, the chat text thread's first save passes its home check and is held there,
/// the home is replaced, a launch root is recorded, and only then does the save go on. Neither
/// write lands in the replacement: `config::refuse_lost_home` by path cannot rule that out for a
/// check that passed before the replacement, so the save writes through the folder it holds.
#[test]
fn a_text_save_that_checked_before_the_home_was_replaced_is_not_written_into_it() {
    isolated(
        "a_text_save_that_checked_before_the_home_was_replaced_is_not_written_into_it",
        |home| {
            acpmux::chats::text::SAVE_CHECKED.set(held_save).unwrap();
            acpmux::config::hold_home();
            let service = acpmux::chats::ChatService::start(sources(home));
            let ended = service.subscribe();
            // The hold point is reached in the state this test names: the check passed, before
            // the replacement. A save whose check already failed would prove nothing here.
            assert_eq!(
                held_save_checked(),
                Some(true),
                "the text save was not held past its check"
            );
            replace(home);
            record_a_launch_root(home, &service);
            release_held_save();
            end_service(service, ended);
            assert_eq!(
                left(home),
                Vec::<String>::new(),
                "the held text save wrote into the new home"
            );
        },
    );
}

/// Records a launch root for the service.
fn record_a_launch_root(home: &Path, service: &Arc<acpmux::chats::ChatService>) {
    let root = home.parent().unwrap().join("claude-projects");
    std::fs::create_dir_all(&root).unwrap();
    service.record_launch_roots(&[cmux_chat_index::RootSpec {
        harness: cmux_chat_index::AdapterKind::ClaudeCode,
        path: root,
        label: None,
    }]);
}

/// Drops the service and waits for its own threads to let it go, so a write they make late is
/// seen too: the service ends when its text thread lets go of it, after any save it was making;
/// its change channel closes then.
fn end_service<T: Clone>(
    service: Arc<acpmux::chats::ChatService>,
    mut ended: tokio::sync::broadcast::Receiver<T>,
) {
    drop(service);
    while !matches!(ended.blocking_recv(), Err(tokio::sync::broadcast::error::RecvError::Closed)) {}
}

/// The held save: whether its home check passed, and whether the test let it go on.
static HELD: std::sync::Mutex<(Option<bool>, bool)> = std::sync::Mutex::new((None, false));
static HELD_MOVED: std::sync::Condvar = std::sync::Condvar::new();

/// `SAVE_CHECKED` on the text thread: tells the test whether the first save's check passed, and
/// holds that save, when it passed, until [`release_held_save`]. Later saves go on.
fn held_save(passed: bool) {
    let mut held = HELD.lock().unwrap();
    if held.0.is_some() {
        return;
    }
    held.0 = Some(passed);
    HELD_MOVED.notify_all();
    if passed {
        let _released = HELD_MOVED.wait_while(held, |held| !held.1).unwrap();
    }
}

/// Waits for the text thread's first save to reach its check, and says whether the check passed.
fn held_save_checked() -> Option<bool> {
    // timeout: only a text thread that never saves ends here; the order is the hook's.
    let (held, waited) = HELD_MOVED
        .wait_timeout_while(HELD.lock().unwrap(), std::time::Duration::from_secs(120), |held| {
            held.0.is_none()
        })
        .unwrap();
    assert!(!waited.timed_out(), "the chat text thread never saved");
    held.0
}

fn release_held_save() {
    HELD.lock().unwrap().1 = true;
    HELD_MOVED.notify_all();
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
