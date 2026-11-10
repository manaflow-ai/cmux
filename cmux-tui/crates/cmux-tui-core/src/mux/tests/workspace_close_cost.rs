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
//! STEP 4, NOT DONE (the stored format): a workspace's stored `position` and its public `index` are
//! dense, so a close restates each of the `m` workspaces after the closed one (its ledger row, its
//! journal value). That part is asserted as at most `c * m`, with the `c` this test measures at 60
//! (a close of the first workspace against a close of the last one) and prints. It is not hidden
//! and it is not flat: a close of the first workspace of 826 still pays 825 times `c`.
//!
//! L, NOT DONE: each committed change clones every catalog terminal to publish waiting directory
//! reports (`publish_pending_terminal_directories`). Asserted as at most one clone per live
//! terminal.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

use rusqlite::hooks::{Action, AuthAction, AuthContext, Authorization};

use super::*;
use crate::mux::resource_content::without_crosscheck;
use crate::mux::walk_counters::walk_counts_for_test;

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

/// What the registry connection ran: SELECT statements compiled (the registry prepares each
/// statement when it runs it), rows written by table, and column reads by table (diagnostics for
/// a difference in the SELECT count; not asserted).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Sql {
    selects: u64,
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
}

fn workspace_key(index: usize) -> String {
    format!("018f6e21-7b70-7e70-8000-{index:012}")
}

/// `workspaces` workspaces with one running terminal each, the second one selected (no arm closes
/// it), and the journal's public fold seeded, as in a live session.
pub(super) fn session(workspaces: usize) -> Arc<Mux> {
    let mux = test_mux();
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
    Arms { workspaces, last, middle, first }
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

    // Step 4, not done: at most `c` SELECTs and `c` rows for each workspace after the closed one,
    // `c` as measured at 60 (rounded up to a whole number).
    let (selects, rows) = position_part(&small.first, &small.last);
    let (select_c, row_c) = (selects.div_ceil(small.first.later), rows.div_ceil(small.first.later));
    eprintln!(
        "position part (step 4, not done): {selects} SELECTs and {rows} rows written for {} later \
         workspaces at 60 = at most {select_c} SELECTs and {row_c} rows for each one",
        small.first.later
    );
    let shifted = [
        ("middle of 60", &small.middle, &small.last),
        ("middle of 826", &large.middle, &large.last),
        ("first of 826", &large.first, &large.last),
    ];
    for (name, cost, flat) in shifted {
        let (selects, rows) = position_part(cost, flat);
        eprintln!(
            "position part, {name}: {selects} SELECTs and {rows} rows for {} later",
            cost.later
        );
        if selects > select_c * cost.later + BACKGROUND_SELECTS || rows > row_c * cost.later {
            problems.push(format!(
                "{name}: {selects} SELECTs and {rows} rows above the flat part for {} later \
                 workspaces; {select_c} and {row_c} per later workspace at 60",
                cost.later
            ));
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

    assert!(
        problems.is_empty(),
        "one close-workspace grows with the session:\n{}",
        problems.join("\n")
    );
}

/// The scoped close commits what the full projection would: the debug cross-check (on in tests)
/// fails a close whose rows or public values differ, for the last, a middle, the first and the
/// active workspace.
#[test]
fn a_workspace_close_commits_what_the_full_projection_would() {
    let mux = session(12);
    let live = mux.with_state(|state| state.workspaces.len());
    let before = mux.resource_projection_stats();
    for index in [live - 1, 5, 0, 0] {
        let key = mux.with_state(|state| state.workspaces[index].key.clone());
        let mutation =
            WorkspaceMutation::daemon(format!("close-check-{key}"), "close-cost-test").unwrap();
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
        let stats = mux.resource_projection_stats();
        assert_eq!(stats.crosscheck_mismatches, 0, "closing workspace {key}");
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
            "the close of {key} left rows for a full projection: {written:?}"
        );
    }
    assert_eq!(mux.with_state(|state| state.workspaces.len()), live - 4);
    let after = mux.resource_projection_stats();
    assert_eq!(after.scope_fallbacks, before.scope_fallbacks, "a close left its scope");
    assert_eq!(
        after.crosschecks - before.crosschecks,
        4,
        "each close is a scoped projection compared with the full one"
    );
}
