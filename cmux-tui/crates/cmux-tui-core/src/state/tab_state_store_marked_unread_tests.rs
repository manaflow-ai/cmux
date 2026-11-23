use super::*;

/// A tab_state table without the marked_unread column gains it; a mark
/// alone keeps the row, and clearing it deletes the emptied row. The later
/// attention column (tab-attention-v1) is added too, as the migration
/// does: an update writes every column.
#[test]
fn tab_marked_unread_column_is_added_and_an_empty_row_is_dropped() {
    let mut connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE tab_state (tab_id TEXT PRIMARY KEY NOT NULL, zoom REAL,
                   back_json TEXT, forward_json TEXT, icon TEXT, emulation_json TEXT);",
        )
        .unwrap();
    for _ in 0..2 {
        let transaction = connection.transaction().unwrap();
        add_tab_marked_unread_column(&transaction).unwrap();
        add_tab_attention_column(&transaction).unwrap();
        transaction.commit().unwrap();
    }
    let count = |connection: &Connection| -> i64 {
        connection
            .query_row("SELECT COUNT(*) FROM tab_state WHERE marked_unread = 1", [], |row| {
                row.get(0)
            })
            .unwrap()
    };
    let transaction = connection.transaction().unwrap();
    let mark = TabStateUpdate { marked_unread: Some(true), ..Default::default() };
    update_tab_state(&transaction, "tab_a", &mark).unwrap();
    transaction.commit().unwrap();
    assert_eq!(count(&connection), 1);
    let transaction = connection.transaction().unwrap();
    let clear = TabStateUpdate { marked_unread: Some(false), ..Default::default() };
    update_tab_state(&transaction, "tab_a", &clear).unwrap();
    transaction.commit().unwrap();
    let rows: i64 =
        connection.query_row("SELECT COUNT(*) FROM tab_state", [], |row| row.get(0)).unwrap();
    assert_eq!(rows, 0);
}
