//! Resync of the editor and app project sources (plans/cmux-next/projects.md
//! section 4): one import at daemon start, then a kernel watch of exactly the
//! files the sources read ([`Layout::watch_files`]) through
//! `cmux_config::watch`: kqueue vnode watches on macOS, inotify on Linux. No
//! timer and no polling. A burst of events gives one hint; a hint whose files
//! did not change (size, time, inode) costs a few stats, not a rescan, and
//! only a source whose list changed since the last import is committed, so an
//! editor writing its state file without a new recent folder costs one read.
//!
//! A watch of each whole folder (notify's FSEvents stream) woke the daemon for
//! every write in the folder, also to files no source reads: Codex appends to
//! its logs in ~/.codex several times a second, which was 230-238 context
//! switches per 12 s window at 20 writes a second, on a machine whose many
//! Codex agents keep that folder busy all day. Here a folder's watch reports
//! only its entries being created, removed or renamed, and each read file has
//! a watch of its own writes, so a write to another file of the folder never
//! reaches the process. A file that does not exist yet, or a folder that does
//! not, is watched through the nearest existing folder above it until it
//! appears; a file replaced by rename is watched again at its path.
//! The watch thread is `cmux_config::watch`'s; the hint runs on it.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::SystemTime;

use crate::mux::Mux;
use crate::state::project_sources::{self, Layout, SourceScan};
use crate::state::projects::Observation;

/// The daemon's watch of the project sources' files; dropped with the mux.
#[derive(Default)]
pub(crate) struct ProjectWatch(Mutex<Option<cmux_config::watch::Watcher>>);

/// Arms the watch; its first hint, on the watch thread, runs the start-up
/// import. Returns at once.
pub(crate) fn start(mux: &Arc<Mux>) {
    // In-crate tests build many a `Mux`: none reads the real HOME's editor data (the daemon
    // binary's socket tests set their own HOME).
    if cfg!(test) || !project_sources::enabled() {
        return;
    }
    let Some(layout) = Layout::current() else { return };
    let mux_weak = Arc::downgrade(mux);
    let mut imported: HashMap<&'static str, Vec<Observation>> = HashMap::new();
    let files = layout.watch_files();
    let watch = watch_files(files, move || import_changed(&mux_weak, &layout, &mut imported));
    match watch {
        // A folder that cannot be watched is read at the next daemon start, or on a
        // `project.sync` request (the app sends none since A14).
        Ok(watch) => {
            *mux.project_watch.0.lock().unwrap_or_else(PoisonError::into_inner) = Some(watch);
        }
        Err(error) => note(&format!("project sources watch unavailable: {error}")),
    }
}

fn note(message: &str) {
    eprintln!("cmux-tui: {message}");
}

/// Watches `files` and runs `on_change` once when armed, then after each burst
/// of events that changed one of them.
fn watch_files(
    files: Vec<PathBuf>,
    mut on_change: impl FnMut() + Send + 'static,
) -> notify::Result<cmux_config::watch::Watcher> {
    let mut seen = None;
    let stamped = files.clone();
    cmux_config::watch::Watcher::start_with_writes(files, move || {
        // Taken before the read it describes: a write during the read changes
        // the next fingerprint, and its event reads again.
        let now = fingerprint(&stamped);
        if seen.as_ref() != Some(&now) {
            seen = Some(now);
            on_change();
        }
    })
}

/// Size, modification time and inode of each file.
pub(crate) fn fingerprint(files: &[PathBuf]) -> Vec<Option<(u64, SystemTime, u64)>> {
    files
        .iter()
        .map(|path| {
            let meta = std::fs::metadata(path).ok()?;
            #[cfg(unix)]
            let inode = std::os::unix::fs::MetadataExt::ino(&meta);
            #[cfg(not(unix))]
            let inode = 0;
            Some((meta.len(), meta.modified().ok()?, inode))
        })
        .collect()
}

/// Rescans every source and commits the ones whose list changed. Nothing
/// when the daemon is gone.
pub(crate) fn import_changed(
    mux: &Weak<Mux>,
    layout: &Layout,
    imported: &mut HashMap<&'static str, Vec<Observation>>,
) {
    let Some(mux) = mux.upgrade() else { return };
    let changed: Vec<SourceScan> = project_sources::scan_all(layout)
        .into_iter()
        .filter(|scan| imported.get(scan.source) != Some(&scan.entries))
        .collect();
    if changed.is_empty() {
        return;
    }
    match mux.state_project_import(&changed) {
        Ok(_) => {
            for scan in changed {
                imported.insert(scan.source, scan.entries);
            }
        }
        Err(error) => note(&format!("project import failed: {error}")),
    }
}

#[cfg(test)]
mod tests {
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
            let path = std::env::temp_dir()
                .join(format!("cmux-project-watch-{name}-{}", std::process::id()));
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

    fn armed(layout: &Layout) -> (cmux_config::watch::Watcher, Receiver<()>) {
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
}
