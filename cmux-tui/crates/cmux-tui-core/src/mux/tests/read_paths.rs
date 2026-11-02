//! Read-only requests run no write, and a request that needs one
//! collection reads only that collection's tables (#27698 lock work: every
//! read holds the workspace registry lock, which writes hold across their
//! commits, so a read's extra work is everyone's wait).

use std::collections::BTreeSet;

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use serde_json::{Value, json};
use std::sync::Mutex;

use super::*;

fn resource(mux: &Arc<Mux>, operation: &str, fields: Value) -> Value {
    let mut params = fields;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                          "operation":operation,"params":params});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response["result"].clone()
}

#[derive(Debug, Default)]
struct Touched {
    read: BTreeSet<String>,
    written: BTreeSet<String>,
}

/// Runs `request` with an authorizer on the registry connection that
/// records the tables its statements read and write. Setting an authorizer
/// expires every prepared statement, so cached ones are prepared again and
/// seen too.
fn touched(mux: &Arc<Mux>, request: impl FnOnce()) -> Touched {
    let log = Arc::new(Mutex::new(Touched::default()));
    let sink = log.clone();
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            let mut log = sink.lock().unwrap();
            match context.action {
                AuthAction::Read { table_name, .. } => {
                    log.read.insert(table_name.to_owned());
                }
                AuthAction::Insert { table_name }
                | AuthAction::Delete { table_name }
                | AuthAction::Update { table_name, .. } => {
                    log.written.insert(table_name.to_owned());
                }
                _ => {}
            }
            Authorization::Allow
        }))
        .unwrap();
    request();
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    std::mem::take(&mut *log.lock().unwrap())
}

fn insert_stale_read_mark(mux: &Mux) {
    mux.registry_connection
        .get()
        .execute(
            "INSERT INTO resource_notification_reads(
               notification_id, client_id, read_at_ms, committed_revision
             ) VALUES('ntf_long_gone', 'client', 1, 1)",
            [],
        )
        .unwrap();
}

fn read_mark_count(mux: &Mux) -> i64 {
    mux.registry_connection
        .get()
        .query_row("SELECT COUNT(*) FROM resource_notification_reads", [], |row| row.get(0))
        .unwrap()
}

/// A read runs under the registry lock; a write in it (the snapshot
/// deleted read marks of notifications outside the retained window) makes
/// every other request wait for a write it did not ask for.
#[test]
fn a_session_snapshot_read_runs_no_write() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    insert_stale_read_mark(&mux);

    let mut snapshot = Value::Null;
    let touched = touched(&mux, || snapshot = resource(&mux, "session.snapshot", json!({})));

    assert!(touched.written.is_empty(), "session.snapshot wrote {:?}", touched.written);
    assert_eq!(snapshot["workspaces"].as_array().map(Vec::len), Some(1), "{snapshot}");
    assert!(
        snapshot["notifications"].as_array().is_some_and(Vec::is_empty),
        "a stale read mark names no notification: {snapshot}"
    );
}

/// The read marks a read no longer deletes are dropped when the registry
/// opens, so the table stays bounded across restarts.
#[test]
fn opening_the_registry_drops_read_marks_outside_the_retained_window() {
    let session = "read-marks-at-open";
    let root = std::env::temp_dir()
        .join(format!("cmux-read-marks-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    mux.new_workspace(None, Some((80, 24))).unwrap();
    insert_stale_read_mark(&mux);
    assert_eq!(read_mark_count(&mux), 1);
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux(session, &root);
    assert_eq!(read_mark_count(&reopened), 0, "the open keeps a stale read mark");
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}

/// Tables a workspace list or a session ping has no use for: the topology
/// below workspaces, terminals, projections and the journal.
const NOT_A_WORKSPACE_TABLE: &[&str] = &[
    "resource_screens",
    "resource_panes",
    "resource_tabs",
    "resource_browsers",
    "resource_terminals",
    "terminal_hosts",
    "resource_agent_projections",
    "resource_effect_receipts",
    "frontend_projections",
    "session_journal",
];

/// `workspace.list`, the list agents' CLI calls make most, built the whole
/// session snapshot (every table above) and kept its workspaces.
#[test]
fn workspace_list_reads_only_workspace_tables() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let expected = resource(&mux, "session.snapshot", json!({}))["workspaces"].clone();

    let mut listed = Value::Null;
    let touched = touched(&mux, || {
        listed = resource(&mux, "workspace.list", json!({"order": "session"}));
    });

    assert_eq!(listed, expected, "workspace.list equals the snapshot's workspaces");
    let extra = NOT_A_WORKSPACE_TABLE
        .iter()
        .filter(|table| touched.read.contains(**table))
        .collect::<Vec<_>>();
    assert!(extra.is_empty(), "workspace.list read {extra:?}");
    assert!(touched.written.is_empty(), "workspace.list wrote {:?}", touched.written);
}

/// `session.ping` answers the snapshot's cursor; it built the whole
/// snapshot for it.
#[test]
fn session_ping_reads_only_the_topology_frame() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let expected = resource(&mux, "session.snapshot", json!({}))["cursor"].clone();

    let mut ping = Value::Null;
    let touched = touched(&mux, || ping = resource(&mux, "session.ping", json!({})));

    assert_eq!(ping["cursor"], expected, "{ping}");
    let extra = NOT_A_WORKSPACE_TABLE
        .iter()
        .chain(&["workspaces"])
        .filter(|table| touched.read.contains(**table))
        .collect::<Vec<_>>();
    assert!(extra.is_empty(), "session.ping read {extra:?}");
}
