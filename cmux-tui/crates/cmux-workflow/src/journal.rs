//! A run's journal: one JSON line per entry, appended as steps start and
//! finish. Replay reads it back (see `driver`).

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Entry {
    /// One execution of the run began, with the sha256 of its script.
    Run { script: String },
    /// Step `n` started on the host, which named it `handle` (a session id,
    /// a job id). A later execution passes the handle back to reattach.
    Started { n: u64, key: String, handle: String },
    /// Step `n` finished with `value`. Entries are in finishing order.
    Done { n: u64, key: String, value: Value },
}

pub struct Journal {
    entries: Vec<Entry>,
    file: Option<File>,
}

impl Journal {
    /// A journal kept only in memory (tests, one-shot runs).
    pub fn memory() -> Self {
        Self { entries: Vec::new(), file: None }
    }

    /// Opens or creates the journal at `path` and reads what it holds. A
    /// torn last line (the process stopped mid-write) is cut off, so the
    /// next entry starts on a line of its own.
    pub fn open(path: &Path) -> io::Result<Self> {
        let text = match std::fs::read(path) {
            Ok(bytes) => String::from_utf8(bytes).map_err(io::Error::other)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => String::new(),
            Err(error) => return Err(error),
        };
        let mut entries = Vec::new();
        let mut good = 0usize;
        for line in text.split_inclusive('\n') {
            if !line.ends_with('\n') {
                break;
            }
            if !line.trim().is_empty() {
                match serde_json::from_str::<Entry>(line) {
                    Ok(entry) => entries.push(entry),
                    Err(_) => break,
                }
            }
            good += line.len();
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        if good < text.len() {
            file.set_len(good as u64)?;
        }
        Ok(Self { entries, file: Some(file) })
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// Appends `entry` and, for a file journal, writes it through before
    /// returning, so a crash right after keeps it.
    pub fn append(&mut self, entry: Entry) -> io::Result<()> {
        if let Some(file) = &mut self.file {
            let mut line = serde_json::to_vec(&entry).map_err(io::Error::other)?;
            line.push(b'\n');
            file.write_all(&line)?;
            file.sync_data()?;
        }
        self.entries.push(entry);
        Ok(())
    }
}
