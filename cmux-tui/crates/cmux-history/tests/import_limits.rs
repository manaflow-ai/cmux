use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_history::VisitStore;

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("cmux-history-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn source(path: &Path) -> rusqlite::Connection {
    let db = rusqlite::Connection::open(path).unwrap();
    db.execute_batch(
        "CREATE TABLE visits(
           id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
           visit_time_ms INTEGER NOT NULL, tab TEXT
         );",
    )
    .unwrap();
    db
}

#[test]
fn import_rejects_a_source_file_over_the_migration_ceiling() {
    let scratch = Scratch::new("file-limit");
    let source = scratch.path("History.sqlite");
    std::fs::File::create(&source).unwrap().set_len(256 * 1024 * 1024 + 1).unwrap();
    let target = VisitStore::open(&scratch.path("target.sqlite")).unwrap();

    let error = target.import(&source).unwrap_err().to_string();
    assert!(error.contains("too large"), "{error}");
    assert_eq!(target.count().unwrap(), 0);
}

#[test]
fn import_rejects_more_visits_than_the_live_store_retains() {
    let scratch = Scratch::new("visit-limit");
    let source_path = scratch.path("History.sqlite");
    let source = source(&source_path);
    source
        .execute_batch(
            "WITH RECURSIVE numbers(value) AS (
               VALUES(1) UNION ALL SELECT value + 1 FROM numbers WHERE value < 100001
             )
             INSERT INTO visits(url, visit_time_ms)
             SELECT 'https://example.test/' || value, value FROM numbers;",
        )
        .unwrap();
    drop(source);
    let target = VisitStore::open(&scratch.path("target.sqlite")).unwrap();

    let error = target.import(&source_path).unwrap_err().to_string();
    assert!(error.contains("too many visits"), "{error}");
    assert_eq!(target.count().unwrap(), 0, "a refused import committed partial rows");
}

#[test]
fn import_rejects_oversized_visit_fields() {
    let scratch = Scratch::new("field-limit");
    let source_path = scratch.path("History.sqlite");
    let source = source(&source_path);
    source
        .execute(
            "INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?1, 'title', 1, 'tab')",
            [format!("https://example.test/{}", "x".repeat(8192))],
        )
        .unwrap();
    drop(source);
    let target = VisitStore::open(&scratch.path("target.sqlite")).unwrap();

    let error = target.import(&source_path).unwrap_err().to_string();
    assert!(error.contains("field is too large"), "{error}");
    assert_eq!(target.count().unwrap(), 0, "a refused import committed partial rows");
}

#[test]
fn import_prunes_expired_visits_in_the_import_transaction() {
    let scratch = Scratch::new("retention");
    let source_path = scratch.path("History.sqlite");
    let source = source(&source_path);
    source
        .execute(
            "INSERT INTO visits(url, title, visit_time_ms, tab)
             VALUES ('https://expired.example.test', 'expired', 1, NULL)",
            [],
        )
        .unwrap();
    drop(source);
    let target = VisitStore::open(&scratch.path("target.sqlite")).unwrap();

    assert_eq!(target.import(&source_path).unwrap(), 1);
    assert_eq!(
        target.count().unwrap(),
        0,
        "an expired import survived until the next hourly prune"
    );
}

#[test]
fn import_distinguishes_replacements_with_the_same_size_and_modified_time() {
    let scratch = Scratch::new("generation-identity");
    let source_path = scratch.path("History.sqlite");
    let replacement_path = scratch.path("replacement.sqlite");
    let now_ms = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64;
    let first = source(&source_path);
    first
        .execute(
            "INSERT INTO visits(url, visit_time_ms) VALUES ('https://a.example.test', ?1)",
            [now_ms],
        )
        .unwrap();
    drop(first);
    let original = std::fs::metadata(&source_path).unwrap();
    let original_modified = original.modified().unwrap();

    let second = source(&replacement_path);
    second
        .execute(
            "INSERT INTO visits(url, visit_time_ms) VALUES ('https://b.example.test', ?1)",
            [now_ms],
        )
        .unwrap();
    drop(second);
    assert_eq!(std::fs::metadata(&replacement_path).unwrap().len(), original.len());
    std::fs::File::open(&replacement_path)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(original_modified))
        .unwrap();

    let target = VisitStore::open(&scratch.path("target.sqlite")).unwrap();
    assert_eq!(target.import(&source_path).unwrap(), 1);
    std::fs::remove_file(&source_path).unwrap();
    std::fs::rename(&replacement_path, &source_path).unwrap();
    std::fs::File::open(&source_path)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(original_modified))
        .unwrap();

    assert_eq!(target.import(&source_path).unwrap(), 1);
    assert_eq!(target.count().unwrap(), 2);
}
