//! A per-machine write journal and the read path over a replica, so a paused machine keeps
//! answering file reads and accepting file writes without waking (off by default:
//! `writeJournal.enabled` in config.json).
//!
//! While a machine sleeps, the daemon that holds its sessions answers reads from a replica of
//! the machine's working tree ([`replica`]) and records writes in this journal instead of
//! waking the machine. Reads see the journal first, so the agent always reads what it wrote.
//! Anything that runs code on the machine is a barrier: the machine resumes and the journal is
//! applied there in order ([`flush`]) before the command runs.
//!
//! The journal is append-only and sequence-numbered per machine. Every entry carries the
//! version of the file it was written against (its base). The flush applies an entry only while
//! the machine's file still matches that base; otherwise that entry fails with the machine's
//! copy, like a merge conflict, and so does every later entry for the same file.
//!
//! An entry is durable before [`WriteJournal::record`] returns: the [`JournalStore`] says so.
//! The default store ([`FileJournalStore`]) is one JSON-lines file per machine with an fsync per
//! append. A platform may supply its own store so a journal outlives the host it was written on.
//!
//! This module only decides and records; it changes no call site. Wiring it into the ACP file
//! methods and the exec path is follow-up work, behind the same flag.

pub mod classify;
pub mod flush;
#[cfg(unix)]
mod nofollow;
pub mod replica;
mod store;

pub use store::{FileJournalStore, JournalState, JournalStore};

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io;
use std::sync::Arc;

/// The version of a file: absent, or the SHA-256 of its bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Version {
    Absent,
    Sha256 { hex: String },
}

impl Version {
    /// The version of `bytes`, or [`Version::Absent`] for no file.
    pub fn of(bytes: Option<&[u8]>) -> Self {
        match bytes {
            None => Self::Absent,
            Some(b) => Self::Sha256 { hex: crate::sha256::sha256_hex(b) },
        }
    }
}

/// What an entry does to its file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Op {
    Write { content: String },
    Delete,
}

/// One journaled write.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Per machine, strictly increasing, never reused (also across flushes).
    pub seq: u64,
    /// Relative to the replica's root, `/`-separated ([`rel_path`]).
    pub path: String,
    pub op: Op,
    /// The version the agent saw when it wrote this.
    pub base: Version,
    pub at_ms: u64,
}

impl Entry {
    /// The file's version once this entry is applied.
    pub fn result(&self) -> Version {
        match &self.op {
            Op::Write { content } => Version::of(Some(content.as_bytes())),
            Op::Delete => Version::Absent,
        }
    }
}

/// A path the journal refuses.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PathError {
    #[error("the path is empty")]
    Empty,
    #[error("the path {0:?} is not relative to the machine's folder")]
    Absolute(String),
    #[error("the path {0:?} leaves the machine's folder")]
    Escapes(String),
    /// A name the flush uses for its own staging files ([`STAGING_PREFIX`]).
    #[error("the path {0:?} uses a name the write journal keeps for itself")]
    Reserved(String),
}

/// Names starting with this are the flush's staging files; no journal path may use one.
pub const STAGING_PREFIX: &str = ".cmux-journal-";

/// `raw` as a journal path: relative, `/`-separated, no `.`/empty components, never `..`.
/// Anything that would leave the folder is refused, never resolved.
pub fn rel_path(raw: &str) -> Result<String, PathError> {
    if raw.starts_with(['/', '\\']) {
        return Err(PathError::Absolute(raw.to_owned()));
    }
    let mut parts = Vec::new();
    for part in raw.split(['/', '\\']) {
        match part {
            "" | "." => {}
            ".." => return Err(PathError::Escapes(raw.to_owned())),
            // A drive prefix (`C:/x`, `C:x`) replaces the root on Windows when joined; a `:`
            // also names an NTFS alternate stream. Refused everywhere, so a journal reads the
            // same on every platform.
            p if p.contains(':') => return Err(PathError::Absolute(raw.to_owned())),
            p if p.starts_with(STAGING_PREFIX) => return Err(PathError::Reserved(raw.to_owned())),
            p => parts.push(p),
        }
    }
    if parts.is_empty() {
        return Err(PathError::Empty);
    }
    Ok(parts.join("/"))
}

/// The open journal of one machine.
pub struct WriteJournal {
    machine: String,
    store: Arc<dyn JournalStore>,
    entries: Vec<Entry>,
    next_seq: u64,
    /// A store append failed and may have left a partial record: refuse writes until reopened,
    /// so a later write can never share its sequence number.
    poisoned: bool,
}

impl std::fmt::Debug for WriteJournal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WriteJournal")
            .field("machine", &self.machine)
            .field("entries", &self.entries.len())
            .field("next_seq", &self.next_seq)
            .finish_non_exhaustive()
    }
}

impl WriteJournal {
    /// Loads `machine`'s journal from `store`: the unflushed entries in sequence order, and the
    /// next sequence number after every one ever issued.
    pub fn open(store: Arc<dyn JournalStore>, machine: &str) -> io::Result<Self> {
        let state = store.load(machine)?;
        let mut entries: Vec<Entry> =
            state.entries.into_iter().filter(|e| e.seq > state.cleared_through).collect();
        entries.sort_by_key(|e| e.seq);
        // The same entry twice is harmless; two different entries under one number are not.
        if let Some(w) =
            entries.windows(2).find(|w| matches!(w, [a, b] if a.seq == b.seq && a != b))
            && let Some(e) = w.first()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("journal sequence number {} names two different entries", e.seq),
            ));
        }
        entries.dedup_by_key(|e| e.seq);
        // A stored path is checked again: a flush must never write outside the folder, whatever
        // the store hands back.
        if let Some(e) = entries.iter().find(|e| rel_path(&e.path).ok().as_deref() != Some(&e.path))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("journal entry {} has a path outside the folder: {:?}", e.seq, e.path),
            ));
        }
        let last =
            entries.last().map_or(state.cleared_through, |e| e.seq.max(state.cleared_through));
        Ok(Self {
            machine: machine.to_owned(),
            store,
            entries,
            // u64::MAX + 1 is never issued: `record` refuses at that point.
            next_seq: last.saturating_add(1),
            poisoned: false,
        })
    }

    pub fn machine(&self) -> &str {
        &self.machine
    }

    /// The unflushed entries, oldest first.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The newest unflushed entry for `path` (already a [`rel_path`]): what a read sees.
    pub fn overlay(&self, path: &str) -> Option<&Entry> {
        self.entries.iter().rev().find(|e| e.path == path)
    }

    /// The newest entry per path, for listings that merge the journal over a replica.
    pub fn overlay_paths(&self) -> BTreeMap<&str, &Entry> {
        let mut out = BTreeMap::new();
        for e in &self.entries {
            out.insert(e.path.as_str(), e);
        }
        out
    }

    /// Appends one entry and returns its sequence number. It is durable in the store before
    /// this returns. On a store error the write is reported failed, its sequence number is never
    /// used again, and the journal refuses writes until it is reopened (the store may hold part
    /// of the failed record; a reopen reads what is really there).
    pub fn record(&mut self, path: &str, op: Op, base: Version, at_ms: u64) -> io::Result<u64> {
        if self.poisoned {
            return Err(io::Error::other(
                "an earlier journal write failed; reopen the journal before writing again",
            ));
        }
        let path = rel_path(path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // The last number is never handed out, so no number is ever issued twice.
        let Some(after) = self.next_seq.checked_add(1) else {
            return Err(io::Error::other("the journal has used every sequence number"));
        };
        let entry = Entry { seq: self.next_seq, path, op, base, at_ms };
        if let Err(e) = self.store.append(&self.machine, &entry) {
            self.next_seq = after;
            self.poisoned = true;
            return Err(e);
        }
        self.next_seq = after;
        let seq = entry.seq;
        self.entries.push(entry);
        Ok(seq)
    }

    /// Drops every entry through `seq` (applied or failed); durable before it returns.
    pub(crate) fn clear_through(&mut self, seq: u64) -> io::Result<()> {
        self.store.clear_through(&self.machine, seq)?;
        self.entries.retain(|e| e.seq > seq);
        Ok(())
    }
}

#[cfg(test)]
mod tests;
