//! Snapshots: the full state at a sequence, so recovery replays only the
//! log after it. A snapshot is a cache; the log alone can rebuild the state.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

use cmux_tasks_core::State;

const KEEP: usize = 2;

/// Write `bytes` to `path` atomically: tmp file, fsync, rename, fsync dir.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut file = OpenOptions::new().create(true).truncate(true).write(true).open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    if let Some(parent) = path.parent() {
        super::sync_dir(parent)?;
    }
    Ok(())
}

pub fn write(dir: &Path, state: &State) -> io::Result<()> {
    let bytes = serde_json::to_vec(state).map_err(io::Error::other)?;
    write_atomic(&dir.join(format!("{:020}.json", state.seq)), &bytes)?;
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
        if let Ok(bytes) = fs::read(path)
            && let Ok(state) = serde_json::from_slice::<State>(&bytes)
        {
            return Ok(Some(state));
        }
    }
    Ok(None)
}
