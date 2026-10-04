//! STUB (red commit): the old in-memory pins.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

/// The rename step of the atomic write (a test seam).
pub type Rename = fn(&Path, &Path) -> io::Result<()>;

pub struct KnownHosts {
    path: PathBuf,
    pins: BTreeMap<String, String>,
}

impl KnownHosts {
    pub fn load(path: PathBuf) -> (Self, Vec<String>) {
        (Self { path, pins: BTreeMap::new() }, Vec::new())
    }

    pub fn with_rename(self, _rename: Rename) -> Self {
        self
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn get(&self, machine: &str) -> Option<&str> {
        self.pins.get(machine).map(String::as_str)
    }

    pub fn pin(&mut self, machine: &str, host_key: &str) -> io::Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut pins = self.pins.clone();
        pins.insert(machine.to_owned(), host_key.to_owned());
        let text: String = pins
            .iter()
            .map(|(m, key)| format!("{} {key}\n", super::transfer::host_alias(m)))
            .collect();
        crate::app_env::write_private(&self.path, text.as_bytes())?;
        self.pins = pins;
        Ok(())
    }
}
