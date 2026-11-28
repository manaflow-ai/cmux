//! RFD 0125 D8 step 1: every visit has a stable id (`uid`) that sync can name on every device.

use std::collections::HashSet;

use cmux_history::{ActorFilter, HistoryKind, NewVisit, SearchFilter, VisitStore};

fn visit(url: &str, at_ms: i64) -> NewVisit {
    NewVisit { url: url.to_owned(), title: None, tab: None, actor: None, at_ms }
}

fn is_uid(uid: &str) -> bool {
    uid.len() == 32 && uid.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn all(store: &VisitStore) -> Vec<cmux_history::Visit> {
    store
        .visits_matching_with_actor(
            &SearchFilter::<HistoryKind>::words(Vec::new()),
            1000,
            ActorFilter::All,
        )
        .unwrap()
}

#[test]
fn recorded_visits_get_distinct_stable_ids() {
    let store = VisitStore::open_in_memory().unwrap();
    for at in 0..200 {
        store.record(&visit("https://same.example/", at)).unwrap();
    }
    let rows = all(&store);
    assert_eq!(rows.len(), 200);
    assert!(rows.iter().all(|row| is_uid(&row.uid)));
    let unique: HashSet<_> = rows.iter().map(|row| row.uid.clone()).collect();
    assert_eq!(unique.len(), 200);
}

#[test]
fn uid_survives_remove_and_restore_even_when_the_row_id_moves() {
    let store = VisitStore::open_in_memory().unwrap();
    let id = store.record(&visit("https://a.example/", 1)).unwrap();
    let uid = store.visit(id).unwrap().unwrap().uid;
    assert_eq!(store.remove_visit(id, "b1").unwrap(), 1);
    assert!(store.visit_by_uid(&uid).unwrap().is_none());
    // SQLite hands the freed row id to the next visit (the reason a row id is not a stable
    // id), so the restore has to move this visit to a new one.
    let other = store.record(&visit("https://b.example/", 2)).unwrap();
    assert_eq!(other, id);
    let other_uid = store.visit(other).unwrap().unwrap().uid;
    assert_ne!(other_uid, uid);
    assert_eq!(store.restore("b1").unwrap(), 1);
    let back = store.visit_by_uid(&uid).unwrap().unwrap();
    assert_ne!(back.id, id);
    assert_eq!(back.url, "https://a.example/");
    assert_eq!(back.uid, uid);
}

#[test]
fn uid_survives_remove_and_restore_in_place() {
    let store = VisitStore::open_in_memory().unwrap();
    let id = store.record(&visit("https://a.example/", 1)).unwrap();
    let uid = store.visit(id).unwrap().unwrap().uid;
    store.remove_url("https://a.example/", "b2").unwrap();
    store.restore("b2").unwrap();
    let back = store.visit(id).unwrap().unwrap();
    assert_eq!(back.uid, uid);
}

#[test]
fn a_v4_store_backfills_live_and_removed_rows_once() {
    let dir = std::env::temp_dir().join(format!("cmux-history-uid-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("History.sqlite");
    {
        // The schema as #56401 left it (user_version 4): actor columns, no uid.
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
                 visit_time_ms INTEGER NOT NULL, tab TEXT,
                 actor TEXT NOT NULL DEFAULT 'person', session_id TEXT, search TEXT);
                 CREATE TABLE removed_visits(backup TEXT NOT NULL, id INTEGER NOT NULL,
                 url TEXT NOT NULL, title TEXT, visit_time_ms INTEGER NOT NULL, tab TEXT,
                 actor TEXT NOT NULL DEFAULT 'person', session_id TEXT);
                 CREATE TABLE imported_logs(source TEXT PRIMARY KEY, visits INTEGER NOT NULL);
                 INSERT INTO visits(url, visit_time_ms) VALUES ('https://one.example/', 1);
                 INSERT INTO visits(url, visit_time_ms) VALUES ('https://two.example/', 2);
                 INSERT INTO removed_visits(backup, id, url, visit_time_ms)
                   VALUES ('old', 9, 'https://gone.example/', 3);
                 PRAGMA user_version = 4;",
            )
            .unwrap();
    }
    let first: Vec<String> = {
        let store = VisitStore::open(&path).unwrap();
        let mut uids: Vec<_> = all(&store).into_iter().map(|row| row.uid).collect();
        uids.sort();
        uids
    };
    assert_eq!(first.len(), 2);
    assert!(first.iter().all(|uid| is_uid(uid)));
    assert_ne!(first[0], first[1]);
    // Opening again keeps the same ids; the removed row came back with one too.
    let store = VisitStore::open(&path).unwrap();
    let mut again: Vec<_> = all(&store).into_iter().map(|row| row.uid).collect();
    again.sort();
    assert_eq!(again, first);
    assert_eq!(store.restore("old").unwrap(), 1);
    let gone = all(&store).into_iter().find(|row| row.url == "https://gone.example/").unwrap();
    assert!(is_uid(&gone.uid));
    assert!(!first.contains(&gone.uid));
    let version: i64 = rusqlite::Connection::open(&path)
        .unwrap()
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    assert_eq!(version, 5);
    drop(store);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn rows_written_without_a_uid_get_one_from_the_trigger() {
    let dir = std::env::temp_dir().join(format!("cmux-history-uid-trigger-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("History.sqlite");
    drop(VisitStore::open(&path).unwrap());
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute("INSERT INTO visits(url, visit_time_ms) VALUES ('https://raw.example/', 5)", [])
        .unwrap();
    let store = VisitStore::open(&path).unwrap();
    let raw = all(&store).into_iter().find(|row| row.url == "https://raw.example/").unwrap();
    assert!(is_uid(&raw.uid));
    drop(store);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn imported_visits_get_their_own_ids() {
    let dir = std::env::temp_dir().join(format!("cmux-history-uid-import-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let now = 100 * 86_400_000;
    let source_path = dir.join("source.sqlite");
    let source_uid = {
        let source = VisitStore::open(&source_path).unwrap();
        let id = source.record(&visit("https://imported.example/", now - 1)).unwrap();
        source.visit(id).unwrap().unwrap().uid
    };
    let store = VisitStore::open_in_memory().unwrap();
    assert_eq!(store.import_at(&source_path, now).unwrap(), 1);
    let imported = all(&store).into_iter().next().unwrap();
    assert!(is_uid(&imported.uid));
    // An import copies into another profile's collection: a new visit there, not the same one.
    assert_ne!(imported.uid, source_uid);
    let _ = std::fs::remove_dir_all(dir);
}
