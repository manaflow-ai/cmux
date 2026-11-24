use super::*;

#[test]
fn named_rows_are_read_with_their_originator() {
    let dir = tempfile::tempdir().unwrap();
    let conn = rusqlite::Connection::open(dir.path().join("state_5.sqlite")).unwrap();
    conn.execute_batch(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0, cli_version TEXT NOT NULL DEFAULT '',
                name TEXT, originator TEXT);
             INSERT INTO threads VALUES ('t1', '/w', 'fix it', 0, '0.164.0', NULL, 'codex_desktop');
             INSERT INTO threads VALUES ('t2', '/w', 'other', 1, '', 'named', 'codex_exec');",
    )
    .unwrap();
    drop(conn);
    let rows = thread_rows(dir.path(), &["t1".into(), "t2".into(), "gone".into()]);
    let t1 = rows.iter().find(|r| r.id == "t1").unwrap();
    assert_eq!(t1.originator.as_deref(), Some("codex_desktop"));
    assert_eq!(t1.cwd.as_deref(), Some("/w"));
    assert_eq!(t1.title.as_deref(), Some("fix it"));
    assert_eq!(t1.cli_version.as_deref(), Some("0.164.0"));
    assert!(!t1.archived);
    let t2 = rows.iter().find(|r| r.id == "t2").unwrap();
    assert_eq!(t2.name.as_deref(), Some("named"));
    assert_eq!((t2.cli_version.as_deref(), t2.archived), (None, true));
    assert_eq!(rows.len(), 2);
}

#[test]
fn a_database_older_than_the_originator_column_reads_it_as_none() {
    let dir = tempfile::tempdir().unwrap();
    let conn = rusqlite::Connection::open(dir.path().join("state_5.sqlite")).unwrap();
    conn.execute_batch(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL);
             INSERT INTO threads VALUES ('t1', '/w', 'x');",
    )
    .unwrap();
    drop(conn);
    let rows = thread_rows(dir.path(), &["t1".into()]);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].originator, None);
    assert!(thread_rows(dir.path(), &[]).is_empty());
    assert!(thread_rows(&dir.path().join("missing"), &["t1".into()]).is_empty());
}
