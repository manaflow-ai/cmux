//! Resync of the editor and app project sources (plans/cmux-next/projects.md
//! section 4): one import at daemon start, then a kernel watch of exactly the
//! files the sources read ([`Layout::watch_files`]) through
//! `cmux_config::watch`: kqueue vnode watches on macOS, inotify on Linux. No
//! timer and no polling.
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
//!
//! Two threads, both owned by [`ProjectWatch`] (a field of the mux) and joined
//! when it drops: the watch's own, which only marks an import as wanted, and
//! the import worker (`mux-project-import`), which takes the mark, compares
//! the files' fingerprint (size, time, inode) and, when it changed, rescans
//! every source and commits the ones whose list changed. The import can take
//! longer than a watch thread may be busy (92 ms at start and up to 42 ms per
//! change on a home with 200 projects per source and 826 workspaces,
//! `mux/tests/project_watch_burst.rs`), and the watch thread must be free for
//! the next event. Bursts that come during an import are one more import,
//! never a queue: the mark is a flag.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::thread::JoinHandle;
use std::time::SystemTime;

use crate::mux::Mux;
use crate::state::project_sources::{self, Layout, SourceScan};
use crate::state::projects::Observation;

/// The daemon's watch of the project sources' files and its import worker;
/// both end when it drops (the watch first, so no mark comes after the
/// worker stops).
#[derive(Default)]
pub(crate) struct ProjectWatch {
    watch: Mutex<Option<cmux_config::watch::Watcher>>,
    worker: Mutex<Option<ImportWorker>>,
}

/// Arms the watch and its worker; the watch's first hint runs the start-up
/// import on the worker. Returns at once.
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
    match watch_files(files, move || import_changed(&mux_weak, &layout, &mut imported)) {
        Ok((watch, worker)) => {
            *lock(&mux.project_watch.worker) = Some(worker);
            *lock(&mux.project_watch.watch) = Some(watch);
        }
        // A folder that cannot be watched is read at the next daemon start, or on a
        // `project.sync` request (the app sends none since A14).
        Err(error) => note(&format!("project sources watch unavailable: {error}")),
    }
}

fn note(message: &str) {
    eprintln!("cmux-tui: {message}");
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Starts the worker, then the watch of `files`, whose hints only mark an
/// import as wanted. `import` runs on the worker once when the watch is armed,
/// then after each mark whose files' fingerprint changed.
fn watch_files(
    files: Vec<PathBuf>,
    import: impl FnMut() + Send + 'static,
) -> Result<(cmux_config::watch::Watcher, ImportWorker), String> {
    let worker = ImportWorker::start(files.clone(), import).map_err(|error| error.to_string())?;
    let marks = Arc::clone(&worker.shared);
    let watch = cmux_config::watch::Watcher::start_with_writes(files, move || marks.mark())
        .map_err(|error| error.to_string())?;
    Ok((watch, worker))
}

/// What the watch and the worker share: whether an import is wanted, whether
/// the worker must stop, and how many passes it ran (for tests).
#[derive(Default)]
pub(crate) struct Marks {
    state: Mutex<MarkState>,
    changed: Condvar,
}

#[derive(Default)]
struct MarkState {
    wanted: bool,
    stop: bool,
    passes: u64,
}

impl Marks {
    /// The watch thread's whole work for a hint: one flag and a wake.
    pub(crate) fn mark(&self) {
        lock(&self.state).wanted = true;
        self.changed.notify_all();
    }

    fn stop(&self) {
        lock(&self.state).stop = true;
        self.changed.notify_all();
    }

    /// Waits until the worker finished `passes` passes; false after `limit`.
    #[cfg(test)]
    pub(crate) fn wait_passes(&self, passes: u64, limit: std::time::Duration) -> bool {
        let state = lock(&self.state);
        let (state, _) = self
            .changed
            .wait_timeout_while(state, limit, |state| state.passes < passes)
            .unwrap_or_else(PoisonError::into_inner);
        state.passes >= passes
    }

    #[cfg(test)]
    pub(crate) fn passes(&self) -> u64 {
        lock(&self.state).passes
    }
}

/// The import worker's thread and its marks.
pub(crate) struct ImportWorker {
    pub(crate) shared: Arc<Marks>,
    thread: Option<JoinHandle<()>>,
}

impl ImportWorker {
    pub(crate) fn start(
        files: Vec<PathBuf>,
        mut import: impl FnMut() + Send + 'static,
    ) -> std::io::Result<Self> {
        let shared = Arc::new(Marks::default());
        let marks = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("mux-project-import".into())
            .spawn(move || run_imports(&marks, &files, &mut import))?;
        Ok(Self { shared, thread: Some(thread) })
    }
}

impl Drop for ImportWorker {
    fn drop(&mut self) {
        self.shared.stop();
        if let Some(thread) = self.thread.take() {
            // The import holds the mux while it runs: the last owner can drop
            // the mux, and this worker with it, on the worker's own thread.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

/// Waits for a mark with no timeout, then compares the fingerprint and runs
/// `import` when it changed. The fingerprint is taken before the read it
/// describes: a write during the read changes the next one, and its mark
/// (set again meanwhile) runs one more pass.
fn run_imports(marks: &Marks, files: &[PathBuf], import: &mut dyn FnMut()) {
    let mut seen = None;
    loop {
        {
            let state = lock(&marks.state);
            let mut state = marks
                .changed
                .wait_while(state, |state| !state.wanted && !state.stop)
                .unwrap_or_else(PoisonError::into_inner);
            if state.stop {
                return;
            }
            state.wanted = false;
        }
        let now = fingerprint(files);
        if seen.as_ref() != Some(&now) {
            seen = Some(now);
            import();
        }
        lock(&marks.state).passes += 1;
        marks.changed.notify_all();
    }
}

/// Size, modification time and inode of each file.
fn fingerprint(files: &[PathBuf]) -> Vec<Option<(u64, SystemTime, u64)>> {
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
mod tests;
