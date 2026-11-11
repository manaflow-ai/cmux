//! DAEMON LISTS 4 (2026-11-10): `tab.list` with no scope read the state fields of each tab
//! (`extra`: pin, group, zoom and history, browser owner, conversation, relaunch) with eight
//! statements PER TAB: 20.78 ms at 826 workspaces (930 tabs) in process, where `pane.list` took
//! 2.90 ms. The list reads each of those tables one time.
//!
//! The checks: (1) a count with no clock: the list compiles the same number of statements at any
//! number of tabs, on a registry in memory and on a file registry (where the list reads the
//! read-only connection); (2) the list equals the snapshot's tabs when each state table has rows,
//! so the reader of one tab and the reader of each tab give the same fields; (3) the time of the
//! list on a file registry, as a printed row (60 workspaces by default, 826 with
//! `--include-ignored`).

use std::sync::atomic::{AtomicUsize, Ordering};

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};

use super::*;

/// A session of `workspaces` workspaces on a FILE registry, and the folder to remove after the
/// test.
fn file_session_of(name: &str, workspaces: usize) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir()
        .join(format!("cmux-session-lists-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(name, &root);
    fill(&mux, workspaces);
    assert!(
        mux.registry_connection.read_committed(|_| Ok(())).is_some(),
        "a file registry has a read-only connection"
    );
    (mux, root)
}

fn close_file_session(mux: Arc<Mux>, root: std::path::PathBuf) {
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// How many `SELECT` statements `request` compiled on the registry's connections (the registry's
/// own one and, on a file registry, the read-only one). Setting an authorizer expires each
/// prepared statement, so a cached one is compiled again and counted. The count is of compiled
/// statements: a point read for each row (`query_row`) is one for each row.
fn selects_of(mux: &Arc<Mux>, request: impl FnOnce()) -> usize {
    let count = Arc::new(AtomicUsize::new(0));
    let counter = |count: Arc<AtomicUsize>| {
        move |context: AuthContext<'_>| {
            if matches!(context.action, AuthAction::Select) {
                count.fetch_add(1, Ordering::Relaxed);
            }
            Authorization::Allow
        }
    };
    mux.registry_connection.get().authorizer(Some(counter(count.clone()))).unwrap();
    if let Some(set) = mux.registry_connection.read_committed(|connection| {
        connection.authorizer(Some(counter(count.clone())))?;
        Ok(())
    }) {
        set.unwrap();
    }
    request();
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    if let Some(cleared) = mux.registry_connection.read_committed(|connection| {
        connection.authorizer(None::<fn(AuthContext<'_>) -> Authorization>)?;
        Ok(())
    }) {
        cleared.unwrap();
    }
    count.load(Ordering::Relaxed)
}

/// The statements a `tab.list` with no scope compiles, and how many tabs it lists.
fn tab_list_statements(mux: &Arc<Mux>) -> (usize, usize) {
    let mut listed = Value::Null;
    let statements = selects_of(mux, || listed = resource(mux, "tab.list", json!({})));
    (statements, listed.as_array().map_or(0, Vec::len))
}

fn check_tab_list_statements((few, few_tabs): (usize, usize), (many, many_tabs): (usize, usize)) {
    assert!(
        few_tabs >= 4 && many_tabs >= few_tabs * 4,
        "tabs listed: {few_tabs}, then {many_tabs}"
    );
    assert!(few > 0, "the count sees the statements of the list");
    assert_eq!(
        many, few,
        "tab.list compiled {few} statements for {few_tabs} tabs and {many} for {many_tabs} tabs: \
         it reads the state fields of each tab with statements of that tab; one statement set \
         reads them for the whole list"
    );
}

/// The state fields of the tabs (`extra`) are read for the list, not for each tab: the statements
/// of a `tab.list` with no scope do not grow with the tabs.
#[test]
fn a_session_wide_tab_list_runs_one_statement_set_at_any_number_of_tabs() {
    let few = tab_list_statements(&session_of(4));
    let many = tab_list_statements(&session_of(32));
    check_tab_list_statements(few, many);
}

/// The same count on a file registry.
#[test]
fn a_session_wide_tab_list_runs_one_statement_set_on_a_file_registry() {
    let (few_mux, few_root) = file_session_of("tab-statements-few", 4);
    let (many_mux, many_root) = file_session_of("tab-statements-many", 32);
    let few = tab_list_statements(&few_mux);
    let many = tab_list_statements(&many_mux);
    close_file_session(few_mux, few_root);
    close_file_session(many_mux, many_root);
    check_tab_list_statements(few, many);
}

/// Give each state table that a tab's `extra` reads a row. Tab 0 is pinned, in a group, has zoom,
/// icon, history, an unread mark, an attention mark and a parked relaunch record. Tab 1 has a
/// frontend browser row with an owner, and a conversation. Tab 2 has an agent session (and a page
/// row: the agent session goes before it). Tab 3 has a page and a kept relaunch record. The other
/// tabs have no row. Returns the tab ids in that order.
fn give_each_state_table_a_row(mux: &Arc<Mux>) -> Vec<String> {
    let connection = mux.registry_connection.get();
    let tabs = connection
        .prepare(
            "SELECT public_id, pane_id, content_id FROM resource_tabs
             WHERE deleted_revision IS NULL ORDER BY pane_id, position",
        )
        .unwrap()
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(tabs.len() >= 5, "the session has five tabs: {tabs:?}");
    let run = |sql: &str, id: &String| {
        connection.execute(sql, [id]).unwrap_or_else(|error| panic!("{sql}: {error}"));
    };
    let (tab, pane, _) = &tabs[0];
    run("INSERT INTO tab_presentation(tab_id, pinned) VALUES(?1, 1)", tab);
    run(
        "INSERT INTO tab_groups(group_id, pane_id, name, color)
         VALUES('tgr_lists', ?1, 'group', 'blue')",
        pane,
    );
    run("INSERT INTO tab_group_members(tab_id, group_id) VALUES(?1, 'tgr_lists')", tab);
    run(
        r#"INSERT INTO tab_state(tab_id, zoom, back_json, forward_json, icon, marked_unread,
                                 attention_json)
           VALUES(?1, 1.5, '["https://back.example"]', '["https://forward.example"]', 'star', 1,
                  '{"reason":"needs you","at_ms":5,"request_id":"req_1","page":"p"}')"#,
        tab,
    );
    run("INSERT INTO kept_tabs(tab_id, cwd, on_show) VALUES(?1, '/tmp/parked', 1)", tab);
    let (_, _, content) = &tabs[1];
    run(
        "INSERT INTO frontend_browser_tabs(browser_id, engine, url, owner)
         VALUES(?1, 'webkit', 'https://example.com', 'install_lists')",
        content,
    );
    run(
        "INSERT INTO conversation_tabs(browser_id, conversation, owner)
         VALUES(?1, 'conv_1', 'local')",
        content,
    );
    let (_, _, content) = &tabs[2];
    run(
        "INSERT INTO agent_session_tabs(browser_id, host, session, harness, host_name)
         VALUES(?1, 'host_1', 'session_1', 'claude', 'mini')",
        content,
    );
    run("INSERT INTO page_tabs(browser_id, page) VALUES(?1, 'hidden')", content);
    let (tab, _, content) = &tabs[3];
    run(
        "INSERT INTO page_tabs(browser_id, page, route) VALUES(?1, 'settings', 'general')",
        content,
    );
    run("INSERT INTO kept_tabs(tab_id, cwd, on_show) VALUES(?1, '/tmp/kept', 0)", tab);
    tabs.into_iter().map(|(tab, _, _)| tab).collect()
}

/// The list's tabs carry each state field, and they are the snapshot's tabs (the snapshot reads
/// the fields of one tab at a time).
fn check_tab_list_state_fields(mux: &Arc<Mux>) {
    let ids = give_each_state_table_a_row(mux);
    let snapshot = resource(mux, "session.snapshot", json!({}));
    let listed = resource(mux, "tab.list", json!({}));
    assert_eq!(listed, snapshot["tabs"], "tab.list equals the snapshot's tabs");
    let tab = |index: usize| {
        listed
            .as_array()
            .and_then(|tabs| tabs.iter().find(|tab| tab["id"] == ids[index].as_str()))
            .unwrap_or_else(|| panic!("tab {index} is listed: {listed}"))
    };
    let first = &tab(0)["extra"];
    assert_eq!(first["pinned"], true, "{first}");
    assert_eq!(first["tab_group_id"], "tgr_lists", "{first}");
    assert_eq!(first["zoom"], 1.5, "{first}");
    assert_eq!(first["icon"], "star", "{first}");
    assert_eq!(first["marked_unread"], true, "{first}");
    assert_eq!(
        first["attention"],
        json!({"reason":"needs you","at_ms":5,"request_id":"req_1"}),
        "{first}"
    );
    assert_eq!(first["back"], json!(["https://back.example"]), "{first}");
    assert_eq!(first["forward"], json!(["https://forward.example"]), "{first}");
    assert_eq!(first["relaunch"], json!({"cwd":"/tmp/parked","on_show":true}), "{first}");
    let second = tab(1);
    assert_eq!(second["extra"]["owner"], "install_lists", "{second}");
    assert_eq!(second["extra"]["browser_profile_id"], "default", "{second}");
    assert_eq!(
        second["extra"]["conversation"],
        json!({"conversation":"conv_1","owner":"local"}),
        "{second}"
    );
    assert_eq!(second["content_kind"], "conversation", "{second}");
    let third = tab(2);
    assert_eq!(
        third["extra"]["conversation"]["agent_session"]["session"], "session_1",
        "an agent session goes before a page: {third}"
    );
    let fourth = tab(3);
    assert_eq!(
        fourth["extra"]["conversation"],
        json!({"page":"settings","route":"general"}),
        "{fourth}"
    );
    assert_eq!(fourth["extra"]["relaunch"], json!({"cwd":"/tmp/kept"}), "{fourth}");
    let fifth = tab(4);
    let names = fifth["extra"].as_object().map(|extra| extra.keys().cloned().collect::<Vec<_>>());
    assert_eq!(
        names,
        Some(vec!["name_revision".to_string(), "name_source".to_string()]),
        "a tab with no state row has no state field: {fifth}"
    );
}

#[test]
fn a_session_wide_tab_list_carries_each_state_field() {
    check_tab_list_state_fields(&session_of(4));
}

#[test]
fn a_session_wide_tab_list_carries_each_state_field_on_a_file_registry() {
    let (mux, root) = file_session_of("tab-state-fields", 4);
    check_tab_list_state_fields(&mux);
    close_file_session(mux, root);
}

/// A closed tab keeps its `tab_state` row (zoom, icon, history: only a row with no field is
/// deleted), so the table grows with each tab the person ever closed. The list holds the rows of
/// the live tabs only: its work and its memory follow the list, not the age of the session.
#[test]
fn a_session_wide_tab_list_reads_the_state_rows_of_live_tabs_only() {
    const LIVE_TABS: &str = "SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL";
    const STATE_ROW: &str = r#"INSERT INTO tab_state(tab_id, zoom, back_json)
                               VALUES(?1, 2.0, '["https://closed.example"]')"#;
    let mux = session_of(4);
    give_each_state_table_a_row(&mux);
    // Three more tabs get a state row, and then the person closes them.
    let workspace = mux.new_workspace(Some("closing".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(workspace.id).unwrap());
    let before = tab_ids(&mux, LIVE_TABS);
    let surfaces =
        (0..3).map(|_| mux.new_tab(Some(pane), None, Some((80, 24))).unwrap()).collect::<Vec<_>>();
    let opened = tab_ids(&mux, LIVE_TABS)
        .into_iter()
        .filter(|tab| !before.contains(tab))
        .collect::<Vec<_>>();
    assert_eq!(opened.len(), 3, "three tabs opened: {opened:?}");
    {
        let connection = mux.registry_connection.get();
        for tab in &opened {
            connection.execute(STATE_ROW, [tab]).unwrap();
        }
        // Rows of tabs that the registry does not know.
        for unknown in 0..40 {
            connection.execute(STATE_ROW, [format!("tab_unknown_{unknown}")]).unwrap();
        }
    }
    for surface in &surfaces {
        assert!(mux.close_surface(surface.id).unwrap());
    }
    let closed = tab_ids(
        &mux,
        "SELECT s.tab_id FROM tab_state AS s
         JOIN resource_tabs AS t ON t.public_id = s.tab_id
         WHERE t.deleted_revision IS NOT NULL",
    );
    assert_eq!(closed, opened, "a closed tab keeps its tab row (marked deleted) and its state row");
    let held =
        crate::state::values::session_tab_state_rows(&mux.registry_connection.get()).unwrap();
    assert_eq!(
        held, 1,
        "one live tab has a state row; 3 rows are of closed tabs and 40 of tabs that the registry \
         does not know: the list held {held} rows"
    );
}

/// The tab ids that `sql` selects, sorted.
fn tab_ids(mux: &Arc<Mux>, sql: &str) -> Vec<String> {
    let connection = mux.registry_connection.get();
    let mut ids = connection
        .prepare(sql)
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    ids.sort();
    ids
}

/// The time of the session-wide lists on a FILE registry, as a printed row beside the row of
/// [`check_list_cost`] (a registry in memory). The list reads the read-only connection of the
/// file; the snapshot reads the registry's own connection under its lock.
fn print_file_list_cost(workspaces: usize) {
    let start = Instant::now();
    let (mux, root) = file_session_of("list-cost", workspaces);
    let made_ms = start.elapsed().as_secs_f64() * 1000.0;
    let request = |operation: &'static str| {
        let mux = mux.clone();
        move || {
            black_box(resource(&mux, operation, json!({})));
        }
    };
    let (mut snapshot, mut terminals, mut panes, mut tabs) = (
        request("session.snapshot"),
        request("terminal.list"),
        request("pane.list"),
        request("tab.list"),
    );
    let [snapshot_ms, terminals_ms, panes_ms, tabs_ms] =
        best_ms(7, [&mut snapshot, &mut terminals, &mut panes, &mut tabs]);
    let listed = resource(&mux, "tab.list", json!({}));
    let whole = resource(&mux, "session.snapshot", json!({}));
    eprintln!(
        "session-lists FILE registry workspaces={workspaces} tabs={} made_ms={made_ms:.0} best of \
         7, ms: session.snapshot={snapshot_ms:.2} terminal.list={terminals_ms:.2} \
         pane.list={panes_ms:.2} tab.list={tabs_ms:.2}",
        listed.as_array().map_or(0, Vec::len),
    );
    close_file_session(mux, root);
    assert_eq!(listed, whole["tabs"], "tab.list equals the snapshot's tabs on a file registry");
}

#[test]
fn a_session_wide_tab_list_equals_the_snapshot_on_a_file_registry_at_60() {
    print_file_list_cost(60);
}

/// The person's session size. Run with `--include-ignored`.
#[test]
#[ignore = "826 workspaces: run with --include-ignored"]
fn a_session_wide_tab_list_equals_the_snapshot_on_a_file_registry_at_826() {
    print_file_list_cost(826);
}
