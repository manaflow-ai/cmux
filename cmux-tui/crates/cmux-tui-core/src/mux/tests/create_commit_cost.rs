//! One create (a split, a new tab, a new workspace) must not do more work under the registry
//! lock and the state lock in a bigger session, and the journal writer's disk time for it must
//! not hold a lock that a request of the person takes.
//!
//! Lawrence's Mac (2026-11-10, build 824dfe557cb2: 826 workspaces, 798 terminals, a 10 GB
//! registry file, 13 clients): the registry lock was held at `creation_settlement.rs:183`, the
//! commit of a create, for 739 ms in the mean and 2157 ms at the most (9 creates), and the state
//! lock at the same site for 2105 ms at the most. Requests waited behind it: a terminal read
//! (`resource_router.rs:477`) 2815 ms, `list-workspaces` (`server.rs:3028`) 2142 ms.
//!
//! The create's projection was "scoped", but only in its subtree: the walk still stated the row
//! and the public value of EVERY workspace, the read still returned every stored workspace row,
//! the journal fold compared each of those values and the journal writer checked each of those
//! rows, all with the registry lock held. After the commit, each create cloned every catalog
//! terminal two times under the state lock.
//!
//! COUNT form (no clock): one split, one new tab and one new workspace, in a session of 60 and of
//! 826 workspaces (one terminal each) whose registry is a FILE in a temporary directory, with the
//! journal writer thread, as in a daemon. The counts of one create must be equal at 60 and at 826.
//!
//! FULL-PATH row (the lead's condition): the same split when the registry has lost its fold of the
//! journal, which is its state after a daemon start and after a commit whose receipt did not
//! come (`abandon_effect_commit`). On his Mac this is the candidate for the 2157 ms: without the
//! fold the create took the FULL projection, which reads the whole stored topology and every
//! terminal record and writes one journal value for each resource of the session.
//!
//! FOCUS row (a product defect at the same site, not a cost): an empty workspace made with focus
//! commits the workspace rows and the active workspace, but its journal record did not state
//! the screen and the pane that lose the focus. The journal then says `focused: true` for two
//! screens until a later projection has the old workspace in its scope: each `session.events`
//! client and each reader of the journal's state can show two focused screens. A release daemon
//! does not detect it (the cross-check is a debug check). The record must state that one screen
//! and that one pane, and its size must not grow with the session.
//!
//! WAIT form (no clock for the verdict): the journal writer is stopped inside the transaction of
//! the create's commit, which is the model of a slow disk. While it is there, the registry lock
//! and the state lock must be free.
//!
//! What these tests leave out (a count is a LOWER BOUND of his case): the page-cache misses and
//! the WAL of a 10 GB file, `fullfsync` (off in a test build), a journal writer that is shared
//! with the output of 798 terminals, exited terminal records, 13 clients and the host load. The
//! debug cross-check (one full projection for each scoped one) is off here, as in a release
//! daemon.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::mpsc::sync_channel;
use std::sync::{Mutex, OnceLock};

use rusqlite::hooks::{Action, AuthAction, AuthContext, Authorization};

use super::workspace_close_cost::session_in;
use super::*;
use crate::mux::resource_content::without_crosscheck;
use crate::walk_counters::walk_counts_for_test;

/// SELECT statements that a create may run more in one session than in the other for a reason
/// that is not the session's size (the one-slot sidebar document cache of the process: see
/// `workspace_close_cost::BACKGROUND_SELECTS`). One statement for each workspace would add 766.
const BACKGROUND_SELECTS: u64 = 16;

/// What one create did.
#[derive(Debug, Clone, Default)]
struct CreateCost {
    live_terminals: u64,
    full_projections: u64,
    scoped_projections: u64,
    scope_fallbacks: u64,
    /// Reads of the whole stored topology.
    full_reads: u64,
    /// Workspaces whose row and public value the walk stated.
    workspace_rows: u64,
    /// Stored workspace rows that the scoped read returned.
    frame_rows: u64,
    /// Durable changes in the patch that went to the journal writer.
    patch_changes: u64,
    /// Public deltas (JSON values) that the projection built.
    public_deltas: u64,
    index_rebuild: u64,
    decoration_walk: u64,
    terminal_clones: u64,
    /// SELECT statements that the request thread compiled on the registry connection.
    selects: u64,
    /// Column reads by table on the request thread (printed for a difference, not asserted).
    reads: BTreeMap<String, u64>,
    /// Rows written by table, on every thread (the journal writer commits the create).
    rows: BTreeMap<String, u64>,
}

impl CreateCost {
    fn workspace_rows_written(&self) -> u64 {
        self.rows.get("resource_workspaces").copied().unwrap_or(0)
    }

    fn reads_that_differ(&self, other: &Self) -> Vec<(String, u64, u64)> {
        let mut tables = self.reads.keys().chain(other.reads.keys()).collect::<Vec<_>>();
        tables.sort();
        tables.dedup();
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

/// The three creates of a person in one session.
#[derive(Debug, Clone)]
struct Arms {
    split: CreateCost,
    tab: CreateCost,
    workspace: CreateCost,
    /// A split when the registry has no fold of the journal.
    no_fold: CreateCost,
    /// An empty workspace made with focus.
    empty: EmptyWorkspaceRecord,
}

/// What the journal record of an empty workspace made with focus states.
#[derive(Debug, Clone, Default)]
struct EmptyWorkspaceRecord {
    /// Changes in the journal records of the commit.
    changes: u64,
    /// `focused` of the screen that had the focus before, when the record states that screen.
    old_screen_focused: Option<bool>,
    /// `focused` of the pane that had the focus before, when the record states that pane.
    old_pane_focused: Option<bool>,
    /// The same two values in the record of the close of that empty workspace, which gives the
    /// focus back to the same screen and pane.
    back_screen_focused: Option<bool>,
    back_pane_focused: Option<bool>,
}

/// `focused` of the last upsert of each `(resource, id)` in the journal records after
/// `revision`, and the count of changes in those records.
fn stated_focus(mux: &Arc<Mux>, revision: u64, ids: [(&str, &str); 2]) -> ([Option<bool>; 2], u64) {
    let page = mux.workspace_registry.lock().unwrap().resource_events_after(revision).unwrap();
    let changes = page
        .batches
        .iter()
        .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
        .collect::<Vec<_>>();
    let focused = |(resource, id): (&str, &str)| {
        changes
            .iter()
            .rev()
            .find(|change| {
                change["kind"] == "upsert" && change["resource"] == resource && change["id"] == id
            })
            .and_then(|change| change["value"]["focused"].as_bool())
    };
    (ids.map(focused), changes.len() as u64)
}

/// Makes an empty workspace with focus and reads what the journal says of the commit.
fn empty_workspace_record(mux: &Arc<Mux>) -> EmptyWorkspaceRecord {
    let (screen, pane) = mux.with_state(|state| {
        let workspace = &state.workspaces[state.active_workspace];
        let screen = &workspace.screens[workspace.active_screen];
        (
            screen.public_id.to_string(),
            state.panes.get(&screen.active_pane).unwrap().public_id.to_string(),
        )
    });
    let ids = [("screen", screen.as_str()), ("pane", pane.as_str())];
    let revision = || mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
    let before = revision();
    let empty = without_crosscheck(|| {
        mux.create_empty_workspace(Some("empty".into()), None, None).unwrap().workspace
    });
    let ([old_screen_focused, old_pane_focused], changes) = stated_focus(mux, before, ids);
    let before = revision();
    assert!(without_crosscheck(|| mux.close_workspace(empty)), "the empty workspace did not close");
    let ([back_screen_focused, back_pane_focused], _) = stated_focus(mux, before, ids);
    EmptyWorkspaceRecord {
        changes,
        old_screen_focused,
        old_pane_focused,
        back_screen_focused,
        back_pane_focused,
    }
}

impl Arms {
    fn each(&self) -> [(&'static str, &CreateCost); 3] {
        [("split", &self.split), ("new tab", &self.tab), ("new workspace", &self.workspace)]
    }
}

struct FileSession {
    mux: Arc<Mux>,
    root: PathBuf,
    /// The first terminal of the active workspace: the creates of the person go there.
    target: Arc<Surface>,
}

impl FileSession {
    fn target_pane(&self) -> PaneId {
        self.mux.with_state(|state| state.pane_of(self.target.id).unwrap())
    }

    fn end(self, created: Vec<Arc<Surface>>) {
        for surface in created {
            surface.kill();
        }
        self.target.kill();
        drop(self.mux);
        let _ = std::fs::remove_dir_all(self.root);
    }
}

/// A session of `workspaces` workspaces with one terminal each, whose registry is a file in a
/// new temporary directory and whose commits go through the journal writer thread. The last
/// workspace is the active one and holds a terminal that a create can split.
fn file_session(workspaces: usize) -> FileSession {
    let root = std::env::temp_dir().join(format!(
        "cmux-create-commit-cost-{workspaces}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux("create-commit-cost", &root);
    assert!(mux.disk_usage_stats().is_some(), "the registry of this session is not a file");
    assert!(mux.journal_writer_stats().is_some(), "this session has no journal writer thread");
    // Made with the debug cross-check off: with it, each create also runs a full projection.
    let (mux, target) = without_crosscheck(|| {
        let mux = session_in(mux, workspaces - 1);
        let target = mux.new_workspace(Some("target".into()), Some((80, 24))).unwrap();
        (mux, target)
    });
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspaces);
    assert!(
        mux.workspace_registry.lock().unwrap().public_fold_seeded(),
        "the public fold is not seeded: the creates of this test would run the full projection"
    );
    FileSession { mux, root, target }
}

/// SELECT statements, column reads by table and rows written by table.
type SqlLog = (u64, BTreeMap<String, u64>, BTreeMap<String, u64>);

/// Runs `create` with the debug cross-check off and counts it.
fn counted_create(
    mux: &Arc<Mux>,
    create: impl FnOnce() -> Arc<Surface>,
) -> (CreateCost, Arc<Surface>) {
    let live_terminals = mux.with_state(|state| state.terminal_catalog.len() as u64);
    let log = Arc::new(Mutex::new(SqlLog::default()));
    let (read_log, row_log) = (log.clone(), log.clone());
    let caller = std::thread::current().id();
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            if std::thread::current().id() == caller {
                match context.action {
                    AuthAction::Select => read_log.lock().unwrap().0 += 1,
                    AuthAction::Read { table_name, .. } => {
                        *read_log.lock().unwrap().1.entry(table_name.to_owned()).or_default() += 1;
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
            *row_log.lock().unwrap().2.entry(table.to_owned()).or_default() += 1;
        }))
        .unwrap();
    let stats = mux.resource_projection_stats();
    let full_reads = WorkspaceRegistry::full_topology_reads_for_test();
    let walks = walk_counts_for_test();

    let surface = without_crosscheck(create);

    let walked = walk_counts_for_test();
    let after = mux.resource_projection_stats();
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    mux.registry_connection.get().update_hook(None::<fn(Action, &str, &str, i64)>).unwrap();
    let (selects, reads, rows) = std::mem::take(&mut *log.lock().unwrap());
    let cost = CreateCost {
        live_terminals,
        full_projections: after.full_projections - stats.full_projections,
        scoped_projections: after.scoped_projections - stats.scoped_projections,
        scope_fallbacks: after.scope_fallbacks - stats.scope_fallbacks,
        full_reads: WorkspaceRegistry::full_topology_reads_for_test() - full_reads,
        workspace_rows: walked.workspace_rows - walks.workspace_rows,
        frame_rows: walked.frame_rows - walks.frame_rows,
        patch_changes: walked.patch_changes - walks.patch_changes,
        public_deltas: walked.public_deltas - walks.public_deltas,
        index_rebuild: walked.index_rebuild - walks.index_rebuild,
        decoration_walk: walked.decoration_walk - walks.decoration_walk,
        terminal_clones: walked.terminal_clones - walks.terminal_clones,
        selects,
        reads,
        rows,
    };
    (cost, surface)
}

/// One split, one new tab and one new workspace in a new file session of `workspaces`.
fn arms(workspaces: usize) -> Arms {
    let session = file_session(workspaces);
    let mux = session.mux.clone();
    let pane = session.target_pane();
    let (split, split_surface) =
        counted_create(&mux, || mux.split(pane, SplitDir::Down, None).unwrap());
    let (tab, tab_surface) =
        counted_create(&mux, || mux.new_tab(Some(pane), None, Some((80, 24))).unwrap());
    let (workspace, workspace_surface) = counted_create(&mux, || {
        mux.new_workspace(Some("measured".into()), Some((80, 24))).unwrap()
    });
    // The registry loses its fold of the journal, as after a daemon start or a commit whose
    // receipt did not come.
    let other_pane = mux.with_state(|state| state.pane_of(workspace_surface.id).unwrap());
    mux.workspace_registry.lock().unwrap().abandon_effect_commit();
    let (no_fold, no_fold_surface) =
        counted_create(&mux, || mux.split(other_pane, SplitDir::Down, None).unwrap());
    // The full projection of the split above seeded the fold again.
    let empty = empty_workspace_record(&mux);
    let arms = Arms { split, tab, workspace, no_fold, empty };
    eprintln!("empty workspace with focus at {workspaces} workspaces: {:?}", arms.empty);
    for (name, cost) in arms.each().into_iter().chain([("split with no fold", &arms.no_fold)]) {
        eprintln!("create cost at {workspaces} workspaces, {name}: {cost:?}");
    }
    drop(mux);
    session.end(vec![split_surface, tab_surface, workspace_surface, no_fold_surface]);
    arms
}

/// The creates at 60 and at 826, measured one time for every test of this file.
fn measured() -> &'static (Arms, Arms) {
    static MEASURED: OnceLock<(Arms, Arms)> = OnceLock::new();
    MEASURED.get_or_init(|| (arms(60), arms(826)))
}

fn assert_no_problems(problems: Vec<String>) {
    assert!(
        problems.is_empty(),
        "one create costs more in a session of 826 workspaces than in one of 60:\n{}",
        problems.join("\n")
    );
}

#[test]
fn a_create_projects_and_commits_the_same_in_a_bigger_session() {
    let (small, large) = measured();
    let mut problems = Vec::new();
    for ((name, small), (_, large)) in small.each().into_iter().zip(large.each()) {
        for (size, cost) in [(60, small), (826, large)] {
            if cost.full_projections != 0 || cost.scope_fallbacks != 0 || cost.full_reads != 0 {
                problems.push(format!(
                    "{name} at {size}: {} full projections, {} scope fallbacks, {} reads of the \
                     whole stored topology",
                    cost.full_projections, cost.scope_fallbacks, cost.full_reads
                ));
            }
        }
        let counts: [(&str, u64, u64); 6] = [
            ("scoped projections", small.scoped_projections, large.scoped_projections),
            ("workspaces stated by the walk", small.workspace_rows, large.workspace_rows),
            ("stored workspace rows read", small.frame_rows, large.frame_rows),
            (
                "durable changes sent to the journal writer",
                small.patch_changes,
                large.patch_changes,
            ),
            ("public values built", small.public_deltas, large.public_deltas),
            (
                "workspace rows written",
                small.workspace_rows_written(),
                large.workspace_rows_written(),
            ),
        ];
        for (what, at_small, at_large) in counts {
            if at_small != at_large {
                problems.push(format!("{name}: {what}: {at_small} at 60, {at_large} at 826"));
            }
        }
        if large.selects > small.selects + BACKGROUND_SELECTS {
            problems.push(format!(
                "{name}: SELECT statements on the request thread: {} at 60, {} at 826; tables \
                 whose reads differ (table, at 60, at 826): {:?}",
                small.selects,
                large.selects,
                small.reads_that_differ(large)
            ));
        }
    }
    assert_no_problems(problems);
}

#[test]
#[ignore = "still red: the index rebuild of a split and the decoration walks visit the session (the next PR of create-commit-800 removes this line)"]
fn a_create_walks_no_more_of_the_session_in_a_bigger_session() {
    let (small, large) = measured();
    let mut problems = Vec::new();
    for ((name, small), (_, large)) in small.each().into_iter().zip(large.each()) {
        let counts: [(&str, u64, u64); 2] = [
            ("workspaces visited by index rebuilds", small.index_rebuild, large.index_rebuild),
            ("surfaces visited by decoration walks", small.decoration_walk, large.decoration_walk),
        ];
        for (what, at_small, at_large) in counts {
            if at_small != at_large {
                problems.push(format!("{name}: {what}: {at_small} at 60, {at_large} at 826"));
            }
        }
    }
    assert_no_problems(problems);
}

#[test]
#[ignore = "still red: each create clones every catalog terminal two times (the next PR of create-commit-800 removes this line)"]
fn a_create_clones_no_more_terminals_in_a_bigger_session() {
    let (small, large) = measured();
    let mut problems = Vec::new();
    for ((name, small), (_, large)) in small.each().into_iter().zip(large.each()) {
        if small.terminal_clones != large.terminal_clones {
            problems.push(format!(
                "{name}: catalog terminals cloned under the state lock: {} at 60 ({} live), {} at \
                 826 ({} live)",
                small.terminal_clones,
                small.live_terminals,
                large.terminal_clones,
                large.live_terminals
            ));
        }
    }
    assert_no_problems(problems);
}

#[test]
#[ignore = "still red: a create with no journal fold runs the full projection (the next PR of create-commit-800 removes this line)"]
fn a_create_with_no_journal_fold_does_not_project_the_session() {
    let (small, large) = measured();
    let (small, large) = (&small.no_fold, &large.no_fold);
    let mut problems = Vec::new();
    for (size, cost) in [(60, small), (826, large)] {
        if cost.full_projections != 0 || cost.full_reads != 0 {
            problems.push(format!(
                "split with no fold at {size}: {} full projections, {} reads of the whole stored \
                 topology",
                cost.full_projections, cost.full_reads
            ));
        }
    }
    let counts: [(&str, u64, u64); 7] = [
        ("workspaces stated by the walk", small.workspace_rows, large.workspace_rows),
        ("stored workspace rows read", small.frame_rows, large.frame_rows),
        ("durable changes sent to the journal writer", small.patch_changes, large.patch_changes),
        ("public values built", small.public_deltas, large.public_deltas),
        ("workspace rows written", small.workspace_rows_written(), large.workspace_rows_written()),
        ("workspaces visited by index rebuilds", small.index_rebuild, large.index_rebuild),
        ("surfaces visited by decoration walks", small.decoration_walk, large.decoration_walk),
    ];
    for (what, at_small, at_large) in counts {
        if at_small != at_large {
            problems
                .push(format!("split with no fold: {what}: {at_small} at 60, {at_large} at 826"));
        }
    }
    assert_no_problems(problems);
}

#[test]
fn a_workspace_commit_that_moves_the_focus_states_the_screen_and_the_pane_that_change() {
    let (small, large) = measured();
    let mut problems = Vec::new();
    for (size, record) in [(60, &small.empty), (826, &large.empty)] {
        if record.old_screen_focused != Some(false) {
            problems.push(format!(
                "at {size}: the journal record says focused = {:?} for the screen that lost the \
                 focus (None: the record does not state the screen, so the journal keeps true)",
                record.old_screen_focused
            ));
        }
        if record.old_pane_focused != Some(false) {
            problems.push(format!(
                "at {size}: the journal record says focused = {:?} for the pane that lost the \
                 focus (None: the record does not state the pane, so the journal keeps true)",
                record.old_pane_focused
            ));
        }
        if record.back_screen_focused != Some(true) || record.back_pane_focused != Some(true) {
            problems.push(format!(
                "at {size}: the close of that empty workspace gives the focus back, but its \
                 journal record says focused = {:?} for the screen and {:?} for the pane",
                record.back_screen_focused, record.back_pane_focused
            ));
        }
    }
    if small.empty.changes != large.empty.changes {
        problems.push(format!(
            "changes in the journal record: {} at 60, {} at 826",
            small.empty.changes, large.empty.changes
        ));
    }
    assert!(
        problems.is_empty(),
        "a workspace commit that moves the focus leaves a wrong focused screen in the journal, or \
         its record grows with the session:\n{}",
        problems.join("\n")
    );
}

/// How long the test looks for a free lock before it says that the lock is held for the whole
/// stop of the journal writer. It is a give-up limit for the failing case, not a time budget: a
/// lock that is free is seen at the first look. It is shorter than the journal writer's deadline
/// of a test build (2 s), so the stopped commit still passes after the release.
const HELD_VERDICT_AFTER: Duration = Duration::from_millis(500);

/// True when `free` holds at some look before [`HELD_VERDICT_AFTER`].
fn seen_free(free: impl Fn() -> bool) -> bool {
    let give_up = Instant::now() + HELD_VERDICT_AFTER;
    loop {
        if free() {
            return true;
        }
        if Instant::now() >= give_up {
            return false;
        }
        std::thread::yield_now();
    }
}

/// How many creates the wait test runs to get one stop of the journal writer inside a create.
const STOP_TRIES: usize = 20;

/// One try of the wait test: what was seen while the journal writer stood before a COMMIT.
struct StopSeen {
    /// The creating thread was still inside its create when the looks ended.
    creator_inside: bool,
    state_free: bool,
    registry_free: bool,
}

#[test]
#[ignore = "still red: a create waits for the journal writer's receipt with the registry lock held (the next PR of create-commit-800 removes this line)"]
fn the_locks_of_a_persons_request_are_free_while_the_journal_writer_commits_a_create() {
    let session = file_session(60);
    let mux = session.mux.clone();
    let pane = session.target_pane();
    let mut created = Vec::new();
    let mut failed = Vec::new();
    let mut verdict = None;
    let mut tries = Vec::new();
    // Channels of the tries whose stop came late or never: they stay open, with the release
    // sent, so a later batch of the journal writer that takes such a stop goes on at once.
    let mut spent = Vec::new();
    for attempt in 0..STOP_TRIES {
        // The journal writer stops inside a batch transaction, before its COMMIT (it holds the
        // registry connection there, as during a slow disk write). The stop is armed after the
        // projection of the create is built, with the registry lock held by the create.
        let (entered, entered_receiver) = sync_channel(1);
        let (release, release_receiver) = sync_channel::<()>(1);
        let stop = Mutex::new(Some((entered, release_receiver)));
        let arming = Arc::downgrade(&mux);
        *mux.resource_projection_before_commit.lock().unwrap() = Some(Arc::new(move || {
            if let (Some(mux), Some((entered, release))) =
                (arming.upgrade(), stop.lock().unwrap().take())
            {
                mux.install_journal_before_commit_for_test(entered, release);
            }
        }));
        let before = mux.write_path_stats();
        let inside = Arc::new(AtomicBool::new(true));
        let creator = std::thread::spawn({
            let mux = mux.clone();
            let inside = inside.clone();
            move || {
                let made = without_crosscheck(|| mux.new_tab(Some(pane), None, Some((80, 24))));
                inside.store(false, Ordering::SeqCst);
                made
            }
        });
        let give_up = Instant::now() + Duration::from_secs(30);
        let stopped = loop {
            if entered_receiver.recv_timeout(Duration::from_millis(5)).is_ok() {
                break true;
            }
            if !inside.load(Ordering::SeqCst) || Instant::now() >= give_up {
                break entered_receiver.try_recv().is_ok();
            }
        };
        let seen = stopped.then(|| {
            let state_free = seen_free(|| mux.state.try_lock().is_ok());
            let registry_free = seen_free(|| mux.workspace_registry.try_lock().is_ok());
            // Read last: a create that is still inside after both looks was inside for each.
            StopSeen { creator_inside: inside.load(Ordering::SeqCst), state_free, registry_free }
        });
        release.send(()).unwrap();
        match creator.join().expect("the creating thread panicked") {
            Ok(surface) => created.push(surface),
            Err(error) => failed.push(format!("try {attempt}: {error:#}")),
        }
        *mux.resource_projection_before_commit.lock().unwrap() = None;
        let after = mux.write_path_stats();
        tries.push(format!(
            "try {attempt}: writer stopped {stopped}, create still inside at the stop {:?}, \
             commits through the writer {} and on the request thread {}",
            seen.as_ref().map(|seen| seen.creator_inside),
            after.effect_intents - before.effect_intents,
            after.request_effect_commits - before.request_effect_commits,
        ));
        spent.push((entered_receiver, release));
        if let Some(seen) = seen.filter(|seen| seen.creator_inside) {
            verdict = Some(seen);
            break;
        }
    }
    drop(mux);
    session.end(created);
    drop(spent);

    // A try in which the create ended before the looks says nothing about the create's wait:
    // without one valid try the test fails, it never passes.
    let Some(seen) = verdict else {
        panic!(
            "in {STOP_TRIES} creates the journal writer never stood before a COMMIT while the \
             create was still inside its commit, so the test can not say which lock the create \
             holds for the disk time:\n{}",
            tries.join("\n")
        );
    };
    assert!(
        seen.state_free,
        "the state lock is held while the journal writer commits a create: a key to another \
         terminal and list-workspaces wait for the disk\n{}",
        tries.join("\n")
    );
    assert!(
        seen.registry_free,
        "the registry lock is held while the journal writer is before its COMMIT and a create \
         waits for its receipt: every request that takes the registry lock waits for the disk \
         time of the create\n{}",
        tries.join("\n")
    );
    assert!(
        failed.is_empty(),
        "a create whose commit was stopped did not pass after the release:\n{}",
        failed.join("\n")
    );
}

/// The stored workspace rows whose group key is not the one the projection states (the session's
/// name): each as `name: group key`.
fn rows_in_another_form(mux: &Arc<Mux>) -> Vec<String> {
    let snapshot = mux.workspace_registry.lock().unwrap().snapshot().unwrap();
    snapshot
        .workspaces
        .iter()
        .filter(|workspace| workspace.group_key != mux.session)
        .map(|workspace| format!("{}: {}", workspace.name, workspace.group_key))
        .collect()
}

/// A plan that states a workspace row (a tab move that empties a workspace, a pane focus) must
/// write it in the form the projection states. A created view states only the workspaces it
/// changes, so a row that a plan wrote in another form stays in the store: the next create then
/// differs from the full projection. Before, each create stated every workspace and wrote such a
/// row again, which hid the difference.
///
/// The creates here run with the debug cross-check ON: it panics when the full projection would
/// write a row that the create left out.
#[test]
fn a_plan_writes_a_workspace_row_as_the_projection_states_it() {
    let mux = test_mux();
    let first = mux.new_workspace(Some("source".into()), Some((80, 24))).unwrap();
    let second = mux.new_tab(None, None, Some((80, 24))).unwrap();
    mux.move_tab_to_workspace(second.id, None).unwrap();
    let empty = mux.create_empty_workspace(Some("empty".into()), None, None).unwrap();
    // The move empties the second workspace: the plan states that workspace's row.
    mux.move_tab_to_workspace(second.id, Some(empty.workspace)).unwrap();
    let after_move = rows_in_another_form(&mux);
    assert!(
        after_move.is_empty(),
        "a tab move to another workspace wrote a workspace row with a group key that the          projection does not state: {after_move:?}"
    );
    let third = mux.new_tab(None, None, Some((80, 24))).unwrap();
    // A pane focus in another workspace states the row of that workspace.
    let pane = mux.with_state(|state| state.pane_of(first.id)).unwrap();
    assert!(mux.focus_pane(pane), "the pane of the first workspace did not take the focus");
    let after_focus = rows_in_another_form(&mux);
    assert!(
        after_focus.is_empty(),
        "a pane focus wrote a workspace row with a group key that the projection does not          state: {after_focus:?}"
    );
    // A create in a workspace that is not the one the focus left.
    let fourth = mux.new_tab(None, None, Some((80, 24))).unwrap();
    for surface in [fourth, third, second, first] {
        // The end of the test's terminals; a close is not the subject here.
        let _ = mux.close_surface(surface.id);
    }
}
