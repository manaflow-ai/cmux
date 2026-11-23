//! `terminal.get` reads that terminal's own rows, never a snapshot of the
//! whole session. The bundled screen detector reads one terminal per output
//! burst; a session-wide snapshot per read (every workspace, screen and tab,
//! each decorated from SQLite, under the projection lock) made every command
//! of a large session wait behind it, so a classic migration of 512
//! workspaces slowed with each workspace it made (O(n²)).
//!
//! `terminal.get` also reads each terminal that `terminal.list` gives: an
//! ended terminal with no tab stays a row of the list until a
//! `terminal.close`, and a client that reads each listed terminal must not
//! get `selector.not_found` for an id that the list gave.

use std::sync::atomic::{AtomicUsize, Ordering};

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

fn envelope(operation: &str, fields: Value, key: Option<&str>) -> String {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("terminal-get-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    serde_json::to_string(&envelope).unwrap()
}

fn call(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let response = handle_resource_message(mux, &envelope(operation, fields, key))
        .unwrap_or_else(|error| panic!("{operation}: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

/// The fields of a terminal value that hold still between two reads (no
/// activity clocks).
fn stable(terminal: &Value) -> Value {
    json!({
        "id": terminal["id"],
        "tab_id": terminal["tab_id"],
        "tab_ids": terminal["tab_ids"],
        "cols": terminal["cols"],
        "rows": terminal["rows"],
        "running": terminal["running"],
        "lifecycle": terminal["lifecycle"],
    })
}

#[test]
fn terminal_get_reads_no_full_topology_and_matches_the_snapshot() {
    let mux = Mux::new_for_test("terminal-get", SurfaceOptions::default());
    let mut terminals = Vec::new();
    for index in 0..4 {
        let key = format!("terminal-get-{index}");
        let created = call(
            &mux,
            "workspace.create",
            json!({"initial_content":"terminal","name":key}),
            Some(&key),
        );
        terminals.push(created["value"]["terminal_id"].as_str().unwrap().to_string());
    }
    let snapshot = call(&mux, "session.snapshot", json!({}), None);

    let reads = WorkspaceRegistry::full_topology_reads_for_test();
    let got = terminals
        .iter()
        .map(|terminal| call(&mux, "terminal.get", json!({"terminal":terminal}), None))
        .collect::<Vec<_>>();
    assert_eq!(
        WorkspaceRegistry::full_topology_reads_for_test(),
        reads,
        "terminal.get read the whole session topology"
    );

    for (terminal, value) in terminals.iter().zip(&got) {
        let listed = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|listed| listed["id"] == terminal.as_str())
            .unwrap_or_else(|| panic!("{terminal} is not in the session snapshot"));
        assert_eq!(stable(value), stable(listed), "terminal.get differs from the snapshot");
    }
    mux.shutdown();
}

/// What one request costs on the thread that runs it, as counts with no
/// clock: the `SELECT` statements it compiles on the registry's connections
/// (a point read is one statement), and how many times it takes the registry
/// lock and the session's state lock.
#[derive(Debug, PartialEq, Eq)]
struct RequestCost {
    registry_statements: usize,
    registry_lock_takes: u64,
    state_lock_takes: u64,
}

/// Runs `request` and counts its cost. Setting an authorizer expires each
/// prepared statement, so a cached one is compiled again and counted. Only
/// the statements of this thread count: the mux's background threads use the
/// same connection at their own times. The reads of the sidebar document rows
/// do not count (`sidebar_doc_store::reading_rows_on_this_thread`).
fn cost_of<R>(mux: &Arc<Mux>, request: impl FnOnce() -> R) -> (R, RequestCost) {
    let statements = Arc::new(AtomicUsize::new(0));
    let request_thread = std::thread::current().id();
    let counter = |statements: Arc<AtomicUsize>| {
        move |context: AuthContext<'_>| {
            if matches!(context.action, AuthAction::Select)
                && std::thread::current().id() == request_thread
                && !crate::state::sidebar_doc_store::reading_rows_on_this_thread()
            {
                statements.fetch_add(1, Ordering::Relaxed);
            }
            Authorization::Allow
        }
    };
    mux.registry_connection.get().authorizer(Some(counter(statements.clone()))).unwrap();
    if let Some(set) = mux.registry_connection.read_committed(|connection| {
        connection.authorizer(Some(counter(statements.clone())))?;
        Ok(())
    }) {
        set.unwrap();
    }
    let registry_locks = crate::mux::registry_locks_taken_on_this_thread();
    let state_locks = crate::mux::state_locks_taken_on_this_thread();
    let result = request();
    let cost = RequestCost {
        registry_statements: statements.load(Ordering::Relaxed),
        registry_lock_takes: crate::mux::registry_locks_taken_on_this_thread() - registry_locks,
        state_lock_takes: crate::mux::state_locks_taken_on_this_thread() - state_locks,
    };
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    if let Some(cleared) = mux.registry_connection.read_committed(|connection| {
        connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>)?;
        Ok(())
    }) {
        cleared.unwrap();
    }
    (result, cost)
}

/// An ended terminal with no tab (its process ended, its tab went, its stored
/// row stays until a `terminal.close`) is a row of `terminal.list`.
/// `terminal.get` resolved its selector in the live state only and gave
/// `selector.not_found` for that id.
///
/// The cost of that read is a count, so a change of it shows here: the check
/// that the stored row is there (two point reads, one take of the registry
/// lock), then the value from the terminal's own rows (three point reads, one
/// take of the registry lock), with no read of the whole topology.
#[test]
fn terminal_get_reads_an_ended_terminal_that_the_list_gives() {
    let mux = Mux::new_for_test(
        "terminal-get-ended",
        SurfaceOptions { command: Some(vec!["fake-shell".into()]), ..SurfaceOptions::default() },
    );
    let create = |name: &str| {
        call(
            &mux,
            "workspace.create",
            json!({"initial_content":"terminal","name":name}),
            Some(name),
        )
    };
    let ended = create("terminal-get-ended");
    let open = create("terminal-get-open");
    let ended_id = ended["value"]["terminal_id"].as_str().unwrap().to_string();
    let open_workspace = open["value"]["workspace_id"].as_str().unwrap().to_string();
    let public_id = TerminalPublicId::parse(ended_id.as_str()).unwrap();
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 23 },
        exited_at_ms: 2_345_678,
    };
    assert!(mux.persist_terminal_exit_for_test(&public_id, &exit).unwrap());
    assert!(
        mux.resource_surface_for_terminal(&public_id).is_none(),
        "the end of the process retires the terminal's runtime"
    );

    let list = call(&mux, "terminal.list", json!({}), None);
    let row = list
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == ended_id.as_str())
        .unwrap_or_else(|| panic!("terminal.list does not give the ended terminal: {list}"));
    assert_eq!(row["lifecycle"], "exited", "{row}");
    assert_eq!(row["running"], false, "{row}");
    assert_eq!(row["tab_id"], Value::Null, "{row}");
    assert_eq!(row["tab_ids"], json!([]), "{row}");

    let topology_reads = WorkspaceRegistry::full_topology_reads_for_test();
    let get = envelope("terminal.get", json!({"terminal":ended_id}), None);
    let (response, cost) = cost_of(&mux, || handle_resource_message(&mux, &get).unwrap());
    assert_eq!(
        response["ok"], true,
        "terminal.get failed for a terminal that terminal.list gives ({cost:?}): {response}"
    );
    assert_eq!(&response["result"], row, "terminal.get differs from the row of terminal.list");
    assert_eq!(
        WorkspaceRegistry::full_topology_reads_for_test(),
        topology_reads,
        "terminal.get read the whole session topology"
    );
    assert_eq!(
        cost,
        RequestCost { registry_statements: 5, registry_lock_takes: 2, state_lock_takes: 4 },
        "the cost of one terminal.get of an ended terminal with no tab"
    );

    // An ended terminal with no tab is in no workspace: a selector with a
    // parent stays a selector error.
    let nested = json!({"workspace":open_workspace,"terminal":ended_id});
    let refused = handle_resource_message(&mux, &envelope("terminal.get", nested, None)).unwrap();
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(
        refused["error"]["code"].as_str().is_some_and(|code| code.starts_with("selector.")),
        "an ended terminal with no tab answered a selector with a workspace: {refused}"
    );

    // A closed terminal is in no list, and a read of it finds nothing.
    call(&mux, "terminal.close", json!({"terminal":ended_id}), Some("terminal-get-ended-close"));
    let list = call(&mux, "terminal.list", json!({}), None);
    assert!(
        list.as_array().unwrap().iter().all(|terminal| terminal["id"] != ended_id.as_str()),
        "terminal.list gives a closed terminal: {list}"
    );
    let gone = handle_resource_message(&mux, &get).unwrap();
    assert_eq!(gone["ok"], false, "{gone}");
    assert_eq!(gone["error"]["code"], "selector.not_found", "{gone}");
    mux.shutdown();
}
