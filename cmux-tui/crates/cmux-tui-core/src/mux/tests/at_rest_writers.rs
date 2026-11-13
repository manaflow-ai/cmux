//! The terminal and project writers stop at rest (REGISTRY WAL, PR 1 part B).
//!
//! On Lawrence's Mac (826 workspaces, 798 terminals) a terminal that only
//! prints cost one registry commit per 5 s: `terminal.progress` was 11 % of
//! the journal rows at 3,922 bytes each (199 MB a day), and its lock site
//! (`mux/terminal_progress.rs`) took the workspace registry 4,692 times in
//! 2 h. A spinner, an OSC 9;4 progress value, a "last output" time and a
//! program status report that repeats its state are live facts for clients:
//! none of them is a durable change. `project.observe` committed a revision
//! and a journal row for an observation equal to the stored one.
//!
//! These tests run a real `Mux` on an on-disk registry and count, at the
//! registry: journal rows, resource revisions, WAL commits, WAL frame bytes
//! and file sizes. Counts, not times, so the result does not depend on the
//! machine. Arms: 1, 60 and 826 workspaces (the session size rule).

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::diagnostics::journal_bytes_by_kind;

/// Terminals that print (Lawrence's session: about 30 of 798 at a time).
const PRINTING_TERMINALS: usize = 30;
/// The simulated span at rest.
const SIMULATED_MINUTES: u64 = 5;
/// One step of the simulated clock: the interval at which a printing
/// terminal pushed its "last output" time (`terminal_activity.rs`).
const TICK_MS: u64 = 5_000;
const SPINNER: [&str; 4] = ["⠋", "⠙", "⠹", "⠸"];

/// What the registry holds and wrote so far.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Written {
    journal_head: u64,
    revision: u64,
    wal_commits: u64,
    wal_frame_bytes: u64,
    database_bytes: u64,
    wal_file_bytes: u64,
}

fn database_path(mux: &Mux) -> std::path::PathBuf {
    mux.journal_kernel.database_path().expect("an on-disk registry").to_path_buf()
}

fn file_bytes(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |metadata| metadata.len())
}

fn written(mux: &Mux) -> Written {
    let stats = mux.write_path_stats();
    let database = database_path(mux);
    let mut wal = database.clone().into_os_string();
    wal.push("-wal");
    Written {
        journal_head: mux.session_journal_head().unwrap(),
        revision: mux.with_state(|state| state.resource_revision),
        wal_commits: stats.wal_commits,
        wal_frame_bytes: stats.registry_wal_frame_bytes,
        database_bytes: file_bytes(&database),
        wal_file_bytes: file_bytes(Path::new(&wal)),
    }
}

fn journal_rows(mux: &Mux) -> BTreeMap<String, u64> {
    let connection =
        crate::workspace_registry::open_registry_database_read_only(&database_path(mux)).unwrap();
    journal_bytes_by_kind(&connection)
        .unwrap()
        .into_iter()
        .map(|(kind, (rows, _))| (kind, rows))
        .collect()
}

/// The journal rows added since `before`, by kind.
fn rows_added(mux: &Mux, before: &BTreeMap<String, u64>) -> BTreeMap<String, u64> {
    journal_rows(mux)
        .into_iter()
        .filter_map(|(kind, rows)| {
            let added = rows - before.get(&kind).copied().unwrap_or(0);
            (added > 0).then_some((kind, added))
        })
        .collect()
}

/// What a client reads as each terminal's `extra.last_output.at_ms`, by
/// terminal id (one session snapshot).
fn read_last_outputs(mux: &Mux) -> BTreeMap<String, String> {
    let snapshot = crate::resource_api::public_session_snapshot(mux)
        .unwrap_or_else(|error| panic!("session snapshot failed: {error:?}"));
    snapshot["terminals"]
        .as_array()
        .expect("the snapshot lists terminals")
        .iter()
        .filter_map(|terminal| {
            Some((
                terminal["id"].as_str()?.to_owned(),
                terminal["extra"]["last_output"]["at_ms"].as_str()?.to_owned(),
            ))
        })
        .collect()
}

/// One frame of a program that works: a spinner title, an OSC 9;4 progress
/// value and text.
fn working_frame(tick: u64) -> Vec<u8> {
    let glyph = SPINNER[usize::try_from(tick).unwrap() % SPINNER.len()];
    format!("\x1b]2;{glyph} build\x07\x1b]9;4;1;{}\x07line {tick}\r\n", tick % 100).into_bytes()
}

/// `surface` prints one frame at `at_ms` and its program reports `working`
/// again (OSC 7501; the test terminal has no parser callback for it, so the
/// report goes to the records as the callback gives it).
fn print_frame(surface: &Surface, tick: u64, at_ms: u64) {
    surface.apply_stream_output_for_test(&working_frame(tick)).unwrap();
    surface.report_program_status_for_test(ghostty_vt::ProgramStatusState::Working, at_ms);
    surface.note_output_at_for_test(at_ms);
}

/// `PRINTING_TERMINALS` terminals on a session of `workspaces` workspaces
/// print for `SIMULATED_MINUTES`. Nothing durable changes, so the registry
/// must not change. Then one real program status edge commits exactly once.
fn printing_terminals_at_rest(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-at-rest-writers-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("at-rest-writers", &root);
    // The worker would checkpoint and seal on its own ticks, and move bytes
    // between the files this test measures.
    mux.stop_journal_maintenance();

    // The session: with one workspace all terminals are its tabs; otherwise
    // each printing terminal has its own workspace and the rest are empty.
    let mut terminals = Vec::with_capacity(PRINTING_TERMINALS);
    if workspaces == 1 {
        terminals.push(mux.new_workspace(None, Some((80, 24))).unwrap());
        for _ in 1..PRINTING_TERMINALS {
            terminals.push(mux.new_tab(None, None, Some((80, 24))).unwrap());
        }
    } else {
        for _ in 0..PRINTING_TERMINALS {
            terminals.push(mux.new_workspace(None, Some((80, 24))).unwrap());
        }
        for index in PRINTING_TERMINALS..workspaces {
            mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
        }
    }

    // Each terminal starts: its launch directory, its first output and its
    // first `working` report are real changes and may commit.
    let start_ms = crate::workspace_registry::unix_epoch_ms().unwrap();
    for surface in &terminals {
        surface.publish_pending_directory();
        surface.publish_pending_progress();
        print_frame(surface, 0, start_ms);
        surface.publish_pending_state();
    }
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );

    let rows_before = journal_rows(&mux);
    let before = written(&mux);
    let ticks = SIMULATED_MINUTES * 60_000 / TICK_MS;
    for tick in 1..=ticks {
        for surface in &terminals {
            print_frame(surface, tick, start_ms + tick * TICK_MS);
            // What the terminal publisher runs for a terminal whose reader found a publication due.
            surface.publish_pending_state();
        }
    }
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );
    let after = written(&mux);
    let added = rows_added(&mux, &rows_before);
    println!(
        "at_rest_writers: workspaces={workspaces} terminals={PRINTING_TERMINALS} \
         simulated_minutes={SIMULATED_MINUTES} journal_rows_added={added:?} \
         revisions={} wal_commits={} wal_frame_bytes={} database_bytes={}->{} wal_file_bytes={}->{}",
        after.revision - before.revision,
        after.wal_commits - before.wal_commits,
        after.wal_frame_bytes - before.wal_frame_bytes,
        before.database_bytes,
        after.database_bytes,
        before.wal_file_bytes,
        after.wal_file_bytes,
    );
    let mut failures = Vec::new();
    if after != before || !added.is_empty() {
        failures.push(format!(
            "{PRINTING_TERMINALS} printing terminals at rest for {SIMULATED_MINUTES} simulated \
             minutes on {workspaces} workspaces wrote to the registry: journal rows {added:?}, \
             {} revisions, {} WAL commits, {} WAL frame bytes (before {before:?}, after {after:?})",
            after.revision - before.revision,
            after.wal_commits - before.wal_commits,
            after.wal_frame_bytes - before.wal_frame_bytes,
        ));
    }

    // A client that reads still gets the live fact, exact at the read.
    let last_tick_ms = (start_ms + ticks * TICK_MS).to_string();
    let read = read_last_outputs(&mux);
    for surface in &terminals {
        let id = surface.terminal_public_id().expect("a public terminal").as_str();
        if read.get(id) != Some(&last_tick_ms) {
            failures.push(format!(
                "a client read last_output {:?} of {id}, the terminal printed at {last_tick_ms}",
                read.get(id)
            ));
            break;
        }
    }
    if written(&mux) != after {
        failures.push("a client read wrote to the registry".to_owned());
    }

    // Positive control: a real program status edge (working -> idle) is one
    // commit: one revision, one journal row, WAL bytes.
    let before_edge = written(&mux);
    let rows_before_edge = journal_rows(&mux);
    let edge = &terminals[0];
    edge.report_program_status_for_test(
        ghostty_vt::ProgramStatusState::Idle,
        start_ms + ticks * TICK_MS,
    );
    edge.publish_pending_state();
    edge.publish_pending_state();
    let after_edge = written(&mux);
    let edge_rows = rows_added(&mux, &rows_before_edge);
    println!(
        "at_rest_writers: workspaces={workspaces} status_edge journal_rows_added={edge_rows:?} \
         revisions={} wal_commits={} wal_frame_bytes={}",
        after_edge.revision - before_edge.revision,
        after_edge.wal_commits - before_edge.wal_commits,
        after_edge.wal_frame_bytes - before_edge.wal_frame_bytes,
    );
    if after_edge.revision - before_edge.revision != 1
        || after_edge.journal_head - before_edge.journal_head != 1
        || edge_rows.values().sum::<u64>() != 1
        || after_edge.wal_commits == before_edge.wal_commits
        || after_edge.wal_frame_bytes == before_edge.wal_frame_bytes
    {
        failures.push(format!(
            "a program status edge (working -> idle) must commit exactly once: journal rows \
             {edge_rows:?} (before {before_edge:?}, after {after_edge:?})"
        ));
    }

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{failures:#?}");
}

#[cfg(unix)]
#[test]
fn printing_terminals_at_rest_write_nothing_on_1_workspace() {
    printing_terminals_at_rest(1);
}

#[cfg(unix)]
#[test]
fn printing_terminals_at_rest_write_nothing_on_60_workspaces() {
    printing_terminals_at_rest(60);
}

#[cfg(unix)]
#[test]
fn printing_terminals_at_rest_write_nothing_on_826_workspaces() {
    printing_terminals_at_rest(826);
}

/// A journal hook is delivered every row its filter matches. While an
/// enabled hook's kinds match `terminal.progress`, each live fact of a
/// terminal is one row again (the rate before live facts left the journal);
/// a hook for other kinds changes nothing.
#[cfg(unix)]
#[test]
fn a_journal_hook_for_terminal_progress_keeps_a_row_for_each_live_fact() {
    let root = std::env::temp_dir()
        .join(format!("cmux-at-rest-progress-hook-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("at-rest-progress-hook", &root);
    mux.stop_journal_maintenance();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.publish_pending_directory();
    surface.publish_pending_progress();
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );
    let hook = |id: &str, kind: &str| crate::JournalHookManifest {
        hook_id: id.into(),
        manifest_version: 1,
        filter: crate::JournalHookFilter { kinds: vec![kind.into()], ..Default::default() },
        exec: crate::JournalHookExec {
            argv: vec!["/usr/bin/true".into()],
            timeout_ms: 1000,
            max_parallel: 1,
        },
        delivery: crate::JournalHookDeliveryPolicy {
            start: "tail".into(),
            retry: crate::JournalHookRetry { max_attempts: 1, backoff_ms: 0 },
        },
        permissions: vec!["journal.read".into()],
    };
    // Three live facts: the terminal prints and reports a new OSC 9;4 value,
    // one output step (5 s) apart.
    let start_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    let mut tick = 0_u64;
    let mut progress_rows = |mux: &Arc<Mux>| {
        let before = journal_rows(mux);
        for _ in 0..3 {
            tick += 1;
            let frame = format!("\x1b]9;4;1;{}\x07line {tick}\r\n", tick % 100);
            surface.apply_stream_output_for_test(frame.as_bytes()).unwrap();
            surface.note_output_at_for_test(start_ms + tick * TICK_MS);
            surface.publish_pending_state();
        }
        rows_added(mux, &before).get("terminal.progress").copied().unwrap_or(0)
    };
    assert_eq!(progress_rows(&mux), 0, "no journal hook: no row");
    mux.put_journal_hook(&hook("other_kinds", "agent.*"), "test", "progress-hook-1").unwrap();
    assert_eq!(progress_rows(&mux), 0, "a hook for other kinds: no row");
    mux.put_journal_hook(&hook("progress_kinds", "terminal.progress"), "test", "progress-hook-2")
        .unwrap();
    assert_eq!(
        progress_rows(&mux),
        3,
        "a journal hook for `terminal.progress` got no row for each live fact of a terminal"
    );
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

fn observation(last_used_ms: [u64; 3]) -> Value {
    json!([
        {"path": "/srv/cmux-at-rest/alpha", "last_used_ms": last_used_ms[0].to_string()},
        {"path": "/srv/cmux-at-rest/beta", "last_used_ms": last_used_ms[1].to_string()},
        {"path": "/srv/cmux-at-rest/gamma", "last_used_ms": last_used_ms[2].to_string()},
    ])
}

/// The app sends one complete `project.observe` per chat index change. An
/// observation equal to the stored projects is not a change: no revision, no
/// journal row, no WAL byte. One with a newer time is one commit.
#[cfg(unix)]
#[test]
fn an_equal_project_observation_writes_nothing() {
    let root = std::env::temp_dir()
        .join(format!("cmux-at-rest-projects-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("at-rest-projects", &root);
    mux.stop_journal_maintenance();
    let observe = |entries: &Value| {
        mux.state_project_observe(
            &WorkspaceMutation::daemon_local("at-rest-test"),
            "acpmux",
            entries,
            true,
        )
        .unwrap()
    };

    let before_first = written(&mux);
    let first = observe(&observation([1_000, 2_000, 3_000]));
    let after_first = written(&mux);
    assert_eq!(
        after_first.revision - before_first.revision,
        1,
        "the first observation is one commit: {first:?}"
    );

    let rows_before = journal_rows(&mux);
    for _ in 0..100 {
        let equal = observe(&observation([1_000, 2_000, 3_000]));
        assert_eq!(equal.result["changed"], json!([]), "an equal observation changed a project");
    }
    let after_equal = written(&mux);
    let added = rows_added(&mux, &rows_before);
    println!(
        "at_rest_writers: project.observe equal x100 journal_rows_added={added:?} revisions={} \
         wal_commits={} wal_frame_bytes={}",
        after_equal.revision - after_first.revision,
        after_equal.wal_commits - after_first.wal_commits,
        after_equal.wal_frame_bytes - after_first.wal_frame_bytes,
    );
    let mut failures = Vec::new();
    if after_equal != after_first || !added.is_empty() {
        failures.push(format!(
            "100 project observations equal to the stored projects wrote to the registry: \
             journal rows {added:?}, {} revisions, {} WAL commits, {} WAL frame bytes",
            after_equal.revision - after_first.revision,
            after_equal.wal_commits - after_first.wal_commits,
            after_equal.wal_frame_bytes - after_first.wal_frame_bytes,
        ));
    }

    // Positive control: a newer use of one project is one commit.
    let changed = observe(&observation([1_000, 2_000, 9_000]));
    let after_changed = written(&mux);
    if changed.result["changed"] != json!(["/srv/cmux-at-rest/gamma"])
        || after_changed.revision - after_equal.revision != 1
        || after_changed.journal_head - after_equal.journal_head != 1
        || after_changed.wal_commits == after_equal.wal_commits
    {
        failures.push(format!(
            "a changed observation must commit exactly once: result {}, before {after_equal:?}, \
             after {after_changed:?}",
            changed.result
        ));
    }

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{failures:#?}");
}
