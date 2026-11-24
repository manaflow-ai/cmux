use super::*;

fn titles(db: &Path) -> Vec<Option<String>> {
    query_threads(db).unwrap().into_iter().map(|entry| entry.title).collect()
}

/// A prompt rewritten to the same length with no time bump is the one change a row's key
/// misses: the whole table is read again once [`FULL_AFTER`] has passed since the last whole
/// read.
#[test]
fn a_same_length_rewrite_shows_after_the_full_read_bound() {
    let home = tempfile::tempdir().unwrap();
    let db = home.path().join("state_5.sqlite");
    let conn = Connection::open(&db).unwrap();
    conn.execute_batch(
        "create table threads (id text primary key, title text, updated_at_ms integer);
             insert into threads values ('a', 'first title', 1);",
    )
    .unwrap();
    assert_eq!(titles(&db), vec![Some("first title".to_owned())]);
    conn.execute("update threads set title = 'other title'", []).unwrap();
    assert_eq!(titles(&db), vec![Some("first title".to_owned())], "the key did not change");

    let root = db.parent().unwrap().to_path_buf();
    if let Some(known) = KNOWN.lock().unwrap().get_mut(&root) {
        known.full_at = Instant::now().checked_sub(FULL_AFTER).unwrap();
    }
    assert_eq!(titles(&db), vec![Some("other title".to_owned())]);
}
