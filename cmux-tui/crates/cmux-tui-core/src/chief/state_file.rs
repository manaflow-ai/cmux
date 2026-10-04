//! `$MUX_HOME/state/host.json`: the brain host's durable state, in the JSON
//! the TypeScript host writes (`mux/host/src/state.ts`), so either host takes
//! over the other's state. The lock holder is its only writer.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use cmux_chief::HostState;

pub(super) struct StateFile {
    path: PathBuf,
}

impl StateFile {
    pub(super) fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// The saved state; a missing or unreadable file is the empty state (as
    /// in TypeScript: every entry is a to-do an owner dedupes, so a lost
    /// file only costs a replay).
    pub(super) fn load(&self, log: &dyn Fn(&str)) -> HostState {
        let Ok(text) = std::fs::read_to_string(&self.path) else { return HostState::default() };
        serde_json::from_str(&text).unwrap_or_else(|error| {
            log(&format!(
                "{} is unreadable ({error}); starting from an empty state",
                self.path.display()
            ));
            HostState::default()
        })
    }

    /// Writes atomically and durably: a temp file, `sync_all` (F_FULLFSYNC on
    /// Apple platforms), rename, then a sync of the directory. A failed write
    /// removes the temp file; host.json is untouched.
    pub(super) fn save(&self, state: &HostState) -> io::Result<()> {
        let mut text = serde_json::to_vec(state).map_err(io::Error::other)?;
        text.push(b'\n');
        let temp = self.path.with_extension(format!("json.{}.tmp", std::process::id()));
        let written = write_synced(&temp, &text);
        if let Err(error) = written {
            let _ = std::fs::remove_file(&temp);
            return Err(error);
        }
        std::fs::rename(&temp, &self.path)?;
        // Not every file system syncs a directory; the rename is still atomic.
        if let Some(directory) = self.path.parent() {
            let _ = File::open(directory).and_then(|directory| directory.sync_all());
        }
        Ok(())
    }
}

fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create(true).truncate(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}
