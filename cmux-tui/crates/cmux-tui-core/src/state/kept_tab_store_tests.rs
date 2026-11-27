use super::*;

/// A table an older build created gains the title column; its rows stay.
#[test]
fn kept_tab_schema_adds_the_title_column_to_an_older_table() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE kept_tabs (tab_id TEXT PRIMARY KEY NOT NULL, cwd TEXT);
                 INSERT INTO kept_tabs(tab_id, cwd) VALUES('tab_old', '/tmp');",
        )
        .unwrap();
    for _ in 0..2 {
        let transaction = connection.transaction().unwrap();
        create_kept_tab_schema(&transaction).unwrap();
        transaction.commit().unwrap();
    }
    let row = connection
        .query_row("SELECT cwd, title FROM kept_tabs WHERE tab_id = 'tab_old'", [], |row| {
            Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .unwrap();
    assert_eq!(row, (Some("/tmp".into()), None));
}

#[test]
fn kept_title_drops_empty_and_cuts_long_titles_at_a_char_boundary() {
    assert_eq!(kept_title(""), None);
    assert_eq!(kept_title("vim"), Some("vim".into()));
    let long = "é".repeat(MAX_KEPT_TAB_TITLE_BYTES);
    let cut = kept_title(&long).unwrap();
    assert!(cut.len() <= MAX_KEPT_TAB_TITLE_BYTES && cut.chars().all(|c| c == 'é'));
}
