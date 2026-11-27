//! A project observation equal to the stored projects writes nothing
//! (REGISTRY WAL, PR 1).
//!
//! The app sends one complete `project.observe` per chat index change and
//! one on each connection. On one Mac (826 workspaces, 2 h) the lock site
//! `state/projects_ops.rs` took the workspace registry 3020 times, and each
//! take committed a resource revision, a ledger row and a journal row: 47 MB
//! of journal a day for observations that said what the registry already
//! held.
//!
//! The test runs a real `Mux` on an on-disk registry and counts, at the
//! registry: journal rows, resource revisions, WAL commits and WAL frame
//! bytes. Counts, not times, so the result does not depend on the machine.
//! Arms: 1, 60 and 826 workspaces (the session size rule).

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::diagnostics::journal_bytes_by_kind;

/// Observations the app sent while nothing changed.
const EQUAL_OBSERVATIONS: usize = 100;

/// What the registry holds and wrote so far.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Written {
    journal_head: u64,
    revision: u64,
    wal_commits: u64,
    wal_frame_bytes: u64,
}

fn written(mux: &Mux) -> Written {
    let stats = mux.write_path_stats();
    Written {
        journal_head: mux.session_journal_head().unwrap(),
        revision: mux.with_state(|state| state.resource_revision),
        wal_commits: stats.wal_commits,
        wal_frame_bytes: stats.registry_wal_frame_bytes,
    }
}

fn journal_rows(mux: &Mux) -> BTreeMap<String, u64> {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry").to_path_buf();
    let connection =
        crate::workspace_registry::open_registry_database_read_only(&database).unwrap();
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

fn observation(last_used_ms: [u64; 3]) -> Value {
    json!([
        {"path": "/srv/cmux-at-rest/alpha", "last_used_ms": last_used_ms[0].to_string()},
        {"path": "/srv/cmux-at-rest/beta", "last_used_ms": last_used_ms[1].to_string()},
        {"path": "/srv/cmux-at-rest/gamma", "last_used_ms": last_used_ms[2].to_string()},
    ])
}

/// On a session of `workspaces` workspaces, `EQUAL_OBSERVATIONS`
/// observations equal to the stored projects must not change the registry.
/// Then one with a newer time commits exactly once.
fn equal_project_observations(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-at-rest-projects-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("at-rest-projects", &root);
    // The worker would checkpoint and seal on its own ticks, which commit.
    mux.stop_journal_maintenance();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    for index in 1..workspaces {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
    }
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
    for _ in 0..EQUAL_OBSERVATIONS {
        let equal = observe(&observation([1_000, 2_000, 3_000]));
        assert_eq!(equal.result["changed"], json!([]), "an equal observation changed a project");
    }
    let after_equal = written(&mux);
    let added = rows_added(&mux, &rows_before);
    println!(
        "project_observe_at_rest: workspaces={workspaces} equal_observations={EQUAL_OBSERVATIONS} \
         journal_rows_added={added:?} revisions={} wal_commits={} wal_frame_bytes={}",
        after_equal.revision - after_first.revision,
        after_equal.wal_commits - after_first.wal_commits,
        after_equal.wal_frame_bytes - after_first.wal_frame_bytes,
    );
    let mut failures = Vec::new();
    if after_equal != after_first || !added.is_empty() {
        failures.push(format!(
            "{EQUAL_OBSERVATIONS} project observations equal to the stored projects wrote to the \
             registry of {workspaces} workspaces: journal rows {added:?}, {} revisions, {} WAL \
             commits, {} WAL frame bytes",
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

#[cfg(unix)]
#[test]
fn equal_project_observations_write_nothing_on_1_workspace() {
    equal_project_observations(1);
}

#[cfg(unix)]
#[test]
fn equal_project_observations_write_nothing_on_60_workspaces() {
    equal_project_observations(60);
}

#[cfg(unix)]
#[test]
fn equal_project_observations_write_nothing_on_826_workspaces() {
    equal_project_observations(826);
}
