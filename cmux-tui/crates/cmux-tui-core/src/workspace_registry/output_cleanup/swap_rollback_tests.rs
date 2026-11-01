//! A rollback that cannot put the previous registry back refuses the start
//! and is finished by the next one.

use super::*;

fn temp_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-output-cleanup-rollback-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_rollback_that_cannot_put_the_registry_back_refuses_and_finishes_next_start() {
    let dir = temp_dir("pending");
    let db_path = dir.join("workspace-registry.sqlite3");
    fs::write(&db_path, b"cleaned").unwrap();
    // The previous registry cannot be renamed over the swapped one (a
    // directory stands in for a file still held open).
    let previous = previous_path(&db_path);
    fs::create_dir_all(previous.join("held")).unwrap();

    let error = roll_back_swap(&db_path, &anyhow::anyhow!("test: did not serve")).unwrap_err();
    assert!(format!("{error:#}").contains("next start tries again"), "{error:#}");
    assert!(rollback_pending_path(&db_path).is_file(), "the rollback is recorded");
    assert_eq!(fs::read(&db_path).unwrap(), b"cleaned");
    assert!(refuse_open_beside_backup(&db_path).is_err(), "no open uses the swapped registry");

    // The next start (nothing holds the file any more) finishes it.
    fs::remove_dir_all(&previous).unwrap();
    fs::write(&previous, b"full").unwrap();
    finish_pending_rollback(&db_path).unwrap();
    assert_eq!(fs::read(&db_path).unwrap(), b"full");
    assert!(!previous.exists());
    assert!(!rollback_pending_path(&db_path).exists());
    refuse_open_beside_backup(&db_path).unwrap();
    // Nothing pending: a no-op.
    finish_pending_rollback(&db_path).unwrap();
    assert_eq!(fs::read(&db_path).unwrap(), b"full");
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_failure_marker_beside_a_plain_registry_is_not_a_pending_rollback() {
    // The failure marker alone (a cleanup that failed with the registry
    // unchanged) never moves files: no swap stands behind it.
    let dir = temp_dir("failed-only");
    let db_path = dir.join("workspace-registry.sqlite3");
    fs::write(&db_path, b"registry").unwrap();
    fs::write(super::super::failed_path(&db_path), b"build\nreason\n").unwrap();
    finish_pending_rollback(&db_path).unwrap();
    assert_eq!(fs::read(&db_path).unwrap(), b"registry");
    refuse_open_beside_backup(&db_path).unwrap();
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_rollback_whose_wal_cannot_be_removed_keeps_the_backup_aside() {
    // The cleaned registry's WAL cannot go (a directory stands in for a
    // file a reader holds without delete sharing on Windows). Its frames
    // belong to the cleaned file's pages: the previous registry must not be
    // put back beneath it.
    let dir = temp_dir("wal-held");
    let db_path = dir.join("workspace-registry.sqlite3");
    fs::write(&db_path, b"cleaned").unwrap();
    let previous = previous_path(&db_path);
    fs::write(&previous, b"full").unwrap();
    let wal = sidecar_path(&db_path, "-wal");
    fs::create_dir_all(wal.join("held")).unwrap();

    roll_back_swap(&db_path, &anyhow::anyhow!("test: did not serve")).unwrap_err();
    assert_eq!(fs::read(&db_path).unwrap(), b"cleaned", "the backup was put back beneath the WAL");
    assert_eq!(fs::read(&previous).unwrap(), b"full");
    assert!(rollback_pending_path(&db_path).is_file(), "the rollback is recorded");
    assert!(refuse_open_beside_backup(&db_path).is_err(), "no open uses the swapped registry");

    // The next start, once the WAL can go, finishes it.
    fs::remove_dir_all(&wal).unwrap();
    finish_pending_rollback(&db_path).unwrap();
    assert_eq!(fs::read(&db_path).unwrap(), b"full");
    assert!(!rollback_pending_path(&db_path).exists());
    fs::remove_dir_all(&dir).unwrap();
}

fn registry_with_meta(path: &Path, entries: &[(&str, &str)]) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        .unwrap();
    for (key, value) in entries {
        connection.execute("INSERT INTO meta(key, value) VALUES(?1, ?2)", [key, value]).unwrap();
    }
}

fn full_starts(db_path: &Path) -> Option<String> {
    Connection::open(db_path)
        .unwrap()
        .query_row("SELECT value FROM meta WHERE key = ?1", [FULL_STARTS_META_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()
        .unwrap()
}

#[test]
fn a_full_start_that_cannot_read_the_backup_is_refused_not_counted_as_unswapped() {
    // The swapped registry's backup cannot be read (a directory stands in for
    // a file another process holds). Treating that as "not the swapped
    // registry" would let this start serve without recording itself, and a
    // later failed start could roll back over what it served.
    let dir = temp_dir("backup-unreadable");
    let db_path = dir.join("workspace-registry.sqlite3");
    registry_with_meta(&db_path, &[("registry_id", "r1"), (DONE_META_KEY, "{\"kept\":1}")]);
    let previous = previous_path(&db_path);
    fs::create_dir_all(previous.join("held")).unwrap();

    let error = note_full_start(&db_path).unwrap_err();
    assert!(format!("{error:#}").contains("the start is refused"), "{error:#}");
    assert_eq!(full_starts(&db_path), None);

    // Once the backup reads again, the start is recorded.
    fs::remove_dir_all(&previous).unwrap();
    registry_with_meta(&previous, &[("registry_id", "r1")]);
    note_full_start(&db_path).unwrap();
    assert_eq!(full_starts(&db_path).as_deref(), Some("1"));
    assert!(!rollback_possible(&db_path), "a recorded start ends the rollback window");
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_full_start_beside_another_registrys_backup_is_not_counted() {
    let dir = temp_dir("backup-other");
    let db_path = dir.join("workspace-registry.sqlite3");
    registry_with_meta(&db_path, &[("registry_id", "r1"), (DONE_META_KEY, "{\"kept\":1}")]);
    registry_with_meta(&previous_path(&db_path), &[("registry_id", "r2")]);
    note_full_start(&db_path).unwrap();
    assert_eq!(full_starts(&db_path), None);
    fs::remove_dir_all(&dir).unwrap();
}
