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
    roots: Vec<RootSpec>,
}

/// The recorded roots and the file they persist to.
#[derive(Debug)]
pub struct RecordedRoots {
    path: PathBuf,
    roots: Vec<RootSpec>,
}

impl RecordedRoots {
    /// Loads the file; a missing, unreadable or other-version file is empty.
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let roots = store_file::read_json::<File>(&path)
            .filter(|file| file.version == VERSION)
            .map(|file| file.roots)
            .unwrap_or_default();
        Self { path, roots }
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
        if self.roots.len() >= MAX_ROOTS {
            self.roots.remove(0);
        }
        self.roots.push(spec);
        store_file::write_json_private(
            &self.path,
            &File { version: VERSION, roots: self.roots.clone() },
        )?;
        Ok(true)
    }
}
