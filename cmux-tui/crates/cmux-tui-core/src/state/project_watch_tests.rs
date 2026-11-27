use super::*;
use std::path::Path;
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

/// A hint comes at most 1 s after a burst starts: 3 s leaves room for a
/// loaded host.
const CHANGE_WITHIN: Duration = Duration::from_secs(3);
const NO_CHANGE_FOR: Duration = Duration::from_millis(800);

struct Home(PathBuf);

impl Home {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("cmux-project-watch-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn layout(&self) -> Layout {
        if cfg!(target_os = "macos") {
            Layout::macos(&self.0)
        } else {
            Layout::linux(&self.0, None, None)
        }
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn armed(layout: &Layout) -> ((cmux_config::watch::Watcher, ImportWorker), Receiver<()>) {
    let (change, changes) = mpsc::channel();
    let watch = watch_files(layout.watch_files(), move || {
        let _ = change.send(());
    })
    .expect("the watch starts");
    changes.recv_timeout(CHANGE_WITHIN).expect("the start-up import runs when armed");
    (watch, changes)
}

fn expect_change(changes: &Receiver<()>, what: &str) {
    assert!(changes.recv_timeout(CHANGE_WITHIN).is_ok(), "{what} was not seen");
    while changes.recv_timeout(Duration::from_millis(300)).is_ok() {}
}

fn expect_none(changes: &Receiver<()>, what: &str) {
    assert!(changes.recv_timeout(NO_CHANGE_FOR).is_err(), "{what} ran an import");
}

fn append(path: &Path, text: &str) {
    use std::io::Write as _;
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    file.write_all(text.as_bytes()).unwrap();
    file.sync_all().unwrap();
}

#[test]
fn the_watch_lists_each_file_a_source_reads_and_no_other() {
    let home = Home::new("files");
    let layout = home.layout();
    let files = layout.watch_files();
    assert!(files.contains(&layout.codex_global_state()));
    assert!(files.contains(&layout.conductor_db()));
    assert!(files.iter().any(|file| file.ends_with("conductor.db-wal")));
    assert!(files.iter().all(|file| file.parent() != Some(&*home.0.join(".codex"))
        || file.ends_with(".codex-global-state.json")));
}

#[test]
fn a_source_file_replaced_by_rename_is_seen() {
    let home = Home::new("rename");
    let layout = home.layout();
    let state = layout.codex_global_state();
    std::fs::create_dir_all(state.parent().unwrap()).unwrap();
    std::fs::write(&state, "{}").unwrap();
    let (_watch, changes) = armed(&layout);
    for round in 0..2 {
        let staged = state.with_extension("json.tmp");
        std::fs::write(&staged, format!("{{\"round\": {round}}}")).unwrap();
        std::fs::rename(&staged, &state).unwrap();
        expect_change(&changes, "a state file replaced by rename");
    }
    // The replaced file's own writes are watched too.
    append(&state, " ");
    expect_change(&changes, "a write to the replacing file");
}

#[test]
fn a_source_file_created_later_and_its_log_written_in_place_are_seen() {
    let home = Home::new("later-file");
    let layout = home.layout();
    let db = layout.conductor_db();
    std::fs::create_dir_all(db.parent().unwrap()).unwrap();
    let (_watch, changes) = armed(&layout);
    std::fs::write(&db, "db").unwrap();
    expect_change(&changes, "a database created after the watch");
    // A writer keeps its log open: writes with no close in between.
    let log = PathBuf::from(format!("{}-wal", db.display()));
    std::fs::write(&log, "").unwrap();
    expect_change(&changes, "a log created after the watch");
    use std::io::Write as _;
    let mut writer = std::fs::OpenOptions::new().append(true).open(&log).unwrap();
    writer.write_all(b"commit").unwrap();
    writer.sync_all().unwrap();
    expect_change(&changes, "a commit to an open log");
}

#[test]
fn a_source_folder_created_later_is_seen() {
    let home = Home::new("later-folder");
    let layout = home.layout();
    let (_watch, changes) = armed(&layout);
    // Neither ~/.codex nor ~/.t3/userdata exists when the watch starts.
    let state = layout.codex_global_state();
    std::fs::create_dir_all(state.parent().unwrap()).unwrap();
    std::fs::write(&state, "{}").unwrap();
    expect_change(&changes, "a state file in a folder made after the watch");
    let [db, _] = layout.t3code_dbs();
    std::fs::create_dir_all(db.parent().unwrap()).unwrap();
    expect_none(&changes, "an empty folder");
    std::fs::write(&db, "db").unwrap();
    expect_change(&changes, "a database two folders below one made after the watch");
}

#[test]
fn writes_to_files_no_source_reads_are_not_seen() {
    let home = Home::new("unread");
    let layout = home.layout();
    let codex = home.0.join(".codex");
    std::fs::create_dir_all(&codex).unwrap();
    std::fs::write(layout.codex_global_state(), "{}").unwrap();
    let (_watch, changes) = armed(&layout);
    for round in 0..20 {
        append(&codex.join("logs_2.sqlite-wal"), &format!("{round}\n"));
        // The scan's own read-only open of a database makes its
        // shared-memory index: never a change.
        append(&codex.join("state_5.sqlite-shm"), "x");
    }
    std::fs::write(codex.join("history.jsonl.tmp"), "x").unwrap();
    std::fs::rename(codex.join("history.jsonl.tmp"), codex.join("history.jsonl")).unwrap();
    expect_none(&changes, "writes to files no source reads");
}

/// A change during a long import is not lost and is not queued: the
/// marks that come meanwhile are one more import, run when it ends.
#[test]
fn a_change_during_a_long_import_runs_one_more_import() {
    let home = Home::new("long-import");
    let layout = home.layout();
    let state = layout.codex_global_state();
    std::fs::create_dir_all(state.parent().unwrap()).unwrap();
    std::fs::write(&state, "{}").unwrap();
    let (started, imports) = mpsc::channel();
    let mut calls = 0;
    let _watch = watch_files(layout.watch_files(), move || {
        calls += 1;
        let _ = started.send(calls);
        if calls == 2 {
            std::thread::sleep(Duration::from_millis(1500));
        }
    })
    .expect("the watch starts");
    assert_eq!(imports.recv_timeout(CHANGE_WITHIN), Ok(1), "the start-up import");
    std::fs::write(&state, "{\"round\": 1}").unwrap();
    assert_eq!(imports.recv_timeout(CHANGE_WITHIN), Ok(2), "the long import starts");
    for round in 2..5 {
        let staged = state.with_extension("json.tmp");
        std::fs::write(&staged, format!("{{\"round\": {round}}}")).unwrap();
        std::fs::rename(&staged, &state).unwrap();
    }
    assert_eq!(
        imports.recv_timeout(Duration::from_millis(1500) + CHANGE_WITHIN),
        Ok(3),
        "the changes made during the long import"
    );
    assert!(imports.recv_timeout(NO_CHANGE_FOR).is_err(), "the changes were queued, not merged");
}
