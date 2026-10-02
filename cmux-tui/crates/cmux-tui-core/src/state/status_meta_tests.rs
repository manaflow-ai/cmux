use super::*;
use rusqlite::Connection;
use serde_json::json;

fn connection() -> Connection {
    let mut connection = Connection::open_in_memory().unwrap();
    let tx = connection.transaction().unwrap();
    tx.execute_batch(
        "CREATE TABLE workspace_status_entries (workspace_id TEXT NOT NULL, status_key TEXT NOT NULL,
           text TEXT NOT NULL, PRIMARY KEY(workspace_id, status_key));",
    )
    .unwrap();
    create_status_meta_schema(&tx).unwrap();
    tx.commit().unwrap();
    connection
}

fn term(n: u8) -> String {
    format!("term_{}", format!("{n:02x}").repeat(16))
}

fn meta(fields: Value) -> StatusMeta {
    StatusMeta::from_fields(fields.as_object().unwrap()).unwrap()
}

fn put(connection: &mut Connection, workspace: &str, key: &str, value: &StatusMeta, now: u64) {
    let tx = connection.transaction().unwrap();
    tx.execute(
        "INSERT OR REPLACE INTO workspace_status_entries VALUES(?1, ?2, 't')",
        params![workspace, key],
    )
    .unwrap();
    write_meta(&tx, workspace, key, value, "mach_a", now).unwrap();
    tx.commit().unwrap();
}

#[test]
fn plain_requests_have_no_meta_and_old_callers_validate() {
    assert!(meta(json!({})).is_plain());
    assert!(meta(json!({"state": "info"})).is_plain());
    assert!(!meta(json!({"state": "busy"})).is_plain());
    meta(json!({})).validate(|_| false).unwrap();
}

#[test]
fn validation_rejects_every_malformed_field() {
    let known = term(1);
    let ok = |id: &TerminalPublicId| id.as_str() == known;
    let bad = [
        json!({"state": "spinning"}),
        json!({"state": "info", "progress": 0.5}),
        json!({"state": "busy", "progress": 1.5}),
        json!({"state": "busy", "style": "rainbow"}),
        json!({"ttl_ms": 0}),
        json!({"ttl_ms": MAX_TTL_MS + 1}),
        json!({"state": "busy", "exit_code": 1}),
        json!({"owner": {"terminal": "nope"}}),
        json!({"owner": {"terminal": term(2)}}),
        json!({"target_terminal": term(3)}),
        json!({"owner": {"agent_session": ""}}),
    ];
    for fields in bad {
        assert!(meta(fields.clone()).validate(ok).is_err(), "accepted {fields}");
    }
    assert!(StatusMeta::from_fields(json!({"owner": {"pid": 1}}).as_object().unwrap()).is_err());
    assert!(StatusMeta::from_fields(json!({"exit_code": "x"}).as_object().unwrap()).is_err());
    meta(json!({"state": "busy", "progress": 0.4, "style": "native", "ttl_ms": 30000,
                "owner": {"terminal": term(1), "pid": 4242, "agent_session": "s1"},
                "target_terminal": term(1)}))
    .validate(ok)
    .unwrap();
    meta(json!({"state": "error", "exit_code": 2, "duration_ms": 1500})).validate(ok).unwrap();
}

#[test]
fn snapshot_entries_carry_the_meta_and_plain_writes_drop_it() {
    let mut connection = connection();
    let busy = meta(json!({"state": "busy", "progress": 0.25, "ttl_ms": 1000,
                           "owner": {"pid": 77, "terminal": term(1)}}));
    put(&mut connection, "ws_a", "build", &busy, 5000);
    let mut entries = vec![json!({"key": "build", "text": "t"}), json!({"key": "plain"})];
    decorate_entries(&connection, "ws_a", &mut entries).unwrap();
    assert_eq!(entries[0]["state"], "busy");
    assert_eq!(entries[0]["progress"], 0.25);
    assert_eq!(entries[0]["expires_at_ms"], "6000");
    assert_eq!(entries[0]["owner"], json!({"pid": 77, "machine": "mach_a", "terminal": term(1)}));
    assert!(entries[1].get("state").is_none(), "plain entries stay plain");
    put(&mut connection, "ws_a", "build", &StatusMeta::default(), 7000);
    let mut entries = vec![json!({"key": "build"})];
    decorate_entries(&connection, "ws_a", &mut entries).unwrap();
    assert!(entries[0].get("state").is_none());
}

#[test]
fn each_owner_end_removes_exactly_its_entries() {
    let mut connection = connection();
    put(&mut connection, "ws_a", "a", &meta(json!({"state": "busy", "owner": {"terminal": term(1)}})), 0);
    put(&mut connection, "ws_a", "b", &meta(json!({"state": "busy", "owner": {"pid": 9}})), 0);
    put(&mut connection, "ws_b", "c", &meta(json!({"state": "success", "ttl_ms": 100})), 1000);
    put(&mut connection, "ws_b", "d", &meta(json!({"state": "busy", "ttl_ms": 5000})), 1000);
    let terminal = OwnerEnd::Terminal { terminal: term(1) };
    assert_eq!(owned_entries(&connection, &terminal).unwrap(), vec![("ws_a".into(), "a".into())]);
    let other_machine = OwnerEnd::Process { pid: 9, machine: "mach_b".into() };
    assert!(owned_entries(&connection, &other_machine).unwrap().is_empty());
    let process = OwnerEnd::Process { pid: 9, machine: "mach_a".into() };
    assert_eq!(owned_entries(&connection, &process).unwrap(), vec![("ws_a".into(), "b".into())]);
    assert_eq!(next_expiry_ms(&connection).unwrap(), Some(1100));
    let expired = owned_entries(&connection, &OwnerEnd::Expired { now_ms: 1100 }).unwrap();
    assert_eq!(expired, vec![("ws_b".into(), "c".into())]);
    let tx = connection.transaction().unwrap();
    assert_eq!(remove_entries(&tx, &expired).unwrap(), vec!["ws_b".to_string()]);
    tx.commit().unwrap();
    assert_eq!(next_expiry_ms(&connection).unwrap(), Some(6000));
    let count: i64 =
        connection.query_row("SELECT COUNT(*) FROM workspace_status_entries", [], |row| row.get(0)).unwrap();
    assert_eq!(count, 3);
    // Replaying the same removal changes nothing more (idempotent).
    let tx = connection.transaction().unwrap();
    remove_entries(&tx, &expired).unwrap();
    tx.commit().unwrap();
    assert!(owned_entries(&connection, &OwnerEnd::Expired { now_ms: 1100 }).unwrap().is_empty());
    let (terminals, pids) = live_owners(&connection, "mach_a").unwrap();
    assert_eq!((terminals, pids), (vec![term(1)], vec![9]));
}
