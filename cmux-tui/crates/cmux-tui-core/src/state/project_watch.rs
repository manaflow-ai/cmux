//! Resync of the editor and app project sources (plans/cmux-next/projects.md
//! section 4): one import at daemon start, then a file watch on the few
//! folders the sources read (FSEvents on macOS, inotify on Linux). No timer
//! and no polling. A burst of events is drained before one rescan; only a
//! source whose list changed since the last import is committed, so an
//! editor writing its state file without a new recent folder costs one read.

use cmux_threads::checked::fs as files;
use cmux_threads::checked::sync as waits;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Weak};
use std::time::SystemTime;

use notify::Watcher as _;

use crate::mux::Mux;
use crate::state::project_sources::{self, Layout, SourceScan, WATCHED_NAMES};
use crate::state::projects::Observation;

/// Starts the import and the watch on its own thread; returns at once.
pub(crate) fn start(mux: &Arc<Mux>) {
    // In-crate tests build many a `Mux`: none reads the real HOME's editor data (the daemon
    // binary's socket tests set their own HOME).
    if cfg!(test) || !project_sources::enabled() {
        return;
    }
    let Some(layout) = Layout::current() else { return };
    let weak = Arc::downgrade(mux);
    if let Err(error) = spawn_thread(move || run(&weak, &layout)) {
        note(&format!("project sources thread did not start: {error}"));
    }
}

/// Starts `body` on the `mux-project-sources` thread. An upkeep thread
/// (p04-input-084): each import pass runs at utility (`import_changed`),
/// raised while it holds the registry a request waits for.
pub(crate) fn spawn_thread(
    body: impl FnOnce() + Send + 'static,
) -> std::io::Result<std::thread::JoinHandle<()>> {
    cmux_threads::spawn("mux-project-sources", crate::request_qos::UPKEEP_THREAD_QOS, body)
}

fn note(message: &str) {
    eprintln!("cmux-tui: {message}");
}

#[track_caller]
fn run(mux: &Weak<Mux>, layout: &Layout) {
    let (sender, events) = channel();
    let watcher = notify::recommended_watcher(move |event| {
        let _ = sender.send(event);
    });
    let mut watcher = match watcher {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            note(&format!("project sources watch unavailable: {error}"));
            None
        }
    };
    if let Some(watcher) = watcher.as_mut() {
        for dir in layout.watch_dirs().iter().filter(|dir| dir.is_dir()) {
            // A folder that cannot be watched is picked up on project.sync.
            let _ = watcher.watch(dir, notify::RecursiveMode::NonRecursive);
        }
    }
    let mut imported: HashMap<&'static str, Vec<Observation>> = HashMap::new();
    let dirs = layout.watch_dirs();
    let mut seen = fingerprint(&dirs);
    if !import_changed(mux, layout, &mut imported) {
        return;
    }
    if watcher.is_none() {
        return;
    }
    while next_relevant(&events) {
        // An event with no source file changed (a reader's lock, a touch)
        // costs a few stats, not a rescan of every store.
        let now = fingerprint(&dirs);
        if now == seen {
            continue;
        }
        seen = now;
        if !import_changed(mux, layout, &mut imported) {
            return;
        }
    }
}

/// Size and modification time of every source file and its write-ahead log
/// in the watched folders.
fn fingerprint(dirs: &[PathBuf]) -> Vec<(PathBuf, Option<(u64, SystemTime)>)> {
    dirs.iter()
        .flat_map(|dir| {
            WATCHED_NAMES
                .iter()
                .flat_map(move |name| [dir.join(name), dir.join(format!("{name}-wal"))])
        })
        .map(|path| {
            let stamp = files::metadata(&path)
                .ok()
                .and_then(|meta| Some((meta.len(), meta.modified().ok()?)));
            (path, stamp)
        })
        .collect()
}

/// Waits for an event on a source file, then drains the burst queued behind
/// it. False when the watch ended.
fn next_relevant(events: &Receiver<notify::Result<notify::Event>>) -> bool {
    loop {
        let Ok(event) = waits::recv(events) else { return false };
        if relevant(&event) {
            while events.try_recv().is_ok() {}
            return true;
        }
    }
}

fn relevant(event: &notify::Result<notify::Event>) -> bool {
    let Ok(event) = event else { return true };
    event.paths.iter().any(|path| is_source_path(path))
}

/// A source file, its write-ahead log or a temporary copy an editor renames
/// over it. Not SQLite's shared-memory index (`-shm`): the scan's own
/// read-only open writes it, so watching it made every scan wake the next
/// one and kept this thread busy for good.
fn is_source_path(path: &Path) -> bool {
    path.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
        !name.ends_with("-shm") && WATCHED_NAMES.iter().any(|watched| name.starts_with(watched))
    })
}

/// Rescans every source and commits the ones whose list changed. False when
/// the daemon is gone.
#[track_caller]
fn import_changed(
    mux: &Weak<Mux>,
    layout: &Layout,
    imported: &mut HashMap<&'static str, Vec<Observation>>,
) -> bool {
    let Some(mux) = mux.upgrade() else { return false };
    let _pass = mux.request_qos().enter_upkeep_pass();
    let changed: Vec<SourceScan> = project_sources::scan_all(layout)
        .into_iter()
        .filter(|scan| imported.get(scan.source) != Some(&scan.entries))
        .collect();
    if changed.is_empty() {
        return true;
    }
    match mux.state_project_import(&changed) {
        Ok(_) => {
            for scan in changed {
                imported.insert(scan.source, scan.entries);
            }
        }
        Err(error) => note(&format!("project import failed: {error}")),
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(path: &str) -> notify::Result<notify::Event> {
        Ok(notify::Event::new(notify::EventKind::Any).add_path(PathBuf::from(path)))
    }

    #[test]
    fn a_readers_shared_memory_index_does_not_wake_the_watch() {
        assert!(!relevant(&event("/a/com.conductor.app/conductor.db-shm")));
        assert!(!relevant(&event("/a/.t3/userdata/state.sqlite-shm")));
    }

    #[test]
    fn a_source_file_or_its_log_wakes_the_watch() {
        assert!(relevant(&event("/a/com.conductor.app/conductor.db")));
        assert!(relevant(&event("/a/.t3/userdata/state.sqlite-wal")));
        assert!(relevant(&event("/a/User/globalStorage/storage.json")));
        assert!(!relevant(&event("/a/.codex/logs_2.sqlite-wal")));
    }

    /// An import pass runs at utility with `daemonRequestQos` on, and at
    /// the declared class with it off (p04-input-084).
    #[test]
    fn an_import_pass_runs_at_utility_with_the_feature_on() {
        use crate::request_qos::tests::take_entered;
        let home = std::env::temp_dir().join(format!("cmux-project-qos-{}", std::process::id()));
        let layout = Layout::linux(&home, None, None);
        let mux = Mux::new_for_test("project-import-qos", crate::SurfaceOptions::default());
        let weak = Arc::downgrade(&mux);
        let _ = take_entered();
        assert!(import_changed(&weak, &layout, &mut HashMap::new()));
        assert!(take_entered().is_empty(), "the feature is off");
        mux.set_request_qos_for_test(true);
        assert!(import_changed(&weak, &layout, &mut HashMap::new()));
        assert_eq!(take_entered(), vec![cmux_threads::ThreadQos::Utility]);
    }

    #[test]
    fn the_fingerprint_changes_only_when_a_source_file_changes() {
        let dir = std::env::temp_dir().join(format!("cmux-project-watch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dirs = vec![dir.clone()];
        let before = fingerprint(&dirs);
        std::fs::write(dir.join("conductor.db-shm"), b"reader").unwrap();
        std::fs::write(dir.join("unrelated.json"), b"{}").unwrap();
        assert_eq!(fingerprint(&dirs), before);
        std::fs::write(dir.join("conductor.db-wal"), b"commit").unwrap();
        assert_ne!(fingerprint(&dirs), before);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
