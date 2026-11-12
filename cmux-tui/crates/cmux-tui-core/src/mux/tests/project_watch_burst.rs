//! What one burst of the project-source watch costs its watch thread, and
//! how long the import it asks for runs on the import worker
//! (`state/project_watch.rs`), on a real `Mux` with an on-disk registry of
//! 826 workspaces (the session size rule) and a home whose sources each list
//! 200 projects, with the databases in write-ahead-log mode and a writer
//! holding each one open.
//!
//! The rule for a watch thread: no burst keeps it busy over 20 ms. The import
//! itself took 92 ms at start and up to 42 ms per change when it ran on the
//! watch thread, so it runs on the worker and the watch thread only marks it
//! as wanted ([`Marks::mark`]). Each watch has its own thread besides
//! (`cmux-config` `tests/watch.rs` `a_busy_watch_does_not_delay_another_watch`).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;
use crate::state::project_sources::Layout;
use crate::state::project_watch::{ImportWorker, import_changed};

/// Projects each source lists.
const PROJECTS: usize = 200;
/// Imports timed per kind of change.
const ROUNDS: u64 = 20;
/// The rule for one burst on a watch thread.
const BURST_BOUND: Duration = Duration::from_millis(20);
/// How long a pass may take to finish on a loaded host.
const PASS_WITHIN: Duration = Duration::from_secs(10);

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
    let local: Map<String, Value> = (0..projects)
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
    writers: Vec<rusqlite::Connection>,
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
        let entries: Vec<Value> = (0..PROJECTS)
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
        Self { path, layout, writers: vec![t3, conductor, vscode] }
    }

    fn t3(&self) -> &rusqlite::Connection {
        &self.writers[0]
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[test]
fn a_project_watch_burst_keeps_its_watch_thread_busy_under_the_bound() {
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
    let layout = home.layout.clone();
    let mut imported = HashMap::new();
    let times: Arc<Mutex<Vec<Duration>>> = Arc::default();
    let recorded = Arc::clone(&times);
    let worker = ImportWorker::start(home.layout.watch_files(), move || {
        let started = Instant::now();
        import_changed(&weak, &layout, &mut imported);
        recorded.lock().unwrap().push(started.elapsed());
    })
    .unwrap();
    let marks = Arc::clone(&worker.shared);
    // The watch thread's work for one burst, timed as it runs.
    let mut marked = Vec::new();
    let mut mark = || {
        let started = Instant::now();
        marks.mark();
        marked.push(started.elapsed());
    };

    mark();
    assert!(marks.wait_passes(1, PASS_WITHIN), "the start-up import did not finish");
    for round in 0..ROUNDS {
        // A commit to a source that changes no project (the app saved other state).
        home.t3()
            .execute("UPDATE projection_projects SET deleted_at = NULL WHERE rowid = 1", [])
            .unwrap();
        mark();
        // A new project in Codex's list, marked twice (two bursts).
        codex_state(&home.layout, PROJECTS + 1 + round as usize);
        mark();
        mark();
        let passes = marks.passes();
        assert!(marks.wait_passes(passes + 1, PASS_WITHIN), "round {round}: no pass ran");
        // Settled: the marks of this round are all taken.
        while marks.wait_passes(marks.passes() + 1, Duration::from_millis(300)) {}
    }
    let imports = times.lock().unwrap().clone();
    let longest = |times: &[Duration]| times.iter().max().copied().unwrap_or_default();
    let median = |times: &[Duration]| {
        let mut sorted = times.to_vec();
        sorted.sort();
        sorted.get(sorted.len() / 2).copied().unwrap_or_default()
    };
    println!(
        "project_watch_burst: 826 workspaces, {PROJECTS} projects in each of 4 sources | watch thread per \
         mark: median {:.3} ms, max {:.3} ms ({} marks) | import on the worker: start-up {:.1} ms, \
         later median {:.1} ms, max {:.1} ms ({} imports, {} passes)",
        median(&marked).as_secs_f64() * 1000.0,
        longest(&marked).as_secs_f64() * 1000.0,
        marked.len(),
        imports.first().copied().unwrap_or_default().as_secs_f64() * 1000.0,
        median(imports.get(1..).unwrap_or_default()).as_secs_f64() * 1000.0,
        longest(imports.get(1..).unwrap_or_default()).as_secs_f64() * 1000.0,
        imports.len(),
        marks.passes(),
    );
    drop(marks);
    drop(worker);
    drop(mux);
    let _ = std::fs::remove_dir_all(&state);
    let slowest = longest(&marked);
    assert!(
        slowest <= BURST_BOUND,
        "one project-watch burst kept its watch thread busy {slowest:?} (bound {BURST_BOUND:?})"
    );
}
