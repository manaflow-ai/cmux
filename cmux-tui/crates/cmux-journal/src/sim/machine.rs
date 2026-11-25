//! The simulated machine of `SimStorage` (see `sim.rs`): each file's page cache and disk, the
//! ordered log of names, and what an OS crash or a power loss leaves of them.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};

use super::{Crash, SECTOR, SIM_PAGE, SimRng};
use crate::storage::SyncLevel;

#[derive(Clone)]
pub(super) struct SimFile {
    /// What reads see: the page cache.
    pub(super) data: Vec<u8>,
    /// What the disk holds.
    pub(super) disk: Vec<u8>,
    /// Pages of `data` written since the disk got them.
    pub(super) dirty: BTreeSet<usize>,
    /// The disk content after each good sync, with its machine-wide sync number (for a power
    /// loss). A file the last crash kept starts with its content as sync 0.
    pub(super) synced: Vec<(u64, Vec<u8>)>,
    /// Pages a failed sync dropped: the cache has their bytes, the disk does not, and no later
    /// sync writes them (they are not dirty). An eviction makes reads see the disk's bytes.
    pub(super) dropped: BTreeSet<usize>,
}

impl SimFile {
    pub(super) fn empty() -> Self {
        Self {
            data: Vec::new(),
            disk: Vec::new(),
            dirty: BTreeSet::new(),
            synced: Vec::new(),
            dropped: BTreeSet::new(),
        }
    }

    pub(super) fn kept(content: Vec<u8>) -> Self {
        Self {
            data: content.clone(),
            disk: content.clone(),
            dirty: BTreeSet::new(),
            synced: vec![(0, content)],
            dropped: BTreeSet::new(),
        }
    }

    /// Marks the pages of bytes `start..end` dirty.
    pub(super) fn touch(&mut self, start: usize, end: usize) {
        if start < end {
            for page in start / SIM_PAGE..end.div_ceil(SIM_PAGE) {
                // A dirty page goes to the disk whole at the next sync, dropped bytes included.
                self.dropped.remove(&page);
                self.dirty.insert(page);
            }
        }
    }

    pub(super) fn append(&mut self, bytes: &[u8]) {
        let start = self.data.len();
        self.data.extend_from_slice(bytes);
        self.touch(start, self.data.len());
    }

    /// A shortening or an extension with zeros. The new length reaches the disk with the next
    /// sync (`write_back`); the bytes an extension adds are dirty.
    pub(super) fn set_len(&mut self, len: usize) {
        let old = self.data.len();
        self.data.resize(len, 0);
        self.dirty.retain(|page| page.saturating_mul(SIM_PAGE) < len);
        self.dropped.retain(|page| page.saturating_mul(SIM_PAGE) < len);
        self.touch(old, len);
    }

    /// Writes `pages` of the cache and its length to the disk.
    pub(super) fn write_back(&mut self, pages: &[usize]) {
        self.disk.resize(self.data.len(), 0);
        for page in pages {
            self.dropped.remove(page);
            let start = page.saturating_mul(SIM_PAGE).min(self.data.len());
            let end = start.saturating_add(SIM_PAGE).min(self.data.len());
            if let (Some(dst), Some(src)) =
                (self.disk.get_mut(start..end), self.data.get(start..end))
            {
                dst.copy_from_slice(src);
            }
        }
    }

    /// A sync that completed: every dirty page and the length are on the disk.
    pub(super) fn good_sync(&mut self, number: u64, last_full: u64) {
        let pages: Vec<usize> = self.dirty.iter().copied().collect();
        self.write_back(&pages);
        self.dirty.clear();
        // Only the last content at or before the last full sync can come back after a crash.
        if let Some(keep) = self.synced.iter().rposition(|(sync, _)| *sync <= last_full) {
            self.synced.drain(..keep);
        }
        self.synced.push((number, self.disk.clone()));
    }

    /// A sync that failed: a random part of the dirty pages reached the disk (none, without
    /// `rng`); the cache dropped the rest as clean, so no later sync writes them.
    pub(super) fn failed_sync(&mut self, rng: Option<&mut SimRng>) {
        let pages: Vec<usize> = match rng {
            Some(rng) => self.dirty.iter().copied().filter(|_| rng.coin()).collect(),
            None => Vec::new(),
        };
        self.write_back(&pages);
        let lost: Vec<usize> =
            self.dirty.iter().copied().filter(|page| !pages.contains(page)).collect();
        self.dropped.extend(lost);
        self.dirty.clear();
    }

    /// The kernel evicts the dropped pages that bytes `start..end` touch: later reads see what the
    /// disk holds there (zeros past its end).
    pub(super) fn evict(&mut self, start: usize, end: usize) {
        if start >= end {
            return;
        }
        for page in start / SIM_PAGE..end.div_ceil(SIM_PAGE) {
            if !self.dropped.remove(&page) {
                continue;
            }
            let from = page.saturating_mul(SIM_PAGE).min(self.data.len());
            let to = from.saturating_add(SIM_PAGE).min(self.data.len());
            for at in from..to {
                let disk = self.disk.get(at).copied().unwrap_or(0);
                if let Some(byte) = self.data.get_mut(at) {
                    *byte = disk;
                }
            }
        }
    }

    /// What an OS crash could leave: the cache's dirty pages, and the disk's pages elsewhere
    /// (a page a failed sync dropped never reached the disk).
    pub(super) fn os_view(&self) -> Vec<u8> {
        let mut out = self.data.clone();
        for (page, chunk) in out.chunks_mut(SIM_PAGE).enumerate() {
            if self.dirty.contains(&page) {
                continue;
            }
            let start = page.saturating_mul(SIM_PAGE);
            for (offset, byte) in chunk.iter_mut().enumerate() {
                *byte = self.disk.get(start.saturating_add(offset)).copied().unwrap_or(0);
            }
        }
        out
    }

    /// The content after a crash: `cut` is the power-loss cut (none for an OS crash).
    pub(super) fn after_crash(&self, cut: Option<u64>, rng: &mut SimRng) -> Vec<u8> {
        match cut {
            None => mix(&self.disk, &self.os_view(), rng),
            Some(cut) => {
                let base = self
                    .synced
                    .iter()
                    .rev()
                    .find(|(sync, _)| *sync <= cut)
                    .map(|(_, content)| content.clone())
                    .unwrap_or_default();
                let next = match self.synced.iter().find(|(sync, _)| *sync > cut) {
                    Some((_, content)) => content.clone(),
                    None => self.os_view(),
                };
                mix(&base, &next, rng)
            }
        }
    }
}

/// `old` with some of `new`'s writes: a length between both lengths, and each page that differs
/// whole from `old`, whole from `new`, or `new`'s first sectors over `old`. Bytes past `new`'s end
/// (a shortening that did not reach the disk) stay `old`'s; bytes past both read as zeros.
pub(super) fn mix(old: &[u8], new: &[u8], rng: &mut SimRng) -> Vec<u8> {
    let (short, long) = (old.len().min(new.len()), old.len().max(new.len()));
    let len = short.saturating_add(rng.index(long.saturating_sub(short).saturating_add(1)));
    let old_at = |at: usize| old.get(at).copied().unwrap_or(0);
    let new_at = |at: usize| new.get(at).copied().unwrap_or_else(|| old_at(at));
    let mut out = Vec::with_capacity(len);
    let mut start = 0;
    while start < len {
        let end = start.saturating_add(SIM_PAGE).min(len);
        let differs = (start..end).any(|at| old_at(at) != new_at(at));
        let new_until = match (differs, rng.below(3)) {
            (false, _) | (true, 0) => start,
            (true, 1) => end,
            (true, _) => start.saturating_add(rng.index(SIM_PAGE / SECTOR).saturating_mul(SECTOR)),
        };
        out.extend((start..end).map(|at| if at < new_until { new_at(at) } else { old_at(at) }));
        start = end;
    }
    out
}

/// A change of names, in the order the file system logs it.
#[derive(Clone, Debug)]
pub(super) enum Change {
    Folder(PathBuf),
    Create(PathBuf, u64),
    Rename(PathBuf, PathBuf),
    Remove(PathBuf),
}

impl Change {
    /// Whether the change made or removed an entry of `dir`.
    pub(super) fn in_folder(&self, dir: &Path) -> bool {
        let entry_of = |path: &PathBuf| path.parent() == Some(dir);
        match self {
            Self::Folder(path) | Self::Create(path, _) | Self::Remove(path) => entry_of(path),
            Self::Rename(from, to) => entry_of(from) || entry_of(to),
        }
    }
}

#[derive(Clone, Default)]
pub(super) struct Names {
    pub(super) files: BTreeMap<PathBuf, u64>,
    pub(super) dirs: BTreeSet<PathBuf>,
}

impl Names {
    pub(super) fn apply(&mut self, change: &Change) {
        match change {
            Change::Folder(path) => {
                self.dirs.insert(path.clone());
            }
            Change::Create(path, inode) => {
                self.files.insert(path.clone(), *inode);
            }
            Change::Rename(from, to) => {
                if let Some(inode) = self.files.remove(from) {
                    self.files.insert(to.clone(), inode);
                }
            }
            Change::Remove(path) => {
                self.files.remove(path);
            }
        }
    }
}

/// What a process crash keeps: the cache, the disk and the names.
#[derive(Clone)]
pub(super) struct Machine {
    pub(super) rng: SimRng,
    pub(super) files: BTreeMap<u64, SimFile>,
    pub(super) next_inode: u64,
    /// The names at the last crash (all durable), the changes since, how many of them are
    /// durable, and the names now.
    pub(super) base: Names,
    pub(super) log: Vec<Change>,
    pub(super) durable_changes: usize,
    pub(super) names: Names,
    /// Syncs so far (file and folder), and the number of the last full one.
    pub(super) syncs: u64,
    pub(super) last_full: u64,
}

impl Machine {
    pub(super) fn new(seed: u64) -> Self {
        Self {
            rng: SimRng::new(seed),
            files: BTreeMap::new(),
            next_inode: 1,
            base: Names::default(),
            log: Vec::new(),
            durable_changes: 0,
            names: Names::default(),
            syncs: 0,
            last_full: 0,
        }
    }

    pub(super) fn change(&mut self, change: Change) {
        self.names.apply(&change);
        self.log.push(change);
    }

    pub(super) fn sync_number(&mut self, level: SyncLevel) -> u64 {
        self.syncs = self.syncs.saturating_add(1);
        if level == SyncLevel::Full {
            self.last_full = self.syncs;
        }
        self.syncs
    }

    pub(super) fn sync_folder(&mut self, dir: &Path) {
        if let Some(last) = self.log.iter().rposition(|change| change.in_folder(dir)) {
            self.durable_changes = self.durable_changes.max(last.saturating_add(1));
        }
        // A folder sync flushes the drive like a full sync (FsStorage uses F_FULLFSYNC).
        self.sync_number(SyncLevel::Full);
    }

    pub(super) fn file(&mut self, inode: u64) -> io::Result<&mut SimFile> {
        self.files.get_mut(&inode).ok_or_else(|| io::Error::other("simulated file is gone"))
    }

    /// The machine after an OS crash or a power loss ([module docs](self)).
    pub(super) fn after_crash(&mut self, crash: Crash) -> Self {
        let mut rng = SimRng::new(self.rng.next_u64());
        let unsure = self.log.len().saturating_sub(self.durable_changes);
        let kept = self.durable_changes.saturating_add(rng.index(unsure.saturating_add(1)));
        let mut names = self.base.clone();
        for change in self.log.iter().take(kept) {
            names.apply(change);
        }
        let cut = match crash {
            Crash::Process | Crash::Os => None,
            Crash::PowerLoss => {
                let span = self.syncs.saturating_sub(self.last_full);
                Some(self.last_full.saturating_add(rng.below(span.saturating_add(1))))
            }
        };
        let mut files = BTreeMap::new();
        for inode in names.files.values() {
            if let (false, Some(file)) = (files.contains_key(inode), self.files.get(inode)) {
                files.insert(*inode, SimFile::kept(file.after_crash(cut, &mut rng)));
            }
        }
        Self {
            rng,
            files,
            next_inode: self.next_inode,
            base: names.clone(),
            log: Vec::new(),
            durable_changes: 0,
            names,
            syncs: 0,
            last_full: 0,
        }
    }
}
