use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use cmux_tui_core::resource::{MachinePublicId, SessionPublicId};
use cmux_tui_core::{CatalogAliasKind, CatalogRepairPhase, SessionCatalog, WorkspaceRegistry};

static NEXT_ROOT: AtomicU64 = AtomicU64::new(1);

struct TestRoot(PathBuf);

impl TestRoot {
    fn new(test: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-session-catalog-{test}-{}-{}",
            std::process::id(),
            NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn seed_session(root: &Path, name: &str) -> (MachinePublicId, SessionPublicId, String) {
    let registry = WorkspaceRegistry::open(root, name).unwrap();
    let identity = (
        registry.machine_id().clone(),
        registry.session_id().clone(),
        registry.registry_id().to_string(),
    );
    drop(registry);
    identity
}

fn registry_directory(root: &Path, session_id: &SessionPublicId) -> PathBuf {
    fs::read_dir(root)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .find(|path| {
            let database = path.join("workspace-registry.sqlite3");
            if !database.is_file() {
                return false;
            }
            let connection = rusqlite::Connection::open_with_flags(
                database,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .unwrap();
            connection
                .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| {
                    row.get::<_, String>(0)
                })
                .is_ok_and(|stored| stored == session_id.as_str())
        })
        .expect("seeded registry directory")
}

#[test]
fn imports_legacy_sessions_without_changing_any_locator() {
    let root = TestRoot::new("import-locators");
    let (machine_id, session_id, registry_id) = seed_session(root.path(), "agents/red");
    let directory = registry_directory(root.path(), &session_id);
    let storage_component = directory.file_name().unwrap().to_str().unwrap().to_string();

    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    let report = catalog.import_legacy_sessions().unwrap();
    assert_eq!(report.imported, 1);

    let snapshot = catalog.snapshot(false).unwrap();
    assert_eq!(snapshot.machine_id, machine_id);
    let session = snapshot.sessions.iter().find(|item| item.session_id == session_id).unwrap();
    assert_eq!(session.registry_id, registry_id);
    assert_eq!(session.owner_key, "agents/red");
    assert_eq!(session.display_name, "agents/red");
    assert_eq!(session.locators.storage_component, storage_component);
    assert_eq!(session.locators.socket.kind, "legacy-default");
    assert_eq!(session.locators.socket.value, "agents/red");
    assert_eq!(session.locators.remote_state.kind, "legacy-session-name");
    assert_eq!(session.locators.remote_state.value, "agents/red");
    assert!(session.locators.terminal_host_component.starts_with("terminal-hosts-"));
    assert_eq!(session.repair_phase, CatalogRepairPhase::Ready);
    assert_eq!(session.deleted_revision, None);
    assert_eq!(
        session.aliases.iter().map(|alias| (alias.value.as_str(), alias.kind)).collect::<Vec<_>>(),
        vec![("agents/red", CatalogAliasKind::Legacy)]
    );
}

#[test]
fn legacy_import_is_idempotent_and_keeps_public_ids() {
    let root = TestRoot::new("idempotent");
    let (machine_id, session_id, _) = seed_session(root.path(), "main");
    let mut catalog = SessionCatalog::open(root.path()).unwrap();

    assert_eq!(catalog.import_legacy_sessions().unwrap().imported, 1);
    let first = catalog.snapshot(false).unwrap();
    assert_eq!(catalog.import_legacy_sessions().unwrap().imported, 0);
    let second = catalog.snapshot(false).unwrap();

    assert_eq!(first, second);
    assert_eq!(second.machine_id, machine_id);
    assert_eq!(second.sessions[0].session_id, session_id);
}

#[test]
fn import_migrates_a_registry_that_has_no_public_session_id() {
    let root = TestRoot::new("missing-public-id");
    let (_, old_session_id, _) = seed_session(root.path(), "main");
    let directory = registry_directory(root.path(), &old_session_id);
    let database = directory.join("workspace-registry.sqlite3");
    let connection = rusqlite::Connection::open(&database).unwrap();
    connection
        .execute("DELETE FROM meta WHERE key = 'session_public_id'", [])
        .unwrap();
    drop(connection);

    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    let report = catalog.import_legacy_sessions().unwrap();
    assert_eq!(report.migrated_registries, 1);
    assert_eq!(report.imported, 1);

    let imported = catalog.snapshot(false).unwrap().sessions.remove(0);
    let connection = rusqlite::Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let stored = connection
        .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| {
            row.get::<_, String>(0)
        })
        .unwrap();
    assert_eq!(imported.session_id.as_str(), stored);
}

#[test]
fn legacy_import_orders_main_then_alias_then_session_id() {
    let root = TestRoot::new("order");
    seed_session(root.path(), "zeta");
    seed_session(root.path(), "main");
    seed_session(root.path(), "Alpha");

    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();
    let names = catalog
        .snapshot(false)
        .unwrap()
        .sessions
        .into_iter()
        .map(|session| session.display_name)
        .collect::<Vec<_>>();

    assert_eq!(names, ["main", "Alpha", "zeta"]);
}

#[test]
fn rename_and_alias_changes_leave_all_owner_locators_unchanged() {
    let root = TestRoot::new("rename");
    let (_, session_id, _) = seed_session(root.path(), "main");
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();
    let before = catalog.snapshot(false).unwrap().sessions.remove(0);

    catalog.rename(&session_id, "My work").unwrap();
    catalog.add_alias(&session_id, "work:one", CatalogAliasKind::User).unwrap();
    let after = catalog.snapshot(false).unwrap().sessions.remove(0);

    assert_eq!(after.display_name, "My work");
    assert_eq!(after.owner_key, before.owner_key);
    assert_eq!(after.locators, before.locators);
    assert!(after.aliases.iter().any(|alias| alias.value == "main"));
    assert!(after.aliases.iter().any(|alias| alias.value == "work:one"));
    assert_eq!(catalog.resolve_alias("MAIN").unwrap(), None);
    assert_eq!(catalog.resolve_alias("main").unwrap().unwrap().session_id, session_id);
}

#[test]
fn alias_changes_advance_the_session_revision() {
    let root = TestRoot::new("alias-revision");
    let (_, session_id, _) = seed_session(root.path(), "main");
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();
    let before = catalog.snapshot(false).unwrap().sessions.remove(0);

    let alias_revision =
        catalog.add_alias(&session_id, "second", CatalogAliasKind::User).unwrap();
    let after = catalog.snapshot(false).unwrap().sessions.remove(0);

    assert!(alias_revision > before.updated_revision);
    assert_eq!(after.updated_revision, alias_revision);
}

#[test]
fn unsafe_legacy_name_is_imported_but_never_accepted_as_a_new_alias() {
    let root = TestRoot::new("unsafe-alias");
    let (_, session_id, _) = seed_session(root.path(), "old/name with spaces");
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();

    let imported = catalog.resolve_alias("old/name with spaces").unwrap().unwrap();
    assert_eq!(imported.session_id, session_id);
    assert_eq!(imported.aliases[0].kind, CatalogAliasKind::Legacy);
    let error =
        catalog.add_alias(&session_id, "new/name with spaces", CatalogAliasKind::User).unwrap_err();
    assert!(error.to_string().contains("safe routing alias"));
}

#[test]
fn interrupted_delete_repairs_to_a_tombstone_after_storage_is_gone() {
    let root = TestRoot::new("delete-repair");
    let (_, session_id, _) = seed_session(root.path(), "delete-me");
    let directory = registry_directory(root.path(), &session_id);
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();
    catalog.begin_delete(&session_id).unwrap();
    fs::remove_dir_all(directory).unwrap();

    let report = catalog.repair_incomplete().unwrap();
    assert_eq!(report.tombstoned, 1);
    assert!(catalog.snapshot(false).unwrap().sessions.is_empty());
    let deleted = catalog.snapshot(true).unwrap().sessions.remove(0);
    assert!(deleted.deleted_revision.is_some());
    assert_eq!(catalog.resolve_alias("delete-me").unwrap(), None);
}

#[test]
fn deleted_name_can_be_reused_by_a_new_public_session_id() {
    let root = TestRoot::new("reuse-deleted-name");
    let (_, deleted_session_id, _) = seed_session(root.path(), "repeat");
    let deleted_directory = registry_directory(root.path(), &deleted_session_id);
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();
    catalog.begin_delete(&deleted_session_id).unwrap();
    fs::remove_dir_all(deleted_directory).unwrap();
    assert_eq!(catalog.repair_incomplete().unwrap().tombstoned, 1);

    let (_, replacement_session_id, _) = seed_session(root.path(), "repeat");
    assert_ne!(replacement_session_id, deleted_session_id);
    assert_eq!(catalog.import_legacy_sessions().unwrap().imported, 1);

    let live = catalog.resolve_alias("repeat").unwrap().unwrap();
    assert_eq!(live.session_id, replacement_session_id);
    let history = catalog.snapshot(true).unwrap().sessions;
    assert_eq!(history.len(), 2);
    assert!(history.iter().any(|session| {
        session.session_id == deleted_session_id && session.deleted_revision.is_some()
    }));
    assert!(history.iter().any(|session| {
        session.session_id == replacement_session_id && session.deleted_revision.is_none()
    }));
}

#[test]
fn catalog_does_not_persist_running_state() {
    let root = TestRoot::new("no-running");
    seed_session(root.path(), "main");
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();

    let connection = rusqlite::Connection::open(root.path().join("catalog.sqlite3")).unwrap();
    let columns = connection
        .prepare("PRAGMA table_info(local_sessions)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(!columns.iter().any(|column| column == "running" || column == "pid"));
}

#[test]
fn snapshot_rejects_a_row_from_a_different_machine_identity() {
    let root = TestRoot::new("machine-mismatch");
    seed_session(root.path(), "main");
    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    catalog.import_legacy_sessions().unwrap();

    let other_machine = MachinePublicId::parse(format!("machine_{}", "f".repeat(32))).unwrap();
    let connection = rusqlite::Connection::open(root.path().join("catalog.sqlite3")).unwrap();
    connection
        .execute(
            "UPDATE local_sessions SET machine_id = ?1",
            [other_machine.as_str()],
        )
        .unwrap();

    let error = catalog.snapshot(false).unwrap_err();
    assert!(error.to_string().contains("different machine identity"));
}

#[cfg(unix)]
#[test]
fn scan_ignores_symlink_entries() {
    use std::os::unix::fs::symlink;

    let root = TestRoot::new("symlink");
    let outside = TestRoot::new("symlink-outside");
    seed_session(outside.path(), "outside");
    let outside_registry = fs::read_dir(outside.path())
        .unwrap()
        .filter_map(Result::ok)
        .find(|entry| entry.path().join("workspace-registry.sqlite3").is_file())
        .unwrap()
        .path();
    symlink(outside_registry, root.path().join("linked-session")).unwrap();

    let mut catalog = SessionCatalog::open(root.path()).unwrap();
    assert_eq!(catalog.import_legacy_sessions().unwrap().examined, 0);
    assert!(catalog.snapshot(false).unwrap().sessions.is_empty());
}
