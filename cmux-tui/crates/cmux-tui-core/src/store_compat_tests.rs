use super::*;

const RULE: StoreRule = StoreRule { label: "test store", schema: 5, min_reader: 4 };

fn stamps(schema: Option<i64>, min_reader: Option<i64>) -> Stamps {
    Stamps { schema, min_reader, written_by: None }
}

fn temp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-store-compat-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn verdict_follows_the_rule() {
    assert_eq!(verdict(RULE, &stamps(None, None)), Verdict::Fresh);
    assert_eq!(verdict(RULE, &stamps(Some(5), Some(4))), Verdict::Current);
    // A build of schema 4 reads what this build writes: no backup.
    assert_eq!(verdict(RULE, &stamps(Some(4), None)), Verdict::Migrate { from: 4, backup: false });
    // A build of schema 3 does not: keep the schema 3 file first.
    assert_eq!(
        verdict(RULE, &stamps(Some(3), Some(3))),
        Verdict::Migrate { from: 3, backup: true }
    );
    // Newer, additive: min reader at or below this build's schema.
    assert_eq!(verdict(RULE, &stamps(Some(7), Some(5))), Verdict::ReadNewer { found: 7 });
    // Newer, breaking.
    assert_eq!(
        verdict(RULE, &stamps(Some(7), Some(6))),
        Verdict::Refuse { found: 7, min_reader: 6 }
    );
    // Newer, from a writer before the rule: its schema is its min reader.
    assert_eq!(verdict(RULE, &stamps(Some(6), None)), Verdict::Refuse { found: 6, min_reader: 6 });
    assert!(!Verdict::ReadNewer { found: 7 }.stamps());
    assert!(!Verdict::Refuse { found: 7, min_reader: 6 }.stamps());
}

#[test]
fn backup_restore_round_trip_keeps_both_files() {
    let dir = temp_dir("restore");
    let database = dir.join("store.sqlite3");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             INSERT INTO meta VALUES('schema_version', '3');
             CREATE TABLE item(name TEXT);
             INSERT INTO item VALUES('before');",
        )
        .unwrap();
    let backup = keep_backup(&connection, &database, 3).unwrap();
    assert_eq!(backup, dir.join("store.sqlite3.v3.bak"));
    connection
        .execute_batch(
            "UPDATE meta SET value = '5' WHERE key = 'schema_version';
             INSERT INTO item VALUES('after');",
        )
        .unwrap();
    // A second backup of the same schema keeps the first copy.
    assert_eq!(keep_backup(&connection, &database, 3).unwrap(), backup);
    drop(connection);
    assert_eq!(newest_backup(&database, 4), Some(backup.clone()));
    assert_eq!(newest_backup(&database, 2), None);

    let aside = restore_backup(&backup).unwrap();
    assert!(backup.is_file(), "the backup stays");
    let restored = Connection::open(&database).unwrap();
    let schema: String = restored
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
        .unwrap();
    assert_eq!(schema, "3");
    let items: i64 = restored.query_row("SELECT COUNT(*) FROM item", [], |row| row.get(0)).unwrap();
    assert_eq!(items, 1);
    drop(restored);
    let moved = Connection::open(aside.join("store.sqlite3")).unwrap();
    let items: i64 = moved.query_row("SELECT COUNT(*) FROM item", [], |row| row.get(0)).unwrap();
    assert_eq!(items, 2, "the replaced store keeps its writes");
    drop(moved);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn restore_refuses_a_file_that_is_not_a_backup() {
    let dir = temp_dir("not-backup");
    let error = restore_backup(&dir.join("store.sqlite3")).unwrap_err();
    assert!(format!("{error:#}").contains("is not a store backup"), "{error:#}");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn refusal_names_both_versions_and_the_backup() {
    let text = refusal_text(
        "test store",
        7,
        6,
        5,
        Some("9.9.9"),
        Some(Path::new("/s/store.sqlite3")),
        Some(Path::new("/s/store.sqlite3.v5.bak")),
    );
    assert!(text.starts_with("unsupported test store schema 7; newest supported is 5"), "{text}");
    assert!(text.contains("written by cmux-tui 9.9.9"), "{text}");
    assert!(text.contains("reader of schema 6 or newer"), "{text}");
    assert!(text.contains(&format!("cmux-tui {BUILD_VERSION}) reads schema 5")), "{text}");
    assert!(text.contains("__store-schemas --restore /s/store.sqlite3.v5.bak"), "{text}");
    let text = refusal_text("test store", 7, 6, 5, None, None, None);
    assert!(text.contains("No backup at schema 5 or older"), "{text}");
}
