//! Clock-controlled regression tests for persisted attention identities.
use super::*;

fn schema(connection: &Connection) {
    connection
        .execute_batch(
            "CREATE TABLE tab_state (tab_id TEXT PRIMARY KEY NOT NULL, zoom REAL,
         back_json TEXT, forward_json TEXT, icon TEXT, emulation_json TEXT,
         marked_unread INTEGER, attention_json TEXT);",
        )
        .unwrap();
}

fn mark(connection: &mut Connection, time: u64) -> Value {
    let transaction = connection.transaction().unwrap();
    update_tab_state_at_time(
        &transaction,
        "tab_a",
        &TabStateUpdate { attention: Some(Some("Confirm access".into())), ..Default::default() },
        time,
    )
    .unwrap();
    transaction.commit().unwrap();
    current(connection)
}

fn current(connection: &Connection) -> Value {
    let stored: Option<String> = connection
        .query_row("SELECT attention_json FROM tab_state WHERE tab_id = 'tab_a'", [], |row| {
            row.get(0)
        })
        .optional()
        .unwrap()
        .flatten();
    stored.map(|s| shown_attention(&s).unwrap()).unwrap_or(Value::Null)
}

fn clear(connection: &mut Connection, id: Option<&str>) {
    let transaction = connection.transaction().unwrap();
    let update = TabStateUpdate {
        attention: Some(None),
        attention_request_id: id.map(str::to_string),
        ..Default::default()
    };
    update.validate().unwrap();
    update_tab_state_at_time(&transaction, "tab_a", &update, 1000).unwrap();
    transaction.commit().unwrap();
}

#[test]
fn attention_request_identity_survives_fixed_clock_clear_reissue_and_rollback() {
    let mut connection = Connection::open_in_memory().unwrap();
    schema(&connection);
    let a = mark(&mut connection, 1000);
    let a_id = a["request_id"].as_str().unwrap();
    assert!(valid_attention_request_id(a_id));
    let b = mark(&mut connection, 1000);
    assert_eq!(a["at_ms"], b["at_ms"]);
    assert_ne!(a["request_id"], b["request_id"], "same time and reason is a new request");
    clear(&mut connection, Some(a_id));
    assert_eq!(current(&connection), b, "stale A must not clear B");
    clear(&mut connection, b["request_id"].as_str());
    assert!(current(&connection).is_null());
    assert_eq!(
        connection.query_row("SELECT count(*) FROM tab_state", [], |r| r.get::<_, i64>(0)).unwrap(),
        0
    );
    let c = mark(&mut connection, 1000);
    assert_ne!(c["request_id"], b["request_id"], "row deletion cannot recycle identity");
    clear(&mut connection, b["request_id"].as_str());
    assert_eq!(current(&connection), c);
    let d = mark(&mut connection, 1);
    assert_eq!(d["at_ms"], 1, "wall clock stays display-only");
    assert_ne!(d["request_id"], c["request_id"]);
    clear(&mut connection, c["request_id"].as_str());
    assert_eq!(current(&connection), d);
    clear(&mut connection, None); // legacy callers retain their unconditional API
    assert!(current(&connection).is_null());
}

#[test]
fn attention_request_identity_persists_and_legacy_backfill_is_idempotent() {
    let temp = crate::state::tests::Session::new("attention-identity");
    std::fs::create_dir_all(&temp.root).unwrap();
    let path = temp.root.join("state.sqlite");
    let original;
    {
        let mut connection = Connection::open(&path).unwrap();
        schema(&connection);
        connection
            .execute(
                "INSERT INTO tab_state(tab_id, attention_json) VALUES('tab_a', ?1)",
                [json!({"reason":"Confirm access", "at_ms":1000,"page":"https://example.com"})
                    .to_string()],
            )
            .unwrap();
        let transaction = connection.transaction().unwrap();
        add_tab_attention_column(&transaction).unwrap();
        transaction.commit().unwrap();
        original = current(&connection);
        assert!(valid_attention_request_id(original["request_id"].as_str().unwrap()));
        assert!(original.get("page").is_none());
    }
    let mut connection = Connection::open(&path).unwrap();
    let transaction = connection.transaction().unwrap();
    add_tab_attention_column(&transaction).unwrap();
    transaction.commit().unwrap();
    assert_eq!(current(&connection), original, "reopen keeps identity");
    // A rolled-back old writer still works. Re-upgrade gives its replacement
    // a new identity even though time and reason have not changed.
    connection
        .execute(
            "UPDATE tab_state SET attention_json = ?1 WHERE tab_id = 'tab_a'",
            [json!({"reason":"Confirm access", "at_ms":1000}).to_string()],
        )
        .unwrap();
    let transaction = connection.transaction().unwrap();
    add_tab_attention_column(&transaction).unwrap();
    transaction.commit().unwrap();
    let replacement = current(&connection);
    assert_ne!(replacement["request_id"], original["request_id"]);
    clear(&mut connection, original["request_id"].as_str());
    assert_eq!(current(&connection), replacement);
    clear(&mut connection, replacement["request_id"].as_str());
    assert!(current(&connection).is_null());
}
