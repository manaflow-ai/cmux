use super::*;

/// A tab_state table without the attention column gains it; a mark alone
/// keeps the row with its reason, clearing it deletes the emptied row, and
/// a closing tab drops its mark.
#[test]
fn tab_attention_column_is_added_and_cleared_by_clear_or_close() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE tab_state (tab_id TEXT PRIMARY KEY NOT NULL, zoom REAL,
                   back_json TEXT, forward_json TEXT, icon TEXT, emulation_json TEXT,
                   marked_unread INTEGER);",
        )
        .unwrap();
    for _ in 0..2 {
        let transaction = connection.transaction().unwrap();
        add_tab_attention_column(&transaction).unwrap();
        transaction.commit().unwrap();
    }
    let rows = |connection: &Connection| -> i64 {
        connection.query_row("SELECT COUNT(*) FROM tab_state", [], |row| row.get(0)).unwrap()
    };
    let mark = TabStateUpdate {
        attention: Some(Some("Confirm GitHub access".into())),
        ..Default::default()
    };
    let transaction = connection.transaction().unwrap();
    update_tab_state(&transaction, "tab_a", &mark).unwrap();
    update_tab_state(&transaction, "tab_b", &mark).unwrap();
    transaction.commit().unwrap();
    assert!(tab_has_attention(&connection, "tab_a").unwrap());
    let stored: String = connection
        .query_row("SELECT attention_json FROM tab_state WHERE tab_id = 'tab_a'", [], |row| {
            row.get(0)
        })
        .unwrap();
    let stored: Value = serde_json::from_str(&stored).unwrap();
    assert_eq!(stored["reason"], "Confirm GitHub access");
    assert!(stored["at_ms"].as_u64().is_some());
    let transaction = connection.transaction().unwrap();
    let clear = TabStateUpdate { attention: Some(None), ..Default::default() };
    update_tab_state(&transaction, "tab_a", &clear).unwrap();
    clear_closed_tab_attention(&transaction, "tab_b").unwrap();
    clear_closed_tab_attention(&transaction, "tab_never_marked").unwrap();
    transaction.commit().unwrap();
    assert!(!tab_has_attention(&connection, "tab_a").unwrap());
    assert!(!tab_has_attention(&connection, "tab_b").unwrap());
    assert_eq!(rows(&connection), 0);
}

#[test]
fn an_attention_reason_is_one_short_readable_line() {
    let with = |reason: &str| TabStateUpdate {
        attention: Some(Some(reason.to_string())),
        ..Default::default()
    };
    assert!(with("Confirm GitHub access").validate().is_ok());
    assert!(with("   ").validate().is_err());
    assert!(with("two\nlines").validate().is_err());
    assert!(with("two\u{2028}lines").validate().is_err(), "a line separator is two lines");
    assert!(with("two\u{2029}lines").validate().is_err(), "a paragraph separator is two lines");
    assert!(with(&"x".repeat(MAX_ATTENTION_REASON_BYTES + 1)).validate().is_err());
    assert!(TabStateUpdate { attention: Some(None), ..Default::default() }.validate().is_ok());
}

/// A navigation clears a mark set on another page, and only that: a mark
/// an agent sets on the new page before the navigation's commit stays,
/// which a read outside the clearing transaction could not promise.
#[test]
fn a_navigation_clears_only_a_mark_set_on_another_page() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE tab_state (tab_id TEXT PRIMARY KEY NOT NULL, zoom REAL,
                   back_json TEXT, forward_json TEXT, icon TEXT, emulation_json TEXT,
                   marked_unread INTEGER, attention_json TEXT);",
        )
        .unwrap();
    let mark = |reason: &str, page: Option<&str>| TabStateUpdate {
        attention: Some(Some(reason.into())),
        attention_page: page.map(str::to_string),
        ..Default::default()
    };
    let (a, b) = ("https://github.com/login", "https://github.com/settings");
    let transaction = connection.transaction().unwrap();
    update_tab_state(&transaction, "tab_a", &mark("Log in to GitHub", Some(a))).unwrap();
    update_tab_state(&transaction, "tab_t", &mark("Approve the prompt", None)).unwrap();
    transaction.commit().unwrap();
    let stored: String = connection
        .query_row("SELECT attention_json FROM tab_state WHERE tab_id = 'tab_a'", [], |row| {
            row.get(0)
        })
        .unwrap();
    let shown = shown_attention(&stored).unwrap();
    assert_eq!(shown["reason"], "Log in to GitHub");
    assert!(shown.get("page").is_none(), "extra.attention shows no page: {shown}");

    assert!(!tab_has_attention_off_page(&connection, "tab_a", a).unwrap());
    assert!(tab_has_attention_off_page(&connection, "tab_a", b).unwrap());
    let transaction = connection.transaction().unwrap();
    assert!(!clear_attention_off_page(&transaction, "tab_a", a).unwrap(), "same page");
    transaction.commit().unwrap();
    assert!(tab_has_attention(&connection, "tab_a").unwrap());

    // The agent marks the new page before the navigation's clear commits.
    let transaction = connection.transaction().unwrap();
    update_tab_state(&transaction, "tab_a", &mark("Approve the scopes", Some(b))).unwrap();
    assert!(!clear_attention_off_page(&transaction, "tab_a", b).unwrap(), "a stale clear");
    transaction.commit().unwrap();
    assert!(tab_has_attention(&connection, "tab_a").unwrap(), "the new page's mark stays");

    let transaction = connection.transaction().unwrap();
    assert!(clear_attention_off_page(&transaction, "tab_a", a).unwrap(), "went back to a");
    assert!(clear_attention_off_page(&transaction, "tab_t", a).unwrap(), "a mark with no page");
    assert!(!clear_attention_off_page(&transaction, "tab_never_marked", a).unwrap());
    transaction.commit().unwrap();
    assert!(!tab_has_attention(&connection, "tab_a").unwrap());
    assert!(!tab_has_attention(&connection, "tab_t").unwrap());
    let rows: i64 =
        connection.query_row("SELECT COUNT(*) FROM tab_state", [], |row| row.get(0)).unwrap();
    assert_eq!(rows, 0, "a row left with no field is deleted");
}
