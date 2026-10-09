//! Unit tests for `config`; topic tests live in `tests/`.

#[cfg(unix)]
use crate::test_exec::write_executable;
use ratatui::buffer::CellWidth;
use std::cell::{Cell, RefCell};
use {super::*, crate::local_actor::TuiMuxOps};

#[test]
fn config_diagnostics_do_not_echo_parser_details() {
    let error = serde_json::from_str::<RawConfig>(r#"{"typo":true}"#).unwrap_err();
    let diagnostic = config_diagnostic(&error);
    assert!(diagnostic.contains("unknown config field"));
    assert!(!diagnostic.contains("typo"));
}
use std::ffi::OsString;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

/// Config env vars are process-global state; tests that set them must not
/// run concurrently with each other.
static CONFIG_ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn startup_snapshot_invokes_loader_once() {
    let loads = Cell::new(0);
    let snapshot = StartupConfigSnapshot::from_loader(|| {
        loads.set(loads.get() + 1);
        Config::default()
    });

    assert!(snapshot.server.detached_owner);
    assert!(snapshot.server.detached_owner);
    let _config = snapshot.into_config();
    assert_eq!(loads.get(), 1);
}
static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(0);

struct TestDirectory {
    path: PathBuf,
}

impl TestDirectory {
    fn new(label: &str) -> Self {
        loop {
            let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("cmux-tui-config-{label}-{}-{sequence}", std::process::id()));
            match std::fs::create_dir(&path) {
                Ok(()) => return Self { path },
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create config test directory failed: {error}"),
            }
        }
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn restore_env_var(key: &str, value: Option<OsString>) {
    match value {
        // SAFETY: env mutation in tests is serialized by CONFIG_ENV_LOCK.
        Some(value) => unsafe { std::env::set_var(key, value) },
        None => unsafe { std::env::remove_var(key) },
    }
}

fn assert_committed(outcome: ConfigWriteOutcome) {
    assert!(matches!(
        outcome,
        ConfigWriteOutcome::Committed
            | ConfigWriteOutcome::CommittedWithoutDirectorySync
            | ConfigWriteOutcome::CommittedButUnsynced { .. }
    ));
}

mod ghostty_defaults;
mod chrome_theme;
mod ghostty_config_files;
mod ghostty_helper;
mod ghostty_theme_mode;
mod sections;
mod keys;
mod status_and_sidebar_chrome;
mod commands;
mod config_write;
