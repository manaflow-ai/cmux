//! Where a journal is kept: the [`JournalStore`] trait and its local-file default.

use super::Entry;
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// What a store holds for one machine.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct JournalState {
    /// Every entry through this sequence number was flushed (or failed) and is gone; the next
    /// entry's number is above it, so numbers are never reused.
    pub cleared_through: u64,
    pub entries: Vec<Entry>,
}

/// Durable storage of unflushed journals. Every method is durable before it returns `Ok`: a
/// write whose tool result was returned must survive a restart of the process that wrote it.
/// An `append` that returns `Err` should leave no record behind (the file store cuts it back);
/// when it cannot be sure, the journal stops taking writes until reopened, and the reopen keeps
/// whatever the store really holds, never under a reused sequence number.
pub trait JournalStore: Send + Sync {
    fn load(&self, machine: &str) -> io::Result<JournalState>;
    fn append(&self, machine: &str, entry: &Entry) -> io::Result<()>;
    /// Forget every entry through `seq`, remembering `seq` as cleared.
    fn clear_through(&self, machine: &str, seq: u64) -> io::Result<()>;
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
enum Line {
    Cleared { through: u64 },
    Entry(Entry),
}

/// One JSON-lines file per machine in a folder (`$ACPMUX_HOME/write-journal/` by convention),
/// fsync'd on every append and replaced atomically on clear. A torn last line (the process died
/// mid-append, so its tool result never returned) is ignored; any other unreadable line is an
/// error, never silently dropped.
pub struct FileJournalStore {
    dir: PathBuf,
    /// The folder's own link in its parent is durable (synced once, after creating it).
    dir_durable: std::sync::atomic::AtomicBool,
    /// Appends and rewrites of one store are serialized; one machine has one writer.
    lock: Mutex<()>,
}

impl FileJournalStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: dir.into(),
            dir_durable: std::sync::atomic::AtomicBool::new(false),
            lock: Mutex::new(()),
        }
    }

    /// The file for `machine`: its name hex-encoded, so any machine id is one safe file name.
    pub fn path_for(&self, machine: &str) -> PathBuf {
        let name: String = machine.bytes().map(|b| format!("{b:02x}")).collect();
        self.dir.join(format!("{name}.jsonl"))
    }

    /// Creates the folder and makes its link in its parent durable, once per store.
    fn ensure_dir(&self) -> io::Result<()> {
        use std::sync::atomic::Ordering;
        std::fs::create_dir_all(&self.dir)?;
        if !self.dir_durable.load(Ordering::SeqCst) {
            if let Some(parent) = self.dir.parent().filter(|p| !p.as_os_str().is_empty()) {
                sync_dir(parent)?;
            }
            self.dir_durable.store(true, Ordering::SeqCst);
        }
        Ok(())
    }

    fn guard(&self) -> std::sync::MutexGuard<'_, ()> {
        self.lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn invalid(e: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, e.to_string())
}

fn read_lines(path: &Path) -> io::Result<JournalState> {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(JournalState::default()),
        Err(e) => return Err(e),
    };
    let mut state = JournalState::default();
    // Every complete line ends with a newline; bytes after the last one are a torn append (which
    // may end inside a UTF-8 character), so only the prefix is decoded.
    let end = bytes.iter().rposition(|&c| c == b'\n').unwrap_or(0);
    let complete = std::str::from_utf8(bytes.get(..end).unwrap_or_default())
        .map_err(|e| invalid(format!("{}: {e}", path.display())))?;
    for line in complete.split('\n') {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Line>(line)
            .map_err(|e| invalid(format!("{}: {e}", path.display())))?
        {
            Line::Cleared { through } => state.cleared_through = state.cleared_through.max(through),
            Line::Entry(e) => state.entries.push(e),
        }
    }
    let through = state.cleared_through;
    state.entries.retain(|e| e.seq > through);
    Ok(state)
}

fn line_of(line: &Line) -> io::Result<String> {
    let mut s = serde_json::to_string(line).map_err(invalid)?;
    s.push('\n');
    Ok(s)
}

impl JournalStore for FileJournalStore {
    fn load(&self, machine: &str) -> io::Result<JournalState> {
        let _g = self.guard();
        read_lines(&self.path_for(machine))
    }

    fn append(&self, machine: &str, entry: &Entry) -> io::Result<()> {
        let _g = self.guard();
        self.ensure_dir()?;
        let path = self.path_for(machine);
        drop_torn_tail(&path)?;
        let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
        let before = file.metadata()?.len();
        let written = file
            .write_all(line_of(&Line::Entry(entry.clone()))?.as_bytes())
            .and_then(|()| file.sync_data())
            // Always the folder too: the file may be new, or the replacement an earlier
            // `clear_through` renamed into place may not have reached the disk yet.
            .and_then(|()| sync_dir(&self.dir));
        if let Err(e) = written {
            // The caller reports this write as failed, so it must not come back on the next load:
            // cut the file back to where it was. If even that fails, the journal refuses further
            // writes until it is reopened (`WriteJournal::record`).
            let _ = file.set_len(before).and_then(|()| file.sync_data());
            return Err(e);
        }
        Ok(())
    }

    fn clear_through(&self, machine: &str, seq: u64) -> io::Result<()> {
        let _g = self.guard();
        self.ensure_dir()?;
        let path = self.path_for(machine);
        let state = read_lines(&path)?;
        let through = state.cleared_through.max(seq);
        let mut text = line_of(&Line::Cleared { through })?;
        for e in state.entries.into_iter().filter(|e| e.seq > through) {
            text.push_str(&line_of(&Line::Entry(e))?);
        }
        let mut tmp = tempfile::NamedTempFile::new_in(&self.dir)?;
        tmp.write_all(text.as_bytes())?;
        tmp.as_file().sync_data()?;
        tmp.persist(&path).map_err(|e| e.error)?;
        // The rename itself is durable once the folder is.
        sync_dir(&self.dir)
    }
}

/// Makes a rename, create or remove in `dir` durable. Windows has no folder fsync; NTFS journals
/// its metadata.
pub(super) fn sync_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        File::open(dir)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(())
    }
}

/// Cuts a torn last line (an append that died before its newline) so the next append starts a
/// line of its own. That append's tool result never returned, so nothing relied on it.
fn drop_torn_tail(path: &Path) -> io::Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = match OpenOptions::new().read(true).write(true).open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    let len = f.metadata()?.len();
    if len == 0 {
        return Ok(());
    }
    f.seek(SeekFrom::Start(len.saturating_sub(1)))?;
    let mut b = [0u8; 1];
    f.read_exact(&mut b)?;
    if b == [b'\n'] {
        return Ok(());
    }
    f.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    f.read_to_end(&mut bytes)?;
    let keep = bytes.iter().rposition(|&c| c == b'\n').map_or(0, |i| i.saturating_add(1));
    f.set_len(u64::try_from(keep).unwrap_or(len))?;
    f.sync_data()
}
