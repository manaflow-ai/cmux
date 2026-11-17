//! Each test leaves a registry the way a production Cloud machine was found
//! crash-looping, shows the open fails, recovers as the daemon's start does,
//! and opens again.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::resource::{BrowserPublicId, TabPublicId};
use crate::{Mux, SurfaceOptions, WorkspaceRegistry};

const SESSION: &str = "startup-self-recovery";

struct TestRoot(PathBuf);

impl TestRoot {
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn root() -> TestRoot {
    TestRoot(
        std::env::temp_dir().join(format!(
            "cmux-startup-self-recovery-{}",
            crate::workspace_registry::new_uuid_v4()
        )),
    )
}

fn db_path(root: &Path) -> PathBuf {
    persistent_session_state_dir(root, SESSION).join(WORKSPACE_REGISTRY_FILE)
}

fn open(root: &Path) -> anyhow::Result<Arc<Mux>> {
    Mux::open_persistent(SESSION, SurfaceOptions::default(), root)
}

/// A registry with a few committed rows, closed cleanly so every page is in
/// the main file.
fn written_registry(root: &Path) {
    let mux = open(root).unwrap();
    mux.shutdown();
    drop(mux);
}

/// Drops the WAL a clean close left behind, so the damage below is what
/// SQLite reads.
fn without_sidecars(root: &Path) {
    for suffix in SIDECAR_SUFFIXES {
        let _ = fs::remove_file(sidecar_path(&db_path(root), suffix));
    }
}

/// Opens, expects the failure, recovers, and opens a new registry.
fn recovers(root: &Path, expect: impl Fn(&str) -> bool) -> PathBuf {
    let error = match open(root) {
        Ok(mux) => {
            mux.shutdown();
            panic!("the damaged registry opened");
        }
        Err(error) => error,
    };
    assert!(expect(&format!("{error:#}")), "{error:#}");
    let (_, recovery_dir) = recover_registry_after_failed_open(root, SESSION, &error)
        .expect("the failure was not recognized as registry damage")
        .unwrap_or_else(|error| panic!("the registry was not moved aside: {error:#}"));
    assert!(recovery_dir.join(WORKSPACE_REGISTRY_FILE).is_file());
    assert!(recovery_dir.starts_with(persistent_session_state_dir(root, SESSION)));
    let mux = open(root).unwrap_or_else(|error| panic!("open after recovery: {error:#}"));
    mux.shutdown();
    recovery_dir
}

#[test]
fn startup_self_recovery_moves_aside_a_registry_that_is_not_a_database() {
    let root = root();
    written_registry(root.path());
    let mut bytes = fs::read(db_path(root.path())).unwrap();
    bytes[..100].fill(0x5a);
    fs::write(db_path(root.path()), bytes).unwrap();
    without_sidecars(root.path());

    let kept = recovers(root.path(), |error| error.contains("not a database"));
    assert!(fs::read_to_string(kept.join("reason.txt")).unwrap().contains("not a database"));
}

#[test]
fn startup_self_recovery_moves_aside_a_malformed_registry() {
    let root = root();
    written_registry(root.path());
    let mut bytes = fs::read(db_path(root.path())).unwrap();
    let page_size = usize::from(u16::from_be_bytes([bytes[16], bytes[17]]));
    assert!(bytes.len() > page_size, "the registry has one page");
    bytes[page_size..].fill(0xff);
    fs::write(db_path(root.path()), bytes).unwrap();
    without_sidecars(root.path());

    recovers(root.path(), |error| {
        error.contains("malformed") || error.contains("integrity check failed")
    });
}

#[test]
fn startup_self_recovery_moves_aside_unsettleable_interrupted_creations() {
    let root = root();
    {
        let mut registry = WorkspaceRegistry::open(root.path(), SESSION).unwrap();
        for index in 0..2 {
            let idempotency_key = format!("attempt-{index}");
            let fingerprint = json!({"operation":"tab.create_browser","index":index});
            let intent = json!({
                "browser_reservation":{
                    "tab_id":TabPublicId::random().unwrap(),
                    "browser_id":BrowserPublicId::random().unwrap(),
                },
            });
            registry
                .prepare_resource_creation(
                    &format!("correlation-{index}"),
                    &idempotency_key,
                    "tab.create_browser",
                    &fingerprint,
                    &intent,
                    true,
                    None,
                    None,
                )
                .unwrap();
            registry
                .mark_resource_effect_executing(
                    &idempotency_key,
                    "tab.create_browser",
                    &fingerprint,
                )
                .unwrap();
        }
    }

    recovers(root.path(), |error| error.contains("cannot be recovered atomically"));
}

#[test]
fn startup_self_recovery_leaves_a_registry_another_daemon_holds() {
    let root = root();
    written_registry(root.path());
    let holder = WorkspaceRegistry::open(root.path(), SESSION).unwrap();
    let damage = RegistryStartupDamage::InterruptedCreations("test".into());

    quarantine_session_registry(root.path(), SESSION, &damage)
        .expect_err("moved a registry another daemon has open");
    assert!(db_path(root.path()).is_file());
    drop(holder);
}

#[test]
fn startup_self_recovery_leaves_a_registry_that_passes_a_fresh_check() {
    let root = root();
    written_registry(root.path());
    let damage = RegistryStartupDamage::Unreadable("disk I/O error".into());

    quarantine_session_registry(root.path(), SESSION, &damage)
        .expect_err("moved a sound registry over a transient failure");
    assert!(db_path(root.path()).is_file());
    let recovery_root =
        persistent_session_state_dir(root.path(), SESSION).join(REGISTRY_RECOVERY_DIR);
    assert!(
        !recovery_root.exists() || fs::read_dir(&recovery_root).unwrap().next().is_none(),
        "a recovery directory was left behind"
    );
}

#[test]
fn startup_self_recovery_ignores_failures_that_are_not_damage() {
    let busy = anyhow::anyhow!("workspace session is already owned by another daemon");
    assert_eq!(registry_startup_damage(&busy), None);
    let schema = anyhow::Error::new(rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CORRUPT),
        Some("malformed database schema (x)".into()),
    ));
    assert_eq!(registry_startup_damage(&schema), None);
    let full = anyhow::Error::new(rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_FULL),
        None,
    ));
    assert_eq!(registry_startup_damage(&full), None);
}
