//! The daemon-side work one sidebar click causes, as the session grows.
//!
//! Leo (2026-11-17): "we should be stress testing everything that isn't already stress tested".
//! `workspace_close_cost` and `create_commit_cost` count a close and a create at 60 and 826
//! workspaces; nothing swept rename, select, a one-step move, a move to the end, or the list a
//! client fetches, and nothing printed their times at several sizes. This file does both, on a
//! session whose registry is a FILE with the journal writer thread, as in a daemon, and whose
//! workspaces each hold [`TABS`] running terminals (placeholders: no terminal host).
//!
//! COUNT form (ungated, no clock): [`a_single_workspace_change_costs_the_same_in_a_bigger_session`]
//! renames one workspace, selects another, moves one a single step and creates an empty one, at
//! [`SMALL`] and at [`LARGE`] workspaces, and asserts per operation: the SELECT statements the
//! registry prepares, the rows it writes, the bytes of the journal changes it appends, the
//! workspace upserts in them, and the surfaces the tree-decoration walk visits do not grow with
//! the session (beyond a small fixed slack). A cost linear in the workspaces fails it by a factor
//! of ten.
//!
//! TIME form (gated): `CMUX_STRESS=1`, or a plain `cargo test` filter naming
//! `registry_stress_bench` (as `apps/supervisor_load_tests.rs`). It prints one
//! `STRESS-WORKSPACE-REGISTRY` JSON line per size and operation with p50/p95 in milliseconds and
//! the same counts:
//!
//! ```text
//! env CMUX_STRESS=1 cargo test -p cmux-tui-core --release --lib registry_stress_bench -- --nocapture
//! ```
//!
//! THOUSANDS form (ungated): [`open_pane_switch_and_create_cost_the_same_at_four_thousand_workspaces`]
//! opens a pane, switches workspace and creates one at 8 and at 4,000 workspaces, and fails when
//! the counts above or the median time of any of them grow with the workspace count.
//!
//! A move to the end and the list are whole-set by nature (every later position changes; the list
//! returns every workspace): they are printed, not asserted.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Instant;

use rusqlite::hooks::{Action, AuthAction, AuthContext, Authorization};
use serde_json::{Value, json};

use super::*;
use crate::mux::resource_content::without_crosscheck;
use crate::walk_counters::walk_counts_for_test;

/// Running terminals (tabs) in each workspace of a session.
const TABS: usize = 3;
const SMALL: usize = 20;
const LARGE: usize = 200;

/// SELECT statements an operation may prepare more in one session than in another for a reason
/// that is not the session's size (the process-wide one-slot sidebar document cache, see
/// `workspace_close_cost::BACKGROUND_SELECTS`).
const BACKGROUND_SELECTS: u64 = 16;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("registry_stress_bench"))
        && !args.iter().any(|a| a == "--exact")
}

/// Milliseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1000.0);
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 1000.0).round() / 1000.0
        };
        json!({ "n": v.len(), "p50": at(0.5), "p95": at(0.95), "max": at(1.0) })
    }
}

/// What one operation did, counted on the calling thread.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Cost {
    selects: u64,
    rows: BTreeMap<String, u64>,
    /// Bytes of the resource journal changes the operation appended.
    journal_bytes: u64,
    /// Workspace upserts in those changes.
    workspace_upserts: u64,
    /// Surfaces and tab slots the tree-decoration walk visited.
    decoration_walk: u64,
    /// Workspaces visited by an index rebuild.
    index_rebuild: u64,
}

impl Cost {
    fn rows_written(&self) -> u64 {
        self.rows.values().sum()
    }

    fn to_json(&self) -> Value {
        json!({
            "selects": self.selects,
            "rows": self.rows_written(),
            "journal_bytes": self.journal_bytes,
            "workspace_upserts": self.workspace_upserts,
            "decoration_walk": self.decoration_walk,
            "index_rebuild": self.index_rebuild,
        })
    }
}

fn workspace_key(index: usize) -> String {
    format!("018f6e21-7b70-7e70-8000-{index:012}")
}

struct Session {
    mux: Arc<Mux>,
    root: std::path::PathBuf,
    /// The seeded terminals, `tabs` per workspace, in workspace order.
    surfaces: Vec<SurfaceId>,
    tabs: usize,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.mux.shutdown();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// `workspaces` workspaces with [`TABS`] running terminals each, the registry a file with the
/// journal writer, the second workspace selected and the journal's public fold complete.
fn session(workspaces: usize) -> Session {
    session_with(workspaces, TABS)
}

/// [`session`] with `tabs` running terminals in each workspace.
fn session_with(workspaces: usize, tabs: usize) -> Session {
    let root = std::env::temp_dir().join(format!(
        "cmux-registry-stress-{workspaces}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux("registry-stress", &root);
    assert!(mux.journal_writer_stats().is_some(), "this session has no journal writer thread");
    let surfaces = without_crosscheck(|| {
        let mut terminals = Vec::with_capacity(workspaces * tabs);
        for index in 0..workspaces {
            mux.create_empty_workspace(
                Some(format!("ws {index:06}")),
                Some(workspace_key(index)),
                None,
            )
            .unwrap();
            for tab in 0..tabs {
                let number = index * tabs + tab + 1;
                terminals.push((
                    format!("00000000000040008000{number:012x}"),
                    format!("10000000000040008000{number:012x}"),
                    workspace_key(index),
                ));
            }
        }
        let surfaces = mux.seed_running_terminals_for_test(&terminals).unwrap();
        mux.select_workspace(Some(1.min(workspaces - 1)), None);
        let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
        let fingerprint = json!({"operation": operation, "fixture": key});
        let expected_revision = mux.with_state(|state| state.resource_revision);
        mux.prepare_resource_effect(
            &WorkspaceMutation::daemon(key, "test").unwrap(),
            operation,
            &fingerprint,
            &json!({}),
            None,
            Some(expected_revision),
        )
        .unwrap();
        mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
        mux.commit_full_resource_effect_projection(key, operation, &fingerprint, json!({}))
            .unwrap();
        surfaces
    });
    assert!(
        mux.workspace_registry.lock().unwrap().public_fold_complete_for_test(),
        "the public fold is not complete"
    );
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspaces);
    assert_eq!(surfaces.len(), workspaces * tabs);
    Session { mux, root, surfaces, tabs }
}

/// Runs `operation` with the debug cross-check off (as a release daemon) and counts it.
fn counted(mux: &Arc<Mux>, operation: impl FnOnce()) -> Cost {
    let log = Arc::new(Mutex::new(Cost::default()));
    let (selects, rows) = (log.clone(), log.clone());
    let caller = std::thread::current().id();
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            if std::thread::current().id() == caller && context.action == AuthAction::Select {
                selects.lock().unwrap().selects += 1;
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
    let revision = mux.with_state(|state| state.resource_revision);
    let walks = walk_counts_for_test();
    without_crosscheck(operation);
    let walked = walk_counts_for_test();
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    mux.registry_connection.get().update_hook(None::<fn(Action, &str, &str, i64)>).unwrap();
    let mut cost = std::mem::take(&mut *log.lock().unwrap());
    cost.decoration_walk = walked.decoration_walk - walks.decoration_walk;
    cost.index_rebuild = walked.index_rebuild - walks.index_rebuild;
    for batch in mux.resource_events_after(revision).unwrap().batches {
        cost.journal_bytes += batch.changes.to_string().len() as u64;
        for change in batch.changes.as_array().into_iter().flatten() {
            if change["resource"] == "workspace" && change["kind"] == "upsert" {
                cost.workspace_upserts += 1;
            }
        }
    }
    cost
}

fn mutation(label: &str) -> WorkspaceMutation {
    WorkspaceMutation::daemon(
        format!("{label}-{}", crate::workspace_registry::new_uuid_v4()),
        "stress",
    )
    .unwrap()
}

fn workspace_at(mux: &Arc<Mux>, index: usize) -> WorkspaceId {
    mux.with_state(|state| state.workspaces[index].id)
}

/// Renames the workspace at `index`; names keep one length so the journal bytes compare.
fn rename(mux: &Arc<Mux>, index: usize, round: usize) {
    let target = workspace_at(mux, index);
    mux.rename_workspace_with_mutation(
        Some(target),
        None,
        format!("renamed {round:06}"),
        None,
        None,
        &mutation("rename"),
    )
    .unwrap();
}

/// Moves the workspace at `from` to insertion point `to`.
fn move_to(mux: &Arc<Mux>, from: usize, to: usize) {
    let target = workspace_at(mux, from);
    mux.move_workspace_with_mutation(Some(target), None, to, None, None, &mutation("move"))
        .unwrap();
}

fn select(mux: &Arc<Mux>, index: usize) {
    mux.select_workspace(Some(index), None);
    assert_eq!(mux.with_state(|state| state.active_workspace), index);
}

fn request(mux: &Arc<Mux>, operation: &str) -> Value {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                          "operation":operation,"params":{"machine":"current","session":"current"}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response
}

/// Opens a pane beside the first terminal of the workspace at `index` (Cmd-D) and returns the
/// new terminal.
fn open_pane(s: &Session, index: usize) -> SurfaceId {
    let mux = &s.mux;
    let pane =
        mux.with_state(|state| state.pane_of(*s.surfaces.get(index * s.tabs).unwrap()).unwrap());
    mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap().id
}

fn close_opened(mux: &Arc<Mux>, surface: SurfaceId) {
    without_crosscheck(|| assert!(mux.close_surface(surface).unwrap()));
}

/// Creates an empty workspace keyed by `round` (Cmd-N).
fn create_extra(mux: &Arc<Mux>, round: usize) -> String {
    let key = format!("018f6e21-7b70-7e70-9000-{round:012}");
    mux.create_empty_workspace(Some(format!("ws extra{round:04}")), Some(key.clone()), None)
        .unwrap();
    key
}

fn close_extra(mux: &Arc<Mux>, key: &str) {
    without_crosscheck(|| {
        mux.close_workspace_ending_terminals(None, Some(key), None, None, &mutation("close"))
            .unwrap();
    });
}

/// One operation in a session of `n`: the cost of the middle workspace's rename, a select of
/// another workspace, a one-step move of a middle workspace, an empty workspace's create and a
/// pane opened in the middle workspace.
fn single_change_costs(n: usize) -> BTreeMap<&'static str, Cost> {
    // The test-only whole-tree check of each delta entity is not daemon work (this thread only:
    // before the session is built, or a build of thousands is quadratic).
    crate::server::skip_tree_entity_check();
    change_costs(&session(n))
}

fn change_costs(s: &Session) -> BTreeMap<&'static str, Cost> {
    let mux = &s.mux;
    let n = mux.with_state(|state| state.workspaces.len());
    let middle = n / 2;
    // Warm what a first operation of each kind pays once (statement caches, sidebar doc slot).
    rename(mux, middle, 0);
    select(mux, middle);
    move_to(mux, middle, middle + 2);
    let mut costs = BTreeMap::new();
    costs.insert("rename", counted(mux, || rename(mux, middle, 1)));
    costs.insert("select", counted(mux, || select(mux, middle - 1)));
    costs.insert("move_one", counted(mux, || move_to(mux, middle, middle + 2)));
    select(mux, middle);
    for round in 0..2 {
        // The first create, pane and close warm their statements; the second is counted.
        if round == 1 {
            let mut key = String::new();
            costs.insert("create_empty", counted(mux, || key = create_extra(mux, round)));
            close_extra(mux, &key);
            let mut opened = None;
            costs.insert("open_pane", counted(mux, || opened = Some(open_pane(s, middle))));
            close_opened(mux, opened.unwrap());
        } else {
            let key = without_crosscheck(|| create_extra(mux, round));
            close_extra(mux, &key);
            let opened = without_crosscheck(|| open_pane(s, middle));
            close_opened(mux, opened);
        }
    }
    for (operation, cost) in &costs {
        eprintln!("registry stress {operation} at {n}: {cost:?}");
    }
    costs
}

/// What grew from the `small` session's costs to the `large` one's, one line per count.
fn grown_counts(
    small: &BTreeMap<&'static str, Cost>,
    large: &BTreeMap<&'static str, Cost>,
    (small_n, large_n): (usize, usize),
) -> Vec<String> {
    let mut failures = Vec::new();
    for (operation, at_small) in small {
        let at_large = &large[operation];
        let mut check = |what: &str, small: u64, large: u64, slack: u64| {
            if large > small + slack {
                failures.push(format!(
                    "{operation}: {what} {small} at {small_n} workspaces, {large} at {large_n}"
                ));
            }
        };
        check("SELECT statements", at_small.selects, at_large.selects, BACKGROUND_SELECTS);
        check("rows written", at_small.rows_written(), at_large.rows_written(), 0);
        // Ids and numbers in the changes are a few bytes longer in a bigger session.
        check("journal bytes", at_small.journal_bytes, at_large.journal_bytes, 64);
        check("workspace upserts", at_small.workspace_upserts, at_large.workspace_upserts, 0);
        check("decoration walk", at_small.decoration_walk, at_large.decoration_walk, 0);
        check("index rebuild", at_small.index_rebuild, at_large.index_rebuild, 0);
    }
    failures
}

#[cfg(unix)]
#[test]
fn a_single_workspace_change_costs_the_same_in_a_bigger_session() {
    let small = single_change_costs(SMALL);
    let large = single_change_costs(LARGE);
    let failures = grown_counts(&small, &large, (SMALL, LARGE));
    assert!(
        failures.is_empty(),
        "one workspace change grows with the session:\n{}",
        failures.join("\n")
    );
}

/// Leo (2026-11-04): "It should just never, ever, ever, ever be ... acceptable for there to be
/// some sort of linear time growth degradation in performance just because the app somehow has
/// tons of workspaces, thousands, whatever workspace ... Proportionally, we should have it be
/// like just like constant, right?"
///
/// Opening a pane, switching workspace and creating one, in a session of [`FEW`] workspaces and
/// one of [`THOUSANDS`] (one running terminal each): the counted work of each must not grow
/// (as [`a_single_workspace_change_costs_the_same_in_a_bigger_session`]), and its median time
/// over [`TIMED_ROUNDS`] must stay within [`TIME_RATIO`] of the small session's plus
/// [`TIME_SLACK_MS`]. A cost linear in the workspaces is hundreds of times the small one at
/// 4,000 (under the registry cap, `WORKSPACE_REGISTRY_LIMIT`); the ratio and slack only absorb
/// a shared CI host's noise.
const FEW: usize = 8;
const THOUSANDS: usize = 4_000;
const TIMED_ROUNDS: usize = 9;
const TIME_RATIO: f64 = 3.0;
const TIME_SLACK_MS: f64 = 4.0;

fn median_ms(mut samples: Vec<f64>) -> f64 {
    samples.sort_by(f64::total_cmp);
    samples.get(samples.len() / 2).copied().unwrap_or(f64::NAN)
}

/// Median milliseconds of open pane, switch and create in `s`.
fn timed_costs(s: &Session) -> BTreeMap<&'static str, f64> {
    let mux = &s.mux;
    let n = mux.with_state(|state| state.workspaces.len());
    let (middle, far) = (n / 2, n - 1);
    let mut times: BTreeMap<&'static str, Vec<f64>> = BTreeMap::new();
    for round in 0..TIMED_ROUNDS {
        select(mux, middle);
        let started = Instant::now();
        let opened = without_crosscheck(|| open_pane(s, middle));
        times.entry("open_pane").or_default().push(started.elapsed().as_secs_f64() * 1000.0);
        close_opened(mux, opened);

        let started = Instant::now();
        without_crosscheck(|| select(mux, if round % 2 == 0 { far } else { 0 }));
        times.entry("switch").or_default().push(started.elapsed().as_secs_f64() * 1000.0);

        let started = Instant::now();
        let key = without_crosscheck(|| create_extra(mux, 100 + round));
        times.entry("create_empty").or_default().push(started.elapsed().as_secs_f64() * 1000.0);
        close_extra(mux, &key);
    }
    let medians: BTreeMap<_, _> = times.into_iter().map(|(k, v)| (k, median_ms(v))).collect();
    for (operation, ms) in &medians {
        println!("WORKSPACE-SCALE {}", json!({"size": n, "op": operation, "p50_ms": ms}));
    }
    medians
}

#[cfg(unix)]
#[test]
fn open_pane_switch_and_create_cost_the_same_at_four_thousand_workspaces() {
    crate::server::skip_tree_entity_check();
    let few = session_with(FEW, 1);
    let few_counts = change_costs(&few);
    let few_times = timed_costs(&few);
    drop(few);
    let built = Instant::now();
    let many = session_with(THOUSANDS, 1);
    eprintln!("workspace scale: {THOUSANDS} workspaces built in {:?}", built.elapsed());
    let many_counts = change_costs(&many);
    let many_times = timed_costs(&many);
    let mut failures = grown_counts(&few_counts, &many_counts, (FEW, THOUSANDS));
    for (operation, few_ms) in &few_times {
        let many_ms = many_times.get(operation).copied().unwrap_or(f64::INFINITY);
        if many_ms > few_ms * TIME_RATIO + TIME_SLACK_MS {
            failures.push(format!(
                "{operation}: median {few_ms:.3} ms at {FEW} workspaces, {many_ms:.3} ms at {THOUSANDS}"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "an operation on one workspace grows with the workspace count:\n{}",
        failures.join("\n")
    );
}

const BENCH_SIZES: [usize; 4] = [1, 100, 500, 2000];
const ROUNDS: usize = 20;

fn report(size: usize, operation: &str, samples: &Samples, cost: &Cost) {
    let line = json!({
        "size": size,
        "tabs_per_workspace": TABS,
        "op": operation,
        "ms": samples.summary(),
        "work": cost.to_json(),
    });
    println!("STRESS-WORKSPACE-REGISTRY {line}");
}

/// Times `operation` [`ROUNDS`] times (the first one also counted).
fn sweep(size: usize, name: &str, mux: &Arc<Mux>, mut operation: impl FnMut(usize)) {
    let mut samples = Samples::default();
    let cost = counted(mux, || operation(0));
    for round in 1..=ROUNDS {
        let started = Instant::now();
        without_crosscheck(|| operation(round));
        samples.push(started);
    }
    report(size, name, &samples, &cost);
}

#[cfg(unix)]
#[test]
fn registry_stress_bench() {
    if !bench_selected() {
        eprintln!("registry_stress_bench skipped: set CMUX_STRESS=1");
        return;
    }
    crate::server::skip_tree_entity_check();
    for size in BENCH_SIZES {
        let built = Instant::now();
        let s = session(size);
        eprintln!("registry stress session of {size} built in {:?}", built.elapsed());
        let mux = &s.mux;
        let middle = size / 2;
        sweep(size, "rename", mux, |round| rename(mux, middle, round));
        if size > 1 {
            sweep(size, "select", mux, |round| {
                select(mux, if round % 2 == 0 { 0 } else { size - 1 });
            });
            sweep(size, "move_one", mux, |round| {
                if round % 2 == 0 {
                    move_to(mux, middle, middle + 2);
                } else {
                    move_to(mux, middle + 1, middle);
                }
            });
            sweep(size, "move_first_to_end", mux, |_| move_to(mux, 0, size));
        }
        sweep(size, "workspace.list", mux, |_| {
            request(mux, "workspace.list");
        });
        sweep(size, "sidebar.get", mux, |_| {
            request(mux, "sidebar.get");
        });
        sweep(size, "create_then_close_last", mux, |round| {
            let key = format!("018f6e21-7b70-7e70-9000-{round:012}");
            mux.create_empty_workspace(
                Some(format!("ws extra{round:04}")),
                Some(key.clone()),
                None,
            )
            .unwrap();
            mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation("close"))
                .unwrap();
        });
    }
}
