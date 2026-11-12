//! How long one hint of the project-source watch keeps its thread busy
//! (`state/project_watch.rs`): the fingerprint of the watched files, the
//! rescan of every source and the commit of the changed ones, on a real
//! `Mux` with an on-disk registry of 826 workspaces (the session size rule)
//! and a home whose sources each list 200 projects, with the databases in
//! write-ahead-log mode and a writer holding each one open.
//!
//! The thread is the watch's own (`cmux_config::watch` starts one per
//! watcher), so a long hint delays only the next project rescan, never the
//! settings or acpmux socket watches (`cmux-config` `tests/watch.rs`
//! `a_busy_watch_does_not_delay_another_watch`). The bound here is the lead's
//! rule for work on a watch thread: 20 ms for the bursts that come while the
//! daemon runs (a source writes, with or without a new project).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::*;
use crate::state::project_sources::Layout;
use crate::state::project_watch::{fingerprint, import_changed};

/// Projects each source lists.
const PROJECTS: usize = 200;
/// Hints timed per kind of burst.
const ROUNDS: usize = 20;
/// The rule for one burst while the daemon runs.
const BURST_BOUND: Duration = Duration::from_millis(20);

fn root(index: usize) -> String {
    format!("/Users/someone/src/project-{index:03}")
}

/// A database in write-ahead-log mode with `rows`, and the connection that
/// keeps its log open (as the app that owns it does).
fn database(path: &Path, schema: &str, insert: &str, rows: usize) -> rusqlite::Connection {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let connection = rusqlite::Connection::open(path).unwrap();
    connection.pragma_update(None, "journal_mode", "WAL").unwrap();
    connection.execute_batch(schema).unwrap();
    for index in 0..rows {
        connection.execute(insert, rusqlite::params![root(index), index as i64]).unwrap();
    }
    connection
}

fn codex_state(layout: &Layout, projects: usize) {
    let local: serde_json::Map<String, serde_json::Value> = (0..projects)
        .map(|index| {
            (
                format!("id-{index}"),
                serde_json::json!({"rootPaths": [root(index)], "updatedAt": 1_700_000_000_000_i64 + index as i64}),
            )
        })
        .collect();
    let saved: Vec<String> = (0..projects).map(|index| format!("{}-saved", root(index))).collect();
    let state = serde_json::json!({
        "local-projects": local,
        "electron-saved-workspace-roots": saved,
        // The rest of the file the app keeps (window state, flags): read and dropped.
        "other": (0..2000).map(|index| format!("value-{index}")).collect::<Vec<_>>(),
    });
    let file = layout.codex_global_state();
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let staged = file.with_extension("json.tmp");
    std::fs::write(&staged, state.to_string()).unwrap();
    std::fs::rename(staged, file).unwrap();
}

struct Home {
    path: PathBuf,
    layout: Layout,
    _writers: Vec<rusqlite::Connection>,
}

impl Home {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .join(format!("cmux-project-burst-{}", crate::workspace_registry::new_uuid_v4()));
        let layout = if cfg!(target_os = "macos") {
            Layout::macos(&path)
        } else {
            Layout::linux(&path, None, None)
        };
        codex_state(&layout, PROJECTS);
        let [t3, _] = layout.t3code_dbs();
        let t3 = database(
            &t3,
            "CREATE TABLE projection_projects (workspace_root TEXT, updated_at TEXT, deleted_at TEXT);",
            "INSERT INTO projection_projects VALUES (?1, '2026-11-0' || (?2 % 9 + 1) || 'T10:00:00Z', NULL)",
            PROJECTS,
        );
        let conductor = database(
            &layout.conductor_db(),
            "CREATE TABLE repos (root_path TEXT, updated_at TEXT, hidden INTEGER);",
            "INSERT INTO repos VALUES (?1, '2026-11-0' || (?2 % 9 + 1) || ' 10:00:00', 0)",
            PROJECTS,
        );
        let entries: Vec<serde_json::Value> = (0..PROJECTS)
            .map(|index| serde_json::json!({"folderUri": format!("file://{}", root(index))}))
            .collect();
        let vscode = database(
            &layout.vscode_user_dir("Code").join("globalStorage").join("state.vscdb"),
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);",
            "INSERT INTO ItemTable VALUES ('filler-' || ?1, ?2)",
            PROJECTS,
        );
        vscode
            .execute(
                "INSERT INTO ItemTable VALUES ('history.recentlyOpenedPathsList', ?1)",
                [serde_json::json!({"entries": entries}).to_string()],
            )
            .unwrap();
        Self { path, layout, _writers: vec![t3, conductor, vscode] }
    }

    fn t3(&self) -> &rusqlite::Connection {
        &self._writers[0]
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[test]
fn a_project_watch_burst_keeps_its_thread_busy_under_the_bound() {
    let home = Home::new();
    let state = std::env::temp_dir()
        .join(format!("cmux-project-burst-state-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("project-burst", &state);
    mux.stop_journal_maintenance();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    for index in 1..826 {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
    }
    let weak = Arc::downgrade(&mux);
    let files = home.layout.watch_files();
    let mut imported = std::collections::HashMap::new();
    // One hint, as the watch thread runs it.
    let mut hint = || {
        let started = Instant::now();
        let _ = fingerprint(&files);
        import_changed(&weak, &home.layout, &mut imported);
        started.elapsed()
    };

    let first = hint();
    let mut same = Vec::new();
    let mut new_project = Vec::new();
    for round in 0..ROUNDS {
        // A commit to a source that changes no project (the app saved other state).
        home.t3()
            .execute("UPDATE projection_projects SET deleted_at = NULL WHERE rowid = 1", [])
            .unwrap();
        same.push(hint());
        // A new project in Codex's list.
        codex_state(&home.layout, PROJECTS + 1 + round);
        new_project.push(hint());
    }
    let max = |times: &[Duration]| times.iter().max().copied().unwrap_or_default();
    let median = |times: &[Duration]| {
        let mut sorted = times.to_vec();
        sorted.sort();
        sorted[sorted.len() / 2]
    };
    println!(
        "project_watch_burst: 826 workspaces, {PROJECTS} projects in each of 4 sources | start-up import \
         {:.1} ms | write with no new project: median {:.1} ms, max {:.1} ms | new project: median {:.1} ms, \
         max {:.1} ms ({ROUNDS} rounds)",
        first.as_secs_f64() * 1000.0,
        median(&same).as_secs_f64() * 1000.0,
        max(&same).as_secs_f64() * 1000.0,
        median(&new_project).as_secs_f64() * 1000.0,
        max(&new_project).as_secs_f64() * 1000.0,
    );
    drop(hint);
    drop(mux);
    let _ = std::fs::remove_dir_all(&state);
    let slowest = max(&same).max(max(&new_project));
    assert!(
        slowest <= BURST_BOUND,
        "one project-watch burst kept its thread busy {slowest:?} (bound {BURST_BOUND:?})"
    );
}
