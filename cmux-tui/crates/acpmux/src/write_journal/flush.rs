//! Applying a journal on the machine, in sequence order, with conflict detection.
//!
//! For each entry, oldest first:
//! 1. The machine's file already has the entry's result, or the result of later edits made on
//!    top of it: it was applied (a flush that stopped half way and runs again), so it counts as
//!    applied and nothing is written twice.
//! 2. The machine's file is still the entry's base: apply it (an atomic replace, or a remove).
//! 3. Otherwise a process on the machine changed the file since the agent's edit: the entry
//!    fails with the machine's copy, and so does every later entry for that file, so no edit is
//!    stacked on a version the agent never saw.
//!
//! An I/O error stops the flush at that entry; it and everything after it stay in the journal
//! for the next try. Everything before it is cleared.

use super::{Entry, Op, Version, WriteJournal};
use std::collections::BTreeMap;
use std::io::{self, Write};
use std::path::PathBuf;

/// The machine's files, as the flush sees them. Paths are journal paths.
pub trait MachineFs {
    fn read(&self, path: &str) -> io::Result<Option<Vec<u8>>>;
    /// Replace the whole file atomically (readers see the old or the new bytes, never a mix).
    fn write(&self, path: &str, bytes: &[u8]) -> io::Result<()>;
    /// Remove the file; an absent file is not an error.
    fn remove(&self, path: &str) -> io::Result<()>;
}

/// [`MachineFs`] over a local folder: what runs on the machine itself, and the test double.
pub struct DirMachineFs {
    root: PathBuf,
}

impl DirMachineFs {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// The file for `path`, refusing any link on the way, so a journal path never writes
    /// outside the folder.
    fn resolve(&self, path: &str) -> io::Result<PathBuf> {
        let mut at = self.root.clone();
        for part in path.split('/') {
            at.push(part);
            if let Ok(m) = std::fs::symlink_metadata(&at)
                && m.file_type().is_symlink()
            {
                return Err(io::Error::other(format!("{path}: a symlink is on the way")));
            }
        }
        Ok(at)
    }
}

impl MachineFs for DirMachineFs {
    fn read(&self, path: &str) -> io::Result<Option<Vec<u8>>> {
        match std::fs::read(self.resolve(path)?) {
            Ok(b) => Ok(Some(b)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn write(&self, path: &str, bytes: &[u8]) -> io::Result<()> {
        let full = self.resolve(path)?;
        let dir = full.parent().map(PathBuf::from).unwrap_or_else(|| self.root.clone());
        std::fs::create_dir_all(&dir)?;
        let mut tmp = tempfile::NamedTempFile::new_in(&dir)?;
        tmp.write_all(bytes)?;
        tmp.as_file().sync_data()?;
        // Keep the old file's permissions (an executable script stays executable).
        if let Ok(m) = std::fs::metadata(&full) {
            let _ = std::fs::set_permissions(tmp.path(), m.permissions());
        }
        tmp.persist(&full).map_err(|e| e.error)?;
        Ok(())
    }

    fn remove(&self, path: &str) -> io::Result<()> {
        match std::fs::remove_file(self.resolve(path)?) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }
}

/// Why one entry did not apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictReason {
    /// The machine's file is neither the version the edit was made against nor its result.
    ChangedOnMachine { expected: Version, found: Version },
    /// An earlier entry for the same file (this seq) did not apply.
    EarlierEditFailed { seq: u64 },
}

/// One entry that did not apply, with what the agent needs to redo it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conflict {
    pub seq: u64,
    pub path: String,
    pub reason: ConflictReason,
    /// The machine's copy now: `None` if absent or not text.
    pub machine_copy: Option<String>,
}

impl Conflict {
    /// The text the agent's next tool result carries.
    pub fn message(&self) -> String {
        match &self.reason {
            ConflictReason::ChangedOnMachine { .. } => {
                let copy = match &self.machine_copy {
                    Some(text) => format!("The machine's copy now:\n{text}"),
                    None => "The file is not there on the machine now.".to_owned(),
                };
                format!(
                    "{} changed on the machine since your edit, so the edit was not applied. {copy}",
                    self.path
                )
            }
            ConflictReason::EarlierEditFailed { seq } => format!(
                "{}: an earlier edit to this file (journal entry {seq}) did not apply, so this one was not applied either.",
                self.path
            ),
        }
    }
}

/// What a flush did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct FlushReport {
    /// Written or removed by this flush.
    pub applied: Vec<u64>,
    /// Already on the machine (an earlier flush got this far).
    pub already: Vec<u64>,
    pub conflicts: Vec<Conflict>,
    /// The flush stopped at this entry on an I/O error; it and later entries stay journaled.
    pub stopped: Option<(u64, String)>,
}

impl FlushReport {
    pub fn is_clean(&self) -> bool {
        self.conflicts.is_empty() && self.stopped.is_none()
    }
}

/// Whether `found` is where the chain of edits to this file from `entries[0]` onward already
/// leads: `entries[0]`'s result, or a later entry's for the same file that was written on top of
/// it. A flush that stopped after applying several edits to one file sees the last one there.
fn already_applied(entries: &[Entry], found: &Version) -> bool {
    let Some(first) = entries.first() else { return false };
    let mut at = first.result();
    if &at == found {
        return true;
    }
    for e in entries.iter().skip(1).filter(|e| e.path == first.path) {
        if e.base != at {
            return false;
        }
        at = e.result();
        if &at == found {
            return true;
        }
    }
    false
}

/// Applies `entries[0]`; `Ok(None)` when it applied (or was there already, `already` set).
fn apply(
    entries: &[Entry],
    machine: &dyn MachineFs,
    already: &mut bool,
) -> io::Result<Option<(Version, Option<Vec<u8>>)>> {
    let Some(entry) = entries.first() else { return Ok(None) };
    let now = machine.read(&entry.path)?;
    let found = Version::of(now.as_deref());
    if already_applied(entries, &found) {
        *already = true;
        return Ok(None);
    }
    if found != entry.base {
        return Ok(Some((found, now)));
    }
    match &entry.op {
        Op::Write { content } => machine.write(&entry.path, content.as_bytes())?,
        Op::Delete => machine.remove(&entry.path)?,
    }
    Ok(None)
}

/// Applies `journal` on `machine` (module docs) and clears what it settled, durably, before
/// returning. The caller surfaces each conflict's [`Conflict::message`] to the agent.
pub fn flush(journal: &mut WriteJournal, machine: &dyn MachineFs) -> io::Result<FlushReport> {
    let mut report = FlushReport::default();
    let mut failed: BTreeMap<String, u64> = BTreeMap::new();
    let mut settled = None;
    let entries = journal.entries();
    for (i, entry) in entries.iter().enumerate() {
        if let Some(&seq) = failed.get(&entry.path) {
            report.conflicts.push(Conflict {
                seq: entry.seq,
                path: entry.path.clone(),
                reason: ConflictReason::EarlierEditFailed { seq },
                machine_copy: None,
            });
            settled = Some(entry.seq);
            continue;
        }
        let mut already = false;
        match apply(entries.get(i..).unwrap_or_default(), machine, &mut already) {
            Ok(None) if already => report.already.push(entry.seq),
            Ok(None) => report.applied.push(entry.seq),
            Ok(Some((found, now))) => {
                failed.insert(entry.path.clone(), entry.seq);
                report.conflicts.push(Conflict {
                    seq: entry.seq,
                    path: entry.path.clone(),
                    reason: ConflictReason::ChangedOnMachine {
                        expected: entry.base.clone(),
                        found,
                    },
                    machine_copy: now.and_then(|b| String::from_utf8(b).ok()),
                });
            }
            Err(e) => {
                report.stopped = Some((entry.seq, e.to_string()));
                break;
            }
        }
        settled = Some(entry.seq);
    }
    if let Some(seq) = settled {
        journal.clear_through(seq)?;
    }
    Ok(report)
}
