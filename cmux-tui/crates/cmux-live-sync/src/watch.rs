//! The file watcher of one side: FSEvents on macOS, inotify on Linux. It names paths, never
//! states; the replica reads each named path's state. A watcher that loses events (the kernel
//! queue overflowed, FSEvents asks for a rescan) or fails says so as [`Seen::Rescan`] with the
//! reason, and the side walks the whole folder: never a silent gap.

use std::path::{Path, PathBuf};

use crossbeam_channel::Sender;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher as _};

/// What the watcher saw.
#[derive(Debug)]
pub enum Seen {
    Paths(Vec<PathBuf>),
    /// Events were lost: walk everything. The reason's first line.
    Rescan(String),
}

/// Watches `root` recursively until dropped, sending what it sees to `tx` mapped by `wrap`.
pub struct Watch {
    _watcher: RecommendedWatcher,
}

impl Watch {
    pub fn start<T: Send + 'static>(
        root: &Path,
        tx: Sender<T>,
        wrap: impl Fn(Seen) -> T + Send + 'static,
    ) -> notify::Result<Self> {
        let mut watcher = notify::recommended_watcher(move |res: notify::Result<Event>| {
            let seen = match res {
                Ok(ev) if ev.need_rescan() => {
                    Seen::Rescan("watcher asked for a rescan (events lost)".into())
                }
                Ok(ev) => match ev.kind {
                    EventKind::Access(_) => return,
                    _ => Seen::Paths(ev.paths),
                },
                Err(e) => Seen::Rescan(format!(
                    "watcher error: {}",
                    crate::replica::first_line(&e.to_string())
                )),
            };
            let _ = tx.send(wrap(seen));
        })?;
        watcher.watch(root, RecursiveMode::Recursive)?;
        Ok(Self { _watcher: watcher })
    }
}
