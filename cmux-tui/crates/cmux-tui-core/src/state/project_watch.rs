//! Resync of the editor and app project sources (plans/cmux-next/projects.md
//! section 4): one import at daemon start, then a file watch on the few
//! folders the sources read (FSEvents on macOS, inotify on Linux). No timer
//! and no polling. A burst of events is drained before one rescan; only a
//! source whose list changed since the last import is committed, so an
//! editor writing its state file without a new recent folder costs one read.

use std::collections::HashMap;
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Weak};

use notify::Watcher as _;

use crate::mux::Mux;
use crate::state::project_sources::{self, Layout, SourceScan, WATCHED_NAMES};
use crate::state::projects::Observation;

/// Starts the import and the watch on its own thread; returns at once.
pub(crate) fn start(mux: &Arc<Mux>) {
    if !project_sources::enabled() {
        return;
    }
    let Some(layout) = Layout::current() else { return };
    let weak = Arc::downgrade(mux);
    let spawned = std::thread::Builder::new()
        .name("mux-project-sources".into())
        .spawn(move || run(&weak, &layout));
    if let Err(error) = spawned {
        note(&format!("project sources thread did not start: {error}"));
    }
}

fn note(message: &str) {
    eprintln!("cmux-tui: {message}");
}

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
    if !import_changed(mux, layout, &mut imported) {
        return;
    }
    if watcher.is_none() {
        return;
    }
    while next_relevant(&events) {
        if !import_changed(mux, layout, &mut imported) {
            return;
        }
    }
}

/// Waits for an event on a source file, then drains the burst queued behind
/// it. False when the watch ended.
fn next_relevant(events: &Receiver<notify::Result<notify::Event>>) -> bool {
    loop {
        let Ok(event) = events.recv() else { return false };
        if relevant(&event) {
            while events.try_recv().is_ok() {}
            return true;
        }
    }
}

fn relevant(event: &notify::Result<notify::Event>) -> bool {
    let Ok(event) = event else { return true };
    event.paths.iter().any(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| WATCHED_NAMES.iter().any(|watched| name.starts_with(watched)))
    })
}

/// Rescans every source and commits the ones whose list changed. False when
/// the daemon is gone.
fn import_changed(
    mux: &Weak<Mux>,
    layout: &Layout,
    imported: &mut HashMap<&'static str, Vec<Observation>>,
) -> bool {
    let Some(mux) = mux.upgrade() else { return false };
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
