//! The Resources files cmux-tui owns (`shipped-resources.json` beside this
//! crate's Cargo.toml): the shipped theme files and sidebar looks. The daemon
//! embeds them (`theme_file::SHIPPED`, `sidebar_look::SHIPPED`) and, when its
//! settings owner starts, writes them to `<state root>/shipped/<folder>/`
//! with a `stamp` of their contents. The Mac app reads that folder in place
//! of its bundle's copy (Swift `ShippedResourceFolder`, CmuxNextSettings) and
//! reloads settings when the stamp changes, so a change to one of these files
//! rides the daemon binary: hot-apply swaps it in with no new app build
//! (`live_apply.py` classifies the files as daemon from the same manifest).
//!
//! Daemons that share a state root ship the same binary; each writes only
//! at start, and writes a file only when its text differs.

use std::fs;
use std::io;
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::fsio::write_atomic;

/// The folder under the state root.
pub const FOLDER: &str = "shipped";
/// The file holding the digest of every shipped file.
pub const STAMP: &str = "stamp";

/// `(folder, [(name, text)])`: each folder's name in `Resources/` and in
/// `<state root>/shipped/`, and its files (`<name>.json`).
pub fn kinds() -> [(&'static str, &'static [(&'static str, &'static str)]); 2] {
    [("theme-files", &crate::theme_file::SHIPPED), ("sidebar-looks", &crate::sidebar_look::SHIPPED)]
}

/// The digest `stamp` holds: sha256 over every folder, name and text.
pub fn stamp() -> String {
    let mut hasher = Sha256::new();
    for (folder, files) in kinds() {
        for (name, text) in files {
            for part in [folder, name, text] {
                hasher.update(part.len().to_le_bytes());
                hasher.update(part.as_bytes());
            }
        }
    }
    hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Writes the shipped files under `<state_root>/shipped/`, drops a `.json`
/// there that this binary no longer ships, and writes the stamp last, so a
/// reader that sees the new stamp sees the new files.
pub fn write(state_root: &Path) -> io::Result<()> {
    let root = state_root.join(FOLDER);
    for (folder, files) in kinds() {
        let directory = root.join(folder);
        fs::create_dir_all(&directory)?;
        for (name, text) in files {
            let path = directory.join(format!("{name}.json"));
            if fs::read(&path).ok().as_deref() != Some(text.as_bytes()) {
                write_atomic(&path, text.as_bytes())?;
            }
        }
        for entry in fs::read_dir(&directory)? {
            let path = entry?.path();
            let stem = path.file_stem().and_then(|stem| stem.to_str()).unwrap_or_default();
            let stale = path.extension().is_some_and(|ext| ext == "json")
                && !files.iter().any(|(name, _)| *name == stem);
            if stale {
                fs::remove_file(&path)?;
            }
        }
    }
    let stamp = stamp();
    let path = root.join(STAMP);
    if fs::read_to_string(&path).ok().as_deref() != Some(stamp.as_str()) {
        write_atomic(&path, stamp.as_bytes())?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "shipped_tests.rs"]
mod tests;
