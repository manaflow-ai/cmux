//! Closed-history rows written before `strip_url` learned a privacy rule
//! keep the secret until something rewrites them: the store scrubs them
//! once when it opens (`closed_history_privacy::scrub_closed_groups`).

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::closed_history_store::create_closed_history_schema;

/// A store as an older daemon left it: closed groups, no scrub yet.
fn old_store() -> Connection {
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE closed_groups (
               seq INTEGER PRIMARY KEY AUTOINCREMENT,
               closed_id TEXT UNIQUE NOT NULL,
               kind TEXT NOT NULL CHECK(kind IN ('tab','screen','workspace')),
               window_id TEXT,
               closed_at_ms INTEGER NOT NULL CHECK(closed_at_ms >= 0),
               record_json TEXT NOT NULL
             );",
        )
        .unwrap();
    connection
}

fn insert(connection: &Connection, closed_id: &str, url: &str, history: &str) {
    let record = json!({
        "id": closed_id,
        "kind": "tab",
        "members": [{
            "kind": "tab",
            "screens": [{"name": null, "tabs": [{
                "kind": "browser",
                "url": url,
                "browser_history": history,
            }]}],
        }],
    });
    connection
        .execute(
            "INSERT INTO closed_groups(closed_id, kind, closed_at_ms, record_json)
             VALUES(?1, 'tab', 1, ?2)",
            params![closed_id, record.to_string()],
        )
        .unwrap();
}

fn stored_tab(connection: &Connection, closed_id: &str) -> Value {
    let record: String = connection
        .query_row(
            "SELECT record_json FROM closed_groups WHERE closed_id = ?1",
            [closed_id],
            |row| row.get(0),
        )
        .unwrap();
    let record: Value = serde_json::from_str(&record).unwrap();
    record["members"][0]["screens"][0]["tabs"][0].clone()
}

fn open(connection: &mut Connection) {
    let transaction = connection.transaction().unwrap();
    create_closed_history_schema(&transaction).unwrap();
    transaction.commit().unwrap();
}

#[test]
fn strip_url_scrub_rewrites_closed_rows_written_before_it() {
    let mut connection = old_store();
    insert(
        &connection,
        "closed-1",
        "https://u:p@a.example/#/cb?code=abc&x=1",
        r#"{"entries":[{"url":"https://a.example/p?a=1;token=s"}]}"#,
    );
    insert(&connection, "closed-2", "https://a.example/plain", r#"{"entries":[]}"#);

    open(&mut connection);

    let tab = stored_tab(&connection, "closed-1");
    assert_eq!(tab["url"], "https://a.example/#/cb?x=1");
    assert_eq!(tab["browser_history"], r#"{"entries":[{"url":"https://a.example/p?a=1"}]}"#);
    let plain = stored_tab(&connection, "closed-2");
    assert_eq!(plain["url"], "https://a.example/plain");
    assert_eq!(plain["browser_history"], r#"{"entries":[]}"#);
}

/// The scrub runs once: a later open does not walk every row again.
#[test]
fn strip_url_scrub_runs_once_per_store() {
    let mut connection = old_store();
    open(&mut connection);
    // Rows a current daemon writes are stripped as they are written; one
    // inserted raw here shows the second open leaves the table alone.
    insert(&connection, "closed-late", "https://u:p@a.example/", r#"{"entries":[]}"#);
    open(&mut connection);
    assert_eq!(stored_tab(&connection, "closed-late")["url"], "https://u:p@a.example/");
}

/// A scrub that cannot run never keeps the store from opening: the daemon
/// starts, the rows stay as they were, and the next open tries again.
#[test]
fn strip_url_scrub_failure_does_not_fail_the_store_open() {
    let mut connection = old_store();
    // A scrub table this release cannot read (no `version` column).
    connection.execute_batch("CREATE TABLE closed_history_scrub (other TEXT);").unwrap();
    insert(&connection, "closed-1", "https://u:p@a.example/", r#"{"entries":[]}"#);

    let transaction = connection.transaction().unwrap();
    create_closed_history_schema(&transaction).expect("the store opens without its scrub");
    transaction.commit().unwrap();
    assert_eq!(stored_tab(&connection, "closed-1")["url"], "https://u:p@a.example/");
}
