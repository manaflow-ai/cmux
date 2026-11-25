//! The file tree and search of a paused machine (RFD 0144 piece 2): a folder listing and a text
//! search answered from the replica with the journal laid over it, never waking the machine.
//!
//! Same rule as [`super::replica::read_text`]: a stale replica, or a folder the seed left
//! incomplete, is [`NeedsMachine`] and the caller resumes the machine.

use super::replica::{NeedsMachine, ReplicaRead, ReplicaSource};
use super::seed::SeededReplica;
use super::{Op, WriteJournal, rel_path};
use std::collections::BTreeMap;
use std::io;

/// One name in a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListEntry {
    pub name: String,
    pub is_dir: bool,
    /// Bytes; 0 for a folder.
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListOutcome {
    Entries(Vec<ListEntry>),
    NotFound,
    NeedsMachine(NeedsMachine),
}

/// One matching line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub path: String,
    /// 1-based.
    pub line: u32,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchOutcome {
    Hits { hits: Vec<Hit>, truncated: bool },
    NeedsMachine(NeedsMachine),
}

fn fresh(replica: &SeededReplica) -> Result<u64, NeedsMachine> {
    if replica.is_fresh() { Ok(replica.generation()) } else { Err(NeedsMachine::Stale) }
}

/// The names under `raw_dir` ("" or "." is the machine's folder): the replica's, plus what the
/// journal wrote, minus what it deleted. Sorted by name.
pub fn list_dir(
    journal: &WriteJournal,
    replica: &SeededReplica,
    raw_dir: &str,
) -> io::Result<ListOutcome> {
    let dir = if matches!(raw_dir, "" | ".") {
        String::new()
    } else {
        match rel_path(raw_dir) {
            Ok(d) => d,
            Err(_) => return Ok(ListOutcome::NeedsMachine(NeedsMachine::MachineOnly)),
        }
    };
    let generation = match fresh(replica) {
        Ok(g) => g,
        Err(why) => return Ok(ListOutcome::NeedsMachine(why)),
    };
    let Some(mut entries) = replica.list(&dir)? else {
        return Ok(ListOutcome::NeedsMachine(NeedsMachine::MachineOnly));
    };
    if !replica.is_fresh() || replica.generation() != generation {
        return Ok(ListOutcome::NeedsMachine(NeedsMachine::Stale));
    }
    let prefix = if dir.is_empty() { String::new() } else { format!("{dir}/") };
    let mut by_name: BTreeMap<String, ListEntry> =
        entries.drain(..).map(|e| (e.name.clone(), e)).collect();
    let mut journal_touched_here = false;
    for (path, entry) in journal.overlay_paths() {
        let Some(rest) = path.strip_prefix(&prefix) else { continue };
        journal_touched_here = true;
        let (name, nested) = match rest.split_once('/') {
            Some((n, _)) => (n, true),
            None => (rest, false),
        };
        match (&entry.op, nested) {
            (Op::Write { content }, false) => {
                by_name.insert(
                    name.to_owned(),
                    ListEntry { name: name.to_owned(), is_dir: false, size: content.len() as u64 },
                );
            }
            (Op::Write { .. }, true) => {
                by_name.entry(name.to_owned()).or_insert(ListEntry {
                    name: name.to_owned(),
                    is_dir: true,
                    size: 0,
                });
            }
            (Op::Delete, false) => {
                by_name.remove(name);
            }
            (Op::Delete, true) => {}
        }
    }
    if by_name.is_empty() && !journal_touched_here && !replica.dir_exists(&dir) {
        return Ok(ListOutcome::NotFound);
    }
    Ok(ListOutcome::Entries(by_name.into_values().collect()))
}

/// Lines containing `query` (case-sensitive) in the text files of the replica, journal writes
/// first-class. Stops after `max_hits`. Files the replica holds as non-text or over its size
/// bound are skipped, so a hit list is a subset: that is `truncated` only when it hit `max_hits`.
pub fn search(
    journal: &WriteJournal,
    replica: &SeededReplica,
    query: &str,
    max_hits: usize,
) -> io::Result<SearchOutcome> {
    let generation = match fresh(replica) {
        Ok(g) => g,
        Err(why) => return Ok(SearchOutcome::NeedsMachine(why)),
    };
    if query.is_empty() {
        return Ok(SearchOutcome::Hits { hits: Vec::new(), truncated: false });
    }
    let overlay = journal.overlay_paths();
    let mut paths: BTreeMap<String, Option<String>> = BTreeMap::new();
    for p in replica.walk_files()? {
        paths.insert(p, None);
    }
    for (p, e) in &overlay {
        match &e.op {
            Op::Write { content } => {
                paths.insert((*p).to_owned(), Some(content.clone()));
            }
            Op::Delete => {
                paths.remove(*p);
            }
        }
    }
    let mut hits = Vec::new();
    for (path, journaled) in paths {
        let text = match journaled {
            Some(t) => t,
            None => match replica.read(&path)? {
                ReplicaRead::Present(b) => match String::from_utf8(b) {
                    Ok(t) => t,
                    Err(_) => continue,
                },
                _ => continue,
            },
        };
        for (i, line) in text.lines().enumerate() {
            if line.contains(query) {
                if hits.len() >= max_hits {
                    return Ok(SearchOutcome::Hits { hits, truncated: true });
                }
                hits.push(Hit {
                    path: path.clone(),
                    line: u32::try_from(i + 1).unwrap_or(u32::MAX),
                    text: line.chars().take(400).collect(),
                });
            }
        }
    }
    if !replica.is_fresh() || replica.generation() != generation {
        return Ok(SearchOutcome::NeedsMachine(NeedsMachine::Stale));
    }
    Ok(SearchOutcome::Hits { hits, truncated: false })
}
