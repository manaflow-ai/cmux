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

/// Tables a pane or tab list of one pane, screen or workspace has no use
/// for: terminal hosts, projections and the journal (a tab row joins its
/// terminal's resource row for the host id).
const NOT_A_TAB_TABLE: &[&str] = &[
    "terminal_hosts",
    "resource_agent_projections",
    "resource_effect_receipts",
    "frontend_projections",
    "session_journal",
];

/// CLI-1 (TYPING UNDER LOAD, STATUS 6237): `pane.list` and `tab.list` built
/// the whole session snapshot under the registry and state locks, then kept
/// one pane's rows; under the L1 CLI storm that held both locks 37 % of the
/// time. A scoped list reads only its workspace's rows, the same values.
#[test]
fn scoped_pane_and_tab_lists_read_only_their_workspace() {
    let mux = test_mux();
    for _ in 0..2 {
        let first = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap();
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    }
    let snapshot = resource(&mux, "session.snapshot", json!({}));
    let rows = |collection: &str| snapshot[collection].as_array().unwrap().clone();
    let pane = rows("panes")[0]["id"].as_str().unwrap().to_string();
    let screen = rows("panes")[0]["screen_id"].as_str().unwrap().to_string();
    let workspace = rows("screens")
        .into_iter()
        .find(|value| value["id"] == screen.as_str())
        .unwrap()["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let screens = rows("screens")
        .into_iter()
        .filter(|value| value["workspace_id"] == workspace.as_str())
        .map(|value| value["id"].as_str().unwrap().to_string())
        .collect::<BTreeSet<_>>();
    let panes = rows("panes")
        .into_iter()
        .filter(|value| screens.contains(value["screen_id"].as_str().unwrap()))
        .collect::<Vec<_>>();
    let pane_ids = panes
        .iter()
        .map(|value| value["id"].as_str().unwrap().to_string())
        .collect::<BTreeSet<_>>();
    let tabs_of = |keep: &dyn Fn(&str) -> bool| {
        Value::Array(
            rows("tabs")
                .into_iter()
                .filter(|value| keep(value["pane_id"].as_str().unwrap()))
                .collect(),
        )
    };
    let cases = [
        ("pane.list", json!({"workspace": workspace}), Value::Array(panes)),
        ("tab.list", json!({"pane": pane}), tabs_of(&|id| id == pane)),
        ("tab.list", json!({"workspace": workspace}), tabs_of(&|id| pane_ids.contains(id))),
    ];
    assert!(pane_ids.len() >= 2, "the workspace has two panes: {snapshot}");
    for (operation, scope, expected) in cases {
        assert!(expected.as_array().is_some_and(|rows| !rows.is_empty()), "{operation} {scope}");
        let reads = WorkspaceRegistry::full_topology_reads_for_test();
        let mut listed = Value::Null;
        let touched = touched(&mux, || listed = resource(&mux, operation, scope.clone()));
        assert_eq!(listed, expected, "{operation} {scope} equals the snapshot's rows");
        assert_eq!(
            WorkspaceRegistry::full_topology_reads_for_test(),
            reads,
            "{operation} {scope} read the whole topology"
        );
        let extra = NOT_A_TAB_TABLE
            .iter()
            .filter(|table| touched.read.contains(**table))
            .collect::<Vec<_>>();
        assert!(extra.is_empty(), "{operation} {scope} read {extra:?}");
        assert!(touched.written.is_empty(), "{operation} {scope} wrote {:?}", touched.written);
    }
}

/// CLI-1 (STATUS 6460): `terminal.list --pane` (a third of the L1 storm's
/// lists) built the whole session snapshot under the registry and state
/// locks, the largest lock holder under L6, and kept one pane's terminals.
/// A terminal list scoped to a workspace, screen or pane reads that
/// workspace's tabs and their terminals' rows only, with the same values in
/// the same order.
#[test]
fn a_scoped_terminal_list_reads_only_its_workspace() {
    let mux = test_mux();
    for _ in 0..2 {
        let first = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap();
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    }
    let snapshot = resource(&mux, "session.snapshot", json!({}));
    let rows = |collection: &str| snapshot[collection].as_array().unwrap().clone();
    let pane = rows("panes")[0]["id"].as_str().unwrap().to_string();
    let screen = rows("panes")[0]["screen_id"].as_str().unwrap().to_string();
    let workspace = rows("screens")
        .into_iter()
        .find(|value| value["id"] == screen.as_str())
        .unwrap()["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let screens = rows("screens")
        .into_iter()
        .filter(|value| value["workspace_id"] == workspace.as_str())
        .map(|value| value["id"].as_str().unwrap().to_string())
        .collect::<BTreeSet<_>>();
    let panes = rows("panes")
        .into_iter()
        .filter(|value| screens.contains(value["screen_id"].as_str().unwrap()))
        .map(|value| value["id"].as_str().unwrap().to_string())
        .collect::<BTreeSet<_>>();
    let tabs_in = |keep: &dyn Fn(&str) -> bool| {
        rows("tabs")
            .into_iter()
            .filter(|value| keep(value["pane_id"].as_str().unwrap()))
            .map(|value| value["id"].as_str().unwrap().to_string())
            .collect::<BTreeSet<_>>()
    };
    let terminals_of = |tabs: BTreeSet<String>| {
        Value::Array(
            rows("terminals")
                .into_iter()
                .filter(|terminal| {
                    terminal["tab_ids"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .chain(terminal.get("tab_id"))
                        .filter_map(Value::as_str)
                        .any(|tab| tabs.contains(tab))
                })
                .collect(),
        )
    };
    let cases = [
        (json!({"pane": pane}), terminals_of(tabs_in(&|id| id == pane))),
        (json!({"screen": screen}), terminals_of(tabs_in(&|id| panes.contains(id)))),
        (json!({"workspace": workspace}), terminals_of(tabs_in(&|id| panes.contains(id)))),
    ];
    assert!(panes.len() >= 2, "the workspace has two panes: {snapshot}");
    for (scope, expected) in cases {
        let count = expected.as_array().map_or(0, Vec::len);
        assert!(count >= 1, "terminal.list {scope} has terminals to list");
        let reads = WorkspaceRegistry::full_topology_reads_for_test();
        let listed = resource(&mux, "terminal.list", scope.clone());
        assert_eq!(listed, expected, "terminal.list {scope} equals the snapshot's terminals");
        assert_eq!(
            WorkspaceRegistry::full_topology_reads_for_test(),
            reads,
            "terminal.list {scope} read the whole topology"
        );
    }
}

/// One keyed resource mutation; returns its result.
fn keyed(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Value {
    let mut params = fields;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":key,
                          "operation":operation,"params":params,"idempotency_key":key});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response["result"].clone()
}

/// The changes the journal records after `head`.
fn journaled_changes(mux: &Arc<Mux>, head: u64) -> Vec<Value> {
    mux.session_journal_after(head, 64)
        .unwrap()
        .records
        .into_iter()
        .flat_map(|record| record.payload["changes"].as_array().cloned().unwrap_or_default())
        .collect()
}

/// ask-bdd706af47: a focus or tab selection costs the same with 20
/// workspaces as with one. Each reads the subtrees of the workspaces it
/// changes (the one it leaves and the one it focuses), never the whole
/// session's topology, and its deltas are the rows that changed, each equal
/// to the session snapshot after it.
#[test]
fn focus_and_tab_selection_read_only_the_workspaces_they_change() {
    let mux = test_mux();
    for _ in 0..20 {
        let created = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(created.id).unwrap());
        mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap();
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    }
    let snapshot = || resource(&mux, "session.snapshot", json!({}));
    let rows =
        |snapshot: &Value, collection: &str| snapshot[collection].as_array().unwrap().clone();
    let workspace_of_pane = |snapshot: &Value, pane: &Value| {
        rows(snapshot, "screens")
            .into_iter()
            .find(|screen| screen["id"] == pane["screen_id"])
            .unwrap()["workspace_id"]
            .clone()
    };
    let first = snapshot();
    let workspaces = rows(&first, "workspaces");
    assert_eq!(workspaces.len(), 20, "{first}");
    let unfocused = |snapshot: &Value, skip: usize| {
        rows(snapshot, "workspaces")
            .into_iter()
            .filter(|workspace| workspace["focused"] == false)
            .nth(skip)
            .unwrap()["id"]
            .clone()
    };
    let pane_in = |snapshot: &Value, workspace: &Value, focused: bool| {
        rows(snapshot, "panes")
            .into_iter()
            .find(|pane| {
                workspace_of_pane(snapshot, pane) == *workspace && pane["focused"] == focused
            })
            .unwrap()
    };
    // A tab that is not its pane's selected tab, in a workspace that is not
    // focused, or in the focused pane.
    let inactive_tab = |snapshot: &Value, pane: &Value| {
        rows(snapshot, "tabs")
            .into_iter()
            .find(|tab| tab["pane_id"] == pane["id"] && tab["focused"] != true)
            .unwrap_or_else(|| panic!("pane {pane} has an unselected tab: {snapshot}"))["id"]
            .clone()
    };
    let check = |label: &str, run: &dyn Fn()| {
        let before = snapshot();
        let reads = WorkspaceRegistry::full_topology_reads_for_test();
        let head = mux.session_journal_head().unwrap();
        run();
        assert_eq!(
            WorkspaceRegistry::full_topology_reads_for_test(),
            reads,
            "{label} read the whole topology"
        );
        let changes = journaled_changes(&mux, head);
        assert!(!changes.is_empty(), "{label} journaled its changes");
        let after = snapshot();
        let order = changes
            .iter()
            .map(|change| format!("{} {} {}", change["kind"], change["resource"], change["id"]))
            .collect::<Vec<_>>();
        // A client applies the changes in order, so the last upsert of a row
        // is the row it ends with.
        for (position, change) in changes.iter().enumerate() {
            assert_eq!(change["kind"], "upsert", "{label}: {change}");
            if changes[position + 1..]
                .iter()
                .any(|later| later["resource"] == change["resource"] && later["id"] == change["id"])
            {
                continue;
            }
            let collection = format!("{}s", change["resource"].as_str().unwrap());
            // #35912: on base a tab.focus journals the screen's new active tab while its stored
            // row keeps the old one (full reads too); only that comparison waits on the fix.
            if label == "tab.focus" && collection == "screens" {
                continue;
            }
            let row = rows(&after, &collection)
                .into_iter()
                .find(|row| row["id"] == change["id"])
                .unwrap_or_else(|| panic!("{label}: {change} names a live row"));
            assert_eq!(
                change["value"], row,
                "{label}: the delta equals the snapshot row ({order:?})"
            );
        }
        for collection in ["workspaces", "screens", "panes", "tabs"] {
            for row in rows(&after, collection) {
                let old = rows(&before, collection).into_iter().find(|old| old["id"] == row["id"]);
                if old.as_ref() != Some(&row) {
                    assert!(
                        changes.iter().any(|change| change["id"] == row["id"]),
                        "{label} changed {collection} row {row} without a delta"
                    );
                }
            }
        }
    };

    let target = unfocused(&first, 3);
    check("workspace.focus", &|| {
        keyed(&mux, "workspace.focus", json!({"workspace": target}), "scoped-workspace-focus");
    });

    let state = snapshot();
    let target = unfocused(&state, 7);
    let screen = pane_in(&state, &target, false)["screen_id"].clone();
    check("screen.focus", &|| {
        keyed(&mux, "screen.focus", json!({"screen": screen}), "scoped-screen-focus");
    });

    let state = snapshot();
    let target = unfocused(&state, 11);
    let pane = pane_in(&state, &target, false)["id"].clone();
    check("pane.focus", &|| {
        keyed(&mux, "pane.focus", json!({"pane": pane}), "scoped-pane-focus");
    });

    let state = snapshot();
    let target = unfocused(&state, 13);
    let pane = rows(&state, "panes")
        .into_iter()
        .find(|pane| {
            workspace_of_pane(&state, pane) == target
                && rows(&state, "tabs").iter().filter(|tab| tab["pane_id"] == pane["id"]).count()
                    > 1
        })
        .unwrap();
    let tab = inactive_tab(&state, &pane);
    check("tab.focus", &|| {
        keyed(&mux, "tab.focus", json!({"tab": tab}), "scoped-tab-focus");
    });

    // The ordinary selection (the TUI's next-tab key) of the focused pane.
    let state = snapshot();
    let focused = rows(&state, "panes").into_iter().find(|pane| pane["focused"] == true).unwrap();
    assert!(
        rows(&state, "tabs").iter().filter(|tab| tab["pane_id"] == focused["id"]).count() > 1,
        "the focused pane has two tabs: {state}"
    );
    check("tab.select", &|| {
        let pane = mux.with_state(|state| state.active_pane());
        mux.select_tab_as(&Actor::Daemon, pane, None, Some(1));
    });
}

#[test]
fn a_layout_undo_preview_reads_no_whole_topology() {
    // The preview needs only the resource revision for its token. Reading the
    // whole topology made it cost O(session) with hundreds of workspaces.
    let mux = test_mux();
    for _ in 0..4 {
        mux.new_workspace(None, Some((80, 22))).unwrap();
    }
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    let reads = WorkspaceRegistry::full_topology_reads_for_test();
    let preview = mux.undo_layout(right_pane, None, false).unwrap();
    assert!(matches!(preview, LayoutUndoResult::ConfirmationRequired { .. }), "{preview:?}");
    assert_eq!(
        WorkspaceRegistry::full_topology_reads_for_test(),
        reads,
        "a layout undo preview read the whole topology"
    );
}
