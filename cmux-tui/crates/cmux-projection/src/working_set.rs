//! The working set a projection prefetches (RFD 0007, prior-art move 2): the paths the session
//! declares it will need, then the files the last session in the folder read first (REAP's idea:
//! what a run touched predicts the next run), up to a [`Budget`].
//!
//! Both ends are bounded so a crawler cannot turn a projection into a full copy:
//! - a session records at most [`Budget::bytes`] of first reads ([`Trace`]). A session that read
//!   more (`rg` at the root, an indexer) is marked [`Trace::crawled`], and only what it read first
//!   is kept;
//! - a prefetch spends at most [`Budget::bytes`] (and never more than the cache's own cap) in at
//!   most [`Budget::asks`] round trips, each at most [`PREFETCH_BATCH_BYTES`], so a demand read
//!   queued behind one waits for at most that much.
//!
//! The overlay records ([`crate::overlay::Overlay`] reads) and prefetches
//! ([`crate::overlay::Overlay::prefetch`]); this module plans and keeps the trace.

use std::collections::{HashSet, VecDeque};
use std::path::Path;

use crate::FetchError;
use crate::manifest::{Kind, Manifest};

/// The most bytes a prefetch fetches, and a session records, by default.
pub const DEFAULT_BYTES: u64 = 64 * 1024 * 1024;
/// The most round trips a prefetch spends by default.
pub const DEFAULT_ASKS: u32 = 128;
/// The most bytes one prefetch ask carries.
pub const PREFETCH_BATCH_BYTES: u64 = 1024 * 1024;
/// The state folder's file holding the last session's trace.
pub const FILE: &str = "working-set";
/// The trace file's first record.
const HEADER: &str = "cmux-projection working set v1";

/// How much a prefetch may fetch, and a session record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    pub bytes: u64,
    pub asks: u32,
}

impl Default for Budget {
    fn default() -> Self {
        Self { bytes: DEFAULT_BYTES, asks: DEFAULT_ASKS }
    }
}

/// The files one session read, in the order it first read them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Trace {
    pub paths: Vec<String>,
    /// Their bytes (as the manifest the session read them in listed them).
    pub bytes: u64,
    /// The session read more than the budget: only what it read first is here.
    pub crawled: bool,
}

impl Trace {
    /// The trace in `path`; none when there is none or it does not read as one.
    #[must_use]
    pub fn load(path: &Path) -> Option<Self> {
        Self::decode(&std::fs::read(path).ok()?)
    }

    /// Writes the trace to `path` whole (a crash leaves the old one or the new one).
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let temp = path.with_extension("next");
        std::fs::write(&temp, self.encode())?;
        std::fs::rename(&temp, path)
    }

    /// NUL-ended records: the header, the flags, then each path (a name may hold a newline).
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        let flags = format!("bytes={} crawled={}", self.bytes, u8::from(self.crawled));
        for record in
            [HEADER, flags.as_str()].into_iter().chain(self.paths.iter().map(String::as_str))
        {
            out.extend_from_slice(record.as_bytes());
            out.push(0);
        }
        out
    }

    #[must_use]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let text = std::str::from_utf8(bytes).ok()?;
        let mut records = text.strip_suffix('\0')?.split('\0');
        if records.next()? != HEADER {
            return None;
        }
        let mut trace = Self::default();
        for flag in records.next()?.split(' ') {
            match flag.split_once('=')? {
                ("bytes", value) => trace.bytes = value.parse().ok()?,
                ("crawled", value) => trace.crawled = value == "1",
                _ => {}
            }
        }
        trace.paths = records.filter(|path| !path.is_empty()).map(str::to_owned).collect();
        Some(trace)
    }
}

/// A session's first reads as it makes them: each file once, until `cap` bytes.
#[derive(Debug)]
pub(crate) struct Recorder {
    seen: HashSet<u32>,
    order: Vec<u32>,
    bytes: u64,
    cap: u64,
    crawled: bool,
}

impl Recorder {
    pub(crate) fn new(cap: u64) -> Self {
        Self { seen: HashSet::new(), order: Vec::new(), bytes: 0, cap, crawled: false }
    }

    pub(crate) fn set_cap(&mut self, cap: u64) {
        self.cap = cap;
    }

    /// File `entry` (`size` bytes) was read.
    pub(crate) fn touch(&mut self, entry: u32, size: u64) {
        if self.crawled || self.seen.contains(&entry) {
            return;
        }
        if self.bytes.saturating_add(size) > self.cap {
            // Past the budget: a crawl. Its first reads stay; the rest would only be a copy.
            self.crawled = true;
            self.seen = HashSet::new();
            return;
        }
        self.seen.insert(entry);
        self.order.push(entry);
        self.bytes += size;
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    pub(crate) fn trace(&self, manifest: &Manifest) -> Trace {
        Trace {
            paths: self.order.iter().map(|entry| manifest.path_of(*entry)).collect(),
            bytes: self.bytes,
            crawled: self.crawled,
        }
    }
}

/// Why a prefetch stopped before its plan ran out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    /// The byte budget was spent: files past it were left to demand reads.
    Bytes,
    /// The round-trip budget was spent.
    Asks,
    /// The source failed (the Mac went away): demand reads take over.
    Failed(FetchError),
}

/// What one prefetch did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Prefetched {
    pub files: u64,
    pub bytes: u64,
    pub asks: u32,
    pub stopped: Option<Stop>,
}

/// The files to prefetch, in order: those `declared` names (a folder stands for every file below
/// it, breadth first), then the `trace`'s, each once, small enough to come whole (at most
/// `whole_max` bytes), not skipped by `skip`, while their bytes fit in `budget` (a file that does
/// not fit is passed over, and the answer says the budget was reached). A path not in the
/// manifest is passed over.
pub fn plan(
    manifest: &Manifest,
    declared: &[String],
    trace: &[String],
    budget: u64,
    whole_max: u64,
    mut skip: impl FnMut(u32, &str) -> bool,
) -> (Vec<(u32, u64)>, bool) {
    let mut planned = Vec::new();
    let mut seen = HashSet::new();
    let mut bytes = 0u64;
    let mut over = false;
    let mut take = |index: u32, path: &str, over: &mut bool| {
        let Some(entry) = manifest.entry(index) else { return };
        if entry.kind != Kind::File || entry.size == 0 || entry.size > whole_max {
            return;
        }
        if !seen.insert(index) {
            return;
        }
        if bytes.saturating_add(entry.size) > budget {
            *over = true;
            return;
        }
        if skip(index, path) {
            return;
        }
        bytes += entry.size;
        planned.push((index, entry.size));
    };
    for path in declared.iter().chain(trace) {
        let path = path.trim_end_matches('/');
        let Some(index) = manifest.resolve(path) else { continue };
        let Some(entry) = manifest.entry(index) else { continue };
        if entry.kind != Kind::Dir {
            take(index, path, &mut over);
            continue;
        }
        let mut folders = VecDeque::from([(index, path.to_owned())]);
        while let Some((folder, at)) = folders.pop_front() {
            let (first, children) = manifest.children(folder);
            for (offset, child) in children.iter().enumerate() {
                let Some(child_index) = u32::try_from(offset).ok().map(|offset| first + offset)
                else {
                    break;
                };
                let child_path =
                    if at.is_empty() { child.name.clone() } else { format!("{at}/{}", child.name) };
                if child.kind == Kind::Dir {
                    folders.push_back((child_index, child_path));
                } else {
                    take(child_index, &child_path, &mut over);
                }
            }
        }
    }
    (planned, over)
}

#[cfg(test)]
#[path = "working_set_tests.rs"]
mod tests;
