//! `<acpmux home>/chat-roots.json`: store roots cmux saw a harness use at
//! launch (spawn env, hook transcript paths). Catches homes nobody configured.

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::RootSpec;
use crate::store_file;

const VERSION: u32 = 1;
/// A bound so a runaway launcher cannot grow the file without end.
const MAX_ROOTS: usize = 512;

#[derive(Debug, Default, Serialize, Deserialize)]
struct File {
    version: u32,
    roots: Vec<Stored>,
}

/// One entry of the file: a root this build reads, or one it cannot (a harness kind a newer
/// build knows), kept as it was and written back unchanged, so a rollback never loses it.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
enum Stored {
    Root(RootSpec),
    Kept(serde_json::Value),
}

/// The recorded roots and the file they persist to.
#[derive(Debug)]
pub struct RecordedRoots {
    path: PathBuf,
    /// Every entry of the file in its order, the ones this build cannot read too.
    stored: Vec<Stored>,
    /// The entries this build reads.
    roots: Vec<RootSpec>,
    /// The file is another build's (another version): read as no roots, never written.
    foreign: bool,
}

impl RecordedRoots {
    /// Loads the file; a missing or unreadable file is empty, and so is one of another version,
    /// which this build then never writes over. An entry this build cannot read (a harness kind
    /// a newer build added) is kept and written back as it was.
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let file = store_file::read_json::<serde_json::Value>(&path);
        let version = file.as_ref().and_then(|f| f.get("version")).and_then(|v| v.as_u64());
        let foreign = version.is_some_and(|v| v != u64::from(VERSION));
        let stored = file
            .filter(|_| !foreign)
            .and_then(|f| serde_json::from_value::<File>(f).ok())
            .map(|file| file.roots)
            .unwrap_or_default();
        let roots = stored
            .iter()
            .filter_map(|s| match s {
                Stored::Root(root) => Some(root.clone()),
                Stored::Kept(_) => None,
            })
            .collect();
        Self { path, stored, roots, foreign }
    }

    pub fn roots(&self) -> &[RootSpec] {
        &self.roots
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Adds a root and saves the file. Returns true when the root is new.
    pub fn record(&mut self, spec: RootSpec) -> io::Result<bool> {
        if !spec.path.is_absolute() || self.roots.contains(&spec) {
            return Ok(false);
        }
        if self.stored.len() >= MAX_ROOTS {
            // The oldest root this build reads goes first; a kept one only when all are kept.
            let oldest = self.stored.iter().position(|s| matches!(s, Stored::Root(_))).unwrap_or(0);
            if let Stored::Root(gone) = self.stored.remove(oldest) {
                self.roots.retain(|r| *r != gone);
            }
        }
        self.roots.push(spec.clone());
        self.stored.push(Stored::Root(spec));
        if self.foreign {
            return Ok(true);
        }
        store_file::write_json_private(
            &self.path,
            &File { version: VERSION, roots: self.stored.clone() },
        )?;
        Ok(true)
    }
}

#[cfg(test)]
#[path = "recorded_tests.rs"]
mod tests;
