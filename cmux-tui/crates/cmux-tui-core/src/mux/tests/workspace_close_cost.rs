//! One `close-workspace` with `end_terminals` (what the app and the benches send) must not cost
//! more in a bigger session.
//!
//! Lawrence's session (2026-11-10): 826 workspaces, 858 panes, 1600 tabs, 798 terminals. One close
//! took 132 ms there against 14 ms in an empty session (33 ms at 60 workspaces), all of it under the
//! registry and state locks, so every other request waited. The close ran the full projection: one
//! read of the whole stored topology, one row check and one public value for each workspace, a
//! rebuild of every index and a decoration walk over every surface.
//!
//! Counted, not timed, at 60 and at 826 workspaces (one terminal each), for a close of the LAST
//! workspace (no workspace after it), a MIDDLE one and the FIRST one:
//! - no full topology read and no full projection;
//! - the rows written by a close of the last workspace are equal at 60 and at 826, and its SELECT
//!   statements do not grow (the flat part; see [`BACKGROUND_SELECTS`]);
//! - the index rebuild and the decoration walk do not grow.
//!
//! THE WORKSPACES AFTER THE CLOSED ONE (step 4, the stored format, is NOT done): a workspace's
//! stored `position` and its public `index` are dense, so a close changes each of the `m`
//! workspaces after the closed one.
//! - DONE, the ledger rows: a close moves the `m` stored positions with a fixed number of
//!   statements ([`POSITION_MOVE_STATEMENTS`]), asserted with a floor. Each of the `m` rows is
//!   still written two times (2 row changes for each later workspace).
//! - The journal value and the public fold value of each later workspace: their decoration (the
//!   state fields in `extra`, `state/values.rs`) is read with a fixed number of SELECT statements
//!   for all of them ([`LATER_SELECTS`]), not with statements for each one, and it is read ONE
//!   time for the two ([`STATE_FIELD_TABLES`]).
//!
//! The rows are asserted as at most `c * m`, with the `c` this test measures at 60 (a close of the
//! first workspace against a close of the last one) and prints. It is not hidden and it is not
//! flat: a close of the first workspace of 826 still writes 825 times `c` rows.
//!
//! L, NOT DONE: each committed change clones every catalog terminal to publish waiting directory
//! reports (`publish_pending_terminal_directories`). Asserted as at most one clone per live
//! terminal.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

use rusqlite::hooks::{Action, AuthAction, AuthContext, Authorization};

use super::*;
use crate::mux::resource_content::without_crosscheck;
use crate::walk_counters::walk_counts_for_test;

/// SELECT statements that a close may run more in one session than in the other for a reason that
/// is not the session's size.
///
/// The cause: the parsed sidebar document is cached in ONE slot for the whole process
/// (`state/sidebar_doc_store.rs`, `CACHE`), keyed by the registry. A daemon has one registry, so
/// its close finds the document there. `cargo test` runs every test of a filter in one process:
/// when an other test's registry took the slot, this session's close reads the document again,
/// which is 4 SELECT statements (`read_rows`: the revision in `meta`, the table check in
/// `sqlite_master`, `sidebar_sections`, `sidebar_items`). nextest runs one process for each test
/// and does not see it.
///
/// Seen on aws-m4pro-2, 2026-11-10: this test alone (with one other test in the process) counted
/// 198 SELECTs for a close of the last workspace at 60 and at 826; with the 282 tests of the
/// `close` filter in one process each close of the session of 60 counted 202, and the tables whose
/// reads differed were exactly those four (`meta` 43 against 41, `sqlite_master` 22 against 20,
/// `sidebar_sections` 1 against 0, `sidebar_items` 2 against 1). The session of 60 runs while the
/// other tests still run; the session of 826 runs after them.
///
/// The bound is 4 such reads. One statement for each workspace would add 766, so it does not hide
/// the growth this test is for. When the counts differ the test prints the tables whose reads
/// differ.
const BACKGROUND_SELECTS: u64 = 16;

/// SELECT statements that a close with workspaces after the closed one may run more than a close
/// of the last workspace, whatever the number of the later workspaces: one statement for each
/// state table that their decoration reads (7, `state/values.rs`) and 1 more that a close of the
/// last workspace does not run. With statements for each later workspace a close runs 14 for each
/// one (7 for the journal record and 7 for the public fold): 407 at 29 later workspaces, 11523 at
/// 823 (aws-m4pro-2, 2026-11-10).
const LATER_SELECTS: u64 = 8;

/// State tables that a close reads for the workspaces after the closed one only to decorate their
/// values (`state/workspace_extras.rs`). The close decorates the values ONE time and gives the same
/// values to the journal record and to the public fold: the column reads of each of these tables
/// above a close of the last workspace are those of one read of the state fields, which the test
/// measures in the same session ([`one_read_of_the_state_fields`]). A decoration for the journal
/// record and one more for the fold read each table two times.
const STATE_FIELD_TABLES: [&str; 4] =
    ["workspace_state", "workspace_kind", "workspace_agent_folder", "workspace_created_by"];

/// Statements that a close with workspaces after the closed one runs more than a close of the last
/// workspace to move their ledger positions one down: one gives each later row the negative of its
/// position, one gives it its position minus one
/// (`workspace_registry/workspace_rows_commit.rs`).
const POSITION_MOVE_STATEMENTS: u64 = 2;

/// What the registry connection ran: SELECT statements compiled (the registry prepares each
/// statement when it runs it), the statements compiled that write the ledger column
/// `workspaces.position`, rows written by table, and column reads by table (diagnostics for a
/// difference in the SELECT count; not asserted).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Sql {
    selects: u64,
    position_writes: u64,
    rows: BTreeMap<String, u64>,
    reads: BTreeMap<String, u64>,
}

impl Sql {
    fn rows_written(&self) -> u64 {
        self.rows.values().sum()
    }

    /// The tables this ran a different number of column reads on than `other`: `(table, here,
    /// there)`.
    fn reads_that_differ(&self, other: &Self) -> Vec<(String, u64, u64)> {
        let tables = self.reads.keys().chain(other.reads.keys()).collect::<BTreeSet<_>>();
        tables
            .into_iter()
            .filter_map(|table| {
                let here = self.reads.get(table).copied().unwrap_or(0);
                let there = other.reads.get(table).copied().unwrap_or(0);
                (here != there).then(|| (table.clone(), here, there))
            })
            .collect()
    }
}

#[derive(Debug, Clone)]
struct CloseCost {
    /// Workspaces after the closed one (`m`).
    later: u64,
    live_terminals: u64,
    full_reads: u64,
    full_projections: u64,
    sql: Sql,
    index_rebuild: u64,
    decoration_walk: u64,
    terminal_clones: u64,
    /// Workspace upserts and deletes (public ids) in the close's journal records.
    upserts: u64,
    deletes: Vec<String>,
    closed: String,
}

struct Arms {
    workspaces: usize,
    last: CloseCost,
    middle: CloseCost,
    first: CloseCost,
    /// What one read of the state fields of workspaces runs in this session.
    one_read: Sql,
}

fn workspace_key(index: usize) -> String {
    format!("018f6e21-7b70-7e70-8000-{index:012}")
}

/// `workspaces` workspaces with one running terminal each, the second one selected (no arm closes
/// it), and the journal's public fold seeded, as in a live session.
pub(super) fn session(workspaces: usize) -> Arc<Mux> {
    session_in(test_mux(), workspaces)
}

/// [`session`] in `mux`, a new session with a registry of the caller's choice (in memory or a
/// file).
pub(super) fn session_in(mux: Arc<Mux>, workspaces: usize) -> Arc<Mux> {
    let mut terminals = Vec::with_capacity(workspaces);
    for index in 0..workspaces {
        mux.create_empty_workspace(Some(format!("ws {index}")), Some(workspace_key(index)), None)
            .unwrap();
        let number = index + 1;
        terminals.push((
            format!("00000000000040008000{number:012x}"),
            format!("10000000000040008000{number:012x}"),
            workspace_key(index),
        ));
    }
    mux.seed_running_terminals_for_test(&terminals).unwrap();
    mux.select_workspace(Some(1), None);
    assert_eq!(mux.with_state(|state| state.active_workspace), 1, "the second workspace is active");
    let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
    let fingerprint = serde_json::json!({"operation": operation, "fixture": key});
    let expected_revision = mux.with_state(|state| state.resource_revision);
    mux.prepare_resource_effect(
        &WorkspaceMutation::daemon(key, "test").unwrap(),
        operation,
        &fingerprint,
        &serde_json::json!({}),
        None,
        Some(expected_revision),
    )
    .unwrap();
    mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
    mux.commit_full_resource_effect_projection(key, operation, &fingerprint, serde_json::json!({}))
        .unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().public_fold_seeded(),
        "the full projection did not seed the fold"
    );
    mux
}

/// Runs `request` and counts what the registry connection ran for it on this thread (the close
/// commits on its caller's thread; a background writer on the same connection is not counted).
///
/// THE LIMIT OF THE SELECT COUNT: the SQLite authorizer speaks when a statement is PREPARED, not
/// each time it runs. A read that is prepared one time and then run for each workspace, or a
/// `prepare_cached` statement that is already in the cache, counts as one or as none. So this
/// count proves "no statement is prepared for each workspace"; it does not prove "no statement
/// runs for each workspace". The batch read of the state fields uses a plain `prepare`
/// (`state/workspace_extras.rs`), so it is seen here.
fn counted(mux: &Arc<Mux>, request: impl FnOnce()) -> Sql {
    let log = Arc::new(Mutex::new(Sql::default()));
    let (selects, rows) = (log.clone(), log.clone());
    let caller = std::thread::current().id();
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            if std::thread::current().id() == caller {
                match context.action {
                    AuthAction::Select => selects.lock().unwrap().selects += 1,
                    AuthAction::Read { table_name, .. } => {
                        let mut log = selects.lock().unwrap();
                        *log.reads.entry(table_name.to_owned()).or_default() += 1;
                    }
                    // SQLite asks once for each column that a statement it compiles can set.
                    AuthAction::Update { table_name: "workspaces", column_name: "position" } => {
                        selects.lock().unwrap().position_writes += 1;
                    }
                    _ => {}
                }
            }
            Authorization::Allow
        }))
        .unwrap();
    mux.registry_connection
        .get()
        .update_hook(Some(move |_: Action, _: &str, table: &str, _: i64| {
            if std::thread::current().id() == caller {
                *rows.lock().unwrap().rows.entry(table.to_owned()).or_default() += 1;
            }
        }))
        .unwrap();
    request();
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    mux.registry_connection.get().update_hook(None::<fn(Action, &str, &str, i64)>).unwrap();
    std::mem::take(&mut *log.lock().unwrap())
}

/// Close the workspace at `index`, ending its terminal, with the debug cross-check off (as a
/// release daemon runs), and count it.
fn close(mux: &Arc<Mux>, index: usize) -> CloseCost {
    let (key, public_id, later, live_terminals) = mux.with_state(|state| {
        let workspace = &state.workspaces[index];
        (
            workspace.key.clone(),
            workspace.public_id.to_string(),
            (state.workspaces.len() - 1 - index) as u64,
            state.terminal_catalog.len() as u64,
        )
    });
    let revision = mux.with_state(|state| state.resource_revision);
    let mutation =
        WorkspaceMutation::daemon(format!("close-cost-{key}"), "close-cost-test").unwrap();
    let reads = WorkspaceRegistry::full_topology_reads_for_test();
    let projections = mux.resource_projection_stats().full_projections;
    let walks = walk_counts_for_test();
    let sql = counted(mux, || {
        without_crosscheck(|| {
            mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
        });
    });
    let walked = walk_counts_for_test();
    let mut cost = CloseCost {
        later,
        live_terminals,
        full_reads: WorkspaceRegistry::full_topology_reads_for_test() - reads,
        full_projections: mux.resource_projection_stats().full_projections - projections,
        sql,
        index_rebuild: walked.index_rebuild - walks.index_rebuild,
        decoration_walk: walked.decoration_walk - walks.decoration_walk,
        terminal_clones: walked.terminal_clones - walks.terminal_clones,
        upserts: 0,
        deletes: Vec::new(),
        closed: public_id,
    };
    for batch in mux.resource_events_after(revision).unwrap().batches {
        for change in batch.changes.as_array().cloned().unwrap_or_default() {
            if change["resource"] != "workspace" {
                continue;
            }
            if change["kind"] == "upsert" {
                cost.upserts += 1;
            } else if change["kind"] == "delete" {
                cost.deletes.push(change["id"].as_str().unwrap_or_default().to_string());
            }
        }
    }
    assert!(mux.with_state(|state| state.workspace_index_by_key(&key).is_none()));
    cost
}

/// What one read of the state fields of workspaces runs (`workspace_extras`, the read that
/// decorates the workspace values of a change batch), whatever the number of workspaces.
fn one_read_of_the_state_fields(mux: &Arc<Mux>) -> Sql {
    let id = mux.with_state(|state| state.workspaces[0].public_id.to_string());
    counted(mux, || {
        mux.read_registry_state(|connection| {
            crate::state::workspace_extras::workspace_extras(connection, &[id.as_str()])
        })
        .unwrap();
    })
}

/// The three closes in one session: the last workspace, a middle one, the first one.
fn arms(workspaces: usize) -> Arms {
    // The session is made with the debug cross-check off: with it, each create also runs a full
    // projection, and making 826 workspaces takes minutes.
    let mux = without_crosscheck(|| session(workspaces));
    let live = mux.with_state(|state| state.workspaces.len());
    let last = close(&mux, live - 1);
    let middle = close(&mux, (live - 1) / 2);
    let first = close(&mux, 0);
    eprintln!("close cost at {workspaces} workspaces, last: {last:?}");
    eprintln!("close cost at {workspaces} workspaces, middle: {middle:?}");
    eprintln!("close cost at {workspaces} workspaces, first: {first:?}");
    let one_read = one_read_of_the_state_fields(&mux);
    eprintln!("one read of the state fields at {workspaces} workspaces: {one_read:?}");
    Arms { workspaces, last, middle, first, one_read }
}

/// `cost` minus the flat part `flat`, as (SELECT statements, rows written).
fn position_part(cost: &CloseCost, flat: &CloseCost) -> (u64, u64) {
    (
        cost.sql.selects.saturating_sub(flat.sql.selects),
        cost.sql.rows_written().saturating_sub(flat.sql.rows_written()),
    )
}

#[test]
fn a_workspace_close_costs_the_same_in_a_bigger_session() {
    let small = arms(60);
    let large = arms(826);
    let mut problems = Vec::new();

    for arms in [&small, &large] {
        let closes = [("last", &arms.last), ("middle", &arms.middle), ("first", &arms.first)];
        for (name, cost) in closes {
            let at = format!("{name} workspace of {}", arms.workspaces);
            if cost.full_reads != 0 {
                problems.push(format!("{at}: {} full topology reads", cost.full_reads));
            }
            if cost.full_projections != 0 {
                problems.push(format!("{at}: {} full projections", cost.full_projections));
            }
            // The journal deletes the closed workspace only, and states again at most the
            // workspaces after it (their index changed).
            if cost.deletes != [cost.closed.clone()] {
                problems.push(format!(
                    "{at}: the journal deletes {:?}, not only {}",
                    cost.deletes, cost.closed
                ));
            }
            if cost.upserts > cost.later {
                problems.push(format!(
                    "{at}: {} workspace upserts in the journal for {} later workspaces",
                    cost.upserts, cost.later
                ));
            }
            // L, not done: one clone per live terminal at most.
            if cost.terminal_clones > cost.live_terminals {
                problems.push(format!(
                    "{at}: {} terminal clones for {} live terminals",
                    cost.terminal_clones, cost.live_terminals
                ));
            }
        }
    }

    // The flat part: a close with no workspace after it. The rows written are equal, and the
    // SELECT statements do not grow.
    eprintln!(
        "flat part (close of the last workspace): {} SELECTs and {} rows written at 60, {} SELECTs \
         and {} rows written at 826; tables whose reads differ (table, at 60, at 826): {:?}",
        small.last.sql.selects,
        small.last.sql.rows_written(),
        large.last.sql.selects,
        large.last.sql.rows_written(),
        small.last.sql.reads_that_differ(&large.last.sql),
    );
    if small.last.sql.rows != large.last.sql.rows {
        problems.push(format!(
            "the rows written by a close of the last workspace differ: {:?} at 60, {:?} at 826",
            small.last.sql.rows, large.last.sql.rows,
        ));
    }
    if large.last.sql.selects > small.last.sql.selects + BACKGROUND_SELECTS {
        problems.push(format!(
            "the SELECTs of a close of the last workspace grow with the session: {} at 60, {} at \
             826; tables whose reads differ (table, at 60, at 826): {:?}",
            small.last.sql.selects,
            large.last.sql.selects,
            small.last.sql.reads_that_differ(&large.last.sql),
        ));
    }

    // The workspaces after the closed one. Rows (step 4, not done): at most `c` rows for each one,
    // `c` as measured at 60 (rounded up to a whole number). SELECTs: a fixed number for all of
    // them.
    let (selects, rows) = position_part(&small.first, &small.last);
    let row_c = rows.div_ceil(small.first.later);
    eprintln!(
        "later workspaces: {selects} SELECTs and {rows} rows written for {} later workspaces at \
         60 = at most {row_c} rows for each one (step 4, not done); the SELECTs may be \
         {LATER_SELECTS} for all of them",
        small.first.later
    );
    let shifted = [
        ("middle of 60", &small.middle, &small.last, &small.one_read),
        ("first of 60", &small.first, &small.last, &small.one_read),
        ("middle of 826", &large.middle, &large.last, &large.one_read),
        ("first of 826", &large.first, &large.last, &large.one_read),
    ];
    for (name, cost, flat, one_read) in shifted {
        let (selects, rows) = position_part(cost, flat);
        eprintln!(
            "later workspaces, {name}: {selects} SELECTs and {rows} rows for {} later",
            cost.later
        );
        if selects > LATER_SELECTS + BACKGROUND_SELECTS {
            problems.push(format!(
                "{name}: {selects} SELECTs above the flat part for {} later workspaces; a close \
                 may run {LATER_SELECTS} for all of them (and {BACKGROUND_SELECTS} that are not \
                 the session's size)",
                cost.later
            ));
        }
        if rows > row_c * cost.later {
            problems.push(format!(
                "{name}: {rows} rows above the flat part for {} later workspaces; {row_c} for \
                 each later workspace at 60",
                cost.later
            ));
        }
        // The state fields of the later workspaces are read one time for the journal record and
        // the public fold together.
        for table in STATE_FIELD_TABLES {
            let reads = |sql: &Sql| sql.reads.get(table).copied().unwrap_or(0);
            let (above, one) = (reads(&cost.sql).saturating_sub(reads(&flat.sql)), reads(one_read));
            eprintln!(
                "state fields, {name}: {above} column reads of `{table}` above the flat part; \
                 one read of the state fields makes {one}"
            );
            if one == 0 {
                problems.push(format!(
                    "{name}: one read of the state fields made 0 column reads of `{table}`, so \
                     the authorizer saw nothing of it and the bound below proves nothing"
                ));
            }
            if above > one {
                problems.push(format!(
                    "{name}: {above} column reads of `{table}` above the flat part for {} later \
                     workspaces; one read of their state fields makes {one}",
                    cost.later
                ));
            }
        }
    }

    // J and K: the in-memory walks do not grow.
    let pairs = [
        ("last", &small.last, &large.last),
        ("middle", &small.middle, &large.middle),
        ("first", &small.first, &large.first),
    ];
    for (name, small, large) in pairs {
        if small.index_rebuild != large.index_rebuild {
            problems.push(format!(
                "{name}: the index rebuild visited {} workspaces at 60 and {} at 826",
                small.index_rebuild, large.index_rebuild
            ));
        }
        if small.decoration_walk != large.decoration_walk {
            problems.push(format!(
                "{name}: the decoration walk visited {} surfaces at 60 and {} at 826",
                small.decoration_walk, large.decoration_walk
            ));
        }
    }

    // The ledger positions of the workspaces after the closed one: a fixed number of statements
    // moves them, whatever their number (each statement that can set `workspaces.position` is
    // compiled when it runs).
    for arms in [&small, &large] {
        // The floor of the count: the statement that tombstones the closed row always sets its
        // position, so each close compiles one such statement or more.
        if arms.last.sql.position_writes == 0 {
            problems.push(format!(
                "last of {}: 0 statements write `workspaces.position`. The tombstone of the \
                 closed row always sets it, so 0 means that the authorizer saw nothing, and the \
                 bound on the statements of a middle and a first close proves nothing",
                arms.workspaces
            ));
        }
        for (name, cost) in [("middle", &arms.middle), ("first", &arms.first)] {
            eprintln!(
                "position statements, {name} of {}: {} for {} later ({} for the last one)",
                arms.workspaces,
                cost.sql.position_writes,
                cost.later,
                arms.last.sql.position_writes
            );
            if cost.sql.position_writes > arms.last.sql.position_writes + POSITION_MOVE_STATEMENTS {
                problems.push(format!(
                    "{name} of {}: {} statements write `workspaces.position` for {} later \
                     workspaces; a close of the last one runs {}",
                    arms.workspaces,
                    cost.sql.position_writes,
                    cost.later,
                    arms.last.sql.position_writes
                ));
            }
        }
    }

    assert!(
        problems.is_empty(),
        "one close-workspace grows with the session:\n{}",
        problems.join("\n")
    );
}

/// Gives the workspace at `index` a second pane (a split) and a second tab in its first pane, so
/// it is not the one-pane, one-tab workspace that [`session`] makes.
fn split_and_add_a_tab(mux: &Arc<Mux>, index: usize) {
    let pane = mux.with_state(|state| state.workspaces[index].screens[0].active_pane);
    mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap();
    mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
}

fn close_at(mux: &Arc<Mux>, index: usize) {
    let key = mux.with_state(|state| state.workspaces[index].key.clone());
    let mutation = WorkspaceMutation::daemon(format!("close-at-{key}"), "close-cost-test").unwrap();
    mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
}

/// The indexes of the live state that are not what a rebuild of every index gives now, each with
/// both forms.
fn index_differences(mux: &Arc<Mux>) -> Vec<String> {
    fn entries<K: fmt::Debug, V: fmt::Debug>(map: &HashMap<K, V>) -> BTreeSet<String> {
        map.iter().map(|(key, value)| format!("{key:?} -> {value:?}")).collect()
    }
    fn placements<K: fmt::Debug>(map: &HashMap<K, Vec<SurfaceId>>) -> BTreeSet<String> {
        map.iter()
            .map(|(key, value)| {
                let mut value = value.clone();
                value.sort_unstable();
                format!("{key:?} -> {value:?}")
            })
            .collect()
    }
    mux.with_state(|state| {
        let mut rebuilt = state.clone();
        // The split index first, then (inside it) the public indexes from the live tree.
        Mux::rebuild_split_screen_index(&mut rebuilt);
        let (live, built) = (&state.resource_indexes, &rebuilt.resource_indexes);
        let indexes = [
            ("split_screens", entries(&state.split_screens), entries(&rebuilt.split_screens)),
            ("workspaces", entries(&live.workspaces), entries(&built.workspaces)),
            ("workspace_ids", entries(&live.workspace_ids), entries(&built.workspace_ids)),
            ("screens", entries(&live.screens), entries(&built.screens)),
            ("screen_ids", entries(&live.screen_ids), entries(&built.screen_ids)),
            ("screen_workspace", entries(&live.screen_workspace), entries(&built.screen_workspace)),
            ("panes", entries(&live.panes), entries(&built.panes)),
            ("pane_ids", entries(&live.pane_ids), entries(&built.pane_ids)),
            ("pane_screen", entries(&live.pane_screen), entries(&built.pane_screen)),
            ("tabs", entries(&live.tabs), entries(&built.tabs)),
            ("tab_ids", entries(&live.tab_ids), entries(&built.tab_ids)),
            ("tab_pane", entries(&live.tab_pane), entries(&built.tab_pane)),
            ("content_ids", entries(&live.content_ids), entries(&built.content_ids)),
            (
                "content_placements",
                placements(&live.content_placements),
                placements(&built.content_placements),
            ),
            ("splits", entries(&live.splits), entries(&built.splits)),
            ("split_ids", entries(&live.split_ids), entries(&built.split_ids)),
        ];
        indexes
            .into_iter()
            .filter(|(_, live, built)| live != built)
            .map(|(name, live, built)| format!("{name}: live {live:?}, rebuilt {built:?}"))
            .collect()
    })
}

/// The public id of each live split (a split of the live tree, by the split index), `None` for one
/// that has none. The rebuild in [`index_differences`] copies these ids from the live index
/// (`State::rebuild_workspace_indexes`), so it cannot see an id that a close removed from a live
/// workspace: the test compares them with the ids before the closes.
fn live_split_public_ids(mux: &Arc<Mux>) -> BTreeMap<String, Option<String>> {
    mux.with_state(|state| {
        state
            .split_screens
            .keys()
            .map(|split| {
                let public_id = state.resource_indexes.split_ids.get(split);
                (format!("{split:?}"), public_id.map(|id| format!("{id:?}")))
            })
            .collect()
    })
}

/// The positions (workspace indexes) that the split index names.
fn split_positions(mux: &Arc<Mux>) -> BTreeSet<usize> {
    mux.with_state(|state| state.split_screens.values().map(|location| location.0).collect())
}

/// A close drops the index entries of the closed workspace and moves the split index of each
/// later workspace one position down; it does not rebuild every index (step 2). What it leaves
/// must be what the rebuild gives: for a close before workspaces that have a split, for a close
/// of a workspace that has one, and for a close of the first workspace. The cross-check is off,
/// as in a release daemon: it runs a full projection, which builds the public indexes again.
#[test]
fn a_workspace_close_leaves_the_indexes_that_a_rebuild_gives() {
    let mux = session(8);
    for index in [3, 6] {
        split_and_add_a_tab(&mux, index);
    }
    assert_eq!(split_positions(&mux), BTreeSet::from([3, 6]), "the fixture's splits");
    assert_eq!(index_differences(&mux), Vec::<String>::new(), "the fixture, before any close");
    let stated = live_split_public_ids(&mux);
    assert_eq!(stated.len(), 2, "the fixture's live splits");
    assert_eq!(stated.values().flatten().count(), 2, "the fixture: each split has a public id");
    // A live split keeps the public id that it had before the closes.
    let live_splits_keep_their_ids = |live_splits: usize, what: &str| {
        let live = live_split_public_ids(&mux);
        assert_eq!(live.len(), live_splits, "{what}: the live splits");
        for (split, public_id) in live {
            assert_eq!(Some(&public_id), stated.get(&split), "{what}: the id of split {split}");
        }
    };

    // A middle workspace before both: each split entry moves one position down.
    without_crosscheck(|| close_at(&mux, 2));
    assert_eq!(split_positions(&mux), BTreeSet::from([2, 5]), "after a close before the splits");
    assert_eq!(index_differences(&mux), Vec::<String>::new(), "after a close before the splits");
    live_splits_keep_their_ids(2, "after a close before the splits");

    // The first workspace that has a split: its entries go, the later one's move.
    without_crosscheck(|| close_at(&mux, 2));
    assert_eq!(split_positions(&mux), BTreeSet::from([4]), "after a close of a split workspace");
    assert_eq!(index_differences(&mux), Vec::<String>::new(), "after a close of a split workspace");
    live_splits_keep_their_ids(1, "after a close of a split workspace");

    // A workspace after the last split: no entry moves.
    let live = mux.with_state(|state| state.workspaces.len());
    without_crosscheck(|| close_at(&mux, live - 1));
    assert_eq!(split_positions(&mux), BTreeSet::from([4]), "after a close behind the splits");
    assert_eq!(index_differences(&mux), Vec::<String>::new(), "after a close behind the splits");
    live_splits_keep_their_ids(1, "after a close behind the splits");

    without_crosscheck(|| close_at(&mux, 0));
    assert_eq!(split_positions(&mux), BTreeSet::from([3]), "after a close of the first workspace");
    assert_eq!(index_differences(&mux), Vec::<String>::new(), "after a close of the first one");
    live_splits_keep_their_ids(1, "after a close of the first workspace");
}

/// The scoped close commits what the full projection would, in a session where two workspaces
/// have a split and a second tab: after each close a full projection of the live state finds
/// every row stored, and in a debug build the cross-check fails a close whose rows or public
/// values differ. The closes: the last workspace, a middle one before the split ones, a
/// workspace that has a split, the first one, the active one, and two after a selection that no
/// commit stored (the stored active workspace is not the live one): another workspace, then the
/// live active one.
#[test]
fn a_workspace_close_commits_what_the_full_projection_would() {
    let mux = session(12);
    for index in [4, 8] {
        split_and_add_a_tab(&mux, index);
    }
    let live = mux.with_state(|state| state.workspaces.len());
    let before = mux.resource_projection_stats();
    let close_and_compare = |index: usize, what: &str| {
        close_at(&mux, index);
        let stats = mux.resource_projection_stats();
        assert_eq!(stats.crosscheck_mismatches, 0, "closing {what}");
        let written = {
            let full = mux.resource_effect_projection().unwrap();
            let registry = mux.workspace_registry.lock().unwrap();
            let db = registry.connection.get();
            let transaction = db.unchecked_transaction().unwrap();
            crate::workspace_registry::resource_store::prune_unchanged_resource_changes(
                &transaction,
                &full.patch,
            )
            .unwrap()
        };
        assert!(
            written.changes.is_empty(),
            "the close of {what} left rows for a full projection: {written:?}"
        );
    };
    close_and_compare(live - 1, "the last workspace");
    close_and_compare(2, "a middle workspace before the split ones");
    close_and_compare(3, "a workspace that has a split and a second tab");
    close_and_compare(0, "the first workspace");
    let active = mux.with_state(|state| state.active_workspace);
    close_and_compare(active, "the active workspace");

    // A selection that no commit stored (the stored active workspace is not the live one). This
    // state is synthetic: the test writes `active_workspace` itself and names no product path
    // that leaves it. The scoped walk must then take the stored and the live active workspace
    // into its scope.
    let (selected, other) = {
        let mut state = mux.state.lock().unwrap();
        let count = state.workspaces.len();
        let selected = (state.active_workspace + 2) % count;
        state.active_workspace = selected;
        (selected, (selected + 2) % count)
    };
    close_and_compare(other, "a workspace after a selection that no commit stored");
    let selected = if other < selected { selected - 1 } else { selected };
    assert_eq!(mux.with_state(|state| state.active_workspace), selected, "the selection stays");
    {
        let mut state = mux.state.lock().unwrap();
        let count = state.workspaces.len();
        state.active_workspace = (selected + 1) % count;
    }
    let active = mux.with_state(|state| state.active_workspace);
    close_and_compare(active, "the active workspace of a selection that no commit stored");

    let closes = 7;
    assert_eq!(mux.with_state(|state| state.workspaces.len()), live - closes);
    let after = mux.resource_projection_stats();
    assert_eq!(after.scope_fallbacks, before.scope_fallbacks, "a close left its scope");
    // A release test build runs no cross-check (`crosscheck_enabled`), so it counts none.
    if cfg!(debug_assertions) {
        assert_eq!(
            after.crosschecks - before.crosschecks,
            closes as u64,
            "each close is a scoped projection compared with the full one"
        );
    }
}
