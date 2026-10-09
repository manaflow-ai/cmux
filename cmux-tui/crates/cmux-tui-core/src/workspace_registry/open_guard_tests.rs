//! A registry that cannot be opened keeps its files: they move aside together
//! and no empty registry is created on top of them.

use super::super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-registry-guard-{label}-{}", new_uuid_v4()))
}

fn session_dir(root: &Path) -> PathBuf {
    root.join(session_storage_component("session"))
}

fn sidecar(database: &Path, suffix: &str) -> PathBuf {
    let mut name = database.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

/// Every file moved under `registry-recovery/`, by file name.
fn recovered_files(root: &Path) -> HashMap<String, Vec<u8>> {
    let recovery = session_dir(root).join("registry-recovery");
    let mut files = HashMap::new();
    let Ok(batches) = fs::read_dir(&recovery) else { return files };
    for batch in batches {
        for file in fs::read_dir(batch.unwrap().path()).unwrap() {
            let file = file.unwrap();
            files.insert(
                file.file_name().to_string_lossy().into_owned(),
                fs::read(file.path()).unwrap(),
            );
        }
    }
    files
}

#[test]
fn orphaned_wal_is_moved_aside_instead_of_opening_an_empty_registry() {
    let root = temp_root("orphaned-wal");
    let database = session_dir(&root).join(WORKSPACE_REGISTRY_FILE);
    fs::create_dir_all(session_dir(&root)).unwrap();
    let wal = sidecar(&database, "-wal");
    fs::write(&wal, b"committed frames the main file never received").unwrap();

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();

    assert!(!database.exists(), "no empty registry may be created in place: {error:#}");
    assert!(!wal.exists());
    assert_eq!(
        recovered_files(&root).get("workspace-registry.sqlite3-wal").map(Vec::as_slice),
        Some(&b"committed frames the main file never received"[..])
    );
    // With the journal kept aside, the next start begins a new session.
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn corrupt_registry_moves_database_and_sidecars_aside_together() {
    let root = temp_root("corrupt");
    let database = session_dir(&root).join(WORKSPACE_REGISTRY_FILE);
    // A real install first, so the state root has its machine id and pepper.
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    let garbage = vec![0x5a_u8; 8192];
    fs::write(&database, &garbage).unwrap();
    fs::write(sidecar(&database, "-shm"), b"shared memory index").unwrap();

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();

    let recovered = recovered_files(&root);
    assert_eq!(
        recovered.get("workspace-registry.sqlite3").map(Vec::as_slice),
        Some(garbage.as_slice()),
        "the corrupt registry must be kept: {error:#}"
    );
    assert!(recovered.contains_key("workspace-registry.sqlite3-shm"));
    assert!(!database.exists());
    assert!(!sidecar(&database, "-shm").exists());
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_registry_owned_by_another_daemon_stays_in_place() {
    let root = temp_root("owned");
    let database = session_dir(&root).join(WORKSPACE_REGISTRY_FILE);
    let owner = WorkspaceRegistry::open(&root, "session").unwrap();

    WorkspaceRegistry::open(&root, "session").unwrap_err();

    assert!(database.exists());
    assert!(recovered_files(&root).is_empty());
    drop(owner);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_newer_schema_registry_stays_in_place_for_the_build_that_wrote_it() {
    let root = temp_root("newer-schema");
    let database = session_dir(&root).join(WORKSPACE_REGISTRY_FILE);
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
            [(SCHEMA_VERSION + 1).to_string()],
        )
        .unwrap();
    drop(connection);

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();

    assert!(error.downcast_ref::<UnsupportedWorkspaceRegistrySchema>().is_some(), "{error:#}");
    assert!(database.exists());
    assert!(recovered_files(&root).is_empty());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_schema_this_sqlite_cannot_parse_stays_in_place() {
    // A newer build's SQLite may write schema SQL this one rejects as
    // "malformed database schema" (SQLITE_CORRUPT). That data is not damaged.
    let root = temp_root("unparsable-schema");
    let database = session_dir(&root).join(WORKSPACE_REGISTRY_FILE);
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "PRAGMA writable_schema=ON;
             INSERT INTO sqlite_master(type, name, tbl_name, rootpage, sql)
             VALUES('table', 'future', 'future', 0, 'CREATE TABLE future(');
             PRAGMA writable_schema=OFF;",
        )
        .unwrap();
    drop(connection);

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();

    assert!(error.downcast_ref::<RegistryQuarantined>().is_none(), "{error:#}");
    assert!(database.exists());
    assert!(recovered_files(&root).is_empty());
    fs::remove_dir_all(root).unwrap();
}
