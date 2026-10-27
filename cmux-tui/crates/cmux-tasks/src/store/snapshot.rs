//! Snapshots: the full state at a sequence, so recovery replays only the
//! log after it. A snapshot is a cache; the log alone can rebuild the state.

use std::fs;
use std::io;
use std::path::Path;

use cmux_important_file::{Mode, write_important};
use cmux_tasks_core::State;

const KEEP: usize = 2;

pub fn write(dir: &Path, state: &State) -> io::Result<()> {
    let bytes = serde_json::to_vec(state).map_err(io::Error::other)?;
    write_important(&dir.join(format!("{:020}.json", state.seq)), &bytes, Mode::Default)?;
    let mut names: Vec<_> = fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    names.sort();
    let excess = names.len().saturating_sub(KEEP);
    for old in names.into_iter().take(excess) {
        fs::remove_file(old)?;
    }
    Ok(())
}

/// The newest snapshot that parses; an unreadable one is skipped (the log
/// still holds everything after the older snapshot).
pub fn load_latest(dir: &Path) -> io::Result<Option<State>> {
    let mut names: Vec<_> = fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    names.sort();
    for path in names.iter().rev() {
        let parsed = fs::read(path)
            .map_err(|e| e.to_string())
            .and_then(|bytes| serde_json::from_slice::<State>(&bytes).map_err(|e| e.to_string()));
        match parsed {
            Ok(state) => return Ok(Some(state)),
            // Loud, not silent: an older snapshot plus the log still rebuild
            // the state, but a snapshot nobody can read is a bug to fix.
            Err(e) => eprintln!("cmux-tasks: skipping unreadable snapshot {}: {e}", path.display()),
        }
    }
    Ok(None)
}
