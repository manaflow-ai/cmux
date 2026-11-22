//! A workspace create that fails leaves no half-created workspace: the
//! workspace and its first terminal become visible together, or the
//! workspace is rolled back (live report: "new workspace: create-terminal
//! failed: …" left an empty workspace in the sidebar).

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource_api::public_session_snapshot;

fn parsed_request(operation: &str, fields: Value, idempotency_key: &str) -> ParsedResourceRequest {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
        "idempotency_key":idempotency_key,
    });
    parse_resource_request(&serde_json::to_string(&envelope).unwrap()).unwrap()
}

#[test]
fn a_create_whose_commit_fails_leaves_no_workspace_or_terminal() {
    let mux = Mux::new_for_test("partial-create", SurfaceOptions::default());
    let workspaces = |mux: &Mux| mux.with_state(|state| state.workspaces.len());
    let terminals = |mux: &Mux| mux.with_state(|state| state.terminal_catalog.len());
    let public =
        |mux: &Mux| public_session_snapshot(mux).unwrap()["workspaces"].as_array().unwrap().len();
    let (before_workspaces, before_terminals, before_public) =
        (workspaces(&mux), terminals(&mux), public(&mux));
    // Both projection attempts of the create fail, after the workspace row
    // and the terminal were committed.
    mux.set_resource_patch_failures_remaining_for_test(2);
    let created = topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            json!({"initial_content":"terminal","name":"partial","correlation_key":"partial-correlation"}),
            "partial-create",
        ),
    );
    assert!(created.is_err(), "a create whose commit failed reported success: {created:?}");
    assert_eq!(workspaces(&mux), before_workspaces, "a half-created workspace stayed in memory");
    assert_eq!(terminals(&mux), before_terminals, "the failed create left its terminal running");
    assert_eq!(public(&mux), before_public);
    // The failure is the settled outcome: the same request replays it.
    let replay = topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            json!({"initial_content":"terminal","name":"partial","correlation_key":"partial-correlation"}),
            "partial-create",
        ),
    );
    assert!(replay.is_err(), "the replay of a failed create succeeded: {replay:?}");
    // Settled as a failure, not left indeterminate.
    let resolution = mux.resource_creation_resolution("partial-correlation").unwrap();
    assert_eq!(resolution["state"], "not_applied", "{resolution}");
    assert_eq!(workspaces(&mux), before_workspaces);
    mux.shutdown();
}

/// Every later write to the registry fails the way SQLite fails on a full
/// disk: a temp trigger on each table refuses each INSERT, UPDATE and DELETE
/// with "database or disk is full". The registry has one connection, so the
/// triggers cover every write the daemon makes from now on.
fn fill_the_disk(mux: &Mux) {
    let registry = mux.workspace_registry.lock().unwrap();
    let tables = registry
        .query_text_for_test(
            "SELECT group_concat(name, char(10)) FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
               AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'",
        )
        .unwrap();
    let mut refused = 0;
    for (index, table) in tables.lines().enumerate() {
        for (kind, event) in [("i", "INSERT"), ("u", "UPDATE"), ("d", "DELETE")] {
            let sql = format!(
                "CREATE TEMP TRIGGER cmux_test_disk_full_{kind}{index} BEFORE {event} ON \"{table}\"
                 BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END;"
            );
            // An FTS shadow table can refuse a trigger; its writes come from
            // its virtual table, whose other shadow tables still refuse.
            if registry.execute_sql_for_test(&sql).is_ok() {
                refused += 1;
            }
        }
    }
    assert!(refused > 0, "no registry table took a disk-full trigger: {tables}");
}

fn free_the_disk(mux: &Mux) {
    let registry = mux.workspace_registry.lock().unwrap();
    let triggers = registry
        .query_text_for_test(
            "SELECT coalesce(group_concat(name, char(10)), '') FROM sqlite_temp_master
             WHERE type = 'trigger' AND name LIKE 'cmux_test_disk_full_%'",
        )
        .unwrap();
    for trigger in triggers.lines() {
        registry.execute_sql_for_test(&format!("DROP TRIGGER IF EXISTS temp.{trigger}")).unwrap();
    }
}

fn listed_workspace_names(mux: &Arc<Mux>) -> Vec<String> {
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"test-workspace.list",
        "operation":"workspace.list",
        "params":{"machine":"current","session":"current"},
    });
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("workspace.list failed: {error:?}"));
    assert_eq!(response["ok"], true, "workspace.list failed: {response}");
    response["result"]
        .as_array()
        .unwrap_or_else(|| panic!("workspace.list returned no array: {response}"))
        .iter()
        .map(|workspace| workspace["name"].as_str().unwrap_or_default().to_string())
        .collect()
}

/// The workspaces of the `list-workspaces` tree: the reply the app reads at
/// launch and at every reconnect (and the launch snapshot stores).
fn app_tree_workspace_names(mux: &Mux) -> Vec<String> {
    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["name"].as_str().unwrap_or_default().to_string())
        .collect()
}

/// Where the disk fills during a terminal-backed `workspace.create`.
#[derive(Clone, Copy, Debug)]
enum DiskFillsAfter {
    /// The workspace row, before the terminal's reservation: the
    /// workspace has no tab (the fuzz run's ghost had none).
    WorkspaceRow,
    /// The terminal's reservation, before it is running.
    TerminalReservation,
    /// The terminal is running, before its surface joins the
    /// workspace: the projection that publishes the creation fails.
    TerminalReady,
}

fn set_fill_hook(mux: &Arc<Mux>, point: DiskFillsAfter, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
    match point {
        DiskFillsAfter::WorkspaceRow => {
            mux.set_terminal_create_after_workspace_reservation_hook_for_test(hook);
        }
        DiskFillsAfter::TerminalReservation => {
            mux.set_resource_terminal_reservation_hook_for_test(
                hook.map(|hook| -> Arc<dyn Fn(&str) + Send + Sync> { Arc::new(move |_| hook()) }),
            );
        }
        DiskFillsAfter::TerminalReady => mux.set_terminal_ready_hook_for_test(hook),
    }
}

/// What the refused request creates.
#[derive(Clone, Copy, Debug)]
enum RefusedCreate {
    /// `workspace.create` with its first terminal.
    Workspace,
    /// `tab.create_terminal` in the existing workspace's pane.
    Tab,
    /// `pane.split` of the existing workspace's pane.
    Split,
}

/// The counts a refused create must leave as they were.
#[derive(Debug, PartialEq, Eq)]
struct TopologyCounts {
    workspaces: usize,
    panes: usize,
    tabs: usize,
    terminals: usize,
}

/// The store's public projection: what `workspace.list`, `pane.list` and
/// `tab.list` read.
fn public_counts(mux: &Mux) -> TopologyCounts {
    let snapshot = public_session_snapshot(mux).unwrap();
    let count = |collection: &str| snapshot[collection].as_array().map_or(0, Vec::len);
    TopologyCounts {
        workspaces: count("workspaces"),
        panes: count("panes"),
        tabs: count("tabs"),
        terminals: count("terminals"),
    }
}

/// The mux state: what the `list-workspaces` tree (the app's source) reads.
fn memory_counts(mux: &Mux) -> TopologyCounts {
    mux.with_state(|state| TopologyCounts {
        workspaces: state.workspaces.len(),
        panes: state.panes.len(),
        tabs: state.surfaces.len(),
        terminals: state.terminal_catalog.len(),
    })
}

/// Whether `removal` takes away what `add` showed.
fn undoes(removal: &crate::TreeDelta, add: &crate::TreeDelta) -> bool {
    use crate::TreeDeltaKind as Kind;
    match removal.kind {
        Kind::WorkspaceClosed => removal.workspace == add.workspace,
        Kind::ScreenClosed => removal.screen.is_some() && removal.screen == add.screen,
        Kind::PaneClosed => removal.pane.is_some() && removal.pane == add.pane,
        Kind::TabClosed => removal.surface.is_some() && removal.surface == add.surface,
        _ => false,
    }
}

/// One refused create; returns what is wrong, empty when nothing is.
fn refused_create_problems(create: RefusedCreate, point: DiskFillsAfter) -> Vec<String> {
    let case = format!("{create:?} at {point:?}");
    let mux = Mux::new_for_test("diskfull-create", SurfaceOptions::default());
    // The fuzz run made one workspace before the disk filled.
    let before = topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            json!({"initial_content":"terminal","name":"before"}),
            "diskfull-before",
        ),
    )
    .unwrap();
    let pane = before["value"]["pane_id"].as_str().unwrap().to_string();
    let (public_before, memory_before) = (public_counts(&mux), memory_counts(&mux));
    let listed_before = listed_workspace_names(&mux);
    let events = mux.subscribe();
    let filled = Arc::new(std::sync::atomic::AtomicBool::new(false));
    set_fill_hook(
        &mux,
        point,
        Some(Arc::new({
            let mux = Arc::downgrade(&mux);
            let filled = Arc::clone(&filled);
            move || {
                if !filled.swap(true, std::sync::atomic::Ordering::AcqRel) {
                    fill_the_disk(&mux.upgrade().unwrap());
                }
            }
        })),
    );

    let (operation, fields) = match create {
        RefusedCreate::Workspace => {
            ("workspace.create", json!({"initial_content":"terminal","name":"ghost"}))
        }
        RefusedCreate::Tab => ("tab.create_terminal", json!({"pane":pane})),
        RefusedCreate::Split => ("pane.split", json!({"pane":pane,"direction":"right"})),
    };
    let created = topology::dispatch(&mux, parsed_request(operation, fields, "diskfull-ghost"));
    set_fill_hook(&mux, point, None);
    if !filled.load(std::sync::atomic::Ordering::Acquire) {
        mux.shutdown();
        return vec![format!("{case}: the disk never filled")];
    }
    let mut problems = Vec::new();
    // (e) The caller learns why: the store's own reason, not an internal one.
    match &created {
        Ok(value) => {
            problems.push(format!("{case} (e): a create on a full disk succeeded: {value}"));
        }
        Err(error) => {
            eprintln!("{case}: refused create: {error:?}");
            if error.code != "operation.failed" || !error.message.contains("disk is full") {
                problems.push(format!(
                    "{case} (e): the caller's error does not say the disk is full: {error:?}"
                ));
            }
        }
    }

    // (a) The store's public projection (`workspace.list`, `tab.list`).
    let listed = listed_workspace_names(&mux);
    let public_after = public_counts(&mux);
    // (b) The tree the app reads (`list-workspaces`): the mux state.
    let tree = app_tree_workspace_names(&mux);
    let memory_after = memory_counts(&mux);
    // (c) The event stream the app subscribes to: each add has its removal,
    // and a tree resync follows (the app drops a delta that does not advance
    // its revision and recovers on the resync).
    let mut adds = Vec::new();
    let mut removals = Vec::new();
    let mut resynced_after_add = false;
    while let Ok(event) = events.try_recv() {
        match event {
            crate::MuxEvent::TreeDelta(delta) => match delta.kind {
                crate::TreeDeltaKind::WorkspaceAdded
                | crate::TreeDeltaKind::ScreenAdded
                | crate::TreeDeltaKind::PaneAdded
                | crate::TreeDeltaKind::TabAdded => adds.push(delta),
                crate::TreeDeltaKind::WorkspaceClosed
                | crate::TreeDeltaKind::ScreenClosed
                | crate::TreeDeltaKind::PaneClosed
                | crate::TreeDeltaKind::TabClosed => removals.push(delta),
                _ => {}
            },
            crate::MuxEvent::TreeChanged if !adds.is_empty() => resynced_after_add = true,
            _ => {}
        }
    }
    free_the_disk(&mux);

    if listed != listed_before || public_after != public_before {
        problems.push(format!(
            "{case} (a): the store's projection changed: {listed_before:?} {public_before:?} -> \
             {listed:?} {public_after:?}"
        ));
    }
    if tree.iter().any(|name| name == "ghost") || memory_after != memory_before {
        problems.push(format!(
            "{case} (b): the app's list-workspaces tree has what the store refused: {tree:?} \
             {memory_before:?} -> {memory_after:?} (workspace.list: {listed:?})"
        ));
    }
    for add in &adds {
        if !removals.iter().any(|removal| undoes(removal, add)) {
            problems.push(format!(
                "{case} (c): the event stream announced {:?} (workspace {}, pane {:?}, tab {:?}) \
                 and never its removal",
                add.kind, add.workspace, add.pane, add.surface
            ));
        }
    }
    if !adds.is_empty() && !resynced_after_add {
        problems.push(format!("{case} (c): no tree resync followed the refused create's adds"));
    }
    mux.shutdown();
    problems
}

/// Fuzz finding restore h1 (STATUS 3083, build feat d1f0e63691a0): with the
/// daemon's state directory on a full disk, `cmux workspace create --name X`
/// answers `operation.failed` "database or disk is full" and `workspace list`
/// has no X, but the app shows X (no tabs), also after a relaunch against the
/// same daemon. A refused create must leave nothing behind: not in the
/// store's projection, not in the tree the app reads, and the event stream
/// must not announce it without its removal. The caller's error says the
/// disk is full. The disk fills at each step of a workspace create, and
/// after a tab's or a split's terminal is running (review of #30268, R1).
#[test]
fn a_create_refused_for_a_full_disk_leaves_no_workspace_for_the_app() {
    let cases = [
        (RefusedCreate::Workspace, DiskFillsAfter::WorkspaceRow),
        (RefusedCreate::Workspace, DiskFillsAfter::TerminalReservation),
        (RefusedCreate::Workspace, DiskFillsAfter::TerminalReady),
        (RefusedCreate::Tab, DiskFillsAfter::TerminalReady),
        (RefusedCreate::Split, DiskFillsAfter::TerminalReady),
    ];
    let problems = cases
        .into_iter()
        .flat_map(|(create, point)| refused_create_problems(create, point))
        .collect::<Vec<_>>();
    assert!(problems.is_empty(), "a refused create left a ghost:\n{}", problems.join("\n"));
}
